import Foundation
import UIKit
import Combine
import Network

@MainActor
final class IOSAppModel: ObservableObject {
    @Published var identity: DeviceIdentity
    @Published var connectionState: ConnectionState = .disconnected
    @Published var obsStatus: OBSStatus = .disconnected
    @Published var obsScenes: [OBSScene] = []
    @Published var obsPreviewImageData: Data?
    @Published var obsAudioMeters: [OBSAudioMeter] = []
    @Published var selectedQuality: StreamQuality = .medium1080p
    @Published var streamMode: StreamMode = .lowLatency
    @Published var cableOnlyMode = false
    @Published private(set) var activeTransportDescription = "Sin conexión"
    @Published private(set) var obsDownlinkDescription = "Sin retorno por cable"
    @Published private(set) var isOBSDownlinkConnected = false
    @Published var macHost: String = "127.0.0.1"
    @Published var macPort: Int = 7777
    @Published var lastError: String?
    @Published var cameraAvailable = true

    let cameraManager = CameraCaptureManager()
    let hubDiscovery = MacHubDiscoveryService()
    let logger = AppLogger.shared
    private let transport = NetworkStreamTransport()
    private let obsDownlink = OBSWiredDownlinkClient()
    private let frameStreamer: PreviewFrameStreamer
    private let reconnectPolicy = ReconnectPolicy()
    private var reconnectAttempt = 0
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var cablePreferenceTask: Task<Void, Never>?
    private var heartbeatSequence: UInt64 = 0
    private var discoveredMacEndpoint: NWEndpoint?
    private var savedMacEndpoint: IOSConnectionPreferences.MacEndpoint?
    private var didAutoConnectToDiscoveredHub = false
    private var suppressTransportDisconnectCallback = false
    private var isCableUpgradeInProgress = false
    private var zeroFPSHeartbeatCount = 0
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let preferences = IOSConnectionPreferencesStore.load()
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let identity = DeviceIdentityStore.load(defaultName: device.name, model: device.model, osVersion: device.systemVersion)
        self.identity = identity
        self.frameStreamer = PreviewFrameStreamer(deviceID: identity.id, transport: transport)
        self.selectedQuality = preferences.selectedQuality.prefersFastCableFPS
        self.streamMode = preferences.streamMode
        self.cableOnlyMode = preferences.cableOnlyMode || preferences.selectedQuality.prefersFastCableFPS == .max1080p40
        self.macHost = preferences.macHost
        self.macPort = preferences.macPort
        self.savedMacEndpoint = preferences.lastMacEndpoint
        self.discoveredMacEndpoint = preferences.lastMacEndpoint?.nwEndpoint
        self.obsScenes = OBSSceneCacheStore.load()
        self.frameStreamer.configure(quality: selectedQuality)
        self.hubDiscovery.requiredInterfaceType = self.cableOnlyMode ? .wiredEthernet : nil
        self.transport.onOBSState = { [weak self] packet in
            Task { @MainActor in
                self?.applyOBSState(packet)
            }
        }
        self.obsDownlink.onOBSState = { [weak self] packet in
            Task { @MainActor in
                self?.applyOBSState(packet)
            }
        }
        self.obsDownlink.onStateChange = { [weak self] description, connected in
            Task { @MainActor in
                self?.obsDownlinkDescription = description
                self?.isOBSDownlinkConnected = connected
            }
        }
        self.transport.onDisconnect = { [weak self] reason in
            Task { @MainActor in
                self?.handleTransportDisconnect(reason)
            }
        }
        cameraManager.videoSampleHandler = { [frameStreamer] sampleBuffer in
            frameStreamer.handleVideoSampleBuffer(sampleBuffer)
        }
        hubDiscovery.onEndpointFound = { [weak self] endpoint, name in
            guard let self else { return }
            self.discoveredMacEndpoint = endpoint
            self.savedMacEndpoint = IOSConnectionPreferences.MacEndpoint(endpoint: endpoint)
            self.macHost = name
            self.persistConnectionPreferences()
            self.lastError = nil
            guard !self.didAutoConnectToDiscoveredHub, self.connectionState == .disconnected || self.connectionState == .failed else { return }
            self.didAutoConnectToDiscoveredHub = true
            Task { await self.connectToMac() }
        }
        setupPersistenceBindings()
        logger.log(.info, .ui, "iOS app started", deviceID: identity.id)
    }

    func startHubDiscovery() {
        hubDiscovery.start()
        obsDownlink.start()
        connectToSavedMacIfPossible()
        scheduleManualHostFallbackIfNeeded()
        startCablePreferenceMonitor()
    }

    func startCamera() async {
        #if targetEnvironment(simulator)
        cameraAvailable = false
        lastError = "El simulador no expone una cámara real estable para esta app. Usalo para probar UI/conexión; para video real, corré en iPhone físico."
        logger.log(.warning, .camera, "Camera startup skipped on Simulator", deviceID: identity.id)
        return
        #endif

        do {
            frameStreamer.configure(quality: selectedQuality)
            try await cameraManager.configure(quality: selectedQuality)
            try await cameraManager.start()
            cameraAvailable = true
            logger.log(.info, .camera, "Camera started", deviceID: identity.id)
        } catch {
            cameraAvailable = false
            lastError = error.localizedDescription
            logger.log(.error, .camera, error.localizedDescription, deviceID: identity.id)
        }
    }

    func connectToMac() async {
        guard connectionState != .connecting, connectionState != .handshaking else { return }
        guard !(connectionState == .streaming && transport.isConnected) else { return }
        connectionState = .connecting
        logger.log(.info, .transport, "Connecting to Mac \(macHost):\(macPort)", deviceID: identity.id)
        do {
            if let endpoint = discoveredMacEndpoint ?? savedMacEndpoint?.nwEndpoint {
                try await connectToPreferredEndpoint(endpoint)
            } else {
                let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(macHost), port: NWEndpoint.Port(rawValue: UInt16(macPort))!)
                try await connectToPreferredEndpoint(endpoint)
                savedMacEndpoint = .hostPort(host: macHost, port: macPort)
            }
            activeTransportDescription = transport.activeInterfaceDescription
            connectionState = .handshaking
            let packet = HandshakePacket(identity: identity, appVersion: "0.1.0", supportedCodecs: ["h264", "hevc"], preferredQuality: selectedQuality)
            try await transport.sendHandshake(packet)
            connectionState = .streaming
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            persistConnectionPreferences()
            startHeartbeat()
            logger.log(.info, .transport, "Handshake completed", deviceID: identity.id)
        } catch {
            lastError = error.localizedDescription
            activeTransportDescription = transport.activeInterfaceDescription
            logger.log(.error, .transport, error.localizedDescription, deviceID: identity.id)
            scheduleReconnect(reason: .unknown)
        }
    }

    func applyQuality(_ quality: StreamQuality) async {
        selectedQuality = quality
        frameStreamer.configure(quality: quality)
        persistConnectionPreferences()
        await startCamera()
        if connectionState == .streaming {
            await restartConnection()
        }
    }

    func setCableOnlyMode(_ enabled: Bool) {
        cableOnlyMode = enabled
        hubDiscovery.stop()
        hubDiscovery.requiredInterfaceType = enabled ? .wiredEthernet : nil
        persistConnectionPreferences()
        didAutoConnectToDiscoveredHub = false
        startHubDiscovery()
    }

    func restartConnection() async {
        logger.log(.warning, .reconnect, "Manual connection restart requested", deviceID: identity.id)
        frameStreamer.resetPipeline(reason: "manual reconnect")
        heartbeatTask?.cancel()
        heartbeatTask = nil
        closeTransport(suppressingCallback: true)
        connectionState = .disconnected
        reconnectAttempt = 0
        didAutoConnectToDiscoveredHub = false
        await connectToMac()
    }

    func scheduleReconnect(reason: ReconnectReason) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        closeTransport(suppressingCallback: true)
        connectionState = .reconnecting
        reconnectAttempt += 1
        guard let delay = reconnectPolicy.delay(forAttempt: reconnectAttempt) else {
            connectionState = .failed
            return
        }
        logger.log(.warning, .reconnect, "Reconnect scheduled in \(String(format: "%.2f", delay))s because \(reason.rawValue)", deviceID: identity.id)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.connectToMac()
        }
    }

    func useManualMacSettings() {
        discoveredMacEndpoint = nil
        savedMacEndpoint = .hostPort(host: macHost, port: macPort)
        didAutoConnectToDiscoveredHub = false
        persistConnectionPreferences()
    }

    func sendOBSCommand(_ command: ControlCommand) async {
        await sendOBSCommand(command, arguments: [:])
    }

    func sendOBSCommand(_ command: ControlCommand, arguments: [String: String]) async {
        do {
            try await transport.sendControl(ControlPacket(command: command, arguments: arguments))
        } catch {
            lastError = error.localizedDescription
            logger.log(.error, .obs, "Failed sending OBS command proxy: \(error.localizedDescription)", deviceID: identity.id)
        }
    }

    func switchOBSScene(_ scene: OBSScene) async {
        await sendOBSCommand(.switchScene, arguments: ["sceneName": scene.sceneName])
    }

    func applyInstagramLiveCrop() async {
        await sendOBSCommand(.applyInstagramLiveCrop)
    }

    private func applyOBSState(_ packet: OBSStatePacket) {
        obsStatus = packet.status
        obsScenes = mergedScenesWithCachedPreviews(packet.scenes)
        if let previewImageData = packet.previewImageData {
            obsPreviewImageData = previewImageData
        }
        obsAudioMeters = packet.audioMeters
    }

    private func mergedScenesWithCachedPreviews(_ incomingScenes: [OBSScene]) -> [OBSScene] {
        guard !incomingScenes.isEmpty else { return obsScenes }

        var cachedScenes = Dictionary(uniqueKeysWithValues: obsScenes.map { ($0.sceneName, $0) })
        for scene in incomingScenes {
            var updated = scene
            if updated.previewImageData == nil {
                updated.previewImageData = cachedScenes[scene.sceneName]?.previewImageData
            }
            cachedScenes[scene.sceneName] = updated
        }

        let incomingNames = Set(incomingScenes.map(\.sceneName))
        let isFullSceneList = incomingScenes.count >= obsScenes.count || obsScenes.isEmpty
        let baseOrder = isFullSceneList ? incomingScenes.map(\.sceneName) : obsScenes.map(\.sceneName)
        var orderedNames = baseOrder
        for name in incomingNames where !orderedNames.contains(name) {
            orderedNames.append(name)
        }

        let merged = orderedNames.compactMap { cachedScenes[$0] }
        if !merged.isEmpty {
            OBSSceneCacheStore.save(merged)
        }
        return merged
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.sendHeartbeat()
            }
        }
    }

    private func startCablePreferenceMonitor() {
        guard cablePreferenceTask == nil else { return }
        cablePreferenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.upgradeToCableIfAvailable()
            }
        }
    }

    private func sendHeartbeat() async {
        guard connectionState == .streaming else { return }
        heartbeatSequence += 1
        let metrics = frameStreamer.metrics()
        logStreamMetrics(metrics)
        if await shouldRecoverFromZeroFPS(metrics) {
            await recoverFromZeroFPS(metrics)
            return
        }

        let packet = HeartbeatPacket(deviceID: identity.id, sequence: heartbeatSequence, metrics: metrics)
        do {
            try await transport.sendHeartbeat(packet)
        } catch {
            lastError = error.localizedDescription
            logger.log(.error, .transport, "Heartbeat failed: \(error.localizedDescription)", deviceID: identity.id)
            scheduleReconnect(reason: .socketClosed)
        }
    }

    private func logStreamMetrics(_ metrics: StreamMetrics) {
        if metrics.fps < 5 || metrics.droppedFrames > 20 {
            logger.log(
                .warning,
                .encoder,
                "Stream metrics fps=\(String(format: "%.1f", metrics.fps)) bitrate=\(String(format: "%.0f", metrics.bitrate / 1_000_000))Mbps dropped=\(metrics.droppedFrames) route=\(activeTransportDescription)",
                deviceID: identity.id
            )
        } else if heartbeatSequence % 5 == 0 {
            logger.log(
                .debug,
                .encoder,
                "Stream metrics fps=\(String(format: "%.1f", metrics.fps)) bitrate=\(String(format: "%.0f", metrics.bitrate / 1_000_000))Mbps dropped=\(metrics.droppedFrames) route=\(activeTransportDescription)",
                deviceID: identity.id
            )
        }
    }

    private func shouldRecoverFromZeroFPS(_ metrics: StreamMetrics) async -> Bool {
        guard cameraManager.isRunning, transport.isConnected else {
            zeroFPSHeartbeatCount = 0
            return false
        }

        if metrics.fps < 0.5 {
            zeroFPSHeartbeatCount += 1
        } else {
            zeroFPSHeartbeatCount = 0
        }

        return zeroFPSHeartbeatCount >= 3
    }

    private func recoverFromZeroFPS(_ metrics: StreamMetrics) async {
        logger.log(
            .error,
            .reconnect,
            "Zero-FPS watchdog fired after \(zeroFPSHeartbeatCount)s fps=\(String(format: "%.1f", metrics.fps)) dropped=\(metrics.droppedFrames). Resetting camera, encoder and transport.",
            deviceID: identity.id
        )
        lastError = "El stream cayó a 0 FPS. Reiniciando encoder, cámara y conexión..."
        zeroFPSHeartbeatCount = 0
        frameStreamer.resetPipeline(reason: "zero FPS watchdog")
        await startCamera()
        await restartConnection()
    }

    private func connectToPreferredEndpoint(_ endpoint: NWEndpoint) async throws {
        if cableOnlyMode {
            try await transport.connect(to: endpoint, requiredInterfaceType: .wiredEthernet, timeout: 3.5)
            return
        }

        do {
            try await transport.connect(to: endpoint, requiredInterfaceType: .wiredEthernet, timeout: 3.0)
            logger.log(.info, .transport, "Connected using preferred cable route", deviceID: identity.id)
        } catch {
            logger.log(.warning, .transport, "Cable route unavailable, falling back to automatic route: \(error.localizedDescription)", deviceID: identity.id)
            try await transport.connect(to: endpoint, requiredInterfaceType: nil, timeout: 2.2)
        }
    }

    private func upgradeToCableIfAvailable() async {
        guard connectionState == .streaming, transport.isConnected else { return }
        guard !cableOnlyMode, !transport.isUsingWiredEthernet, !isCableUpgradeInProgress else { return }
        guard let endpoint = discoveredMacEndpoint ?? savedMacEndpoint?.nwEndpoint else { return }

        let cableIsReady = await NetworkStreamTransport.canOpenConnection(to: endpoint, requiredInterfaceType: .wiredEthernet)
        guard cableIsReady else { return }

        isCableUpgradeInProgress = true
        defer { isCableUpgradeInProgress = false }
        logger.log(.info, .transport, "Cable became available; upgrading stream route", deviceID: identity.id)
        await restartConnection()
    }

    private func setupPersistenceBindings() {
        $macHost.dropFirst().sink { [weak self] _ in self?.persistConnectionPreferences() }.store(in: &cancellables)
        $macPort.dropFirst().sink { [weak self] _ in self?.persistConnectionPreferences() }.store(in: &cancellables)
        $selectedQuality.dropFirst().sink { [weak self] _ in self?.persistConnectionPreferences() }.store(in: &cancellables)
        $streamMode.dropFirst().sink { [weak self] _ in self?.persistConnectionPreferences() }.store(in: &cancellables)
        $cableOnlyMode.dropFirst().sink { [weak self] _ in self?.persistConnectionPreferences() }.store(in: &cancellables)
    }

    private func connectToSavedMacIfPossible() {
        guard connectionState == .disconnected || connectionState == .failed else { return }
        guard savedMacEndpoint != nil || macHost != "127.0.0.1" else { return }
        Task { await connectToMac() }
    }

    private func scheduleManualHostFallbackIfNeeded() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            guard self.connectionState == .disconnected || self.connectionState == .failed else { return }
            guard self.savedMacEndpoint == nil, self.macHost != "127.0.0.1" else { return }
            self.savedMacEndpoint = .hostPort(host: self.macHost, port: self.macPort)
            await self.connectToMac()
        }
    }

    private func handleTransportDisconnect(_ reason: String?) {
        guard !suppressTransportDisconnectCallback else { return }
        guard connectionState == .streaming || connectionState == .handshaking || connectionState == .connecting else { return }
        lastError = reason ?? "Se perdió la conexión con la Mac."
        activeTransportDescription = transport.activeInterfaceDescription
        scheduleReconnect(reason: .socketClosed)
    }

    private func closeTransport(suppressingCallback: Bool) {
        suppressTransportDisconnectCallback = suppressingCallback
        transport.close()
        if suppressingCallback {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                await MainActor.run {
                    self?.suppressTransportDisconnectCallback = false
                }
            }
        }
    }

    private func persistConnectionPreferences() {
        let endpoint = savedMacEndpoint ?? IOSConnectionPreferences.MacEndpoint.hostPort(host: macHost, port: macPort)
        IOSConnectionPreferencesStore.save(IOSConnectionPreferences(
            macHost: macHost,
            macPort: macPort,
            lastMacEndpoint: endpoint,
            selectedQuality: selectedQuality,
            streamMode: streamMode,
            cableOnlyMode: cableOnlyMode
        ))
    }
}

private extension IOSConnectionPreferences.MacEndpoint {
    init?(endpoint: NWEndpoint) {
        switch endpoint {
        case .service(let name, _, _, _):
            self = .service(name: name)
        case .hostPort(let host, let port):
            self = .hostPort(host: "\(host)", port: Int(port.rawValue))
        default:
            return nil
        }
    }

    var nwEndpoint: NWEndpoint {
        switch self {
        case .service(let name):
            return .service(name: name, type: "_obsphonecam._tcp", domain: "local.", interface: nil)
        case .hostPort(let host, let port):
            return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!)
        }
    }
}
