import Foundation
import Combine
import CryptoKit

@MainActor
final class OBSWebSocketClient: ObservableObject {
    @Published private(set) var isConnected = false
    private var task: URLSessionWebSocketTask?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var config = OBSConnectionConfig()
    private var receiveTask: Task<Void, Never>?
    private var pendingRequests: [String: CheckedContinuation<OBSRequestResponseData, Error>] = [:]
    private var lastOutputPeakDb: Double = -60
    private var lastOutputPeakUpdatedAt = Date.distantPast
    var onAudioMeters: (([OBSAudioMeter]) -> Void)?

    func connect(config: OBSConnectionConfig) async throws {
        guard let url = config.url else { throw OBSWebSocketError.invalidURL }
        self.config = config
        disconnect()
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        try await identify(with: task, config: config)
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        isConnected = true
        AppLogger.shared.log(.info, .obs, "WebSocket task started at \(url.absoluteString)")
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        pendingRequests.values.forEach { $0.resume(throwing: OBSWebSocketError.notConnected) }
        pendingRequests.removeAll()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    @discardableResult
    func sendRequest(_ requestType: String, data: [String: JSONValue]? = nil) async throws -> [String: JSONValue]? {
        guard let task else { throw OBSWebSocketError.notConnected }
        let request = OBSRequest(op: 6, d: OBSRequestData(requestType: requestType, requestData: data))
        let payload = try encoder.encode(request)
        guard let text = String(data: payload, encoding: .utf8) else { throw OBSWebSocketError.requestFailed("Invalid JSON") }
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[request.d.requestId] = continuation
            task.send(.string(text)) { [weak self] error in
                Task { @MainActor in
                    if let error {
                        self?.pendingRequests.removeValue(forKey: request.d.requestId)
                        continuation.resume(throwing: OBSWebSocketError.requestFailed(error.localizedDescription))
                    } else if !Self.isNoisyRequest(requestType) {
                        AppLogger.shared.log(.debug, .obs, "OBS request sent: \(requestType)")
                    }
                }
            }
        }.responseData
    }

    private static func isNoisyRequest(_ requestType: String) -> Bool {
        switch requestType {
        case "GetSourceScreenshot",
             "GetInputVolumeMeters",
             "GetCurrentProgramScene",
             "GetRecordStatus",
             "GetStreamStatus",
             "GetReplayBufferStatus",
             "GetSceneList":
            return true
        default:
            return false
        }
    }

    func refreshStatus() async throws -> OBSStatus {
        guard isConnected else { throw OBSWebSocketError.notConnected }
        var lastError: String?

        let scene: String?
        do {
            scene = try await sendRequest("GetCurrentProgramScene")?["currentProgramSceneName"]?.stringValue
        } catch {
            scene = nil
            lastError = "Escena: \(error.localizedDescription)"
        }

        let recordActive: Bool
        do {
            recordActive = try await sendRequest("GetRecordStatus")?["outputActive"]?.boolValue ?? false
        } catch {
            recordActive = false
            lastError = "Grabación: \(error.localizedDescription)"
        }

        let streamActive: Bool
        do {
            streamActive = try await sendRequest("GetStreamStatus")?["outputActive"]?.boolValue ?? false
        } catch {
            streamActive = false
            lastError = "Streaming: \(error.localizedDescription)"
        }

        let replayAvailable: Bool
        let replayActive: Bool
        do {
            replayActive = try await sendRequest("GetReplayBufferStatus")?["outputActive"]?.boolValue ?? false
            replayAvailable = true
        } catch {
            replayActive = false
            replayAvailable = false
        }

        return OBSStatus(connected: true, currentScene: scene, recording: recordActive, streaming: streamActive, replayBufferAvailable: replayAvailable, replayBufferActive: replayActive, lastError: lastError)
    }

    func getSceneList() async throws -> [OBSScene] {
        guard let response = try await sendRequest("GetSceneList"),
              let scenes = response["scenes"]?.arrayValue else {
            return []
        }
        return scenes.compactMap { value in
            guard let object = value.objectValue,
                  let name = object["sceneName"]?.stringValue else { return nil }
            return OBSScene(sceneName: name, sceneIndex: object["sceneIndex"]?.intValue)
        }
    }

    func setCurrentProgramScene(_ sceneName: String) async throws {
        _ = try await sendRequest("SetCurrentProgramScene", data: ["sceneName": .string(sceneName)])
    }

    func startRecord() async throws { _ = try await sendRequest("StartRecord") }
    func stopRecord() async throws { _ = try await sendRequest("StopRecord") }
    func startStream() async throws { _ = try await sendRequest("StartStream") }
    func stopStream() async throws { _ = try await sendRequest("StopStream") }
    func startReplayBuffer() async throws { _ = try await sendRequest("StartReplayBuffer") }
    func stopReplayBuffer() async throws { _ = try await sendRequest("StopReplayBuffer") }
    func saveReplayBuffer() async throws { _ = try await sendRequest("SaveReplayBuffer") }

