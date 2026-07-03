import Foundation

final class StreamReceiver {
    private let decoder = StreamDecoder()
    private let frameBuffer = FrameBuffer(maxFrames: 3)

    func receive(_ packet: StreamPacket) {
        switch packet.kind {
        case .videoKeyframe, .videoDelta:
            decoder.decodeVideo(packet)
        case .audio:
            decoder.decodeAudio(packet.data)
        }
    }
}
