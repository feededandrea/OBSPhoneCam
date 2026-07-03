import Foundation
import CoreGraphics
import ImageIO
import CoreVideo
import CoreImage
import Darwin

final class OBSNativeFramePublisher {
    static let shared = OBSNativeFramePublisher()

    private struct Header {
        var magic: UInt32 = 0x3143504F // "OPC1" little-endian
        var version: UInt32 = 1
        var headerSize: UInt32 = UInt32(OBSNativeFramePublisher.headerSize)
        var width: UInt32
        var height: UInt32
        var bytesPerRow: UInt32
        var sequence: UInt64
        var timestampNanos: UInt64
        var payloadSize: UInt64
        var reserved0: UInt64 = 0
        var reserved1: UInt64 = 0
    }

    private static let headerSize = 64
    private static let outputWidth = 1920
    private static let outputHeight = 1080
    private static let outputBytesPerRow = outputWidth * 4
    private static let outputPayloadSize = outputBytesPerRow * outputHeight
    private let queue = DispatchQueue(label: "com.dinesys.obsphonecam.native-frame-publisher", qos: .userInitiated)
    private let outputURL = URL(fileURLWithPath: "/tmp/obsphonecam-framebuffer.shm")
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let ciContext = CIContext()
    private let stateLock = NSLock()
    private var latestSequence: UInt64 = 0
    private var isPublishingPixelBuffer = false
    private var pendingPixelBuffer: CVPixelBuffer?
    private var pendingPixelBufferSequence: UInt64 = 0
    private var mappedPointer: UnsafeMutableRawPointer?
    private var mappedSize = 0
    private var mappedFD: Int32 = -1

    deinit {
        if let mappedPointer {
            munmap(mappedPointer, mappedSize)
        }
        if mappedFD >= 0 {
            close(mappedFD)
        }
    }

    func publishJPEGFrame(_ data: Data, sequence: UInt64) {
        queue.async { [weak self] in
            self?.publish(data, sequence: sequence)
        }
    }

    func publishPixelBuffer(_ pixelBuffer: CVPixelBuffer, sequence: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard sequence > latestSequence else { return }

        if isPublishingPixelBuffer {
            guard sequence > pendingPixelBufferSequence else { return }
            pendingPixelBuffer = pixelBuffer
            pendingPixelBufferSequence = sequence
            return
        }

        isPublishingPixelBuffer = true
        queue.async { [weak self] in
            self?.publishAndDrain(pixelBuffer, sequence: sequence)
        }
    }

    private func publishAndDrain(_ pixelBuffer: CVPixelBuffer, sequence: UInt64) {
        var nextPixelBuffer: CVPixelBuffer? = pixelBuffer
        var nextSequence = sequence

        while let currentPixelBuffer = nextPixelBuffer {
            publish(currentPixelBuffer, sequence: nextSequence)

            stateLock.lock()
            if let pending = pendingPixelBuffer {
                nextPixelBuffer = pending
                nextSequence = pendingPixelBufferSequence
                pendingPixelBuffer = nil
                pendingPixelBufferSequence = 0
                stateLock.unlock()
            } else {
                isPublishingPixelBuffer = false
                stateLock.unlock()
                nextPixelBuffer = nil
            }
        }
    }

    private func shouldPublish(sequence: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sequence > latestSequence
    }

    private func markPublished(sequence: UInt64) {
        stateLock.lock()
        if sequence > latestSequence {
            latestSequence = sequence
        }
        if sequence >= pendingPixelBufferSequence {
            pendingPixelBuffer = nil
            pendingPixelBufferSequence = 0
        }
        stateLock.unlock()
    }

    private func publish(_ data: Data, sequence: UInt64) {
        guard shouldPublish(sequence: sequence) else { return }
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return
        }

        guard image.width > 0, image.height > 0,
              let context = prepareOutputContext(sequence: sequence) else {
            return
        }