    func getRecordDirectory() async throws -> String? {
        try await sendRequest("GetRecordDirectory")?["recordDirectory"]?.stringValue
    }

    func getInputVolumeMeters() async throws -> [OBSAudioMeter] {
        guard let inputs = try await sendRequest("GetInputVolumeMeters")?["inputs"]?.arrayValue else {
            return []
        }
        return audioMeters(from: inputs)
    }

    func takeSourceScreenshot(sourceName: String, width: Int = 320, height: Int = 180, compressionQuality: Int = 75) async throws -> Data? {
        guard let response = try await sendRequest("GetSourceScreenshot", data: [
            "sourceName": .string(sourceName),
            "imageFormat": .string("jpg"),
            "imageWidth": .int(width),
            "imageHeight": .int(height),
            "imageCompressionQuality": .int(compressionQuality)
        ]),
        let imageData = response["imageData"]?.stringValue else {
            return nil
        }

        let base64: String
        if let comma = imageData.firstIndex(of: ",") {
            base64 = String(imageData[imageData.index(after: comma)...])
        } else {
            base64 = imageData
        }
        return Data(base64Encoded: base64)
    }

    func applyInstagramLiveCrop(sourceName _: String = "OBS Phone Cam") async throws {
        guard isConnected else { throw OBSWebSocketError.notConnected }
        AppLogger.shared.log(.warning, .obs, "applyInstagramLiveCrop is deprecated; ignoring transform request")
    }

    func upsertBrowserSource(inputName: String, url: String, sceneName preferredSceneName: String? = nil, width: Int = 1920, height: Int = 1080) async throws {
        guard isConnected else { throw OBSWebSocketError.notConnected }
        let sceneName: String
        if let preferredSceneName, !preferredSceneName.isEmpty {
            sceneName = preferredSceneName
        } else if let currentScene = try await sendRequest("GetCurrentProgramScene")?["currentProgramSceneName"]?.stringValue {
            sceneName = currentScene
        } else {
            throw OBSWebSocketError.requestFailed("No se pudo obtener la escena actual de OBS")
        }

        let settings: [String: JSONValue] = [
            "url": .string(url),
            "width": .int(width),
            "height": .int(height),
            "fps": .int(30),
            "reroute_audio": .bool(false),
            "restart_when_active": .bool(true),
            "shutdown": .bool(false)
        ]

        if try await inputExists(named: inputName) {
            _ = try await sendRequest("SetInputSettings", data: [
                "inputName": .string(inputName),
                "inputSettings": .object(settings),
                "overlay": .bool(true)
            ])
        } else {
            _ = try await sendRequest("CreateInput", data: [
                "sceneName": .string(sceneName),
                "inputName": .string(inputName),
                "inputKind": .string("browser_source"),
                "inputSettings": .object(settings),
                "sceneItemEnabled": .bool(true)
            ])
        }
    }

    private func identify(with task: URLSessionWebSocketTask, config: OBSConnectionConfig) async throws {
        let helloMessage = try await task.receive()
        let hello = try decodeOBSMessage(OBSHello.self, from: helloMessage)
        guard hello.op == 0 else { throw OBSWebSocketError.requestFailed("OBS no envió Hello") }

        var payload: [String: JSONValue] = [
            "rpcVersion": .int(1),
            "eventSubscriptions": .int(65_536)
        ]
        if let authentication = hello.d.authentication {
            guard !config.password.isEmpty else {
                throw OBSWebSocketError.authenticationRequired
            }
            payload["authentication"] = .string(authenticationToken(password: config.password, salt: authentication.salt, challenge: authentication.challenge))
        }

        let identify = OBSRawMessage(op: 1, d: payload)
        try await sendRaw(identify, task: task)

        let identifiedMessage = try await task.receive()
        let identified = try decodeOBSMessage(OBSRawMessage.self, from: identifiedMessage)
        guard identified.op == 2 else {
            throw OBSWebSocketError.requestFailed("OBS rechazó Identify")
        }
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                try handle(message)
            } catch {
                if !Task.isCancelled {
                    isConnected = false
                    AppLogger.shared.log(.error, .obs, "OBS receive failed: \(error.localizedDescription)")
                }
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) throws {
        let raw = try decodeOBSMessage(OBSOpEnvelope.self, from: message)
        if raw.op == 5 {
            try handleEvent(message)
            return
        }
        guard raw.op == 7 else { return }
        let envelope = try decodeOBSMessage(OBSResponseEnvelope.self, from: message)
        guard let continuation = pendingRequests.removeValue(forKey: envelope.d.requestId) else { return }
        if envelope.d.requestStatus.result {
            continuation.resume(returning: envelope.d)
        } else {
            let detail = envelope.d.requestStatus.comment ?? "OBS request failed"
            continuation.resume(throwing: OBSWebSocketError.requestFailed(detail))
        }
    }

