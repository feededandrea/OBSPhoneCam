import Foundation
import AVFoundation
import VideoToolbox
import CoreImage
import ImageIO

final class StreamDecoder {
    var onPreviewJPEG: ((Data, UInt64) -> Void)?
    var onPixelBuffer: ((CVPixelBuffer, UInt64) -> Void)?

    private let queue = DispatchQueue(label: "obsphonecam.mac.h264.decoder", qos: .userInitiated)
    private let ciContext = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let previewLock = NSLock()
    private let previewJPEGIntervalNs: UInt64 = 250_000_000
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var sps: Data?
    private var pps: Data?
    private var pendingSequence: UInt64 = 0
    private var lastPreviewJPEGNs: UInt64 = 0

    func decodeVideo(_ packet: StreamPacket) {
        switch packet.codec {
        case .jpeg:
            onPreviewJPEG?(packet.data, packet.sequence)
            OBSNativeFramePublisher.shared.publishJPEGFrame(packet.data, sequence: packet.sequence)
        case .h264:
            queue.async { [weak self] in
                self?.decodeH264(packet)
            }
        case .pcm:
            break
        }
    }

    func decodeAudio(_: Data) {
        // Audio decode/output is intentionally separate from the OBS master meter path.
    }

    private func decodeH264(_ packet: StreamPacket) {
        let nalUnits = packet.data.annexBNALUnits()
        guard !nalUnits.isEmpty else { return }

        var frameNALUnits: [Data] = []
        for nal in nalUnits {
            guard let nalType = nal.first.map({ $0 & 0x1F }) else { continue }
            switch nalType {
            case 7:
                sps = nal
                rebuildSessionIfPossible()
            case 8:
                pps = nal
                rebuildSessionIfPossible()
            case 1, 5:
                frameNALUnits.append(nal)
            default:
                break
            }
        }

        if !frameNALUnits.isEmpty {
            decodeFrame(frameNALUnits, sequence: packet.sequence)
        }
    }

    private func rebuildSessionIfPossible() {
        guard let sps, let pps else { return }

        sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                guard let spsBase = spsBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                let parameterSetPointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let parameterSetSizes = [sps.count, pps.count]

                var newFormatDescription: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormatDescription
                )
                guard status == noErr, let newFormatDescription else { return }

                if let formatDescription, CMFormatDescriptionEqual(formatDescription, otherFormatDescription: newFormatDescription) {
                    return
                }

                formatDescription = newFormatDescription
                decompressionSession.map { VTDecompressionSessionInvalidate($0) }
                decompressionSession = nil
                createDecompressionSession(formatDescription: newFormatDescription)
            }
        }
    }

    private func createDecompressionSession(formatDescription: CMVideoFormatDescription) {
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: StreamDecoder.decompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        guard status == noErr else {
            Task { @MainActor in
                AppLogger.shared.log(.error, .transport, "VTDecompressionSessionCreate failed: \(status)")
            }
            return
        }
        decompressionSession = session
    }

    private func decodeFrame(_ nals: [Data], sequence: UInt64) {
        guard let decompressionSession, let formatDescription else { return }

        var avccNAL = Data()
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avccNAL.append(contentsOf: $0) }
            avccNAL.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = avccNAL.withUnsafeBytes { _ in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avccNAL.count,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccNAL.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard blockStatus == noErr, let blockBuffer else { return }

        avccNAL.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            CMBlockBufferReplaceDataBytes(with: baseAddress, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avccNAL.count)
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avccNAL.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return }

        pendingSequence = sequence
        let flags = VTDecodeFrameFlags()
        VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: flags,
            frameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(sequence)),
            infoFlagsOut: nil
        )
    }

    private func handleDecodedFrame(_ pixelBuffer: CVPixelBuffer, sequence: UInt64) {
        onPixelBuffer?(pixelBuffer, sequence)
        if shouldEmitPreviewJPEG(), let jpeg = previewJPEG(from: pixelBuffer) {
            onPreviewJPEG?(jpeg, sequence)
        }
    }

    private func shouldEmitPreviewJPEG() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        previewLock.lock()
        defer { previewLock.unlock() }
        guard now - lastPreviewJPEGNs >= previewJPEGIntervalNs else { return false }
        lastPreviewJPEGNs = now
        return true
    }

    private func previewJPEG(from pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = min(1, 640 / max(image.extent.width, 1))
        let outputImage = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        return ciContext.jpegRepresentation(
            of: outputImage,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.62]
        )
    }

    private static let decompressionOutputCallback: VTDecompressionOutputCallback = { refcon, frameRefcon, status, _, imageBuffer, _, _ in
        guard status == noErr,
              let refcon,
              let imageBuffer else { return }
        let decoder = Unmanaged<StreamDecoder>.fromOpaque(refcon).takeUnretainedValue()
        let sequence = frameRefcon.map { UInt64(UInt(bitPattern: $0)) } ?? decoder.pendingSequence
        decoder.handleDecodedFrame(imageBuffer, sequence: sequence)
    }
}

private extension Data {
    func annexBNALUnits() -> [Data] {
        var ranges: [Range<Int>] = []
        var index = 0
        while index + 3 < count {
            if self[index] == 0, self[index + 1] == 0 {
                if self[index + 2] == 1 {
                    ranges.append(index..<(index + 3))
                    index += 3
                    continue
                }
                if index + 4 < count, self[index + 2] == 0, self[index + 3] == 1 {
                    ranges.append(index..<(index + 4))
                    index += 4
                    continue
                }
            }
            index += 1
        }

        guard !ranges.isEmpty else { return [] }
        var nalUnits: [Data] = []
        for idx in ranges.indices {
            let start = ranges[idx].upperBound
            let end = idx + 1 < ranges.count ? ranges[idx + 1].lowerBound : count
            if end > start {
                nalUnits.append(subdata(in: start..<end))
            }
        }
        return nalUnits
    }
}
