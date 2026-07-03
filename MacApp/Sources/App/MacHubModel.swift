import Foundation
import Combine

@MainActor
final class MacHubModel: ObservableObject {
    @Published var obsConfig: OBSConnectionConfig
    @Published var obsStatus: OBSStatus = .disconnected
    @Published var selectedDeviceID: String?
    @Published var clips: [ClipRecord] = []
    @Published var instagramDrafts: [InstagramUploadDraft] = []

    let logger = AppLogger.shared
    let deviceManager: ConnectedDeviceManager
    let discoveryService: DeviceDiscoveryService
    let obsDownlinkService = OBSDownlinkService()
    let obsClient: OBSWebSocketClient
    let obsBrowserSourceServer = OBSBrowserSourceServer()
    let clipManager: OBSClipManager
    let virtualCameraManager = VirtualCameraManager()
    let instagramService = InstagramPublishingService()
    @Published var deviceListenerError: String?
    @Published var obsBrowserSourceMessage: String?
    private var cancellables: Set<AnyCancellable> = []
    private var obsStateTask: Task<Void, Never>?
    private var obsReconnectTask: Task<Void, Never>?
    private var obsReconnectAttempt = 0
    private var isConnectingOBS = false
    private let obsReconnectPolicy = ReconnectPolicy(baseDelay: 1, maxDelay: 8, jitter: 0.5)
    private let obsFastPreviewIntervalNs: UInt64 = 330_000_000
    private let obsStatusRefreshInterval: TimeInterval = 1.2
    private let obsSceneListRefreshInterval: TimeInterval = 4.0
    private let obsScenePreviewRefreshInterval: TimeInterval = 2.5
    private let obsScenePreviewBatchSize = 1
    private let obsOutputPreviewRefreshInterval: TimeInterval = 0.5
    private var cachedOBSScenes: [OBSScene] = []
    private var cachedAudioMeters: [OBSAudioMeter] = []
    private var lastOutputPreviewData: Data?
    private var lastStatusRefresh = Date.distantPast
    private var lastSceneListRefresh = Date.distantPast
    private var scenePreviewCache: [String: Data] = [:]
    private var lastScenePreviewRefresh = Date.distantPast
    private var lastOutputPreviewRefresh = Date.distantPast
    private var lastAudioMeterBroadcast = Date.distantPast
    private var lastAudioMeterPoll = Date.distantPast
    private var scenePreviewRefreshIndex = 0
    private var instagramClipStartedAt: Date?
    private var isTogglingInstagramClip = false
    private var lastInstagramClipToggleAt = Date.distantPast

    init() {
        self.obsConfig = OBSConnectionConfigStore.load()
        self.obsClient = OBSWebSocketClient()
        let deviceManager = ConnectedDeviceManager()
        self.deviceManager = deviceManager
        self.discoveryService = DeviceDiscoveryService(manager: deviceManager)
        self.clipManager = OBSClipManager(obsClient: obsClient)
        obsClient.onAudioMeters = { [weak self] meters in
            guard let self else { return }
            self.cachedAudioMeters = meters
            self.broadcastAudioMetersIfNeeded(meters)
        }
        deviceManager.onControlPacket = { [weak self] packet, deviceID in
            Task { @MainActor in
                await self?.handleControl(packet, from: deviceID)
            }
        }
        deviceManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        discoveryService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        $obsConfig
            .dropFirst()
            .sink { OBSConnectionConfigStore.save($0) }
            .store(in: &cancellables)
        logger.log(.info, .ui, "macOS hub started")
    }

    var devices: [DeviceSessionSnapshot] { deviceManager.snapshots }
    var previewFrames: [String: DevicePreviewFrame] { deviceManager.previewFrames }
    var isDeviceListenerRunning: Bool { discoveryService.isAdvertising }
    var isOBSDownlinkRunning: Bool { obsDownlinkService.isAdvertising }
    var isOBSBrowserSourceRunning: Bool { obsBrowserSourceServer.isRunning }
    var obsBrowserSourceError: String? { obsBrowserSourceServer.lastError }
    var deviceListenerStatusError: String? { deviceListenerError ?? discoveryService.lastError }

    func startDeviceListener() {
        do {
            try discoveryService.start(port: 7777)
            deviceListenerError = nil
        } catch {
            deviceListenerError = error.localizedDescription
            logger.log(.error, .transport, "Device listener failed: \(error.localizedDescription)")
            return
        }

        do {
            try obsDownlinkService.start(port: 7778)
        } catch {
            logger.log(.warning, .transport, "OBS wired downlink unavailable: \(error.localizedDescription)")
        }
    }