        context.draw(image, in: aspectFitRect(sourceWidth: image.width, sourceHeight: image.height))
        finishOutputFrame(sequence: sequence)
    }

    private func publish(_ pixelBuffer: CVPixelBuffer, sequence: UInt64) {
        guard shouldPublish(sequence: sequence) else { return }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0,
              let context = prepareOutputContext(sequence: sequence) else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        context.draw(image, in: aspectFitRect(sourceWidth: sourceWidth, sourceHeight: sourceHeight))
        finishOutputFrame(sequence: sequence)
    }

    private func prepareOutputContext(sequence: UInt64) -> CGContext? {
        guard let payloadAddress = prepareFrameWrite(sequence: sequence) else {
            return nil
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: payloadAddress,
            width: Self.outputWidth,
            height: Self.outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: Self.outputBytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: Self.outputWidth, height: Self.outputHeight))
        return context
    }

    private func prepareFrameWrite(sequence: UInt64) -> UnsafeMutableRawPointer? {
        let requiredSize = Self.headerSize + Self.outputPayloadSize
        guard ensureMapping(size: requiredSize) else { return nil }
        guard let mappedPointer else { return nil }

        var header = Header(
            width: UInt32(Self.outputWidth),
            height: UInt32(Self.outputHeight),
            bytesPerRow: UInt32(Self.outputBytesPerRow),
            sequence: sequence,
            timestampNanos: monotonicTimestampNanos(),
            payloadSize: UInt64(Self.outputPayloadSize),
            reserved0: sequence &* 2 &+ 1,
            reserved1: UInt64(requiredSize)
        )
        writeHeader(&header)
        return mappedPointer.advanced(by: Int(header.headerSize))
    }

    private func finishOutputFrame(sequence: UInt64) {
        var header = Header(
            width: UInt32(Self.outputWidth),
            height: UInt32(Self.outputHeight),
            bytesPerRow: UInt32(Self.outputBytesPerRow),
            sequence: sequence,
            timestampNanos: monotonicTimestampNanos(),
            payloadSize: UInt64(Self.outputPayloadSize),
            reserved0: sequence &* 2,
            reserved1: UInt64(Self.headerSize + Self.outputPayloadSize)
        )
        writeHeader(&header)
        markPublished(sequence: sequence)
    }

    private func aspectFitRect(sourceWidth: Int, sourceHeight: Int) -> CGRect {
        let xScale = CGFloat(Self.outputWidth) / CGFloat(sourceWidth)
        let yScale = CGFloat(Self.outputHeight) / CGFloat(sourceHeight)
        let scale = min(xScale, yScale)
        let width = CGFloat(sourceWidth) * scale
        let height = CGFloat(sourceHeight) * scale
        return CGRect(
            x: (CGFloat(Self.outputWidth) - width) / 2,
            y: (CGFloat(Self.outputHeight) - height) / 2,
            width: width,
            height: height
        ).integral
    }

    private func writeHeader(_ header: inout Header) {
        guard let mappedPointer else { return }
        withUnsafeBytes(of: &header) { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                mappedPointer.copyMemory(from: baseAddress, byteCount: rawBuffer.count)
            }
        }
    }

    private func ensureMapping(size: Int) -> Bool {
        if mappedPointer != nil, mappedSize == size {
            return true
        }

        if let mappedPointer {
            munmap(mappedPointer, mappedSize)
            self.mappedPointer = nil
            mappedSize = 0
        }

        if mappedFD < 0 {
            mappedFD = open(outputURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
            guard mappedFD >= 0 else {
                logPublishFailure("open failed: \(String(cString: strerror(errno)))")
                return false
            }
        }

        guard ftruncate(mappedFD, off_t(size)) == 0 else {
            logPublishFailure("ftruncate failed: \(String(cString: strerror(errno)))")
            return false
        }

        let pointer = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, mappedFD, 0)
        guard pointer != MAP_FAILED else {
            logPublishFailure("mmap failed: \(String(cString: strerror(errno)))")
            return false
        }

        mappedPointer = pointer
        mappedSize = size
        return true
    }

    private func logPublishFailure(_ message: String) {
        Task { @MainActor in
            AppLogger.shared.log(.error, .obs, "Native OBS shared-memory publish failed: \(message)")
        }
    }

    private func monotonicTimestampNanos() -> UInt64 {
        UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    }
}
