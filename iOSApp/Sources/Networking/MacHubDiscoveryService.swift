import Foundation
import Network

@MainActor
final class MacHubDiscoveryService: ObservableObject {
    @Published private(set) var isSearching = false
    @Published private(set) var discoveredHubName: String?
    @Published private(set) var lastError: String?

    var onEndpointFound: ((NWEndpoint, String) -> Void)?
    var requiredInterfaceType: NWInterface.InterfaceType?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "obsphonecam.ios.mac-hub.discovery")

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let requiredInterfaceType {
            parameters.requiredInterfaceType = requiredInterfaceType
        }

        let browser = NWBrowser(
            for: .bonjour(type: "_obsphonecam._tcp", domain: "local."),
            using: parameters
        )

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isSearching = true
                    self.lastError = nil
                case .failed(let error):
                    self.isSearching = false
                    self.lastError = error.localizedDescription
                    self.stop()
                case .cancelled:
                    self.isSearching = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let result = results.first else { return }
            let endpoint = result.endpoint
            let name = endpoint.displayName
            Task { @MainActor in
                self?.discoveredHubName = name
                self?.lastError = nil
                self?.onEndpointFound?(endpoint, name)
            }
        }

        self.browser = browser
        isSearching = true
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }
}

private extension NWEndpoint {
    var displayName: String {
        switch self {
        case .service(let name, _, _, _):
            return name
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return "Mac Hub"
        }
    }
}
