import Foundation
import Combine

@MainActor
final class OBSSceneManager: ObservableObject {
    @Published var scenes: [OBSScene] = []
    @Published var currentScene: String?

    private let client: OBSWebSocketClient

    init(client: OBSWebSocketClient) {
        self.client = client
    }

    func refresh() async {
        do { scenes = try await client.getSceneList() }
        catch { AppLogger.shared.log(.error, .obs, error.localizedDescription) }
    }

    func switchTo(_ scene: OBSScene) async {
        do {
            try await client.setCurrentProgramScene(scene.sceneName)
            currentScene = scene.sceneName
        } catch {
            AppLogger.shared.log(.error, .obs, error.localizedDescription)
        }
    }
}
