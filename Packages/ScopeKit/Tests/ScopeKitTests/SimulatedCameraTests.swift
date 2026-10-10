import Foundation
import Testing
@testable import ScopeCapture
import ScopeKit

@Suite("Simulated camera")
struct SimulatedCameraTests {
    /// Washington DC at 03:00 UTC on 2026-10-10: the Sun well down.
    static let observer = Observer(latitude: 38.89, longitude: -77.03)
    static let night = Date(timeIntervalSince1970: 1_791_601_200)

    static func pointing(at planet: Planet, offset: Double = 0) -> Horizontal {
        var sky = Astronomy.horizontal(SolarSystem.position(of: planet, at: night), at: night, observer: observer)
        sky.altitude += offset
        return sky
    }

    static let vega = SkyCatalog.stars.first { $0.name == "Vega" }!

    /// Renders `frames` frames (auto exposure eases in over a few) and returns the last as BGRA.
    static func render(_ pointing: Horizontal, focusOffset: Int = 0, exposure: Int? = nil, gain: Int = 30, frames: Int = 1,
                       width: Int = 640, height: Int = 480) -> [UInt8] {
        let view = SimulatedView(pointing: pointing, observer: observer, date: night, focusOffset: focusOffset)
        let camera = SimulatedCamera { view }
        camera.set(.gain, gain)
        if let exposure {
            camera.set(.autoExposure, UVCCamera.manualExposureMode)
            camera.set(.exposureTime, exposure)
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for _ in 0 ..< frames {
            pixels.withUnsafeMutableBytes { camera.render(into: $0.baseAddress!, width: width, height: height, rowBytes: width * 4) }
        }
        return pixels
    }

    static func sharpness(_ pixels: [UInt8], width: Int = 640, height: Int = 480) -> Double? {
        pixels.withUnsafeBufferPointer { CaptureEngine.sharpness(bgra: $0.baseAddress!, width: width, height: height, rowBytes: width * 4) }
    }

    static func bright(_ pixels: [UInt8], above level: UInt8 = 100) -> Int {
        stride(from: 0, to: pixels.count, by: 4).count { pixels[$0 + 2] > level }
    }

    @Test func pointingAtJupiterShowsItsDisc() {
        let jupiter = Self.render(Self.pointing(at: .jupiter), exposure: 100)
        let elsewhere = Self.render(Self.pointing(at: .jupiter, offset: -3), exposure: 100)
        // Jupiter is about 44″ across, 44 pixels at this scale: well over a thousand bright pixels.
        #expect(Self.bright(jupiter) > 1000, "\(Self.bright(jupiter)) bright pixels")
        #expect(Self.bright(elsewhere) < 200, "\(Self.bright(elsewhere)) bright pixels away from Jupiter")
    }

    /// The focus aid measures planets, not single stars (a few bright pixels don't set its scale), so for a star the
    /// thing to check is its shape: a point in focus, the SCT's doughnut far out of it.
    @Test func aStarFarOutOfFocusIsADoughnut() {
        let sky = Astronomy.horizontal(Astronomy.precess(Self.vega.j2000, to: Self.night), at: Self.night, observer: Self.observer)
        let focused = Self.render(sky, focusOffset: 0, exposure: 2)
        let doughnut = Self.render(sky, focusOffset: 3000, exposure: 50)
        func green(_ pixels: [UInt8], _ x: Int, _ y: Int) -> Int {
            // The brightest within a pixel or two, since the air moves the star about.
            var best = 0
            for dy in -2 ... 2 { for dx in -2 ... 2 { best = max(best, Int(pixels[((y + dy) * 640 + x + dx) * 4 + 1])) } }
            return best
        }
        // 3000 steps is 20 pixels of blur: the ring is about 20 pixels out, the secondary's shadow in the middle.
        #expect(green(focused, 320, 240) > 100, "a bright point in focus")
        #expect(green(doughnut, 320, 240) < green(doughnut, 334, 240), "dark centre \(green(doughnut, 320, 240)), ring \(green(doughnut, 334, 240))")
        #expect(Self.bright(doughnut, above: 30) > 300, "spread out")
    }

    @Test func jupitersEdgeIsSharpestInFocus() throws {
        let focused = try #require(Self.sharpness(Self.render(Self.pointing(at: .jupiter), focusOffset: 0, frames: 5)))
        let blurred = try #require(Self.sharpness(Self.render(Self.pointing(at: .jupiter), focusOffset: 1500, frames: 5)))
        #expect(focused > blurred * 1.5, "sharpness \(focused) in focus, \(blurred) out")
    }

    @Test func autoExposurePutsAPlanetInTheTargetBand() {
        let pixels = Self.render(Self.pointing(at: .jupiter), frames: 30)
        let brightest = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0 + 2] }.max() ?? 0
        #expect((140 ... 230).contains(brightest), "brightest red value \(brightest)")
    }

    @Test func aLongerExposureIsBrighter() {
        // Over Jupiter's disc, in the middle of the frame.
        func mean(_ pixels: [UInt8]) -> Double {
            var total = 0
            for y in 230 ..< 250 { for x in 310 ..< 330 { total += Int(pixels[(y * 640 + x) * 4 + 1]) } }
            return Double(total) / 400
        }
        let short = mean(Self.render(Self.pointing(at: .jupiter), exposure: 5))
        let long = mean(Self.render(Self.pointing(at: .jupiter), exposure: 50))
        #expect(long > short * 3, "mean \(short) at 0.5 ms, \(long) at 5 ms")
    }

    @Test func theCameraReportsTheExposureAutoChose() {
        let view = SimulatedView(pointing: Self.pointing(at: .jupiter), observer: Self.observer, date: Self.night, focusOffset: 0)
        let camera = SimulatedCamera { view }
        var pixels = [UInt8](repeating: 0, count: 640 * 480 * 4)
        for _ in 0 ..< 10 {
            pixels.withUnsafeMutableBytes { camera.render(into: $0.baseAddress!, width: 640, height: 480, rowBytes: 640 * 4) }
        }
        let chosen = camera.value(.exposureTime) ?? 0
        #expect(chosen != 100, "auto exposure moved off the default")
        #expect((1 ... 10_000).contains(chosen))
    }
}
