import Foundation
import CoreGraphics
import ImageIO
import CoreVideo
import CoreImage

final class OBSNativeFramePublisher {
    static let shared = OBSNativeFramePublisher()

    private struct Header {
        var magic: UInt32 = 0x3143504F // "OPC1" little-endian
        var version: UInt32 = 1
        var headerSize: UInt32 = 64
        var width: UInt32
        var height: UInt32
        var bytesPerRow: UInt32
        var sequence: UInt64
        var timestampNanos: UInt64
        var payloadSize: UInt64
        var reserved0: UInt64 = 0
        var reserved1: UInt64 = 0
    }

    private let queue = DispatchQueue(label: "com.dinesys.obsphonecam.native-frame-publisher", qos: .userInitiated)
    private let outputURL = URL(fileURLWithPath: "/tmp/obsphonecam-framebuffer.bin")
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let ciContext = CIContext()
    private let stateLock = NSLock()
    private var latestSequence: UInt64 = 0
    private var isPublishingPixelBuffer = false
    private var pendingPixelBuffer: CVPixelBuffer?
    private var pendingPixelBufferSequence: UInt64 = 0

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

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = Data(count: bytesPerRow * height)

        let ok = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard ok else { return }

        var header = Header(
            width: UInt32(width),
            height: UInt32(height),
            bytesPerRow: UInt32(bytesPerRow),
            sequence: sequence,
            timestampNanos: monotonicTimestampNanos(),
            payloadSize: UInt64(pixels.count)
        )

        var output = Data()
        withUnsafeBytes(of: &header) { output.append(contentsOf: $0) }
        output.append(pixels)

        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".obsphonecam-framebuffer.\(UUID().uuidString).tmp")

        do {
            try output.write(to: temporaryURL, options: .atomic)
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            }
            markPublished(sequence: sequence)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            Task { @MainActor in
                AppLogger.shared.log(.error, .obs, "Native OBS frame publish failed: \(error.localizedDescription)")
            }
        }
    }

    private func publish(_ pixelBuffer: CVPixelBuffer, sequence: UInt64) {
        guard shouldPublish(sequence: sequence) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = Data(count: bytesPerRow * height)

        let ok = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let image = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard ok else { return }
        writeFrame(width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels, sequence: sequence)
    }

    private func writeFrame(width: Int, height: Int, bytesPerRow: Int, pixels: Data, sequence: UInt64) {
        var header = Header(
            width: UInt32(width),
            height: UInt32(height),
            bytesPerRow: UInt32(bytesPerRow),
            sequence: sequence,
            timestampNanos: monotonicTimestampNanos(),
            payloadSize: UInt64(pixels.count)
        )

        var output = Data()
        withUnsafeBytes(of: &header) { output.append(contentsOf: $0) }
        output.append(pixels)

        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".obsphonecam-framebuffer.\(UUID().uuidString).tmp")

        do {
            try output.write(to: temporaryURL, options: .atomic)
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            }
            markPublished(sequence: sequence)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            Task { @MainActor in
                AppLogger.shared.log(.error, .obs, "Native OBS frame publish failed: \(error.localizedDescription)")
            }
        }
    }

    private func monotonicTimestampNanos() -> UInt64 {
        UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    }
}
