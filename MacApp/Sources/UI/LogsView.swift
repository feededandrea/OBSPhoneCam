import SwiftUI

struct LogsView: View {
    @ObservedObject private var logger = AppLogger.shared

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Logs").font(.largeTitle.bold())
                Spacer()
                Button("Limpiar") { logger.clear() }
            }
            List(logger.entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.level.rawValue.uppercased()).font(.caption.bold())
                        Text(entry.category.rawValue).font(.caption)
                        Spacer()
                        Text(entry.timestamp.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(entry.message)
                    if let deviceID = entry.deviceID { Text(deviceID).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .padding()
    }
}
