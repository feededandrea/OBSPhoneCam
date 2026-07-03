import Foundation
import Network

private final class ContinuationResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        action()
    }
}

final class NetworkStreamTransport: StreamTransport {
    private let codec = MessageCodec()
    private var connection: NWConnection?
    private var controlConnection: NWConnection?
    private let queue = DispatchQueue(label: "obsphonecam.ios.network")
    private(set) var isConnected: Bool = false
    private var isControlConnected = false
    private var videoFrameSendInFlight = false
    private(set) var activeInterfaceDescription: String = "Sin conexión"
    private(set) var isUsingWiredEthernet = false
    var onOBSState: (@Sendable (OBSStatePacket) -> Void)?
    var onDisconnect: (@Sendable (String?) -> Void)?

    static func canOpenConnection(to endpoint: NWEndpoint, requiredInterfaceType: NWInterface.InterfaceType, timeout: TimeInterval = 1.4) async -> Bool {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.requiredInterfaceType = requiredInterfaceType
        let probe = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "obsphonecam.ios.network.probe")

        return await withCheckedContinuation { continuation in
            let gate = ContinuationResumeGate()
            probe.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    probe.cancel()
                    gate.resume { continuation.resume(returning: true) }
                case .failed:
                    probe.cancel()
                    gate.resume { continuation.resume(returning: false) }
                case .cancelled:
                    gate.resume { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            probe.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                probe.cancel()
                gate.resume { continuation.resume(returning: false) }
            }
        }
    }

    func connect(host: String, port: UInt16) async throws {
        try await connect(host: host, port: port, requiredInterfaceType: nil)
    }

    func connect(host: String, port: UInt16, requiredInterfaceType: NWInterface.InterfaceType? = nil) async throws {
        try await connect(
            to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!),
            requiredInterfaceType: requiredInterfaceType
        )
    }

    func connect(to endpoint: NWEndpoint, requiredInterfaceType: NWInterface.InterfaceType? = nil, timeout: TimeInterval = 2.2) async throws {
        close()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let requiredInterfaceType {
            parameters.requiredInterfaceType = requiredInterfaceType
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationResumeGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.isConnected = true
                    self.isUsingWiredEthernet = connection.currentPath?.usesInterfaceType(.wiredEthernet) == true
                    self.activeInterfaceDescription = connection.currentPath?.routeSummary ?? "Conectado"
                    Task {
                        await AppLogger.shared.log(.info, .transport, "Primary transport ready via \(self.activeInterfaceDescription)")
                    }
                    self.receiveNext(on: connection)
                    self.startControlConnection(to: endpoint, requiredInterfaceType: requiredInterfaceType)
                    gate.resume { continuation.resume() }
                case .failed(let error):
                    self.isConnected = false
                    self.isUsingWiredEthernet = false
                    self.activeInterfaceDescription = "Falló: \(error.localizedDescription)"
                    Task {
                        await AppLogger.shared.log(.error, .transport, "Primary transport failed: \(error.localizedDescription)")
                    }
                    self.onDisconnect?(error.localizedDescription)
                    gate.resume { continuation.resume(throwing: TransportError.sendFailed(error.localizedDescription)) }
                case .waiting(let error):
                    self.activeInterfaceDescription = "Esperando ruta: \(error.localizedDescription)"
                    Task {
                        await AppLogger.shared.log(.warning, .transport, "Primary transport waiting: \(error.localizedDescription)")
                    }
                case .cancelled:
                    self.isConnected = false
                    self.isUsingWiredEthernet = false
                    self.activeInterfaceDescription = "Desconectado"
                    Task {
                        await AppLogger.shared.log(.warning, .transport, "Primary transport cancelled")
                    }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self, weak connection] in
                guard let self, let connection, self.connection === connection, !self.isConnected else { return }
                self.isConnected = false
                self.isUsingWiredEthernet = false
                self.activeInterfaceDescription = "Timeout conectando"
                Task {
                    await AppLogger.shared.log(.error, .transport, "Primary transport timeout connecting to Mac Hub")
                }
                connection.cancel()
                gate.resume {
                    continuation.resume(throwing: TransportError.sendFailed("Timeout conectando con Mac Hub"))
                }
            }
        }
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] lengthData, _, _, error in
            guard let self else { return }
            guard error == nil, let lengthData, lengthData.count == 4 else {
                self.isConnected = false
                self.isUsingWiredEthernet = false
                self.activeInterfaceDescription = error.map { "Falló: \($0.localizedDescription)" } ?? "Desconectado"
                Task {
                    await AppLogger.shared.log(.error, .transport, "Primary receive length failed: \(error?.localizedDescription ?? "empty length")")
                }
                self.onDisconnect?(error?.localizedDescription)
                return
            }

            let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] payloadData, _, _, error in
                guard let self else { return }
                guard error == nil, let payloadData else {
                    self.isConnected = false
                    self.isUsingWiredEthernet = false
                    self.activeInterfaceDescription = error.map { "Falló: \($0.localizedDescription)" } ?? "Desconectado"
                    Task {
                        await AppLogger.shared.log(.error, .transport, "Primary receive payload failed: \(error?.localizedDescription ?? "empty payload")")
                    }
                    self.onDisconnect?(error?.localizedDescription)
                    return
                }

                do {
                    let envelope = try self.codec.decode(PhoneCamEnvelope.self, from: payloadData)
                    if envelope.type == .obsState {
                        let packet = try self.codec.payload(OBSStatePacket.self, from: envelope)
                        self.onOBSState?(packet)
                    }
                } catch {
                    Task {
                        await AppLogger.shared.log(.error, .transport, "Mac message decode failed: \(error.localizedDescription)")
                    }
                }
                self.receiveNext(on: connection)
            }
        }
    }

    func sendHandshake(_ packet: HandshakePacket) async throws {
        try await sendEnvelope(type: .handshake, deviceID: packet.identity.id, payload: packet)
    }

    func sendHeartbeat(_ packet: HeartbeatPacket) async throws {
        try await sendEnvelope(type: .heartbeat, deviceID: packet.deviceID, payload: packet, preferControlConnection: true)
    }

    func sendControl(_ packet: ControlPacket) async throws {
        try await sendEnvelope(type: .control, deviceID: nil, payload: packet, preferControlConnection: true)
    }

    func sendStreamPacket(_ packet: StreamPacket) async throws {
        if packet.codec == .h264 {
            try await sendEnvelope(type: .streamPacket, deviceID: packet.deviceID, payload: packet, timeout: 1.0)
            return
        }

        guard reserveVideoSendSlot() else {
            throw TransportError.sendFailed("Dropping late video frame")
        }
        defer { releaseVideoSendSlot() }
        try await sendEnvelope(type: .streamPacket, deviceID: packet.deviceID, payload: packet)
    }

    private func sendEnvelope<T: Codable>(type: PhoneCamMessageType, deviceID: String?, payload: T, preferControlConnection: Bool = false, timeout: TimeInterval = 2.0) async throws {
        let targetConnection = preferControlConnection && isControlConnected ? controlConnection : connection
        guard let targetConnection else { throw TransportError.disconnected }
        let envelope = try codec.envelope(type, deviceID: deviceID, payload: payload)
        let data = try codec.encode(envelope)
        var length = UInt32(data.count).bigEndian
        let framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size) + data
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationResumeGate()
            targetConnection.send(content: framed, completion: .contentProcessed { error in
                gate.resume {
                    if let error { continuation.resume(throwing: TransportError.sendFailed(error.localizedDescription)) }
                    else { continuation.resume() }
                }
            })
            queue.asyncAfter(deadline: .now() + timeout) {
                gate.resume {
                    continuation.resume(throwing: TransportError.sendFailed("Send timeout after \(String(format: "%.1f", timeout))s"))
                }
            }
        }
    }

    func close() {
        connection?.cancel()
        connection = nil
        controlConnection?.cancel()
        controlConnection = nil
        isConnected = false
        isControlConnected = false
        videoFrameSendInFlight = false
        isUsingWiredEthernet = false
        activeInterfaceDescription = "Sin conexión"
    }

    private func startControlConnection(to endpoint: NWEndpoint, requiredInterfaceType: NWInterface.InterfaceType?) {
        controlConnection?.cancel()
        isControlConnected = false

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let requiredInterfaceType {
            parameters.requiredInterfaceType = requiredInterfaceType
        }

        let controlConnection = NWConnection(to: endpoint, using: parameters)
        self.controlConnection = controlConnection
        controlConnection.stateUpdateHandler = { [weak self, weak controlConnection] state in
            guard let self, let controlConnection, self.controlConnection === controlConnection else { return }
            switch state {
            case .ready:
                self.isControlConnected = true
                Task {
                    await AppLogger.shared.log(.info, .transport, "Control transport ready")
                }
            case .failed, .cancelled:
                self.isControlConnected = false
                Task {
                    await AppLogger.shared.log(.warning, .transport, "Control transport closed")
                }
            default:
                break
            }
        }
        controlConnection.start(queue: queue)
    }

    private func reserveVideoSendSlot() -> Bool {
        var reserved = false
        queue.sync {
            if !videoFrameSendInFlight {
                videoFrameSendInFlight = true
                reserved = true
            }
        }
        return reserved
    }

    private func releaseVideoSendSlot() {
        queue.async { [weak self] in
            self?.videoFrameSendInFlight = false
        }
    }
}

