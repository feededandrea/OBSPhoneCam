import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.configure(session: session)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.configure(session: session)
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    func configure(session: AVCaptureSession) {
        videoPreviewLayer.session = session
        videoPreviewLayer.videoGravity = .resizeAspect
        applyPreviewOrientation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoPreviewLayer.frame = bounds
        applyPreviewOrientation()
    }

    private func applyPreviewOrientation() {
        guard let connection = videoPreviewLayer.connection else { return }
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
    }
}
