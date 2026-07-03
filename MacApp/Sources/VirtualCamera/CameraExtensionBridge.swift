import Foundation
import Combine

@MainActor
final class CameraExtensionBridge: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var message = "No verificado"

    func refreshStatus() {
        // TODO: consultar SystemExtensionManager/CMIOExtension runtime.
        installed = false
        message = "Instalación pendiente o no autorizada por macOS"
    }
}
