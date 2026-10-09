import CoreImage
import Testing

@MainActor
@Suite("Night vision")
struct NightVisionTests {
    /// The camera preview has its own red filter, and the window's night filter may or may not reach it. Either way
    /// it must look the same: the preview keeps only red, and the window filter leaves red untouched.
    @Test func theCameraPreviewIsTintedOnceEitherWay() {
        let preview = CameraPreview.PreviewView.redFilter()
        #expect((preview.value(forKey: "inputGVector") as? CIVector).map { [$0.x, $0.y, $0.z, $0.w] } == [0, 0, 0, 0])
        #expect((preview.value(forKey: "inputBVector") as? CIVector).map { [$0.x, $0.y, $0.z, $0.w] } == [0, 0, 0, 0])
        #expect(Theme.nightFilter.red == 1)
    }
}
