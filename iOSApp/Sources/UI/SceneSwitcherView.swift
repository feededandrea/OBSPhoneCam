import SwiftUI

struct SceneSwitcherView: View {
    let scenes: [OBSScene]
    let currentScene: String?
    let onSelect: (OBSScene) -> Void

    var body: some View {
        if scenes.isEmpty {
            Label("Sin escenas", systemImage: "rectangle.3.group")
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.8))
                .padding(10)
                .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(scenes) { scene in
                        SceneTile(
                            scene: scene,
                            isSelected: scene.sceneName == currentScene,
                            onSelect: { onSelect(scene) }
                        )
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 2)
            }
            .frame(height: 112)
        }
    }
}

struct SceneTile: View {
    let scene: OBSScene
    let isSelected: Bool
    let onSelect: () -> Void

    private var metadata: SceneVisualMetadata {
        SceneVisualMetadata(sceneName: scene.sceneName)
    }

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .bottomLeading) {
                if let data = scene.previewImageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(colors: metadata.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: metadata.iconName)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white.opacity(0.78))
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack {
                    Spacer()
                    HStack(alignment: .bottom, spacing: 4) {
                        Image(systemName: metadata.iconName)
                            .font(.system(size: 10, weight: .black))
                            .frame(width: 12)
                        Text(shortName)
                            .font(.system(size: 10, weight: .black))
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 11)
                    .padding(.trailing, 6)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .background(Color.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(6)
                }

                if isSelected {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .black))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.black, .white)
                                .padding(6)
                        }
                        Spacer()
                    }
                }
            }
            .frame(width: 116, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.white : Color.white.opacity(0.22), lineWidth: isSelected ? 3 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var shortName: String {
        var name = scene.sceneName
            .replacingOccurrences(of: "Camara principal", with: "Principal")
            .replacingOccurrences(of: "Cámara principal", with: "Principal")
            .replacingOccurrences(of: "camera", with: "cam")
            .replacingOccurrences(of: "Camera", with: "Cam")
            .replacingOccurrences(of: "camara", with: "cam")
            .replacingOccurrences(of: "Cámara", with: "Cam")
            .replacingOccurrences(of: "principal", with: "prin")
        name = name.replacingOccurrences(of: " + ", with: "\n+ ")
        return name
    }
}

private struct SceneVisualMetadata {
    let iconName: String
    let colors: [Color]

    init(sceneName: String) {
        let normalized = sceneName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        if normalized.contains("logo") || normalized.contains("mtv") {
            iconName = "sparkles.tv"
            colors = [Color.pink.opacity(0.88), Color.purple.opacity(0.82), Color.black]
        } else if normalized.contains("garage") {
            iconName = "door.garage.open"
            colors = [Color.orange.opacity(0.88), Color.gray.opacity(0.74), Color.black]
        } else if normalized.contains("trasera") || normalized.contains("back") {
            iconName = "arrow.uturn.backward.circle"
            colors = [Color.indigo.opacity(0.9), Color.blue.opacity(0.74), Color.black]
        } else if normalized.contains("+") || normalized.contains("cam 2") || normalized.contains("camera 2") {
            iconName = "square.grid.2x2"
            colors = [Color.teal.opacity(0.88), Color.blue.opacity(0.72), Color.black]
        } else if normalized.contains("principal") || normalized.contains("camara") || normalized.contains("camera") {
            iconName = "camera.viewfinder"
            colors = [Color.green.opacity(0.82), Color.mint.opacity(0.62), Color.black]
        } else {
            iconName = "rectangle.3.group"
            colors = [Color.gray.opacity(0.86), Color.blue.opacity(0.54), Color.black]
        }
    }
}
