import Foundation
import AVFoundation

final class ClipTrimmerService {
    func trim(inputURL: URL, outputURL: URL, start: TimeInterval, duration: TimeInterval) async throws {
        let asset = AVURLAsset(url: inputURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "ClipTrimmerService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No se pudo crear export session"])
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
        await export.export()
        if export.status == .failed, let error = export.error { throw error }
    }
}
