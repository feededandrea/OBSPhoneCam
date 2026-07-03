import SwiftUI

struct ClipLibraryView: View {
    @EnvironmentObject private var model: MacHubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderCard(title: "Clips", subtitle: "Replay Buffer y clips preparados")
            List(model.clips) { clip in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: clip.isInstagramReady ? "film.fill" : "scissors")
                        .font(.title3)
                        .foregroundStyle(clip.isInstagramReady ? .green : .secondary)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(clip.label).font(.headline)
                        Text(clip.filePath).foregroundStyle(.secondary).lineLimit(2)
                        HStack(spacing: 10) {
                            Text(clip.createdAt.formatted()).font(.caption)
                            if let duration = clip.durationSeconds {
                                Text("\(duration, specifier: "%.0f")s").font(.caption)
                            }
                            if let scene = clip.sceneName {
                                Text(scene).font(.caption)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        Task { await model.prepareInstagramDraft(for: clip) }
                    } label: {
                        Label("Instagram", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(clip.filePath.hasPrefix("OBS Replay Buffer"))
                }
            }
            .overlay {
                if model.clips.isEmpty {
                    ContentUnavailableView("Sin clips", systemImage: "scissors", description: Text("Usá Guardar replay desde iPhone o Mac."))
                }
            }
            if !model.instagramDrafts.isEmpty || model.instagramService.lastMessage != nil {
                Divider()
                Text("Instagram")
                    .font(.headline)
                if let message = model.instagramService.lastMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.instagramDrafts) { draft in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.clip.label).font(.subheadline.bold())
                        Text(draft.caption).font(.caption).foregroundStyle(.secondary)
                        Text(draft.clip.filePath).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding()
    }
}
