import Foundation
import CoreMedia

final class SampleBufferProvider {
    private let frameBuffer = FrameBuffer(maxFrames: 2)

    func push(_ sampleBuffer: CMSampleBuffer) {
        frameBuffer.push(sampleBuffer)
    }

    func latest() -> CMSampleBuffer? {
        frameBuffer.popLatest()
    }
}
