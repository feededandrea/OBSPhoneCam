import Foundation
import Combine

@MainActor
final class OBSRemoteClient: ObservableObject {
    @Published private(set) var status: OBSStatus = .disconnected
    private let logger = AppLogger.shared

    func updateFromHub(_ newStatus: OBSStatus) {
        status = newStatus
        logger.log(.debug, .obs, "OBS status updated from hub")
    }
}
