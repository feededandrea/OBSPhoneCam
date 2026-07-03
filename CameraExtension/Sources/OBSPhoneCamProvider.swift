import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import os.log

private let frameWidth: Int32 = 1920
private let frameHeight: Int32 = 1080
private let frameRate: Int32 = 30
private let providerManufacturer = "DineSys"
private let deviceModel = "OBS Phone Cam Virtual Camera"
private let deviceID = UUID(uuidString: "18FE8A95-8993-4C6A-B29D-B9C0E1339D54")!
private let streamID = UUID(uuidString: "66CE5F4A-C41A-4960-A18B-A41E15109B92")!

final class OBSPhoneCamDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!

    private var streamSource: OBSPhoneCamStreamSource!
    private var streamingCounter: UInt32 = 0
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "obsphonecam.camera-extension.timer", qos: .userInteractive)

    private var videoDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!
    private let bufferAuxAttributes: NSDictionary = [kCVPixelBufferPoolAllocationThresholdKey: 8]
    private var frameNumber: UInt64 = 0

    init(localizedName: String) {
        super.init()

        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)

        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: frameWidth,
            height: frameHeight,
            extensions: nil,
            formatDescriptionOut: &videoDescription
        )
        guard status == noErr, let videoDescription else {
            fatalError("Could not create video format description: \(status)")
        }

        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: Int(frameWidth),
            kCVPixelBufferHeightKey: Int(frameHeight),
            kCVPixelBufferPixelFormatTypeKey: videoDescription.mediaSubType,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary
        ]
        let poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &bufferPool)
        guard poolStatus == kCVReturnSuccess, bufferPool != nil else {
            fatalError("Could not create pixel buffer pool: \(poolStatus)")
        }

        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: videoDescription,
            maxFrameDuration: CMTime(value: 1, timescale: frameRate),
            minFrameDuration: CMTime(value: 1, timescale: frameRate),
            validFrameDurations: nil
        )

        streamSource = OBSPhoneCamStreamSource(
            localizedName: "OBS Phone Cam Video",
            streamID: streamID,
            streamFormat: streamFormat,
            device: device
        )

        do {
            try device.addStream(streamSource.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = deviceModel
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func startStreaming() {
        streamingCounter += 1
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(frameRate), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.emitFrame()
        }
        timer.resume()
        self.timer = timer
        os_log(.info, "OBS Phone Cam native stream started")
    }

    func stopStreaming() {
        guard streamingCounter > 0 else { return }
        streamingCounter -= 1
        guard streamingCounter == 0 else { return }

        timer?.cancel()
        timer = nil
        os_log(.info, "OBS Phone Cam native stream stopped")
    }

    private func emitFrame() {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            bufferPool,
            bufferAuxAttributes,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            os_log(.error, "OBS Phone Cam could not allocate pixel buffer: %d", status)
            return
        }

        drawTestPattern(into: pixelBuffer, frameNumber: frameNumber)
        frameNumber &+= 1

        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: frameRate),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: videoDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            os_log(.error, "OBS Phone Cam could not create sample buffer: %d", sampleStatus)
            return
        }

        let hostTime = UInt64(timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
        streamSource.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostTime)
    }

    private func drawTestPattern(into pixelBuffer: CVPixelBuffer, frameNumber: UInt64) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let movingBand = Int(frameNumber % UInt64(max(1, height)))
        let base = baseAddress.bindMemory(to: UInt8.self, capacity: rowBytes * height)

        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
            for x in 0..<width {
                let offset = x * 4
                let grid = ((x / 80) + (y / 80)) % 2 == 0
                let band = abs(y - movingBand) < 18
                let red = band ? 255 : (grid ? 28 : 8)
                let green = band ? 255 : (grid ? 130 : 72)
                let blue = band ? 255 : (grid ? 206 : 118)
                row[offset + 0] = UInt8(blue)
                row[offset + 1] = UInt8(green)
                row[offset + 2] = UInt8(red)
                row[offset + 3] = 255
            }
        }

        drawBadge(into: base, rowBytes: rowBytes, width: width, height: height)
    }

    private func drawBadge(into base: UnsafeMutablePointer<UInt8>, rowBytes: Int, width: Int, height: Int) {
        let badgeWidth = min(760, width - 120)
        let badgeHeight = 150
        let startX = max(0, (width - badgeWidth) / 2)
        let startY = max(0, (height - badgeHeight) / 2)

        for y in startY..<(startY + badgeHeight) {
            let row = base.advanced(by: y * rowBytes)
            for x in startX..<(startX + badgeWidth) {
                let offset = x * 4
                row[offset + 0] = 22
                row[offset + 1] = 22
                row[offset + 2] = 22
                row[offset + 3] = 255
            }
        }

        let stripeY = startY + badgeHeight - 28
        for y in stripeY..<(stripeY + 10) {
            let row = base.advanced(by: y * rowBytes)
            for x in (startX + 30)..<(startX + badgeWidth - 30) {
                let offset = x * 4
                row[offset + 0] = 80
                row[offset + 1] = 230
                row[offset + 2] = 64
                row[offset + 3] = 255
            }
        }
    }
}

final class OBSPhoneCamStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice

    private let streamFormat: CMIOExtensionStreamFormat
    private var activeFormatIndex = 0

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] {
        [streamFormat]
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: frameRate)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? OBSPhoneCamDeviceSource else { return }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? OBSPhoneCamDeviceSource else { return }
        deviceSource.stopStreaming()
    }
}

final class OBSPhoneCamProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: OBSPhoneCamDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()

        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = OBSPhoneCamDeviceSource(localizedName: "OBS Phone Cam")

        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = providerManufacturer
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
