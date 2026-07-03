import Foundation

struct DevicePreviewFrame: Identifiable, Equatable {
    var id: String { deviceID }
    let deviceID: String
    let sequence: UInt64
    let imageData: Data
    let updatedAt: Date
}
