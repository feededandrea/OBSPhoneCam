import SwiftUI

struct VirtualCameraView: View {
    @EnvironmentObject private var model: MacHubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderCard(title: "Fuente nativa OBS", subtitle: model.virtualCameraManager.statusText)
            Text("El camino activo usa un plugin nativo de OBS, sin Camera Extension de Apple. Reiniciá OBS y agregá una fuente llamada `OBS Phone Cam`.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Revisar plugin") {
                    model.virtualCameraManager.activate()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
