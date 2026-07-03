import Combine
import Foundation

@MainActor
final class VirtualCameraManager: NSObject, ObservableObject {
    @Published private(set) var isAvailable = true
    @Published private(set) var statusText = "Usá el plugin nativo de OBS: Fuente > OBS Phone Cam"
    @Published private(set) var needsUserApproval = false

    func checkAvailability() {
        statusText = "Plugin instalado en OBS. Reiniciá OBS y agregá la fuente OBS Phone Cam."
        AppLogger.shared.log(.info, .virtualCamera, statusText)
    }

    func installOrOpenInstructions() {
        checkAvailability()
    }

    func activate() {
        checkAvailability()
    }
}
