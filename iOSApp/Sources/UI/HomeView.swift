import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: IOSAppModel
    @State private var activeDrawer: CameraDrawer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                CameraView()
                    .ignoresSafeArea()

                if activeDrawer != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture {
                            activeDrawer = nil
                        }
                }

                VStack(spacing: 10) {
                    CameraTopOverlay(activeDrawer: $activeDrawer)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                    Spacer()
                    if let activeDrawer {
                        if activeDrawer == .scenes {
                            SceneSwitcherView(scenes: model.obsScenes, currentScene: model.obsStatus.currentScene) { scene in
                                Task { await model.switchOBSScene(scene) }
                            }
                            .padding(.horizontal, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else if activeDrawer == .controls {
                            HStack {
                                Spacer()
                                CameraDrawerView(drawer: activeDrawer, activeDrawer: $activeDrawer)
                                    .frame(width: 286)
                                    .padding(.trailing, 10)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        } else {
                            CameraDrawerView(drawer: activeDrawer, activeDrawer: $activeDrawer)
                                .padding(.horizontal, 10)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    CameraBottomBar(activeDrawer: $activeDrawer)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
                .animation(.easeInOut(duration: 0.18), value: activeDrawer)
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                model.startHubDiscovery()
                await model.startCamera()
            }
        }
    }
}

enum CameraDrawer: Hashable {
    case obsPreview
    case scenes
    case controls
    case settings
}

struct CameraTopOverlay: View {
    @EnvironmentObject private var model: IOSAppModel
    @Binding var activeDrawer: CameraDrawer?

    var body: some View {
        HStack(spacing: 8) {
            CompactStatusPill(title: model.connectionState.userTitle, systemImage: "antenna.radiowaves.left.and.right", color: model.connectionState == .streaming ? .green : .yellow)
            CompactStatusPill(title: model.activeTransportDescription, systemImage: "cable.connector", color: model.cableOnlyMode ? .blue : .gray)
            if model.isOBSDownlinkConnected {
                CompactStatusPill(title: "OBS cable", systemImage: "arrow.down.to.line.compact", color: .blue)
            }
            Spacer()
            Button {
                toggle(.obsPreview)
            } label: {
                OBSOutputThumbnail(imageData: model.obsPreviewImageData, isLive: model.obsStatus.connected)
            }
            .buttonStyle(.plain)
            Button {
                Task { await model.restartConnection() }
            } label: {
                Label("Reconectar", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(CameraIconButtonStyle())
        }
    }

    private func toggle(_ drawer: CameraDrawer) {
        activeDrawer = activeDrawer == drawer ? nil : drawer
    }
}

struct CameraBottomBar: View {
    @EnvironmentObject private var model: IOSAppModel
    @Binding var activeDrawer: CameraDrawer?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.toggleInstagramClip() }
            } label: {
                Label(model.instagramClipActive ? "Cerrar clip" : "Clip IG", systemImage: model.instagramClipActive ? "stop.circle.fill" : "scissors")
            }
            .buttonStyle(CameraTextButtonStyle(tint: model.instagramClipActive ? .red : .pink))
            .disabled(model.instagramClipCommandInFlight)

            Spacer(minLength: 4)

            Button {
                Task { await model.cameraManager.switchCamera() }
            } label: {
                Label("Cámara", systemImage: "arrow.triangle.2.circlepath.camera")
            }
            .buttonStyle(CameraIconButtonStyle(tint: .white))
            .disabled(!model.cameraAvailable)

            Button {
                Task { await model.sendOBSCommand(model.obsStatus.recording ? .stopRecording : .startRecording) }
            } label: {
                Label("REC", systemImage: model.obsStatus.recording ? "stop.circle.fill" : "record.circle")
            }
            .buttonStyle(CameraIconButtonStyle(tint: .red, isActive: model.obsStatus.recording))

            Button {
                Task { await model.sendOBSCommand(model.obsStatus.streaming ? .stopStreaming : .startStreaming) }
            } label: {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(CameraIconButtonStyle(tint: .green, isActive: model.obsStatus.streaming))

            Button {
                toggle(.scenes)
            } label: {
                Label("Escenas", systemImage: "rectangle.3.group")
            }
            .buttonStyle(CameraIconButtonStyle(isActive: activeDrawer == .scenes))

            Button {
                toggle(.controls)
            } label: {
                Label("Controles", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(CameraIconButtonStyle(isActive: activeDrawer == .controls))
        }
    }

    private func toggle(_ drawer: CameraDrawer) {
        activeDrawer = activeDrawer == drawer ? nil : drawer
    }
}

struct CameraDrawerView: View {
    @EnvironmentObject private var model: IOSAppModel
    let drawer: CameraDrawer
    @Binding var activeDrawer: CameraDrawer?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button {
                    activeDrawer = nil
                } label: {
                    Label("Cerrar", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
            }

            switch drawer {
            case .obsPreview:
                HStack(alignment: .top, spacing: 12) {
                    MiniPreviewView(title: "OBS output", imageData: model.obsPreviewImageData)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.obsStatus.currentScene ?? "Sin escena")
                            .font(.subheadline.bold())
                        Text(model.obsStatus.connected ? "Conectado" : "Desconectado")
                            .font(.caption)
                            .foregroundStyle(model.obsStatus.connected ? .green : .red)
                        if let error = model.obsStatus.lastError ?? model.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(3)
                        }
                    }
                }
            case .scenes:
                EmptyView()
            case .controls:
                CameraCommandGrid(activeDrawer: $activeDrawer)
            case .settings:
                SettingsView()
            }
        }
        .padding(drawer == .scenes ? 8 : 12)
        .frame(maxWidth: drawer == .controls ? 286 : (drawer == .scenes ? 780 : .infinity), alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var title: String {
        switch drawer {
        case .obsPreview: return "OBS"
        case .scenes: return "Escenas"
        case .controls: return "Controles"
        case .settings: return "Ajustes"
        }
    }
}

struct OBSOutputThumbnail: View {
    let imageData: Data?
    let isLive: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55))
                if let imageData, let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "display")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 1))

            Circle()
                .fill(isLive ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .padding(5)
        }
    }
}

struct CameraCommandGrid: View {
    @EnvironmentObject private var model: IOSAppModel
    @Binding var activeDrawer: CameraDrawer?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 8)], spacing: 8) {
            DrawerCommandButton(title: "Replay", systemImage: "scissors") {
                Task { await model.sendOBSCommand(.saveReplayBuffer) }
            }
            DrawerCommandButton(title: "Marca", systemImage: "flag") {
                Task { await model.sendOBSCommand(.markClip) }
            }
            DrawerCommandButton(title: "Ajustes", systemImage: "gearshape") {
                activeDrawer = .settings
            }
            DrawerCommandButton(title: "Reconectar", systemImage: "arrow.clockwise") {
                Task { await model.restartConnection() }
            }
        }
    }
}

struct CompactStatusPill: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .foregroundStyle(.white)
            .background(color.opacity(0.62), in: Capsule())
    }
}

struct DrawerCommandButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
        }
        .buttonStyle(.borderedProminent)
    }
}

struct CameraIconButtonStyle: ButtonStyle {
    var tint: Color = .white
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 17, weight: .bold))
            .frame(width: 44, height: 44)
            .foregroundStyle(isActive ? .black : tint)
            .background((isActive ? tint : Color.black.opacity(0.42)).opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
    }
}

struct CameraTextButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .foregroundStyle(.white)
            .background(tint.opacity(configuration.isPressed ? 0.65 : 0.9), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
