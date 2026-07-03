import SwiftUI

struct CameraView: View {
    @EnvironmentObject private var model: IOSAppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.cameraAvailable {
                CameraPreviewView(session: model.cameraManager.session)
                    .overlay {
                        FocusGuideOverlay(mode: guideMode(for: model.obsStatus.currentScene))
                    }
                    .overlay(alignment: .trailing) {
                        OBSAudioLevelMeter(meters: model.obsAudioMeters, isConnected: model.obsStatus.connected)
                            .padding(.trailing, 10)
                    }
                    .overlay(alignment: .topLeading) {
                        Text(model.cameraManager.isRunning ? "CAM LIVE" : "CAM OFF")
                            .font(.caption.bold())
                            .padding(8)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding()
                    }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 44, weight: .semibold))
                    Text("Cámara no disponible")
                        .font(.headline)
                    if let error = model.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
    }

    private func guideMode(for sceneName: String?) -> FocusGuideMode {
        guard let sceneName else { return .rectangular }
        let normalized = sceneName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        if normalized.contains("+") || normalized.contains("camera 2") || normalized.contains("trasera") || normalized.contains("garage") {
            return .square
        }
        if normalized.contains("principal") || normalized.contains("camara") || normalized.contains("camera") {
            return .rectangular
        }
        return .none
    }
}

struct OBSAudioLevelMeter: View {
    let meters: [OBSAudioMeter]
    let isConnected: Bool

    private var primaryMeter: OBSAudioMeter? { meters.first }
    private var peakDb: Double { primaryMeter?.peakDb ?? -60 }
    private var normalizedLevel: Double { min(1, max(0, primaryMeter?.normalizedLevel ?? 0)) }
    private var displayName: String {
        guard let name = primaryMeter?.inputName, !name.isEmpty else { return "OBS" }
        return name
    }

    var body: some View {
        VStack(spacing: 6) {
            Text("AUDIO")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.white.opacity(0.82))

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.12))

                GeometryReader { proxy in
                    let height = proxy.size.height * normalizedLevel
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        meterColor
                            .frame(height: height)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                VStack {
                    thresholdLine(at: 0.82, color: .red.opacity(0.72))
                    Spacer()
                    thresholdLine(at: 0.68, color: .yellow.opacity(0.72))
                    Spacer()
                }
                .padding(.vertical, 11)
            }
            .frame(width: 14, height: 86)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 1))

            Text(dbText)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(meterColor)
                .frame(width: 42)

            Text(displayName)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(width: 46)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.46), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1))
        .opacity(isConnected ? 1 : 0.62)
        .allowsHitTesting(false)
    }

    private var dbText: String {
        guard primaryMeter != nil else { return "-∞" }
        return "\(Int(round(peakDb)))"
    }

    private var meterColor: Color {
        if primaryMeter == nil { return .gray }
        if peakDb > -6 { return .red }
        if peakDb > -14 { return .yellow }
        if peakDb > -50 { return .green }
        return .gray
    }

    private func thresholdLine(at _: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
            .padding(.horizontal, 2)
    }
}

enum FocusGuideMode {
    case none
    case rectangular
    case square
}

struct FocusGuideOverlay: View {
    let mode: FocusGuideMode

    var body: some View {
        GeometryReader { proxy in
            let rect = guideRect(in: proxy.size)
            if mode != .none {
                ZStack {
                    Path { path in
                        path.addRect(rect)
                        path.move(to: CGPoint(x: rect.minX + rect.width / 3, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.minX + rect.width / 3, y: rect.maxY))
                        path.move(to: CGPoint(x: rect.minX + rect.width * 2 / 3, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.minX + rect.width * 2 / 3, y: rect.maxY))
                        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height / 3))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height / 3))
                        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 2 / 3))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 2 / 3))
                    }
                    .stroke(Color.white.opacity(0.78), style: StrokeStyle(lineWidth: 1, dash: [7, 5]))

                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.yellow.opacity(0.88), lineWidth: 2)
                        .frame(width: min(rect.width, rect.height) * 0.18, height: min(rect.width, rect.height) * 0.18)
                        .position(x: rect.midX, y: rect.midY)
                }
                .shadow(color: .black.opacity(0.6), radius: 2)
            }
        }
        .allowsHitTesting(false)
    }

    private func guideRect(in size: CGSize) -> CGRect {
        let horizontalInset = size.width * 0.045
        let availableWidth = size.width - horizontalInset * 2
        let availableHeight = size.height * 0.86
        let width: CGFloat
        let height: CGFloat

        switch mode {
        case .none:
            width = 0
            height = 0
        case .rectangular:
            width = min(availableWidth, availableHeight * 16 / 9)
            height = width * 9 / 16
        case .square:
            let side = min(availableWidth, availableHeight) * 0.98
            width = side
            height = side
        }

        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }
}
