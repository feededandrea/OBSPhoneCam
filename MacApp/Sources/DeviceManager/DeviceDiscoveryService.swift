import Foundation
import Network
import Combine

@MainActor
final class DeviceDiscoveryService: ObservableObject {
    @Published private(set) var isAdvertising = false
    @Published private(set) var lastError: String?
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var obsStateSendInFlight: Set<UUID> = []
    private var pendingOBSStatePackets: [UUID: OBSStatePacket] = [:]
    private let manager: ConnectedDeviceManager
    private let codec = MessageCodec()

    init(manager: ConnectedDeviceManager) {
        self.manager = manager
        self.manager.onForceReconnectConnection = { [weak self] connectionID in
            Task { @MainActor in
                self?.close(connectionID: connectionID, reason: "zero-FPS watchdog")
            }
        }
    }

    func start(port: UInt16 = 7777) throws {
        stop()
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: "OBS Camera Hub", type: "_obsphonecam._tcp")
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isAdvertising = true
                    self?.lastError = nil
                    AppLogger.shared.log(.info, .transport, "Device listener ready on \(port)")
                case .failed(let error):
                    self?.isAdvertising = false
                    self?.lastError = error.localizedDescription
                    AppLogger.shared.log(.error, .transport, "Device listener failed: \(error.localizedDescription)")
                case .cancelled:
                    self?.isAdvertising = false
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
            }
        }
        listener.start(queue: DispatchQueue(label: "obsphonecam.mac.listener"))
        self.listener = listener
        isAdvertising = true
        lastError = nil
        AppLogger.shared.log(.info, .transport, "Device listener started on \(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        obsStateSendInFlight.removeAll()
        pendingOBSStatePackets.removeAll()
        isAdvertising = false
        lastError = nil
    }

    func broadcastOBSState(_ packet: OBSStatePacket) {
        for connectionID in connections.keys {
            sendOBSState(packet, to: connectionID)
        }
    }

    func broadcastLightweightOBSState(_ packet: OBSStatePacket) {
        let lightweightPacket = OBSStatePacket(status: packet.status, scenes: [], previewImageData: nil, audioMeters: packet.audioMeters)
        broadcastOBSState(lightweightPacket)
    }

    private func accept(_ connection: NWConnection) {
        let connectionID = UUID()
        connections[connectionID] = connection
        connection.start(queue: DispatchQueue(label: "obsphonecam.mac.connection.\(connectionID.uuidString)"))
        receiveNext(on: connection, connectionID: connectionID)
    }

    private func receiveNext(on connection: NWConnection, connectionID: UUID) {
        let manager = manager
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] lengthData, _, _, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in AppLogger.shared.log(.error, .transport, "Receive length failed: \(error.localizedDescription)") }
                Task { @MainActor in self.remove(connectionID) }
                return
            }
            guard let lengthData, lengthData.count == 4 else {
                Task { @MainActor in self.remove(connectionID) }
                return
            }
            let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { payloadData, _, _, error in
                if let error {
                    Task { @MainActor in AppLogger.shared.log(.error, .transport, "Receive payload failed: \(error.localizedDescription)") }
                    Task { @MainActor in self.remove(connectionID) }
                    return
                }
                guard let payloadData else {
                    Task { @MainActor in self.remove(connectionID) }
                    return
                }
                Self.decodeAndIngest(payloadData, connectionID: connectionID, manager: manager)
                Task { @MainActor in
                    self.receiveNext(on: connection, connectionID: connectionID)
                }
            }
        }
    }

    private nonisolated static func decodeAndIngest(_ payloadData: Data, connectionID: UUID, manager: ConnectedDeviceManager) {
        let codec = MessageCodec()
        Task.detached(priority: .userInitiated) { [weak manager] in
            guard let manager else { return }
            do {
                let envelope = try codec.decode(PhoneCamEnvelope.self, from: payloadData)
                switch envelope.type {
                case .handshake:
                    let packet = try codec.payload(HandshakePacket.self, from: envelope)
                    await MainActor.run {
                        manager.ingestHandshake(packet)
                    }
                case .heartbeat:
                    let packet = try codec.payload(HeartbeatPacket.self, from: envelope)
                    await MainActor.run {
                        manager.ingestHeartbeat(packet, from: connectionID)
                    }
                case .control:
                    let packet = try codec.payload(ControlPacket.self, from: envelope)
                    await MainActor.run {
                        manager.ingestControl(packet, deviceID: envelope.deviceID)
                    }
                case .streamPacket:
                    let packet = try codec.payload(StreamPacket.self, from: envelope)
                    await MainActor.run {
                        manager.ingestStreamPacket(packet)
                    }
                default:
                    break
                }
            } catch {
                await MainActor.run {
                    AppLogger.shared.log(.error, .transport, "Decode failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func close(connectionID: UUID, reason: String) {
        AppLogger.shared.log(.warning, .reconnect, "Closing device connection because \(reason)")
        connections[connectionID]?.cancel()
        remove(connectionID)
    }

    private func remove(_ connectionID: UUID) {
        connections.removeValue(forKey: connectionID)
        obsStateSendInFlight.remove(connectionID)
        pendingOBSStatePackets.removeValue(forKey: connectionID)
    }

    private func sendOBSState(_ packet: OBSStatePacket, to connectionID: UUID) {
        guard let connection = connections[connectionID] else { return }
        guard !obsStateSendInFlight.contains(connectionID) else {
            pendingOBSStatePackets[connectionID] = packet
            return
        }
        obsStateSendInFlight.insert(connectionID)
        do {
            let envelope = try codec.envelope(.obsState, deviceID: nil, payload: packet)
            let data = try codec.encode(envelope)
            var length = UInt32(data.count).bigEndian
            let framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size) + data
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    Task { @MainActor in
                        AppLogger.shared.log(.error, .transport, "OBS state send failed: \(error.localizedDescription)")
                        self.remove(connectionID)
                    }
                } else {
                    Task { @MainActor in
                        self.obsStateSendInFlight.remove(connectionID)
                        if let latest = self.pendingOBSStatePackets.removeValue(forKey: connectionID) {
                            self.sendOBSState(latest, to: connectionID)
                        }
                    }
                }
            })
        } catch {
            obsStateSendInFlight.remove(connectionID)
            AppLogger.shared.log(.error, .transport, "OBS state encode failed: \(error.localizedDescription)")
        }
    }
}

