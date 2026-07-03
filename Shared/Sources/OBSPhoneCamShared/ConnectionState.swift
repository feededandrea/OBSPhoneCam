import Foundation

public enum ConnectionState: String, Codable, Sendable, CaseIterable, Equatable {
    case disconnected
    case connecting
    case handshaking
    case streaming
    case degraded
    case reconnecting
    case failed

    public var isRecoverable: Bool {
        switch self {
        case .disconnected, .degraded, .reconnecting, .failed: return true
        case .connecting, .handshaking, .streaming: return false
        }
    }

    public var userTitle: String {
        switch self {
        case .disconnected: return "Desconectado"
        case .connecting: return "Conectando"
        case .handshaking: return "Validando"
        case .streaming: return "Transmitiendo"
        case .degraded: return "Señal degradada"
        case .reconnecting: return "Reconectando"
        case .failed: return "Error"
        }
    }
}

public struct DeviceSessionSnapshot: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var state: ConnectionState
    public var metrics: StreamMetrics
    public var lastHeartbeat: Date?
    public var reconnectCount: Int

    public init(id: String, name: String, state: ConnectionState = .disconnected, metrics: StreamMetrics = .empty, lastHeartbeat: Date? = nil, reconnectCount: Int = 0) {
        self.id = id
        self.name = name
        self.state = state
        self.metrics = metrics
        self.lastHeartbeat = lastHeartbeat
        self.reconnectCount = reconnectCount
    }
}
