import Foundation
import AVFoundation

final class PreviewFrameStreamer: @unchecked Sendable {
    private let deviceID: String
    private let transport: NetworkStreamTransport
    private let encoder: StreamEncoder
    private let lock = NSLock()

    private var sequence: UInt64 = 0
    private var windowStartedAt = Date()
    private var windowFrameCount = 0
    private var windowByteCount = 0
    private var lastMetrics = StreamMetrics.empty
    private var droppedFrames = 0
    private var configuredQuality: StreamQuality = .max1080p40
    private var configuredMode: StreamMode = .lowLatency
    private var frameInFlight = false
    private var frameInFlightStartedAt: Date?
    private var pipelineStallCount = 0
    private var maxFramePipelineAge: TimeInterval {
        switch configuredMode {
        case .lowLatency:
            return configuredQuality == .max1080p40 ? 0.45 : 0.65
        case .stability:
            return 0.9
        }
    }

    init(deviceID: String, transport: NetworkStreamTransport, targetFPS _: Double = 30) {
        self.deviceID = deviceID
        self.transport = transport
        self.encoder = StreamEncoder(configuration: .init(quality: .max1080p40, mode: .lowLatency))
        encoder.setOutputHandler { [weak self] frame in
            self?.sendEncodedFrame(frame)
        }
        encoder.setFailureHandler { [weak self] in
            self?.releaseFramePipeline(recordDrop: true)
        }
        try? encoder.configure(.init(quality: .max1080p40, mode: .lowLatency))
    }

    func configure(quality: StreamQuality, mode: StreamMode = .lowLatency) {
        lock.lock()
        configuredQuality = quality
        configuredMode = mode
        lock.unlock()

        do {
            try encoder.configure(.init(quality: quality, mode: mode))
        } catch {
            Task {
                await AppLogger.shared.log(.error, .transport, "H.264 encoder configure failed: \(error.localizedDescription)", deviceID: deviceID)
            }
        }
    }

    func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard transport.isConnected else { return }
        guard reserveFramePipeline() else {
            recordDroppedFrame()
            return
        }
        guard encoder.encode(sampleBuffer: sampleBuffer) else {
            releaseFramePipeline(recordDrop: true)
            return
        }
    }

    func metrics() -> StreamMetrics {
        lock.lock()
        defer { lock.unlock() }

        let elapsed = max(Date().timeIntervalSince(windowStartedAt), 0.001)
        lastMetrics = StreamMetrics(
            fps: Double(windowFrameCount) / elapsed,
            bitrate: Double(windowByteCount * 8) / elapsed,
            droppedFrames: droppedFrames,
            latencyMs: 0,
            audioSyncWarnings: 0,
            uptimeSeconds: Date().timeIntervalSince(windowStartedAt)
        )
        windowStartedAt = Date()
        windowFrameCount = 0
        windowByteCount = 0
        droppedFrames = 0
        return lastMetrics
    }

    func resetPipeline(reason: String) {
        lock.lock()
        frameInFlight = false
        frameInFlightStartedAt = nil
        pipelineStallCount = 0
        lock.unlock()

        do {
            try encoder.reset()
            Task {
                await AppLogger.shared.log(.warning, .encoder, "Encoder pipeline reset: \(reason)", deviceID: deviceID)
            }
        } catch {
            Task {
                await AppLogger.shared.log(.error, .encoder, "Encoder reset failed after \(reason): \(error.localizedDescription)", deviceID: deviceID)
            }
        }
    }

    private func sendEncodedFrame(_ frame: StreamEncoder.EncodedFrame) {
        guard transport.isConnected else {
            recordDroppedFrame()
            releaseFramePipeline(recordDrop: false)
            return
        }

        let packet = StreamPacket(
            deviceID: deviceID,
            sequence: nextSequenceNumber(),
            presentationTime: frame.presentationTime,
            kind: frame.isKeyframe ? .videoKeyframe : .videoDelta,
            data: frame.data,
            codec: .h264
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                try await transport.sendStreamPacket(packet)
                self.recordSentFrame(byteCount: packet.data.count)
            } catch {
                self.recordDroppedFrame()
                if !error.localizedDescription.contains("Dropping late video frame") {
                    await AppLogger.shared.log(.error, .transport, "H.264 frame send failed: \(error.localizedDescription)", deviceID: deviceID)
                }
            }
            self.releaseFramePipeline(recordDrop: false)
        }
    }

    private func nextSequenceNumber() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        return sequence
    }

    private func recordSentFrame(byteCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        windowFrameCount += 1
        windowByteCount += byteCount
    }

    private func recordDroppedFrame() {
        lock.lock()
        defer { lock.unlock() }
        droppedFrames += 1
    }

    private func reserveFramePipeline() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let allowedAge = maxFramePipelineAge
        if frameInFlight,
           let frameInFlightStartedAt,
           Date().timeIntervalSince(frameInFlightStartedAt) > allowedAge {
            frameInFlight = false
            self.frameInFlightStartedAt = nil
            pipelineStallCount += 1
            Task {
                await AppLogger.shared.log(.error, .encoder, "Frame pipeline was stuck for >\(String(format: "%.2f", allowedAge))s; releasing stale in-flight frame", deviceID: deviceID)
            }
        }
        guard !frameInFlight else { return false }
        frameInFlight = true
        frameInFlightStartedAt = Date()
        return true
    }

    private func releaseFramePipeline(recordDrop: Bool) {
        lock.lock()
        frameInFlight = false
        frameInFlightStartedAt = nil
        if recordDrop {
            droppedFrames += 1
        }
        lock.unlock()
    }
}
