import Foundation

public enum StreamQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case low720p
    case medium1080p
    case high1080p
    case max1080p40
    case pro4k

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .low720p: return "720p estable"
        case .medium1080p: return "1080p medio"
        case .high1080p: return "1080p alto"
        case .max1080p40: return "1080p máximo 40fps"
        case .pro4k: return "4K pro"
        }
    }

    public var resolution: (width: Int, height: Int) {
        switch self {
        case .low720p: return (1280, 720)
        case .medium1080p, .high1080p, .max1080p40: return (1920, 1080)
        case .pro4k: return (3840, 2160)
        }
    }

    public var bitrate: Int {
        switch self {
        case .low720p: return 2_500_000
        case .medium1080p: return 5_000_000
        case .high1080p: return 18_000_000
        case .max1080p40: return 36_000_000
        case .pro4k: return 55_000_000
        }
    }

    public var fps: Int {
        switch self {
        case .low720p: return 30
        case .medium1080p: return 30
        case .high1080p: return 60
        case .max1080p40: return 40
        case .pro4k: return 30
        }
    }

    public var jpegCompressionQuality: Double {
        switch self {
        case .low720p: return 0.50
        case .medium1080p: return 0.58
        case .high1080p: return 0.66
        case .max1080p40: return 0.48
        case .pro4k: return 0.70
        }
    }

    public var streamedJPEGWidth: Double {
        switch self {
        case .low720p: return 1280
        case .medium1080p, .high1080p: return 1920
        case .max1080p40: return 1600
        case .pro4k: return 1920
        }
    }

    public var prefersFastCableFPS: StreamQuality {
        switch self {
        case .pro4k:
            return .pro4k
        default:
            return .max1080p40
        }
    }
}

public struct StreamMetrics: Codable, Sendable, Equatable {
    public var fps: Double
    public var bitrate: Double
    public var droppedFrames: Int
    public var latencyMs: Double
    public var audioSyncWarnings: Int
    public var uptimeSeconds: Double

    public static let empty = StreamMetrics(fps: 0, bitrate: 0, droppedFrames: 0, latencyMs: 0, audioSyncWarnings: 0, uptimeSeconds: 0)

    public init(fps: Double, bitrate: Double, droppedFrames: Int, latencyMs: Double, audioSyncWarnings: Int, uptimeSeconds: Double) {
        self.fps = fps
        self.bitrate = bitrate
        self.droppedFrames = droppedFrames
        self.latencyMs = latencyMs
        self.audioSyncWarnings = audioSyncWarnings
        self.uptimeSeconds = uptimeSeconds
    }
}

public enum StreamMode: String, Codable, Sendable, CaseIterable {
    case lowLatency
    case stability
}
