import Foundation

enum IOSOBSCommand: String, CaseIterable, Identifiable {
    case refreshStatus
    case switchScene
    case startRecord
    case stopRecord
    case startStream
    case stopStream
    case saveReplay

    var id: String { rawValue }
    var title: String {
        switch self {
        case .refreshStatus: return "Actualizar"
        case .switchScene: return "Cambiar escena"
        case .startRecord: return "Grabar"
        case .stopRecord: return "Parar grabación"
        case .startStream: return "Live"
        case .stopStream: return "Cortar live"
        case .saveReplay: return "Guardar clip"
        }
    }
}
