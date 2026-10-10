@preconcurrency import AVFoundation
import AppKit
import CoreImage
import SwiftUI

/// The camera's live picture, drawn by AVFoundation. Night vision runs it through a red filter.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let nightVision: Bool

    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.nightVision = nightVision
    }

    final class PreviewView: NSView {
        private let previewLayer: AVCaptureVideoPreviewLayer

        var nightVision = false {
            didSet {
                guard nightVision != oldValue else { return }
                previewLayer.filters = nightVision ? [Self.redFilter()] : nil
            }
        }

        init(session: AVCaptureSession) {
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            layerUsesCoreImageFilters = true
            layer?.backgroundColor = NSColor.black.cgColor
            previewLayer.videoGravity = .resizeAspect
            layer?.addSublayer(previewLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }

        /// Brightness into the red channel only, slightly dimmed. Kept even though the window's night filter is
        /// multiplied over everything: that isn't guaranteed to reach this AppKit layer, and where it does it leaves
        /// red-only content unchanged (see `Theme.nightFilter`).
        static func redFilter() -> CIFilter {
            let filter = CIFilter(name: "CIColorMatrix")!
            filter.setValue(CIVector(x: 0.24, y: 0.47, z: 0.09, w: 0), forKey: "inputRVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            return filter
        }
    }
}
