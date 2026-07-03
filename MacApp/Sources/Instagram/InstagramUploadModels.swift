import Foundation

struct InstagramUploadDraft: Identifiable, Codable, Hashable {
    let id: UUID
    var clip: ClipRecord
    var caption: String
    var hashtags: [String]
    var mode: InstagramPublishingService.Mode

    init(id: UUID = UUID(), clip: ClipRecord, caption: String = "", hashtags: [String] = [], mode: InstagramPublishingService.Mode = .manualExport) {
        self.id = id
        self.clip = clip
        self.caption = caption
        self.hashtags = hashtags
        self.mode = mode
    }
}
