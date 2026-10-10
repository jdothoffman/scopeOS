@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// The camera's live picture, drawn by AVFoundation. (iPad only; the Camera tab is hidden for now, see #36.)
///
/// iOS layers can't take Core Image filters, so unlike the Mac there is no red filter for night vision yet.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let nightVision: Bool

    func makeUIView(context: Context) -> PreviewView { PreviewView(session: session) }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        init(session: AVCaptureSession) {
            super.init(frame: .zero)
            backgroundColor = .black
            let previewLayer = layer as! AVCaptureVideoPreviewLayer
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspect
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
