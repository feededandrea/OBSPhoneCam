import Foundation
import Combine

@MainActor
final class OBSStateStore: ObservableObject {
    @Published var status: OBSStatus = .disconnected
    @Published var scenes: [OBSScene] = []
    @Published var selectedPreviewName: String?

    func apply(status: OBSStatus) {
        self.status = status
    }
}
