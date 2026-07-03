import SwiftUI
import AppKit

struct DeviceListView: View {
    @EnvironmentObject private var model: MacHubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderCard(title: "Dispositivos conectados", subtitle: "\(model.devices.count) iPhone(s) detectados")
            LabeledContent("Receptor iPhone", value: model.isDeviceListenerRunning ? "Escuchando en puerto 7777" : "Detenido")
            LabeledContent("Retorno OBS por cable", value: model.isOBSDownlinkRunning ? "Escuchando en puerto 7778" : "Opcional detenido")
            LabeledContent("Fuente OBS", value: model.isOBSBrowserSourceRunning ? model.obsBrowserSourceURL() : "Detenida")
            HStack {
                Button("Crear fuente en OBS") {
                    Task { await model.installOBSBrowserSource() }
                }
                .disabled(!model.obsStatus.connected)
                Button("Copiar URL OBS") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.obsBrowserSourceURL(), forType: .string)
                }
            }
            if let message = model.obsBrowserSourceMessage {
                Text(message)
                    .foregroundStyle(message.hasPrefix("No se pudo") ? .red : .secondary)
            }
            if let error = model.deviceListenerStatusError {
                Text(error).foregroundStyle(.red)
            }
            if let error = model.obsBrowserSourceError {
                Text(error).foregroundStyle(.red)
            }
            PhonePreviewStrip(frames: model.previewFrames)
            Table(model.devices) {
                TableColumn("Nombre") { Text($0.name) }
                TableColumn("Estado") { Text($0.state.userTitle) }
                TableColumn("FPS") { Text(String(format: "%.1f", $0.metrics.fps)) }
                TableColumn("Latencia") { Text(String(format: "%.0f ms", $0.metrics.latencyMs)) }
                TableColumn("Reconexiones") { Text("\($0.reconnectCount)") }
            }
            .overlay {
                if model.devices.isEmpty {
                    ContentUnavailableView("Sin dispositivos", systemImage: "iphone.slash", description: Text("Abrí la app en el iPhone y conectá contra el Mac Hub."))
                }
            }
        }
        .padding()
    }
}

struct PhonePreviewStrip: View {
    let frames: [String: DevicePreviewFrame]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.headline)
            if frames.isEmpty {
                ContentUnavailableView("Sin video todavía", systemImage: "video.slash", description: Text("Conectá el iPhone físico y dejá la cámara activa."))
                    .frame(height: 220)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(frames.values.sorted { $0.updatedAt > $1.updatedAt }) { frame in
                            DevicePreviewTile(frame: frame)
                        }
                    }
                }
                .frame(height: 260)
            }
        }
    }
}

struct DevicePreviewTile: View {
    @EnvironmentObject private var model: MacHubModel
    let frame: DevicePreviewFrame

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.black
                if let image = NSImage(data: frame.imageData) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                }
            }
            .frame(width: 360, height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack {
                Text("Frame \(frame.sequence)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copiar URL OBS") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.obsBrowserSourceURL(deviceID: frame.deviceID), forType: .string)
                }
                .font(.caption)
                Button("Enviar a OBS") {
                    Task { await model.installOBSBrowserSource(deviceID: frame.deviceID) }
                }
                .font(.caption)
                .disabled(!model.obsStatus.connected)
            }
        }
    }
}

struct HeaderCard: View {
    let title: String
    let subtitle: String
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).font(.largeTitle.bold())
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
