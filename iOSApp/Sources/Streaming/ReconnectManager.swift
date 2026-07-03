import Foundation
import Combine

@MainActor
final class ReconnectManager: ObservableObject {
    @Published private(set) var attempt = 0
    @Published private(set) var reason: ReconnectReason = .unknown
    private let policy: ReconnectPolicy
    private var task: Task<Void, Never>?

    init(policy: ReconnectPolicy = ReconnectPolicy()) {
        self.policy = policy
    }

    func schedule(reason: ReconnectReason, action: @escaping @MainActor () async -> Void) {
        self.reason = reason
        attempt += 1
        guard let delay = policy.delay(forAttempt: attempt) else { return }
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await action()
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        attempt = 0
        reason = .unknown
    }
}
