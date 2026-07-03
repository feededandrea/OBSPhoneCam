import SwiftUI

struct OBSConnectionView: View {
    @EnvironmentObject private var model: MacHubModel

    var body: some View {
        Form {
            Section("OBS WebSocket") {
                TextField("Host", text: $model.obsConfig.host)
                Text("Si OBS corre en esta misma Mac, usá 127.0.0.1. La IP LAN sirve para otros equipos de la red.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("Puerto: \(model.obsConfig.port)", value: $model.obsConfig.port, in: 1024...65535)
                SecureField("Password", text: $model.obsConfig.password)
                Button("Probar conexión") { Task { await model.connectOBS() } }
            }
            Section("Fuente de video") {
                LabeledContent("Tipo", value: "Plugin nativo de OBS")
                LabeledContent("Nombre", value: "OBS Phone Cam")
                if let message = model.obsBrowserSourceMessage {
                    Text(message)
                        .foregroundStyle(message.hasPrefix("No se pudo") ? .red : .secondary)
                }
                Text("En OBS: + > OBS Phone Cam. La app Mac publica el último frame recibido en /tmp/obsphonecam-framebuffer.bin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Estado") {
                LabeledContent("Conectado", value: model.obsStatus.connected ? "Sí" : "No")
                LabeledContent("Escena", value: model.obsStatus.currentScene ?? "Sin dato")
                LabeledContent("Grabando", value: model.obsStatus.recording ? "Sí" : "No")
                LabeledContent("Streaming", value: model.obsStatus.streaming ? "Sí" : "No")
                LabeledContent("Replay Buffer", value: replayBufferText)
                if let error = model.obsStatus.lastError { Text(error).foregroundStyle(.red) }
            }
        }
        .padding()
        .navigationTitle("OBS")
    }

    private var replayBufferText: String {
        guard model.obsStatus.replayBufferAvailable else { return "No disponible" }
        return model.obsStatus.replayBufferActive ? "Activo" : "Disponible, detenido"
    }
}
