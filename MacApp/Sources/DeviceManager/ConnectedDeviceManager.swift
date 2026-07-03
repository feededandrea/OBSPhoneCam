import Foundation
import Network
import Combine

@MainActor
final class ConnectedDeviceManager: ObservableObject {
    @Published private(set) var snapshots: [DeviceSessionSnapshot] = []
    @Published private(set) var previewFrames: [String: DevicePreviewFrame] = [:]
    private var sessions: [String: DeviceSession] = [:]
    private let streamDecoder = StreamDecoder()
    private let logger = AppLogger.shared
    var onControlPacket: ((ControlPacket, String?) -> Void)?

    init() {
        streamDecoder.onPreviewJPEG = { [weak self] data, sequence in
            Task { @MainActor in
                guard let self else { return }
                let deviceID = self.sessions.keys.sorted().first ?? "iphone"
                self.previewFrames[deviceID] = DevicePreviewFrame(deviceID: deviceID, sequence: sequence, imageData: data, updatedAt: Date())
                self.objectWillChange.send()
            }
        }
        streamDecoder.onPixelBuffer = { pixelBuffer, sequence in
            OBSNativeFramePublisher.shared.publishPixelBuffer(pixelBuffer, sequence: sequence)
        }
    }

    func upsertSession(identity: DeviceIdentity) -> DeviceSession {
        if let existing = sessions[identity.id] { return existing }
        let session = DeviceSession(identity: identity)
        sessions[identity.id] = session
        refreshSnapshots()
        logger.log(.info, .device, "Session created", deviceID: identity.id)
        return session
    }

    func removeSession(deviceID: String) {
        sessions[deviceID]?.cleanup(reason: .socketClosed)
        sessions.removeValue(forKey: deviceID)
        refreshSnapshots()
    }

    func restart(deviceID: String) {
        sessions[deviceID]?.restart(reason: .userRequested)
        refreshSnapshots()
    }

    func ingest(_ envelope: PhoneCamEnvelope, from connectionID: UUID) async {
        let codec = MessageCodec()
        do {
            switch envelope.type {
            case .handshake:
                let packet = try codec.payload(HandshakePacket.self, from: envelope)
                let session = upsertSession(identity: packet.identity)
                session.transition(to: .streaming)
            case .heartbeat:
                let packet = try codec.payload(HeartbeatPacket.self, from: envelope)
                sessions[packet.deviceID]?.receiveHeartbeat(packet)
            case .control:
                let packet = try codec.payload(ControlPacket.self, from: envelope)
                logger.log(.debug, .device, "Control message received: \(packet.command.rawValue)", deviceID: envelope.deviceID)
                onControlPacket?(packet, envelope.deviceID)
            case .streamPacket:
                let packet = try codec.payload(StreamPacket.self, from: envelope)
                sessions[packet.deviceID]?.receiveStreamPacket()
                if packet.kind == .videoKeyframe || packet.kind == .videoDelta {
                    if packet.codec == .jpeg {
                        previewFrames[packet.deviceID] = DevicePreviewFrame(deviceID: packet.deviceID, sequence: packet.sequence, imageData: packet.data, updatedAt: Date())
                        OBSNativeFramePublisher.shared.publishJPEGFrame(packet.data, sequence: packet.sequence)
                    } else {
                        streamDecoder.decodeVideo(packet)
                    }
                }
            default:
                break
            }
            refreshSnapshots()
        } catch {
            logger.log(.error, .device, "Failed ingesting message: \(error.localizedDescription)", deviceID: envelope.deviceID)
        }
    }

    private func refreshSnapshots() {
        snapshots = sessions.values.map { $0.snapshot }.sorted { $0.name < $1.name }
    }
}
