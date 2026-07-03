import SwiftUI

struct ClipControlsView: View {
    @EnvironmentObject private var model: IOSAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clips").font(.headline)
            HStack {
                Button("Marcar momento") { Task { await model.sendOBSCommand(.markClip) } }
                Button("Guardar últimos 30s") { Task { await model.sendOBSCommand(.saveReplayBuffer) } }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
