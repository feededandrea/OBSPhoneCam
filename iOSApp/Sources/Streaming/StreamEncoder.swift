import Foundation
import AVFoundation
import VideoToolbox

final class StreamEncoder {
    struct Configuration: Equatable {
        var quality: StreamQuality
        var mode: StreamMode
    }

    struct EncodedFrame: Sendable {
        let data: Data
        let isKeyframe: Bool
        let presentationTime: Double
    }

    private(set) var configuration: Configuration
    private var compressionSession: VTCompressionSession?
    private let queue = DispatchQueue(label: "obsphonecam.ios.h264.encoder", qos: .userInitiated)
    private let lock = NSLock()
    private var outputHandler: (@Sendable (EncodedFrame) -> Void)?
    private var failureHandler: (@Sendable () -> Void)?
    private var framesInFlight = 0
    private let maxFramesInFlight = 3

    init(configuration: Configuration, outputHandler: (@Sendable (EncodedFrame) -> Void)? = nil) {
        self.configuration = configuration
        self.outputHandler = outputHandler
    }

    func setOutputHandler(_ handler: @escaping @Sendable (EncodedFrame) -> Void) {
        lock.lock()
        outputHandler = handler
        lock.unlock()
    }

    func setFailureHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        failureHandler = handler
        lock.unlock()
    }

    func configure(_ newConfiguration: Configuration) throws {
        guard newConfiguration != configuration || compressionSession == nil else { return }
        teardown()
        configuration = newConfiguration

        let res = newConfiguration.quality.resolution
        var session: VTCompressionSession?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(res.width),
            height: Int32(res.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: StreamEncoder.compressionOutputCallback,
            refcon: refcon,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw CameraError.configurationFailed("VTCompressionSessionCreate failed: \(status)")
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: encoderQuality(for: newConfiguration.quality) as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: newConfiguration.quality.bitrate as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits(for: newConfiguration.quality) as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: newConfiguration.quality.fps as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: max(newConfiguration.quality.fps, 30) as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFTypeRef)
        VTCompressionSessionPrepareToEncodeFrames(session)

        compressionSession = session
    }

    @discardableResult
    func encode(sampleBuffer: CMSampleBuffer) -> Bool {
        guard let compressionSession,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
        guard reserveEncodeSlot() else { return false }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        queue.async { [weak self] in
            let status = VTCompressionSessionEncodeFrame(
                compressionSession,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                duration: .invalid,
                frameProperties: nil,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )
            if status != noErr {
                self?.failPendingEncode()
            }
        }
        return true
    }

    func teardown() {
        if let compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(compressionSession)
        }
        compressionSession = nil
    }

    func reset() throws {
        let currentConfiguration = configuration
        teardown()
        try configure(currentConfiguration)
    }

    private func emit(_ frame: EncodedFrame) {
        releaseEncodeSlot()
        lock.lock()
        let outputHandler = outputHandler
        lock.unlock()
        outputHandler?(frame)
    }

    private func failPendingEncode() {
        releaseEncodeSlot()
        lock.lock()
        let failureHandler = failureHandler
        lock.unlock()
        failureHandler?()
    }

    private func dataRateLimits(for quality: StreamQuality) -> [NSNumber] {
        let bytesPerSecond = max(quality.bitrate / 8, 1)
        let burstBytesPerSecond = bytesPerSecond * 2
        return [NSNumber(value: burstBytesPerSecond), NSNumber(value: 1)]
    }

    private func encoderQuality(for quality: StreamQuality) -> NSNumber {
        switch quality {
        case .low720p:
            return 0.72
        case .medium1080p:
            return 0.78
        case .high1080p:
            return 0.88
        case .max1080p40:
            return 0.96
        case .pro4k:
            return 0.92
        }
    }

    private func reserveEncodeSlot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard framesInFlight < maxFramesInFlight else { return false }
        framesInFlight += 1
        return true
    }

    private func releaseEncodeSlot() {
        lock.lock()
        framesInFlight = max(0, framesInFlight - 1)
        lock.unlock()
    }

    private static let compressionOutputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard let refcon else { return }
        let encoder = Unmanaged<StreamEncoder>.fromOpaque(refcon).takeUnretainedValue()
        guard status == noErr,
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            encoder.failPendingEncode()
            return
        }

        guard let data = annexBData(from: sampleBuffer) else {
            encoder.failPendingEncode()
            return
        }
        let isKeyframe = sampleBuffer.isKeyframe
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        encoder.emit(EncodedFrame(data: data, isKeyframe: isKeyframe, presentationTime: pts))
    }

    private static func annexBData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var output = Data()

        if sampleBuffer.isKeyframe,
           let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            appendParameterSets(from: formatDescription, to: &output)
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let dataPointer else { return nil }

        var offset = 0
        while offset + 4 <= totalLength {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, dataPointer + offset, 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            offset += 4

            guard nalLength > 0, offset + Int(nalLength) <= totalLength else { return nil }
            output.appendStartCode()
            output.append(Data(bytes: dataPointer + offset, count: Int(nalLength)))
            offset += Int(nalLength)
        }

        return output.isEmpty ? nil : output
    }

    private static func appendParameterSets(from formatDescription: CMFormatDescription, to output: inout Data) {
        var parameterSetCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: nil
        )

        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else { continue }
            output.appendStartCode()
            output.append(pointer, count: size)
        }
    }
}

private extension CMSampleBuffer {
    var isKeyframe: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        return first[kCMSampleAttachmentKey_NotSync] == nil
    }
}

private extension Data {
    mutating func appendStartCode() {
        append(contentsOf: [0x00, 0x00, 0x00, 0x01])
    }
}
