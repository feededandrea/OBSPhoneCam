import Foundation
import CoreMedia

final class FrameBuffer {
    private var frames: [CMSampleBuffer] = []
    private let maxFrames: Int
    private let lock = NSLock()

    init(maxFrames: Int = 3) {
        self.maxFrames = maxFrames
    }

    func push(_ frame: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        frames.append(frame)
        if frames.count > maxFrames { frames.removeFirst(frames.count - maxFrames) }
    }

    func popLatest() -> CMSampleBuffer? {
        lock.lock(); defer { lock.unlock() }
        let latest = frames.last
        frames.removeAll()
        return latest
    }
}
