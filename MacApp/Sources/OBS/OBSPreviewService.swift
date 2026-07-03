import Foundation

@MainActor
final class OBSPreviewService: ObservableObject {
    @Published private(set) var latestPreviewData: Data?
    private let client: OBSWebSocketClient

    init(client: OBSWebSocketClient) {
        self.client = client
    }

    func requestSourceScreenshot(sourceName: String) async {
        do {
            _ = try await client.sendRequest("GetSourceScreenshot", data: [
                "sourceName": .string(sourceName),
                "imageFormat": .string("png"),
                "imageWidth": .int(640),
                "imageHeight": .int(360)
            ])
        } catch {
            AppLogger.shared.log(.error, .obs, "Preview failed: \(error.localizedDescription)")
        }
    }
}