@MainActor
final class OBSDownlinkService: ObservableObject {
    @Published private(set) var isAdvertising = false
    @Published private(set) var connectedClientCount = 0
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var obsStateSendInFlight: Set<UUID> = []
    private var pendingOBSStatePackets: [UUID: OBSStatePacket] = [:]
    private let codec = MessageCodec()

    var hasClients: Bool { !connections.isEmpty }

    func start(port: UInt16 = 7778) throws {
        guard listener == nil else { return }
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: "OBS Camera Hub Preview", type: "_obsphonecam-obs._tcp")
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
            }
        }
        listener.start(queue: DispatchQueue(label: "obsphonecam.mac.obs-downlink.listener"))
        self.listener = listener
        isAdvertising = true
        AppLogger.shared.log(.info, .transport, "OBS downlink listener started on \(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        obsStateSendInFlight.removeAll()
        pendingOBSStatePackets.removeAll()
        connectedClientCount = 0
        isAdvertising = false
    }

    func broadcastOBSState(_ packet: OBSStatePacket) {
        for connectionID in connections.keys {
            sendOBSState(packet, to: connectionID)
        }
    }

    private func accept(_ connection: NWConnection) {
        let connectionID = UUID()
        connections[connectionID] = connection
        connectedClientCount = connections.count
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                Task { @MainActor in
                    AppLogger.shared.log(.error, .transport, "OBS downlink failed: \(error.localizedDescription)")
                    self?.remove(connectionID)
                }
            case .cancelled:
                Task { @MainActor in self?.remove(connectionID) }
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "obsphonecam.mac.obs-downlink.\(connectionID.uuidString)"))
        AppLogger.shared.log(.info, .transport, "OBS downlink client connected")
    }

    private func remove(_ connectionID: UUID) {
        connections.removeValue(forKey: connectionID)
        obsStateSendInFlight.remove(connectionID)
        pendingOBSStatePackets.removeValue(forKey: connectionID)
        connectedClientCount = connections.count
    }

    private func sendOBSState(_ packet: OBSStatePacket, to connectionID: UUID) {
        guard let connection = connections[connectionID] else { return }
        guard !obsStateSendInFlight.contains(connectionID) else {
            pendingOBSStatePackets[connectionID] = packet
            return
        }
        obsStateSendInFlight.insert(connectionID)
        do {
            let envelope = try codec.envelope(.obsState, deviceID: nil, payload: packet)
            let data = try codec.encode(envelope)
            var length = UInt32(data.count).bigEndian
            let framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size) + data
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    Task { @MainActor in
                        AppLogger.shared.log(.error, .transport, "OBS downlink send failed: \(error.localizedDescription)")
                        self.remove(connectionID)
                    }
                } else {
                    Task { @MainActor in
                        self.obsStateSendInFlight.remove(connectionID)
                        if let latest = self.pendingOBSStatePackets.removeValue(forKey: connectionID) {
                            self.sendOBSState(latest, to: connectionID)
                        }
                    }
                }
            })
        } catch {
            obsStateSendInFlight.remove(connectionID)
            AppLogger.shared.log(.error, .transport, "OBS downlink encode failed: \(error.localizedDescription)")
        }
    }
}
