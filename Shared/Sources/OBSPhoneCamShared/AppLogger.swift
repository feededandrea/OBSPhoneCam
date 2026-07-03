import Foundation
import Combine

public enum LogLevel: String, Codable, Sendable, CaseIterable {
    case debug, info, warning, error
}

public enum LogCategory: String, Codable, Sendable, CaseIterable {
    case camera, encoder, transport, reconnect, obs, virtualCamera, instagram, ui, device, clips, security
}

public struct LogEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    public let deviceID: String?

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel, category: LogCategory, message: String, deviceID: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.deviceID = deviceID
    }
}

@MainActor
public final class AppLogger: ObservableObject {
    public static let shared = AppLogger()
    @Published public private(set) var entries: [LogEntry] = []
    public var maxEntries = 500

    public init() {}

    public func log(_ level: LogLevel, _ category: LogCategory, _ message: String, deviceID: String? = nil) {
        let entry = LogEntry(level: level, category: category, message: message, deviceID: deviceID)
        entries.append(entry)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        print("[\(entry.timestamp)] [\(level.rawValue.uppercased())] [\(category.rawValue)] \(deviceID ?? "-") \(message)")
    }

    public func clear() { entries.removeAll() }
}
