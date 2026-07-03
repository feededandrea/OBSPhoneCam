import Foundation

/// Abstracción intencional: iOS no expone una API pública general para abrir un stream USB arbitrario app-to-Mac.
/// Este tipo permite elegir la mejor ruta disponible sin acoplar la app a APIs privadas.
final class USBPreferredTransport {
    enum Route: String {
        case localNetwork
        case usbNetworkInterface
        case manualHost
    }

    var selectedRoute: Route = .localNetwork

    func resolveHost(defaultHost: String) -> String {
        // Futuro: detectar Bonjour o interfaz de red disponible por USB/tethering.
        defaultHost
    }
}
