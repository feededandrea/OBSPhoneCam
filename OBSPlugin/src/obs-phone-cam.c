#include <obs-module.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define OPC_MAGIC 0x3143504FU
#define OPC_HEADER_SIZE 64U
#define OPC_DEFAULT_WIDTH 1920U
#define OPC_DEFAULT_HEIGHT 1080U
#define OPC_DEFAULT_PATH "/tmp/obsphonecam-framebuffer.shm"

OBS_DECLARE_MODULE()
OBS_MODULE_AUTHOR("OBSPhoneCam")

struct opc_header {
	uint32_t magic;
	uint32_t version;
	uint32_t header_size;
	uint32_t width;
	uint32_t height;
	uint32_t bytes_per_row;
	uint64_t sequence;
	uint64_t timestamp_nanos;
	uint64_t payload_size;
	uint64_t reserved0;
	uint64_t reserved1;
};

struct opc_source {
	obs_source_t *source;
	char path[PATH_MAX];
	uint8_t *pixels;
	size_t pixel_capacity;
	uint32_t width;
	uint32_t height;
	uint64_t last_sequence;
	bool show_test_pattern;
	float fallback_phase;
	uint8_t *fallback_pixels;
	size_t fallback_capacity;
	int fd;
	void *mapped;
	size_t mapped_size;
};

enum opc_frame_status {
	OPC_FRAME_ERROR,
	OPC_FRAME_UNCHANGED,
	OPC_FRAME_LOADED,
};

static uint64_t opc_now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static const char *opc_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return "OBS Phone Cam";
}

static void opc_defaults(obs_data_t *settings)
{
	obs_data_set_default_string(settings, "framebuffer_path", OPC_DEFAULT_PATH);
	obs_data_set_default_bool(settings, "show_test_pattern", false);
}

static obs_properties_t *opc_properties(void *data)
{
	UNUSED_PARAMETER(data);
	obs_properties_t *props = obs_properties_create();
	obs_properties_add_text(props, "framebuffer_path", "Shared memory path", OBS_TEXT_DEFAULT);
	obs_properties_add_bool(props, "show_test_pattern", "Show test pattern when no iPhone frame exists");
	return props;
}

static void opc_close_mapping(struct opc_source *ctx)
{
	if (!ctx)
		return;

	if (ctx->mapped && ctx->mapped != MAP_FAILED) {
		munmap(ctx->mapped, ctx->mapped_size);
		ctx->mapped = NULL;
		ctx->mapped_size = 0;
	}

	if (ctx->fd >= 0) {
		close(ctx->fd);
		ctx->fd = -1;
	}
}

static void opc_update(void *data, obs_data_t *settings)
{
	struct opc_source *ctx = data;
	const char *path = obs_data_get_string(settings, "framebuffer_path");
	if (!path || !*path)
		path = OPC_DEFAULT_PATH;

	if (strncmp(ctx->path, path, sizeof(ctx->path)) != 0) {
		opc_close_mapping(ctx);
		snprintf(ctx->path, sizeof(ctx->path), "%s", path);
	}
	ctx->show_test_pattern = obs_data_get_bool(settings, "show_test_pattern");
}

static void *opc_create(obs_data_t *settings, obs_source_t *source)
{
	struct opc_source *ctx = calloc(1, sizeof(*ctx));
	if (!ctx)
		return NULL;

	ctx->source = source;
	ctx->width = OPC_DEFAULT_WIDTH;
	ctx->height = OPC_DEFAULT_HEIGHT;
	ctx->fd = -1;
	snprintf(ctx->path, sizeof(ctx->path), "%s", OPC_DEFAULT_PATH);
	opc_update(ctx, settings);

	blog(LOG_INFO, "[obs-phone-cam] Source created, reading %s", ctx->path);
	return ctx;
}

static void opc_destroy(void *data)
{
	struct opc_source *ctx = data;
	if (!ctx)
		return;

	free(ctx->pixels);
	free(ctx->fallback_pixels);
	opc_close_mapping(ctx);
	free(ctx);
}

static bool opc_read_exact(int fd, void *buffer, size_t size)
{
	uint8_t *cursor = buffer;
	size_t remaining = size;

	while (remaining > 0) {
		ssize_t read_count = read(fd, cursor, remaining);
		if (read_count == 0)
			return false;
		if (read_count < 0) {
			if (errno == EINTR)
				continue;
			return false;
		}
		cursor += read_count;
		remaining -= (size_t)read_count;
	}

	return true;
}

static bool opc_ensure_capacity(uint8_t **buffer, size_t *capacity, size_t needed)
{
	if (*capacity >= needed)
		return true;

	uint8_t *new_buffer = realloc(*buffer, needed);
	if (!new_buffer)
		return false;

	*buffer = new_buffer;
	*capacity = needed;
	return true;
}

static enum opc_frame_status opc_load_frame(struct opc_source *ctx)
{
	if (ctx->fd < 0) {
		ctx->fd = open(ctx->path, O_RDONLY);
		if (ctx->fd < 0)
			return OPC_FRAME_ERROR;
	}

	struct stat st;
	if (fstat(ctx->fd, &st) != 0 || st.st_size < (off_t)OPC_HEADER_SIZE) {
		opc_close_mapping(ctx);
		return OPC_FRAME_ERROR;
	}

