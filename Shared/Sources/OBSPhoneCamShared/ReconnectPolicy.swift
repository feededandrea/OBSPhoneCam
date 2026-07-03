import Foundation

public struct ReconnectPolicy: Sendable, Equatable {
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var jitter: TimeInterval
    public var maxAttempts: Int?

    public init(baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 12, jitter: TimeInterval = 0.25, maxAttempts: Int? = nil) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.maxAttempts = maxAttempts
    }

    public func delay(forAttempt attempt: Int) -> TimeInterval? {
        if let maxAttempts, attempt > maxAttempts { return nil }
        let exponent = max(0, attempt - 1)
        let raw = min(maxDelay, baseDelay * pow(2, Double(exponent)))
        let deterministicJitter = jitter == 0 ? 0 : Double(attempt % 3) * (jitter / 2.0)
        return min(maxDelay, raw + deterministicJitter)
    }
}

public enum ReconnectReason: String, Codable, Sendable {
    case heartbeatTimeout
    case socketClosed
    case userRequested
    case appBecameActive
    case obsDisconnected
    case unknown
}
