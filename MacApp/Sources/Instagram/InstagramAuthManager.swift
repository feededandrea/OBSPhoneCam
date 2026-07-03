import Foundation
import Combine

@MainActor
final class InstagramAuthManager: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var accountName: String?

    func startOAuthFlow() {
        // TODO: ASWebAuthenticationSession + Meta OAuth.
        AppLogger.shared.log(.info, .instagram, "OAuth flow requested")
    }

    func signOut() {
        isAuthenticated = false
        accountName = nil
        AppLogger.shared.log(.info, .instagram, "Instagram disconnected")
    }
}
