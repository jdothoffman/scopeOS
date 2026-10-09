import Foundation
import Testing
@testable import ScopeCapture

@Suite("Focus aid sharpness")
struct SharpnessTests {
    /// A bright disc on black, like a planet, with its edge softened over `blur` pixels.
    private func planet(width: Int = 300, height: Int = 240, radius: Double = 30, blur: Double, brightness: Double = 220) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let cx = Double(width) / 2, cy = Double(height) / 2
        for y in 0 ..< height {
            for x in 0 ..< width {
                let distance = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)).squareRoot()
                let edge = max(0, min(1, (radius - distance) / max(blur, 0.5) + 0.5))
                // A little surface detail, like cloud bands, that also blurs out.
                let bands = 1 - 0.2 * max(0, 1 - blur / 4) * (0.5 + 0.5 * sin(Double(y) * 0.8))
                let value = UInt8(min(255, brightness * edge * bands))
                let index = (y * width + x) * 4
                pixels[index] = value; pixels[index + 1] = value; pixels[index + 2] = value; pixels[index + 3] = 255
            }
        }
        return pixels
    }

    private func measure(_ pixels: [UInt8], width: Int = 300, height: Int = 240) -> Double? {
        pixels.withUnsafeBufferPointer { CaptureEngine.sharpness(bgra: $0.baseAddress!, width: width, height: height, rowBytes: width * 4) }
    }

    @Test func sharperImagesScoreHigher() throws {
        let sharp = try #require(measure(planet(blur: 0.5)))
        let soft = try #require(measure(planet(blur: 4)))
        let blurry = try #require(measure(planet(blur: 12)))
        #expect(sharp > soft * 1.5)
        #expect(soft > blurry * 1.5)
    }

    @Test func exposureBarelyChangesTheReading() throws {
        let bright = try #require(measure(planet(blur: 2, brightness: 230)))
        let dim = try #require(measure(planet(blur: 2, brightness: 115)))
        #expect(abs(bright - dim) / bright < 0.15)
    }

    @Test func aDarkFrameHasNoReading() {
        #expect(measure([UInt8](repeating: 3, count: 300 * 240 * 4)) == nil)
    }
}
