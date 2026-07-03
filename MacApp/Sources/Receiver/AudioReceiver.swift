import Foundation

final class AudioReceiver {
    private(set) var receivedPackets = 0

    func receive(_ data: Data, presentationTime: Double) {
        receivedPackets += 1
        // TODO: convertir audio packet a AVAudioPCMBuffer y sincronizar con video.
    }
}
