import Foundation
import Combine

@MainActor
final class InstagramPublishingService: ObservableObject {
    enum Mode: String, Codable, CaseIterable, Hashable, Identifiable {
        case manualExport
        case contentPublishingAPI
        case liveExperimental
        var id: String { rawValue }
    }

    @Published var selectedMode: Mode = .manualExport
    @Published var isConfigured = false
    @Published var lastMessage: String?

    func prepareManualShare(for clip: ClipRecord, caption: String) {
        lastMessage = "Clip preparado para exportación manual. Caption copiado/preparado."
        AppLogger.shared.log(.info, .instagram, "Manual share prepared for \(clip.id)")
    }

    func publishClip(_ clip: ClipRecord, caption: String) async throws {
        guard isConfigured else { throw InstagramPublishingError.notConfigured }
        // TODO: implementar OAuth + Graph API Content Publishing solo con permisos oficiales.
        throw InstagramPublishingError.apiNotAvailableForAccount
    }
}
