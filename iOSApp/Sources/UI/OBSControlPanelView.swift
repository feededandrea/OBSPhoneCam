import SwiftUI

struct OBSControlPanelView: View {
    @EnvironmentObject private var model: IOSAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Control OBS").font(.headline)
            HStack(spacing: 12) {
                ControlButton(title: "Record", systemImage: "record.circle") { Task { await model.sendOBSCommand(.startRecording) } }
                ControlButton(title: "Stream", systemImage: "dot.radiowaves.left.and.right") { Task { await model.sendOBSCommand(.startStreaming) } }
                ControlButton(title: "Replay", systemImage: "scissors") { Task { await model.sendOBSCommand(.saveReplayBuffer) } }
            }
            Text(model.obsStatus.connected ? "OBS conectado" : "OBS vía Mac Hub / esperando estado")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct ControlButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage).font(.title2)
                Text(title).font(.caption.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
    }
}
