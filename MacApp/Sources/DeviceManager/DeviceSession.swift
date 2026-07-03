import Foundation
import Combine

@MainActor
final class DeviceSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let identity: DeviceIdentity
    @Published private(set) var state: ConnectionState = .handshaking
    @Published private(set) var metrics: StreamMetrics = .empty
    @Published private(set) var lastHeartbeat: Date?
    @Published private(set) var reconnectCount = 0

    private let heartbeatTimeout: TimeInterval = 4.0
    private let reconnectPolicy = ReconnectPolicy()
    private var reconnectAttempt = 0
    private var watchdogTask: Task<Void, Never>?

    var snapshot: DeviceSessionSnapshot {
        DeviceSessionSnapshot(id: identity.id, name: identity.displayName, state: state, metrics: metrics, lastHeartbeat: lastHeartbeat, reconnectCount: reconnectCount)
    }

    init(identity: DeviceIdentity) {
        self.identity = identity
        self.id = identity.id
        startWatchdog()
    }

    func transition(to newState: ConnectionState) {
        state = newState
        AppLogger.shared.log(.info, .device, "State -> \(newState.rawValue)", deviceID: identity.id)
    }

    func receiveHeartbeat(_ packet: HeartbeatPacket) {
        lastHeartbeat = Date()
        metrics = packet.metrics
        if packet.metrics.fps < 1 {
            AppLogger.shared.log(
                .error,
                .device,
                "Heartbeat reports zero/low FPS: fps=\(String(format: "%.1f", packet.metrics.fps)) bitrate=\(String(format: "%.0f", packet.metrics.bitrate / 1_000_000))Mbps dropped=\(packet.metrics.droppedFrames)",
                deviceID: identity.id
            )
        } else if packet.metrics.fps < 20 {
            AppLogger.shared.log(
                .warning,
                .device,
                "Heartbeat reports low FPS: fps=\(String(format: "%.1f", packet.metrics.fps)) bitrate=\(String(format: "%.0f", packet.metrics.bitrate / 1_000_000))Mbps dropped=\(packet.metrics.droppedFrames)",
                deviceID: identity.id
            )
        }
        if state == .degraded || state == .reconnecting || state == .handshaking { transition(to: .streaming) }
    }

    func receiveStreamPacket() {
        if state != .streaming { transition(to: .streaming) }
    }

    func restart(reason: ReconnectReason) {
        cleanup(reason: reason)
        reconnectCount += 1
        reconnectAttempt = 0
        transition(to: .reconnecting)
        scheduleReconnect(reason: reason)
    }

    func cleanup(reason: ReconnectReason) {
        AppLogger.shared.log(.warning, .reconnect, "Cleaning session because \(reason.rawValue)", deviceID: identity.id)
        watchdogTask?.cancel()
        watchdogTask = nil
        transition(to: .disconnected)
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.checkHeartbeat()
            }
        }
    }

    private func checkHeartbeat() {
        guard let lastHeartbeat else { return }
        let age = Date().timeIntervalSince(lastHeartbeat)
        if age > heartbeatTimeout, state == .streaming {
            transition(to: .degraded)
            scheduleReconnect(reason: .heartbeatTimeout)
        }
    }

    private func scheduleReconnect(reason: ReconnectReason) {
        reconnectAttempt += 1
        guard let delay = reconnectPolicy.delay(forAttempt: reconnectAttempt) else {
            transition(to: .failed)
            return
        }
        transition(to: .reconnecting)
        AppLogger.shared.log(.warning, .reconnect, "Reconnect in \(delay)s", deviceID: identity.id)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.startWatchdog()
        }
    }
}
