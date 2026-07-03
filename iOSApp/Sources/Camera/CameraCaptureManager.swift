import Foundation
import AVFoundation
import Combine

final class CameraCaptureManager: NSObject, ObservableObject, @unchecked Sendable {
    typealias VideoSampleHandler = @Sendable (CMSampleBuffer) -> Void

    @Published private(set) var session = AVCaptureSession()
    @Published private(set) var isRunning = false
    @Published private(set) var permissionGranted = false
    @Published var selectedPosition: AVCaptureDevice.Position = .back

    private let sessionQueue = DispatchQueue(label: "obsphonecam.camera.session")
    private let outputQueue = DispatchQueue(label: "obsphonecam.camera.output")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var quality: StreamQuality = .medium1080p
    nonisolated(unsafe) var videoSampleHandler: VideoSampleHandler?

    @MainActor
    func configure(quality: StreamQuality) async throws {
        self.quality = quality
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted && micGranted else { throw CameraError.permissionDenied }
        permissionGranted = true
        let selectedPosition = selectedPosition
        let requestedQuality = quality

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.configureSessionLocked(position: selectedPosition, quality: requestedQuality)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if !self.session.isRunning { self.session.startRunning() }
                Task { @MainActor in self.isRunning = self.session.isRunning }
                continuation.resume()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            Task { @MainActor in self.isRunning = false }
        }
    }

    @MainActor
    func switchCamera() async {
        selectedPosition = selectedPosition == .back ? .front : .back
        do { try await configure(quality: quality) }
        catch { AppLogger.shared.log(.error, .camera, error.localizedDescription) }
    }

    private func configureSessionLocked(position: AVCaptureDevice.Position, quality: StreamQuality) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = preset(for: quality)

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw CameraError.configurationFailed("No camera for selected position")
        }
        let videoInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(videoInput) else { throw CameraError.configurationFailed("Cannot add video input") }
        session.addInput(videoInput)
        try configureDeviceFormat(device, quality: quality)

        if let mic = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: mic)
            if session.canAddInput(audioInput) { session.addInput(audioInput) }
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            configureVideoOutputConnection(position: position)
        }

        audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
    }

    private func configureVideoOutputConnection(position: AVCaptureDevice.Position) {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        if #available(iOS 17.0, *) {
            let angle: CGFloat = position == .front ? 180 : 0
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = position == .front ? .landscapeLeft : .landscapeRight
        }
    }

    private func preset(for quality: StreamQuality) -> AVCaptureSession.Preset {
        switch quality {
        case .low720p: return .hd1280x720
        case .medium1080p, .high1080p, .max1080p40: return .hd1920x1080
        case .pro4k: return .hd4K3840x2160
        }
    }

    private func configureDeviceFormat(_ device: AVCaptureDevice, quality: StreamQuality) throws {
        let target = quality.resolution
        let targetFPS = Double(quality.fps)

        let matchingFormats = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dimensions.width) >= target.width, Int(dimensions.height) >= target.height else { return false }
            return format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= targetFPS && targetFPS <= range.maxFrameRate
            }
        }

        guard let format = matchingFormats.sorted(by: { lhs, rhs in
            let left = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let right = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let leftPixels = Int(left.width) * Int(left.height)
            let rightPixels = Int(right.width) * Int(right.height)
            if leftPixels != rightPixels { return leftPixels < rightPixels }
            let leftMaxFPS = lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let rightMaxFPS = rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return leftMaxFPS < rightMaxFPS
        }).first else {
            Task { @MainActor in
                AppLogger.shared.log(.warning, .camera, "No exact camera format for \(quality.title); using session preset")
            }
            return
        }

        try device.lockForConfiguration()
        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: CMTimeScale(quality.fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }
}

extension CameraCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            videoSampleHandler?(sampleBuffer)
        }
    }
}
