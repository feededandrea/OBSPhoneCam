import Foundation

struct ClipRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    let label: String
    let filePath: String
    let sceneName: String?
    let durationSeconds: Double?
    let isInstagramReady: Bool

    init(id: UUID = UUID(), createdAt: Date = Date(), label: String, filePath: String, sceneName: String? = nil, durationSeconds: Double? = nil, isInstagramReady: Bool = false) {
        self.id = id
        self.createdAt = createdAt
        self.label = label
        self.filePath = filePath
        self.sceneName = sceneName
        self.durationSeconds = durationSeconds
        self.isInstagramReady = isInstagramReady
    }
}

@MainActor
final class OBSClipManager {
    private let obsClient: OBSWebSocketClient

    init(obsClient: OBSWebSocketClient) {
        self.obsClient = obsClient
    }

    func saveReplayBuffer(label: String) async throws -> ClipRecord {
        let beforeSave = await recentVideoFiles()
        let sceneName = try? await obsClient.refreshStatus().currentScene
        try await obsClient.saveReplayBuffer()
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let afterSave = await recentVideoFiles()
        let previousPaths = Set(beforeSave.map(\.path))
        let newest = afterSave.first { !previousPaths.contains($0.path) } ?? afterSave.first
        return ClipRecord(
            label: label,
            filePath: newest?.path ?? "OBS Replay Buffer output folder",
            sceneName: sceneName,
            durationSeconds: newest?.durationSeconds ?? 30,
            isInstagramReady: newest != nil
        )
    }

    func prepareInstagramVideo(from clip: ClipRecord) async throws -> ClipRecord {
        let inputURL = URL(fileURLWithPath: clip.filePath)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw NSError(domain: "OBSClipManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "No se encontró el archivo del clip para preparar Instagram."])
        }

        let outputDirectory = instagramDraftDirectory()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory.appendingPathComponent(safeFileName("IG-\(clip.label)-\(clip.createdAt.timeIntervalSince1970).mp4"))

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: inputURL, to: outputURL)
        return ClipRecord(
            label: "Instagram - \(clip.label)",
            filePath: outputURL.path,
            sceneName: clip.sceneName,
            durationSeconds: clip.durationSeconds,
            isInstagramReady: true
        )
    }

    private func recentVideoFiles() async -> [VideoFileCandidate] {
        let roots = await candidateDirectories()
        let allowedExtensions = Set(["mp4", "mov", "mkv", "m4v"])
        var candidates: [VideoFileCandidate] = []

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true,
                      (values.fileSize ?? 0) > 128_000,
                      let modifiedAt = values.contentModificationDate else { continue }
                guard Date().timeIntervalSince(modifiedAt) < 15 * 60 else { continue }
                candidates.append(VideoFileCandidate(url: url, modifiedAt: modifiedAt, durationSeconds: nil))
            }
        }

        return candidates.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func candidateDirectories() async -> [URL] {
        var directories: [URL] = []
        if let recordDirectory = try? await obsClient.getRecordDirectory(), !recordDirectory.isEmpty {
            directories.append(URL(fileURLWithPath: NSString(string: recordDirectory).expandingTildeInPath))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        directories.append(home.appendingPathComponent("Movies"))
        directories.append(home.appendingPathComponent("Movies/OBS"))
        directories.append(home.appendingPathComponent("Desktop"))
        directories.append(home.appendingPathComponent("Downloads"))

        var seen = Set<String>()
        return directories.filter { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            return seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    private func instagramDraftDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies")
            .appendingPathComponent("OBSPhoneCam")
            .appendingPathComponent("Instagram Drafts")
    }

    private func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }
}

private struct VideoFileCandidate {
    let url: URL
    let modifiedAt: Date
    let durationSeconds: Double?

    var path: String { url.path }
}
