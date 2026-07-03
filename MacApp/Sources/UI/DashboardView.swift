import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: MacHubModel
    @State private var selection: SidebarItem? = .devices

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarItem.allCases) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.icon)
                    }
                }
            }
            .navigationTitle("OBS Camera Hub")
        } detail: {
            switch selection ?? .devices {
            case .devices: DeviceListView()
            case .obs: OBSConnectionView()
            case .clips: ClipLibraryView()
            case .logs: LogsView()
            case .virtualCamera: VirtualCameraView()
            }
        }
        .toolbar {
            Picker("Sección", selection: Binding(
                get: { selection ?? .devices },
                set: { selection = $0 }
            )) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
            }
            .pickerStyle(.menu)
            Button("Conectar OBS") { Task { await model.connectOBS() } }
            Button("Guardar replay") { Task { await model.saveReplayBuffer() } }
                .disabled(!model.obsStatus.connected || !model.obsStatus.replayBufferActive)
        }
        .task {
            model.startDeviceListener()
            model.startOBSBrowserSourceServer()
            model.startOBSStateUpdates()
            model.startOBSAutoReconnect()
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case devices, obs, virtualCamera, clips, logs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .devices: return "Dispositivos"
        case .obs: return "OBS"
        case .virtualCamera: return "Cámara virtual"
        case .clips: return "Clips"
        case .logs: return "Logs"
        }
    }
    var icon: String {
        switch self {
        case .devices: return "iphone.gen3"
        case .obs: return "display"
        case .virtualCamera: return "video"
        case .clips: return "scissors"
        case .logs: return "list.bullet.rectangle"
        }
    }
}
