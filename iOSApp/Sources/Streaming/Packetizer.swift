import Foundation
import CoreMedia

final class Packetizer {
    private var sequence: UInt64 = 0

    func nextVideoPacket(deviceID: String, data: Data, isKeyframe: Bool, sampleBuffer: CMSampleBuffer) -> StreamPacket {
        sequence += 1
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        return StreamPacket(deviceID: deviceID, sequence: sequence, presentationTime: pts, kind: isKeyframe ? .videoKeyframe : .videoDelta, data: data)
    }

    func nextAudioPacket(deviceID: String, data: Data, sampleBuffer: CMSampleBuffer) -> StreamPacket {
        sequence += 1
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        return StreamPacket(deviceID: deviceID, sequence: sequence, presentationTime: pts, kind: .audio, data: data)
    }
}