final class OBSWiredDownlinkClient {
    private let codec = MessageCodec()
    private let queue = DispatchQueue(label: "obsphonecam.ios.obs-wired-downlink")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var reconnectTask: DispatchWorkItem?
    private(set) var isConnected = false
    private(set) var activeInterfaceDescription = "Sin retorno por cable"
    var onOBSState: (@Sendable (OBSStatePacket) -> Void)?
    var onStateChange: (@Sendable (String, Bool) -> Void)?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.requiredInterfaceType = .wiredEthernet

        let browser = NWBrowser(for: .bonjour(type: "_obsphonecam-obs._tcp", domain: "local."), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.publishState("Buscando retorno por cable", false)
            case .failed(let error):
                self?.publishState("Retorno cable falló: \(error.localizedDescription)", false)
                self?.restartBrowserAfterDelay()
            case .cancelled:
                self?.publishState("Sin retorno por cable", false)
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let endpoint = results.first?.endpoint else { return }
            self?.connect(to: endpoint)
        }

        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        publishState("Sin retorno por cable", false)
    }

    private func connect(to endpoint: NWEndpoint) {
        guard !isConnected else { return }
        connection?.cancel()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.requiredInterfaceType = .wiredEthernet

        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.isConnected = true
                self.activeInterfaceDescription = connection.currentPath?.routeSummary ?? "Retorno por cable"
                self.publishState(self.activeInterfaceDescription, true)
                self.receiveNext(on: connection)
            case .failed(let error):
                self.connectionDidClose("Retorno cable falló: \(error.localizedDescription)")
            case .cancelled:
                self.connectionDidClose("Sin retorno por cable")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak connection] lengthData, _, _, error in
            guard let self, let connection else { return }
            guard error == nil, let lengthData, lengthData.count == 4 else {
                self.connectionDidClose(error.map { "Retorno cable falló: \($0.localizedDescription)" } ?? "Sin retorno por cable")
                return
            }

            let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self, weak connection] payloadData, _, _, error in
                guard let self, let connection else { return }
                guard error == nil, let payloadData else {
                    self.connectionDidClose(error.map { "Retorno cable falló: \($0.localizedDescription)" } ?? "Sin retorno por cable")
                    return
                }

                do {
                    let envelope = try self.codec.decode(PhoneCamEnvelope.self, from: payloadData)
                    if envelope.type == .obsState {
                        let packet = try self.codec.payload(OBSStatePacket.self, from: envelope)
                        self.onOBSState?(packet)
                    }
                } catch {
                    Task {
                        await AppLogger.shared.log(.error, .transport, "OBS wired downlink decode failed: \(error.localizedDescription)")
                    }
                }
                self.receiveNext(on: connection)
            }
        }
    }

    private func connectionDidClose(_ description: String) {
        connection?.cancel()
        connection = nil
        publishState(description, false)
    }

    private func restartBrowserAfterDelay() {
        reconnectTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.browser?.cancel()
            self?.browser = nil
            self?.start()
        }
        reconnectTask = task
        queue.asyncAfter(deadline: .now() + 1.5, execute: task)
    }

    private func publishState(_ description: String, _ connected: Bool) {
        isConnected = connected
        activeInterfaceDescription = description
        onStateChange?(description, connected)
    }
}

private extension NWPath {
    var routeSummary: String {
        if usesInterfaceType(.wiredEthernet) { return "Cable/Ethernet" }
        if usesInterfaceType(.wifi) { return "Wi-Fi" }
        if usesInterfaceType(.cellular) { return "Celular" }
        if usesInterfaceType(.loopback) { return "Loopback" }
        return "Ruta activa"
    }
}
