import SwiftUI

struct SceneMappingView: View {
    let devices: [DeviceSessionSnapshot]
    let scenes: [OBSScene]
    @State private var mappings: [String: String] = [:]

    var body: some View {
        Form {
            ForEach(devices) { device in
                Picker(device.name, selection: Binding(
                    get: { mappings[device.id] ?? "" },
                    set: { mappings[device.id] = $0 }
                )) {
                    Text("Sin asignar").tag("")
                    ForEach(scenes) { scene in Text(scene.sceneName).tag(scene.sceneName) }
                }
            }
        }
        .navigationTitle("Mapeo a OBS")
    }
}
