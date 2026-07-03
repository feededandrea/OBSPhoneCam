import Foundation

public struct DeviceIdentity: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var displayName: String
    public var model: String
    public var osVersion: String
    public var pairingToken: String

    public init(id: String = UUID().uuidString, displayName: String, model: String, osVersion: String, pairingToken: String = UUID().uuidString) {
        self.id = id
        self.displayName = displayName
        self.model = model
        self.osVersion = osVersion
        self.pairingToken = pairingToken
    }
}

public enum DeviceIdentityStore {
    public static let key = "obsphonecam.device.identity"

    public static func load(defaultName: String, model: String, osVersion: String) -> DeviceIdentity {
        if let data = UserDefaults.standard.data(forKey: key), let identity = try? JSONDecoder().decode(DeviceIdentity.self, from: data) {
            return identity
        }
        let identity = DeviceIdentity(displayName: defaultName, model: model, osVersion: osVersion)
        save(identity)
        return identity
    }

    public static func save(_ identity: DeviceIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    public static func reset(defaultName: String, model: String, osVersion: String) -> DeviceIdentity {
        UserDefaults.standard.removeObject(forKey: key)
        return load(defaultName: defaultName, model: model, osVersion: osVersion)
    }
}
