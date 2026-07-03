import SwiftUI

struct DeviceStatusView: View {
    @EnvironmentObject private var model: IOSAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.identity.displayName).font(.title2.bold())
                    Text(model.identity.id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                StatusPill(title: model.connectionState.userTitle, state: model.connectionState)
            }
            if let error = model.lastError {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
            HStack {
                MetricTile(title: "Calidad", value: model.selectedQuality.title)
                MetricTile(title: "Modo", value: model.streamMode == .lowLatency ? "Baja latencia" : "Estable")
            }
            HStack {
                MetricTile(title: "Transporte", value: model.cableOnlyMode ? "Solo cable" : "Auto")
                MetricTile(title: "Ruta", value: model.activeTransportDescription)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct StatusPill: View {
    let title: String
    let state: ConnectionState
    var body: some View {
        Text(title)
            .font(.caption.bold())
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(color.opacity(0.22), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.65), lineWidth: 1))
    }
    private var color: Color {
        switch state {
        case .streaming: return .green
        case .degraded, .reconnecting, .connecting, .handshaking: return .yellow
        case .failed, .disconnected: return .red
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
