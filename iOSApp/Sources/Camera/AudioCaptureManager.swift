import Foundation
import AVFoundation
import Combine

@MainActor
final class AudioCaptureManager: NSObject, ObservableObject {
    @Published private(set) var isMuted = false

    func setMuted(_ muted: Bool) {
        isMuted = muted
        AppLogger.shared.log(.info, .camera, muted ? "Audio muted" : "Audio unmuted")
    }
}
