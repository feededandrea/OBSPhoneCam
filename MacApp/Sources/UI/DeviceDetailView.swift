import SwiftUI

struct DeviceDetailView: View {
    let device: DeviceSessionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderCard(title: device.name, subtitle: device.state.userTitle)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow { Text("FPS"); Text(String(format: "%.1f", device.metrics.fps)) }
                GridRow { Text("Bitrate"); Text(String(format: "%.0f", device.metrics.bitrate)) }
                GridRow { Text("Dropped"); Text("\(device.metrics.droppedFrames)") }
                GridRow { Text("Latency"); Text(String(format: "%.0f ms", device.metrics.latencyMs)) }
            }
            Spacer()
        }
        .padding()
    }
}
