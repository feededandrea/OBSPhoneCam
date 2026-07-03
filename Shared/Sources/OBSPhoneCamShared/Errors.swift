import Foundation

public protocol UserPresentableError: LocalizedError, Sendable {
    var technicalDescription: String { get }
    var userMessage: String { get }
    var suggestedAction: String { get }
}

public enum CameraError: UserPresentableError {
    case permissionDenied
    case configurationFailed(String)
    case captureFailed(String)

    public var technicalDescription: String { String(describing: self) }
    public var userMessage: String {
        switch self {
        case .permissionDenied: return "La cámara o el micrófono no tienen permisos."
        case .configurationFailed: return "No se pudo configurar la cámara."
        case .captureFailed: return "Falló la captura de video/audio."
        }
    }
    public var suggestedAction: String { "Revisá permisos y reiniciá la sesión de cámara." }
    public var errorDescription: String? { userMessage }
}

public enum TransportError: UserPresentableError {
    case disconnected
    case heartbeatTimeout
    case sendFailed(String)
    case receiveFailed(String)

    public var technicalDescription: String { String(describing: self) }
    public var userMessage: String {
        switch self {
        case .disconnected: return "Se perdió la conexión con la Mac."
        case .heartbeatTimeout: return "La conexión dejó de responder."
        case .sendFailed: return "No se pudo enviar información."
        case .receiveFailed: return "No se pudo recibir información."
        }
    }
    public var suggestedAction: String { "La app va a intentar reconectar automáticamente. Si no vuelve, tocá Reiniciar conexión." }
    public var errorDescription: String? { userMessage }
}

public enum OBSWebSocketError: UserPresentableError {
    case invalidURL
    case notConnected
    case authenticationRequired
    case authenticationFailed
    case requestFailed(String)

    public var technicalDescription: String { String(describing: self) }
    public var userMessage: String {
        switch self {
        case .invalidURL: return "La dirección de OBS no es válida."
        case .notConnected: return "OBS no está conectado."
        case .authenticationRequired: return "OBS requiere password."
        case .authenticationFailed: return "No se pudo autenticar con OBS."
        case .requestFailed(let detail): return "OBS rechazó el comando: \(detail)"
        }
    }
    public var suggestedAction: String { "Revisá que OBS esté abierto, WebSocket habilitado y password correcto." }
    public var errorDescription: String? { userMessage }
}

public enum InstagramPublishingError: UserPresentableError {
    case notConfigured
    case apiNotAvailableForAccount
    case uploadFailed(String)

    public var technicalDescription: String { String(describing: self) }
    public var userMessage: String {
        switch self {
        case .notConfigured: return "Instagram no está configurado."
        case .apiNotAvailableForAccount: return "La API oficial no permite esta acción para esta cuenta o permiso."
        case .uploadFailed: return "Falló la subida a Instagram."
        }
    }
    public var suggestedAction: String { "Exportá el clip y subilo manualmente o configurá Meta Developer/OAuth." }
    public var errorDescription: String? { userMessage }
}
