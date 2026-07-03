import Foundation

public struct OBSConnectionConfig: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var password: String

    public init(host: String = "127.0.0.1", port: Int = 4455, password: String = "") {
        self.host = host
        self.port = port
        self.password = password
    }

    public var url: URL? { URL(string: "ws://\(host):\(port)") }
}

public enum OBSConnectionConfigStore {
    private static let key = "obsphonecam.obs.connection.config"

    public static func load() -> OBSConnectionConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(OBSConnectionConfig.self, from: data) else {
            return OBSConnectionConfig()
        }
        return config
    }

    public static func save(_ config: OBSConnectionConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

public struct IOSConnectionPreferences: Codable, Sendable, Equatable {
    public enum MacEndpoint: Codable, Sendable, Equatable {
        case service(name: String)
        case hostPort(host: String, port: Int)
    }

    public var macHost: String
    public var macPort: Int
    public var lastMacEndpoint: MacEndpoint?
    public var selectedQuality: StreamQuality
    public var streamMode: StreamMode
    public var cableOnlyMode: Bool

    public init(
        macHost: String = "127.0.0.1",
        macPort: Int = 7777,
        lastMacEndpoint: MacEndpoint? = nil,
        selectedQuality: StreamQuality = .max1080p40,
        streamMode: StreamMode = .lowLatency,
        cableOnlyMode: Bool = false
    ) {
        self.macHost = macHost
        self.macPort = macPort
        self.lastMacEndpoint = lastMacEndpoint
        self.selectedQuality = selectedQuality
        self.streamMode = streamMode
        self.cableOnlyMode = cableOnlyMode
    }
}

public enum IOSConnectionPreferencesStore {
    private static let key = "obsphonecam.ios.connection.preferences"

    public static func load() -> IOSConnectionPreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let preferences = try? JSONDecoder().decode(IOSConnectionPreferences.self, from: data) else {
            return IOSConnectionPreferences()
        }
        return preferences
    }

    public static func save(_ preferences: IOSConnectionPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

public struct OBSScene: Codable, Identifiable, Hashable, Sendable {
    public var id: String { sceneName }
    public let sceneName: String
    public let sceneIndex: Int?
    public var previewImageData: Data?

    public init(sceneName: String, sceneIndex: Int? = nil, previewImageData: Data? = nil) {
        self.sceneName = sceneName
        self.sceneIndex = sceneIndex
        self.previewImageData = previewImageData
    }
}

public enum OBSSceneCacheStore {
    private static let key = "obsphonecam.obs.scene.cache"

    public static func load() -> [OBSScene] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let scenes = try? JSONDecoder().decode([OBSScene].self, from: data) else {
            return []
        }
        return scenes
    }

    public static func save(_ scenes: [OBSScene]) {
        guard let data = try? JSONEncoder().encode(scenes) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

public struct OBSStatus: Codable, Sendable, Equatable {
    public var connected: Bool
    public var currentScene: String?
    public var recording: Bool
    public var streaming: Bool
    public var replayBufferAvailable: Bool
    public var replayBufferActive: Bool
    public var lastError: String?

    public static let disconnected = OBSStatus(connected: false, currentScene: nil, recording: false, streaming: false, replayBufferAvailable: false, replayBufferActive: false, lastError: nil)

    public init(connected: Bool, currentScene: String?, recording: Bool, streaming: Bool, replayBufferAvailable: Bool = true, replayBufferActive: Bool, lastError: String?) {
        self.connected = connected
        self.currentScene = currentScene
        self.recording = recording
        self.streaming = streaming
        self.replayBufferAvailable = replayBufferAvailable
        self.replayBufferActive = replayBufferActive
        self.lastError = lastError
    }
}

public struct OBSAudioMeter: Codable, Sendable, Equatable, Identifiable {
    public var id: String { inputName }
    public let inputName: String
    public let peakDb: Double
    public let normalizedLevel: Double
    public let isActive: Bool

    public init(inputName: String, peakDb: Double, normalizedLevel: Double? = nil, isActive: Bool? = nil) {
        self.inputName = inputName
        self.peakDb = peakDb
        let clampedDb = min(0, max(-60, peakDb))
        self.normalizedLevel = normalizedLevel ?? ((clampedDb + 60) / 60)
        self.isActive = isActive ?? (peakDb > -58)
    }
}

public struct OBSRequest: Codable, Sendable {
    public let op: Int
    public let d: OBSRequestData

    public init(op: Int, d: OBSRequestData) {
        self.op = op
        self.d = d
    }
}

public struct OBSRequestData: Codable, Sendable {
    public let requestType: String
    public let requestId: String
    public let requestData: [String: JSONValue]?

    public init(requestType: String, requestId: String = UUID().uuidString, requestData: [String : JSONValue]? = nil) {
        self.requestType = requestType
        self.requestId = requestId
        self.requestData = requestData
    }
}

public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
