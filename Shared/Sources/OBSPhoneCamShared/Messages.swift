import Foundation

public enum PhoneCamMessageType: String, Codable, Sendable {
    case handshake
    case handshakeAccepted
    case heartbeat
    case control
    case streamPacket
    case obsCommand
    case obsState
    case error
}

public struct PhoneCamEnvelope: Codable, Sendable, Identifiable {
    public let id: UUID
    public let type: PhoneCamMessageType
    public let sentAt: Date
    public let deviceID: String?
    public let payload: Data

    public init(id: UUID = UUID(), type: PhoneCamMessageType, sentAt: Date = Date(), deviceID: String?, payload: Data) {
        self.id = id
        self.type = type
        self.sentAt = sentAt
        self.deviceID = deviceID
        self.payload = payload
    }
}

public struct HandshakePacket: Codable, Sendable, Equatable {
    public let identity: DeviceIdentity
    public let appVersion: String
    public let supportedCodecs: [String]
    public let preferredQuality: StreamQuality

    public init(identity: DeviceIdentity, appVersion: String, supportedCodecs: [String], preferredQuality: StreamQuality) {
        self.identity = identity
        self.appVersion = appVersion
        self.supportedCodecs = supportedCodecs
        self.preferredQuality = preferredQuality
    }
}

public struct HeartbeatPacket: Codable, Sendable, Equatable {
    public let deviceID: String
    public let sequence: UInt64
    public let metrics: StreamMetrics

    public init(deviceID: String, sequence: UInt64, metrics: StreamMetrics) {
        self.deviceID = deviceID
        self.sequence = sequence
        self.metrics = metrics
    }
}

public struct StreamPacket: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case videoKeyframe, videoDelta, audio }
    public enum Codec: String, Codable, Sendable { case jpeg, h264, pcm }
    public let deviceID: String
    public let sequence: UInt64
    public let presentationTime: Double
    public let kind: Kind
    public let data: Data
    public let codec: Codec

    public init(deviceID: String, sequence: UInt64, presentationTime: Double, kind: Kind, data: Data, codec: Codec = .jpeg) {
        self.deviceID = deviceID
        self.sequence = sequence
        self.presentationTime = presentationTime
        self.kind = kind
        self.data = data
        self.codec = codec
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case sequence
        case presentationTime
        case kind
        case data
        case codec
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        presentationTime = try container.decode(Double.self, forKey: .presentationTime)
        kind = try container.decode(Kind.self, forKey: .kind)
        data = try container.decode(Data.self, forKey: .data)
        codec = try container.decodeIfPresent(Codec.self, forKey: .codec) ?? .jpeg
    }
}

public enum ControlCommand: String, Codable, Sendable, CaseIterable {
    case restartConnection
    case startRecording
    case stopRecording
    case startStreaming
    case stopStreaming
    case switchScene
    case switchCamera
    case muteAudio
    case unmuteAudio
    case saveReplayBuffer
    case markClip
    case applyInstagramLiveCrop
}

public struct ControlPacket: Codable, Sendable, Equatable {
    public let command: ControlCommand
    public let arguments: [String: String]

    public init(command: ControlCommand, arguments: [String : String] = [:]) {
        self.command = command
        self.arguments = arguments
    }
}

public struct OBSStatePacket: Codable, Sendable, Equatable {
    public let status: OBSStatus
    public let scenes: [OBSScene]
    public let previewImageData: Data?
    public let audioMeters: [OBSAudioMeter]

    public init(status: OBSStatus, scenes: [OBSScene], previewImageData: Data? = nil, audioMeters: [OBSAudioMeter] = []) {
        self.status = status
        self.scenes = scenes
        self.previewImageData = previewImageData
        self.audioMeters = audioMeters
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case scenes
        case previewImageData
        case audioMeters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(OBSStatus.self, forKey: .status)
        scenes = try container.decode([OBSScene].self, forKey: .scenes)
        previewImageData = try container.decodeIfPresent(Data.self, forKey: .previewImageData)
        audioMeters = try container.decodeIfPresent([OBSAudioMeter].self, forKey: .audioMeters) ?? []
    }
}