    func startOBSStateUpdates() {
        guard obsStateTask == nil else { return }
        obsStateTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAndBroadcastOBSState()
                try? await Task.sleep(nanoseconds: self?.obsFastPreviewIntervalNs ?? 250_000_000)
            }
        }
    }

    func startOBSAutoReconnect() {
        guard obsReconnectTask == nil else { return }
        obsReconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.obsClient.isConnected {
                    self.obsReconnectAttempt = 0
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }

                self.obsReconnectAttempt += 1
                await self.connectOBS()
                let delay = self.obsClient.isConnected
                    ? 3
                    : (self.obsReconnectPolicy.delay(forAttempt: self.obsReconnectAttempt) ?? 8)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func startOBSBrowserSourceServer() {
        obsBrowserSourceServer.start { [weak self] deviceID in
            guard let self else { return nil }
            if let deviceID {
                return self.deviceManager.previewFrames[deviceID]
            }
            return self.deviceManager.previewFrames.values.sorted { $0.updatedAt > $1.updatedAt }.first
        }
    }

    func obsBrowserSourceURL(deviceID: String? = nil) -> String {
        obsBrowserSourceServer.viewURL(deviceID: deviceID)
    }

    func installOBSBrowserSource(deviceID: String? = nil) async {
        do {
            if !obsClient.isConnected {
                try await obsClient.connect(config: obsConfig)
            }
            let status = try await obsClient.refreshStatus()
            obsStatus = status
            let url = obsBrowserSourceURL(deviceID: deviceID)
            try await obsClient.upsertBrowserSource(inputName: "OBS Phone Cam", url: url, sceneName: status.currentScene)
            obsBrowserSourceMessage = "Fuente OBS Phone Cam lista en OBS"
            obsStatus = try await obsClient.refreshStatus()
            logger.log(.info, .obs, "Browser source installed at \(url)")
        } catch {
            obsBrowserSourceMessage = "No se pudo crear la fuente: \(error.localizedDescription)"
            logger.log(.error, .obs, "Browser source install failed: \(error.localizedDescription)")
        }
    }

    func connectOBS() async {
        guard !isConnectingOBS else { return }
        isConnectingOBS = true
        defer { isConnectingOBS = false }
        OBSConnectionConfigStore.save(obsConfig)
        do {
            try await obsClient.connect(config: obsConfig)
            obsStatus = try await obsClient.refreshStatus()
            obsReconnectAttempt = 0
            await refreshAndBroadcastOBSState()
            logger.log(.info, .obs, "OBS connected")
        } catch {
            obsStatus = OBSStatus(connected: false, currentScene: nil, recording: false, streaming: false, replayBufferActive: false, lastError: error.localizedDescription)
            let packet = OBSStatePacket(status: obsStatus, scenes: [])
            discoveryService.broadcastOBSState(packet)
            obsDownlinkService.broadcastOBSState(packet)
            logger.log(.error, .obs, error.localizedDescription)
        }
    }

    func saveReplayBuffer() async {
        await saveReplayBuffer(label: "iPhone clip")
    }

    func markClip() async {
        await saveReplayBuffer(label: "Marca \(Date().formatted(date: .omitted, time: .standard))")
    }

    func prepareInstagramDraft(for clip: ClipRecord) async {
        do {
            let instagramClip = try await clipManager.prepareInstagramVideo(from: clip)
            clips.insert(instagramClip, at: 0)
            let draft = InstagramUploadDraft(
                clip: instagramClip,
                caption: defaultInstagramCaption(for: instagramClip),
                hashtags: ["ifeedeparty", "live", "clip"],
                mode: .manualExport
            )
            instagramDrafts.insert(draft, at: 0)
            instagramService.prepareManualShare(for: instagramClip, caption: draft.caption)
            logger.log(.info, .instagram, "Instagram draft ready: \(instagramClip.filePath)")
        } catch {
            instagramService.lastMessage = error.localizedDescription
            logger.log(.error, .instagram, error.localizedDescription)
        }
    }

    private func saveReplayBuffer(label: String) async {
        guard obsStatus.replayBufferAvailable, obsStatus.replayBufferActive else {
            logger.log(.warning, .clips, "Replay Buffer is not active in OBS")
            return
        }
        do {
            let clip = try await clipManager.saveReplayBuffer(label: label)
            clips.insert(clip, at: 0)
            logger.log(.info, .clips, "Clip saved: \(clip.filePath)")
        } catch {
            logger.log(.error, .clips, error.localizedDescription)
        }
    }

    private func toggleInstagramClip() async {
        guard !isTogglingInstagramClip else { return }
        guard Date().timeIntervalSince(lastInstagramClipToggleAt) > 0.8 else { return }
        lastInstagramClipToggleAt = Date()
        isTogglingInstagramClip = true
        defer { isTogglingInstagramClip = false }

        if instagramClipStartedAt == nil {
            await beginInstagramClip()
        } else {
            await finishInstagramClip()
        }
    }

    private func beginInstagramClip() async {
        do {
            obsStatus = try await obsClient.refreshStatus()
            guard obsStatus.replayBufferAvailable else {
                logger.log(.warning, .clips, "No se puede armar Clip IG: Replay Buffer no disponible en OBS")
                return
            }
            if !obsStatus.replayBufferActive {
                try await obsClient.startReplayBuffer()
                try? await Task.sleep(nanoseconds: 300_000_000)
                obsStatus = try await obsClient.refreshStatus()
            }
            guard obsStatus.replayBufferActive else {
                logger.log(.warning, .clips, "No se puede armar Clip IG: Replay Buffer no quedó activo")
                return
            }
            instagramClipStartedAt = Date()
            logger.log(.info, .clips, "Clip IG armado")
        } catch {
            logger.log(.error, .clips, "No se pudo armar Clip IG: \(error.localizedDescription)")
        }
    }

    private func finishInstagramClip() async {
        let startedAt = instagramClipStartedAt
        instagramClipStartedAt = nil
        let duration = startedAt.map { max(1, Date().timeIntervalSince($0)) }
        let label: String
        if let duration {
            label = "Clip IG \(Int(round(duration)))s"
        } else {
            label = "Clip IG"
        }

        guard obsStatus.replayBufferAvailable, obsStatus.replayBufferActive else {
            logger.log(.warning, .clips, "No se pudo cerrar Clip IG: Replay Buffer no está activo")
            return
        }

        do {
            let clip = try await clipManager.saveReplayBuffer(label: label, durationFromEnd: duration)
            clips.insert(clip, at: 0)
            logger.log(.info, .clips, "Clip IG guardado: \(clip.filePath)")
            await prepareInstagramDraft(for: clip)
        } catch {
            logger.log(.error, .clips, "No se pudo guardar Clip IG: \(error.localizedDescription)")
        }
    }

    private func defaultInstagramCaption(for clip: ClipRecord) -> String {
        var parts = ["\(clip.label)"]
        if let sceneName = clip.sceneName {
            parts.append(sceneName)
        }
        parts.append("#ifeedeparty #live")
        return parts.joined(separator: " · ")
    }

    private func handleControl(_ packet: ControlPacket, from deviceID: String?) async {
        do {
            if !obsClient.isConnected {
                try await obsClient.connect(config: obsConfig)
            }
            switch packet.command {
            case .startRecording:
                try await obsClient.startRecord()
                obsStatus = try await obsClient.refreshStatus()
            case .stopRecording:
                try await obsClient.stopRecord()
                obsStatus = try await obsClient.refreshStatus()
            case .startStreaming:
                try await obsClient.startStream()
                obsStatus = try await obsClient.refreshStatus()
            case .stopStreaming:
                try await obsClient.stopStream()
                obsStatus = try await obsClient.refreshStatus()
            case .saveReplayBuffer:
                await saveReplayBuffer()
            case .markClip:
                await markClip()
            case .switchScene:
                guard let sceneName = packet.arguments["sceneName"], !sceneName.isEmpty else { return }
                try await obsClient.setCurrentProgramScene(sceneName)
                obsStatus = try await obsClient.refreshStatus()
            case .applyInstagramLiveCrop, .toggleInstagramClip:
                await toggleInstagramClip()
            case .restartConnection, .switchCamera, .muteAudio, .unmuteAudio:
                logger.log(.debug, .device, "Local iPhone command ignored by Mac Hub: \(packet.command.rawValue)", deviceID: deviceID)
            }
            await refreshAndBroadcastOBSState()
        } catch {
            logger.log(.error, .obs, "Control command failed: \(error.localizedDescription)", deviceID: deviceID)
            obsStatus = OBSStatus(
                connected: obsClient.isConnected,
                currentScene: obsStatus.currentScene,
                recording: obsStatus.recording,
                streaming: obsStatus.streaming,
                replayBufferAvailable: obsStatus.replayBufferAvailable,
                replayBufferActive: obsStatus.replayBufferActive,
                lastError: error.localizedDescription
            )
            await refreshAndBroadcastOBSState()
        }
    }

    private func refreshAndBroadcastOBSState() async {
        guard obsClient.isConnected else {
            let packet = OBSStatePacket(status: obsStatus, scenes: [])
            discoveryService.broadcastOBSState(packet)
            obsDownlinkService.broadcastOBSState(packet)
            return
        }

        let now = Date()
        var scenes: [OBSScene] = []
        var previewData: Data?
        do {
            if now.timeIntervalSince(lastStatusRefresh) >= obsStatusRefreshInterval {
                obsStatus = try await obsClient.refreshStatus()
                lastStatusRefresh = now
            }

            if now.timeIntervalSince(lastAudioMeterPoll) >= 0.6 {
                cachedAudioMeters = (try? await obsClient.getInputVolumeMeters()) ?? cachedAudioMeters
                lastAudioMeterPoll = now
            }

            let sceneListChanged = try await refreshSceneListIfNeeded(at: now)
            let scenePreviewsChanged = await refreshScenePreviewBatchIfNeeded(at: now)
            if sceneListChanged || scenePreviewsChanged {
                scenes = scenesWithCachedPreviewImages()
            }

            if now.timeIntervalSince(lastOutputPreviewRefresh) >= obsOutputPreviewRefreshInterval {
                if let sceneName = obsStatus.currentScene {
                    previewData = try? await obsClient.takeSourceScreenshot(sourceName: sceneName, width: 320, height: 180, compressionQuality: 55)
                }
                if previewData == nil {
                    previewData = try? await obsClient.takeSourceScreenshot(sourceName: "OBS Phone Cam", width: 320, height: 180, compressionQuality: 55)
                }
                if let previewData {
                    lastOutputPreviewData = previewData
                    lastOutputPreviewRefresh = now
                }
            }
        } catch {
            obsStatus = OBSStatus(
                connected: obsClient.isConnected,
                currentScene: obsStatus.currentScene,
                recording: obsStatus.recording,
                streaming: obsStatus.streaming,
                replayBufferAvailable: obsStatus.replayBufferAvailable,
                replayBufferActive: obsStatus.replayBufferActive,
                lastError: error.localizedDescription
            )
        }
        let packet = OBSStatePacket(status: obsStatus, scenes: scenes, previewImageData: previewData ?? lastOutputPreviewData, audioMeters: cachedAudioMeters)
        if obsDownlinkService.hasClients {
            obsDownlinkService.broadcastOBSState(packet)
            discoveryService.broadcastLightweightOBSState(packet)
        } else {
            discoveryService.broadcastOBSState(packet)
        }
    }

    private func broadcastAudioMetersIfNeeded(_ meters: [OBSAudioMeter]) {
        let now = Date()
        guard now.timeIntervalSince(lastAudioMeterBroadcast) >= 0.08 else { return }
        lastAudioMeterBroadcast = now

        let packet = OBSStatePacket(status: obsStatus, scenes: [], previewImageData: nil, audioMeters: meters)
        if obsDownlinkService.hasClients {
            obsDownlinkService.broadcastOBSState(packet)
            discoveryService.broadcastLightweightOBSState(packet)
        } else {
            discoveryService.broadcastOBSState(packet)
        }
    }

    private func refreshSceneListIfNeeded(at now: Date) async throws -> Bool {
        guard cachedOBSScenes.isEmpty || now.timeIntervalSince(lastSceneListRefresh) >= obsSceneListRefreshInterval else {
            return false
        }

        let latestScenes = try await obsClient.getSceneList()
        lastSceneListRefresh = now
        let changed = latestScenes.map(\.sceneName) != cachedOBSScenes.map(\.sceneName)
        cachedOBSScenes = latestScenes

        let validSceneNames = Set(latestScenes.map(\.sceneName))
        scenePreviewCache = scenePreviewCache.filter { validSceneNames.contains($0.key) }
        if scenePreviewRefreshIndex >= max(latestScenes.count, 1) {
            scenePreviewRefreshIndex = 0
        }

        return changed || latestScenes.contains { scenePreviewCache[$0.sceneName] == nil }
    }

    private func refreshScenePreviewBatchIfNeeded(at now: Date) async -> Bool {
        guard !cachedOBSScenes.isEmpty else { return false }
        guard now.timeIntervalSince(lastScenePreviewRefresh) >= obsScenePreviewRefreshInterval else { return false }
        lastScenePreviewRefresh = now

        var refreshed = false
        let count = cachedOBSScenes.count
        for _ in 0..<min(obsScenePreviewBatchSize, count) {
            let index = scenePreviewRefreshIndex % count
            scenePreviewRefreshIndex = (scenePreviewRefreshIndex + 1) % count
            let scene = cachedOBSScenes[index]
            if let data = try? await obsClient.takeSourceScreenshot(sourceName: scene.sceneName, width: 192, height: 108, compressionQuality: 52) {
                if scenePreviewCache[scene.sceneName] != data {
                    scenePreviewCache[scene.sceneName] = data
                    refreshed = true
                }
            }
        }
        return refreshed
    }

    private func scenesWithCachedPreviewImages() -> [OBSScene] {
        cachedOBSScenes.map { scene in
            var updated = scene
            updated.previewImageData = scenePreviewCache[scene.sceneName]
            return updated
        }
    }
}