    private func handleEvent(_ message: URLSessionWebSocketTask.Message) throws {
        let envelope = try decodeOBSMessage(OBSEventEnvelope.self, from: message)
        guard envelope.d.eventType == "InputVolumeMeters",
              let inputs = envelope.d.eventData?["inputs"]?.arrayValue else { return }
        let meters = audioMeters(from: inputs)
        onAudioMeters?(meters)
    }

    private func sendRaw<T: Encodable>(_ value: T, task: URLSessionWebSocketTask) async throws {
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else { throw OBSWebSocketError.requestFailed("Invalid JSON") }
        try await task.send(.string(text))
    }

    private func decodeOBSMessage<T: Decodable>(_ type: T.Type, from message: URLSessionWebSocketTask.Message) throws -> T {
        switch message {
        case .data(let data):
            return try decoder.decode(type, from: data)
        case .string(let text):
            return try decoder.decode(type, from: Data(text.utf8))
        @unknown default:
            throw OBSWebSocketError.requestFailed("Unsupported OBS WebSocket message")
        }
    }

    private func authenticationToken(password: String, salt: String, challenge: String) -> String {
        let secretInput = Data((password + salt).utf8)
        let secret = Data(SHA256.hash(data: secretInput)).base64EncodedString()
        let authInput = Data((secret + challenge).utf8)
        return Data(SHA256.hash(data: authInput)).base64EncodedString()
    }

    private func inputExists(named inputName: String) async throws -> Bool {
        guard let inputs = try await sendRequest("GetInputList")?["inputs"]?.arrayValue else {
            return false
        }
        return inputs.contains { value in
            value.objectValue?["inputName"]?.stringValue == inputName
        }
    }

    private func peakDb(from input: [String: JSONValue]) -> Double? {
        if let levels = input["inputLevelsDb"]?.arrayValue {
            return levels.flatMap { channelGroup in
                channelGroup.arrayValue?.compactMap(\.numberValue) ?? []
            }
            .filter(\.isFinite)
            .max()
        }

        if let levels = input["inputLevelsMul"]?.arrayValue {
            return levels.flatMap { channelGroup in
                channelGroup.arrayValue?.compactMap { value -> Double? in
                    guard let magnitude = value.numberValue, magnitude.isFinite else { return nil }
                    return 20 * log10(max(magnitude, 0.000_001))
                } ?? []
            }
            .filter(\.isFinite)
            .max()
        }

        return nil
    }

    private func audioMeters(from inputs: [JSONValue]) -> [OBSAudioMeter] {
        let meters: [OBSAudioMeter] = inputs.compactMap { value in
            guard let object = value.objectValue,
                  let inputName = object["inputName"]?.stringValue,
                  let peakDb = peakDb(from: object) else {
                return nil
            }
            return OBSAudioMeter(inputName: inputName, peakDb: peakDb)
        }
        .sorted { $0.peakDb > $1.peakDb }

        return [masterMeter(from: meters)] + meters
    }

    private func masterMeter(from meters: [OBSAudioMeter]) -> OBSAudioMeter {
        let activeAmplitudes = meters
            .map { pow(10, max(-60, min(0, $0.peakDb)) / 20) }
            .filter { $0 > 0.0013 }
        let instantDb: Double
        if activeAmplitudes.isEmpty {
            instantDb = -60
        } else {
            let summedPower = activeAmplitudes.reduce(0) { $0 + ($1 * $1) }
            let mixedAmplitude = min(1, sqrt(summedPower))
            instantDb = 20 * log10(max(mixedAmplitude, 0.000_001))
        }

        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(lastOutputPeakUpdatedAt))
        let decayedPeak = max(-60, lastOutputPeakDb - elapsed * 18)
        let heldPeak = max(instantDb, decayedPeak)
        lastOutputPeakDb = heldPeak
        lastOutputPeakUpdatedAt = now
        return OBSAudioMeter(inputName: "MASTER OUT", peakDb: heldPeak, isActive: heldPeak > -58)
    }
}

private struct OBSHello: Decodable {
    struct DataPayload: Decodable {
        struct Authentication: Decodable {
            let challenge: String
            let salt: String
        }

        let rpcVersion: Int?
        let authentication: Authentication?
    }

    let op: Int
    let d: DataPayload
}

private struct OBSRawMessage: Codable {
    let op: Int
    let d: [String: JSONValue]
}

private struct OBSResponseEnvelope: Decodable {
    let op: Int
    let d: OBSRequestResponseData
}

private struct OBSOpEnvelope: Decodable {
    let op: Int
}

private struct OBSEventEnvelope: Decodable {
    struct EventData: Decodable {
        let eventType: String
        let eventIntent: Int?
        let eventData: [String: JSONValue]?
    }

    let op: Int
    let d: EventData
}

private struct OBSRequestResponseData: Decodable {
    struct RequestStatus: Decodable {
        let result: Bool
        let code: Int
        let comment: String?
    }

    let requestType: String
    let requestId: String
    let requestStatus: RequestStatus
    let responseData: [String: JSONValue]?
}

private extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let value) = self { return value }
        if case .int(let value) = self { return Double(value) }
        return nil
    }

    var numberValue: Double? { doubleValue }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}