	if (!ctx->mapped || ctx->mapped_size != (size_t)st.st_size) {
		if (ctx->mapped && ctx->mapped != MAP_FAILED)
			munmap(ctx->mapped, ctx->mapped_size);

		ctx->mapped = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, ctx->fd, 0);
		if (ctx->mapped == MAP_FAILED) {
			ctx->mapped = NULL;
			ctx->mapped_size = 0;
			opc_close_mapping(ctx);
			return OPC_FRAME_ERROR;
		}
		ctx->mapped_size = (size_t)st.st_size;
	}

	struct opc_header *mapped_header = (struct opc_header *)ctx->mapped;
	__sync_synchronize();
	const uint64_t generation_before = mapped_header->reserved0;
	if ((generation_before & 1ULL) != 0)
		return OPC_FRAME_UNCHANGED;

	struct opc_header header = *mapped_header;
	if (header.magic != OPC_MAGIC || header.version != 1 || header.header_size != OPC_HEADER_SIZE ||
	    header.width == 0 || header.height == 0 || header.bytes_per_row < header.width * 4 ||
	    header.payload_size == 0 || header.payload_size > 64ULL * 1024ULL * 1024ULL) {
		return OPC_FRAME_ERROR;
	}

	if (header.sequence == ctx->last_sequence) {
		return OPC_FRAME_UNCHANGED;
	}

	const uint64_t expected_min = (uint64_t)header.bytes_per_row * (uint64_t)header.height;
	if (header.payload_size < expected_min || ctx->mapped_size < (size_t)(header.header_size + header.payload_size)) {
		return OPC_FRAME_ERROR;
	}

	if (!opc_ensure_capacity(&ctx->pixels, &ctx->pixel_capacity, (size_t)header.payload_size)) {
		return OPC_FRAME_ERROR;
	}

	memcpy(ctx->pixels, (uint8_t *)ctx->mapped + header.header_size, (size_t)header.payload_size);
	__sync_synchronize();
	const uint64_t generation_after = ((struct opc_header *)ctx->mapped)->reserved0;
	if (generation_before != generation_after || (generation_after & 1ULL) != 0)
		return OPC_FRAME_UNCHANGED;

	ctx->width = header.width;
	ctx->height = header.height;
	ctx->last_sequence = header.sequence;

	struct obs_source_frame frame = {0};
	frame.data[0] = ctx->pixels;
	frame.linesize[0] = header.bytes_per_row;
	frame.width = header.width;
	frame.height = header.height;
	frame.timestamp = opc_now_ns();
	frame.format = VIDEO_FORMAT_BGRA;
	frame.full_range = true;

	obs_source_output_video(ctx->source, &frame);
	return OPC_FRAME_LOADED;
}

static void opc_output_fallback(struct opc_source *ctx)
{
	const uint32_t width = OPC_DEFAULT_WIDTH;
	const uint32_t height = OPC_DEFAULT_HEIGHT;
	const uint32_t stride = width * 4;
	const size_t needed = (size_t)stride * height;

	if (!opc_ensure_capacity(&ctx->fallback_pixels, &ctx->fallback_capacity, needed))
		return;

	ctx->fallback_phase += 1.0f;
	const uint32_t band = (uint32_t)ctx->fallback_phase % width;

	for (uint32_t y = 0; y < height; y++) {
		uint8_t *row = ctx->fallback_pixels + (size_t)y * stride;
		for (uint32_t x = 0; x < width; x++) {
			const bool stripe = ((x + band) / 80U) % 2U == 0U;
			const size_t offset = (size_t)x * 4U;
			row[offset + 0] = stripe ? 42 : 14;
			row[offset + 1] = stripe ? 170 : 92;
			row[offset + 2] = stripe ? 120 : 34;
			row[offset + 3] = 255;
		}
	}

	ctx->width = width;
	ctx->height = height;

	struct obs_source_frame frame = {0};
	frame.data[0] = ctx->fallback_pixels;
	frame.linesize[0] = stride;
	frame.width = width;
	frame.height = height;
	frame.timestamp = opc_now_ns();
	frame.format = VIDEO_FORMAT_BGRA;
	frame.full_range = true;

	obs_source_output_video(ctx->source, &frame);
}

static void opc_tick(void *data, float seconds)
{
	UNUSED_PARAMETER(seconds);
	struct opc_source *ctx = data;

	const enum opc_frame_status status = opc_load_frame(ctx);
	if (status == OPC_FRAME_LOADED || status == OPC_FRAME_UNCHANGED)
		return;

	if (ctx->show_test_pattern && ctx->last_sequence == 0)
		opc_output_fallback(ctx);
}

static uint32_t opc_width(void *data)
{
	struct opc_source *ctx = data;
	return ctx && ctx->width ? ctx->width : OPC_DEFAULT_WIDTH;
}

static uint32_t opc_height(void *data)
{
	struct opc_source *ctx = data;
	return ctx && ctx->height ? ctx->height : OPC_DEFAULT_HEIGHT;
}

static struct obs_source_info opc_source_info = {
	.id = "obs_phone_cam_source",
	.type = OBS_SOURCE_TYPE_INPUT,
	.output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_DO_NOT_DUPLICATE,
	.get_name = opc_get_name,
	.create = opc_create,
	.destroy = opc_destroy,
	.get_width = opc_width,
	.get_height = opc_height,
	.get_defaults = opc_defaults,
	.get_properties = opc_properties,
	.update = opc_update,
	.video_tick = opc_tick,
	.icon_type = OBS_ICON_TYPE_CAMERA,
};

bool obs_module_load(void)
{
	obs_register_source(&opc_source_info);
	blog(LOG_INFO, "[obs-phone-cam] Native OBS source loaded");
	return true;
}

const char *obs_module_description(void)
{
	return "OBS Phone Cam native source";
}
