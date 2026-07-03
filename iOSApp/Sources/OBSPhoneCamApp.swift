import SwiftUI

@main
struct OBSPhoneCamApp: App {
    @StateObject private var model = IOSAppModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
