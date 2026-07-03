import Foundation
import AVFoundation

struct CameraSettings: Codable, Equatable {
    var quality: StreamQuality = .max1080p40
    var mode: StreamMode = .lowLatency
    var preferredPosition: AVCaptureDevice.Position = .back
    var audioEnabled: Bool = true
    var stabilizationEnabled: Bool = true
    var focusLocked: Bool = false
    var exposureLocked: Bool = false

    enum CodingKeys: String, CodingKey {
        case quality
        case mode
        case preferredPosition
        case audioEnabled
        case stabilizationEnabled
        case focusLocked
        case exposureLocked
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quality = try container.decodeIfPresent(StreamQuality.self, forKey: .quality) ?? .max1080p40
        mode = try container.decodeIfPresent(StreamMode.self, forKey: .mode) ?? .lowLatency
        let positionRawValue = try container.decodeIfPresent(Int.self, forKey: .preferredPosition) ?? AVCaptureDevice.Position.back.rawValue
        preferredPosition = AVCaptureDevice.Position(rawValue: positionRawValue) ?? .back
        audioEnabled = try container.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? true
        stabilizationEnabled = try container.decodeIfPresent(Bool.self, forKey: .stabilizationEnabled) ?? true
        focusLocked = try container.decodeIfPresent(Bool.self, forKey: .focusLocked) ?? false
        exposureLocked = try container.decodeIfPresent(Bool.self, forKey: .exposureLocked) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(quality, forKey: .quality)
        try container.encode(mode, forKey: .mode)
        try container.encode(preferredPosition.rawValue, forKey: .preferredPosition)
        try container.encode(audioEnabled, forKey: .audioEnabled)
        try container.encode(stabilizationEnabled, forKey: .stabilizationEnabled)
        try container.encode(focusLocked, forKey: .focusLocked)
        try container.encode(exposureLocked, forKey: .exposureLocked)
    }
}
