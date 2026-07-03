import SwiftUI

@main
struct OBSCameraHubApp: App {
    @StateObject private var model = MacHubModel()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1100, minHeight: 720)
        }
        Settings {
            OBSConnectionView()
                .environmentObject(model)
                .frame(width: 460)
        }
    }
}
