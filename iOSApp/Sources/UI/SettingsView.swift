import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: IOSAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ajustes").font(.headline)
            TextField("Mac host", text: $model.macHost)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .onChange(of: model.macHost) { _, _ in
                    model.useManualMacSettings()
                }
            Stepper("Puerto: \(model.macPort)", value: $model.macPort, in: 1024...65535)
                .onChange(of: model.macPort) { _, _ in
                    model.useManualMacSettings()
                }
            Picker("Calidad", selection: $model.selectedQuality) {
                ForEach(StreamQuality.allCases) { quality in Text(quality.title).tag(quality) }
            }
            .onChange(of: model.selectedQuality) { _, newValue in
                Task { await model.applyQuality(newValue) }
            }
            Picker("Modo", selection: $model.streamMode) {
                Text("Baja latencia").tag(StreamMode.lowLatency)
                Text("Estabilidad").tag(StreamMode.stability)
            }
            Toggle("Solo cable", isOn: $model.cableOnlyMode)
                .onChange(of: model.cableOnlyMode) { _, newValue in
                    model.setCableOnlyMode(newValue)
                    Task { await model.restartConnection() }
                }
            Text("Transporte: \(model.activeTransportDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
