import SwiftUI

struct MiniPreviewView: View {
    let title: String
    let imageData: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.bold())
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.45))
                if let imageData, let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage).resizable().scaledToFill()
                } else {
                    Image(systemName: "rectangle.dashed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
