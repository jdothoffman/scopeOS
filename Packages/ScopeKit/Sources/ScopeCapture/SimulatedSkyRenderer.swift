import Accelerate
import CoreGraphics
import Foundation
import ScopeKit

/// Draws the simulated camera's frames: the sky's glow, the Moon and planets as discs, then a blur for defocus and
/// seeing, then stars on top (as an SCT shows them: a point in focus, a doughnut well out of it), and sensor noise.
/// The per-pixel work goes through Accelerate, so it keeps up even in a debug build. One queue only.
final class SimulatedSkyRenderer {
    /// Arcseconds across the frame's width: a 10.7′ field, about what the 6SE at f/10 gives on a small planetary sensor.
    static let fieldWidthArcseconds = 640.0
    /// The air's blur (one standard deviation) and the size of its frame-to-frame wobble, in arcseconds.
    static let seeingArcseconds = 1.1
    static let wobbleArcseconds = 0.4
    /// Focus motor steps that blur the picture by one pixel at 640 pixels wide.
    static let focusStepsPerPixel = 150.0
    /// Auto exposure puts the brightest part of the picture here (0–255): the planetary target band.
    static let autoTarget = 0.7 * 255

    private var width = 0, height = 0
    private var red: [Float] = [], green: [Float] = [], blue: [Float] = [], alpha: [Float] = [], moonPlane: [Float] = []
    private var noise: [Float] = []
    private static let noiseSlack = 8192
    private var interleaved: [UInt8] = []
    private var blurTemp: [UInt8] = []
    private var smoothedExposure: Double?
    private static let moonTextureSize = 1024

    /// The Moon's texture takes a moment to make, so it's made in the background once a simulated camera exists, and
    /// the Moon is left out until it's ready.
    private static let moonLock = NSLock()
    nonisolated(unsafe) private static var moonTexture: [Float]?
    nonisolated(unsafe) private static var moonStarted = false

    static var moonReady: Bool { moonLock.withLock { moonTexture != nil } }

    static func prepareMoon() {
        let start = moonLock.withLock {
            defer { moonStarted = true }
            return !moonStarted
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).async {
            let texture = makeMoonTexture()
            moonLock.withLock { moonTexture = texture }
        }
    }

    /// Stars to magnitude 6.5, brought up to date for precession once.
    private static let stars: [(position: Equatorial, magnitude: Double)] = SkyCatalog.stars.map {
        (Astronomy.precess($0.j2000, to: .now), $0.magnitude)
    }

    private struct Disc {
        var x: Double, y: Double, radius: Double
        var body: Planet?
    }

    /// Renders one frame and returns the exposure used, in UVC units of 100 µs (in auto, the one it chose).
    func render(view: SimulatedView?, into base: UnsafeMutableRawPointer, width: Int, height: Int, rowBytes: Int,
                exposureUnits: Int, gain: Int, autoExposure: Bool) -> Int {
        prepare(width: width, height: height)
        let count = width * height
        let arcsecondsPerPixel = Self.fieldWidthArcseconds / Double(width)
        let gainFactor = pow(10, Double(gain) / 100 * 1.5) // 1× to about 32×
        let seeing = Self.seeingArcseconds / arcsecondsPerPixel
        var sky = (r: 0.004, g: 0.004, b: 0.0045)
        var discs: [Disc] = [], stars: [(x: Double, y: Double, magnitude: Double)] = []
        var moon: (x: Double, y: Double, radius: Double)?
        var defocus = 0.0

        if let view {
            let date = view.date, observer = view.observer
            sky = Self.skyGlow(sunAltitude: Astronomy.horizontal(Astronomy.sunPosition(at: date), at: date, observer: observer).altitude,
                               pointingAltitude: view.pointing.altitude)
            defocus = Double(abs(view.focusOffset)) / Self.focusStepsPerPixel * Double(width) / 640
            let wobble = Self.wobbleArcseconds / arcsecondsPerPixel
            let origin = CGPoint(x: Double(width) / 2 + wobble * Self.gaussian(), y: Double(height) / 2 + wobble * Self.gaussian())
            let projection = SkyProjection(center: view.pointing, fieldRadius: 1, origin: origin,
                                           radius: 2 * tan(0.5 * .pi / 180) * 206_264.8 / arcsecondsPerPixel)
            let frame = CGRect(x: 0, y: 0, width: width, height: height)
            for planet in Planet.allCases {
                let sky = Astronomy.horizontal(SolarSystem.position(of: planet, at: date), at: date, observer: observer)
                let radius = Self.angularRadius(planet) / arcsecondsPerPixel
                guard let point = projection.point(for: sky, limit: 0.5),
                      frame.insetBy(dx: -radius * 2.5, dy: -radius * 2.5).contains(point) else { continue }
                discs.append(Disc(x: Double(point.x), y: Double(point.y), radius: radius, body: planet))
            }
            let moonRadius = 932 / arcsecondsPerPixel
            if let point = projection.point(for: SolarSystem.moonHorizontal(at: date, observer: observer), limit: 1),
               frame.insetBy(dx: -moonRadius, dy: -moonRadius).contains(point) {
                moon = (Double(point.x), Double(point.y), moonRadius)
            }
            let center = Astronomy.equatorial(from: view.pointing, at: date, observer: observer)
            let reach = (Double(width * width + height * height)).squareRoot() * arcsecondsPerPixel / 3600 / 2 + 0.01
            for star in Self.stars where abs(star.position.decDegrees - center.decDegrees) < reach
                && Astronomy.separation(star.position, center) < reach {
                if let point = projection.point(for: Astronomy.horizontal(star.position, at: date, observer: observer), limit: 1) {
                    stars.append((Double(point.x), Double(point.y), star.magnitude))
                }
            }
        }

        // Exposure: in auto, aim the brightest thing in view at the target level, easing toward it as a camera does.
        let starSpread = defocus < 3 ? 2 * Double.pi * (seeing * seeing + defocus * defocus / 4) : Self.doughnutArea(defocus)
        var brightest = max(sky.r, sky.g, sky.b)
        for disc in discs { brightest = max(brightest, Self.surfaceBrightness(disc.body)) }
        if moon != nil { brightest = max(brightest, Self.moonBrightness) }
        for star in stars { brightest = max(brightest, Self.starFlux(star.magnitude) / starSpread) }
        var milliseconds = Double(exposureUnits) / 10
        if autoExposure {
            let wanted = min(200, max(0.1, Self.autoTarget / (brightest * gainFactor)))
            let eased = smoothedExposure.map { exp(log($0) * 0.7 + log(wanted) * 0.3) } ?? wanted
            smoothedExposure = eased
            milliseconds = eased
        } else {
            smoothedExposure = milliseconds
        }
        let scale = milliseconds * gainFactor

        // The glow of the sky, then the Moon and planets, sharp; in pixel values from here on.
        fill(&red, Float(sky.r * scale))
        fill(&green, Float(sky.g * scale))
        fill(&blue, Float(sky.b * scale))
        if let moon, let texture = Self.moonLock.withLock({ Self.moonTexture }) {
            addMoon(moon, texture: texture, brightness: Float(Self.moonBrightness * scale))
        }
        for disc in discs { draw(disc, scale: scale) }

        // Sensor noise, from a stock of random numbers read from a different place each frame and channel.
        var level = Float(0.8 + 0.5 * gainFactor.squareRoot())
        noise.withUnsafeBufferPointer { noise in
            for plane in [0, 1, 2] {
                let offset = Int.random(in: 0 ..< Self.noiseSlack)
                withPlane(plane) { vDSP_vsma(noise.baseAddress! + offset, 1, &level, $0, 1, $0, 1, vDSP_Length(count)) }
            }
        }

        // To 8-bit BGRA, clipped, then blurred for focus and seeing straight into the frame.
        convertToBGRA()
        let kernel = UInt32(2 * Int((max(defocus * 0.8, seeing)).rounded()) + 1)
        blur(into: base, rowBytes: rowBytes, kernel: min(kernel, 101))

        // Stars last, so each is drawn at its own blur: a point in focus, a doughnut well out of it.
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for star in stars {
            let total = Self.starFlux(star.magnitude) * scale
            if defocus < 3 {
                drawStar(pixels, rowBytes: rowBytes, x: star.x, y: star.y, total: total, sigma: (seeing * seeing + defocus * defocus / 4).squareRoot())
            } else {
                drawDoughnut(pixels, rowBytes: rowBytes, x: star.x, y: star.y, total: total, radius: defocus)
            }
        }
        return Int((milliseconds * 10).rounded())
    }

    // MARK: Brightness model (pixel value per millisecond at gain 0)

    private static func skyGlow(sunAltitude: Double, pointingAltitude: Double) -> (r: Double, g: Double, b: Double) {
        let night = 0.004, day = 25.0
        let level = sunAltitude >= 0 ? day : sunAltitude <= -12 ? night : night * pow(day / night, (sunAltitude + 12) / 12)
        if pointingAltitude < 0 { return (level * 0.08, level * 0.07, level * 0.05) } // the ground
        let blueness = min(1, level / day)
        return (level * (0.9 - 0.35 * blueness), level * (0.9 - 0.18 * blueness), level)
    }

    /// Total brightness of a star, over all the pixels it covers.
    private static func starFlux(_ magnitude: Double) -> Double { 3000 * pow(10, -0.4 * magnitude) }

    private static let moonBrightness = 20.0

    private static func surfaceBrightness(_ planet: Planet?) -> Double {
        switch planet {
        case .mercury: 40
        case .venus: 120
        case .mars: 25
        case .jupiter: 12
        case .saturn: 6
        case .uranus: 1.5
        case .neptune: 0.8
        case nil: 1
        }
    }

    private static func color(_ planet: Planet?) -> (r: Double, g: Double, b: Double) {
        switch planet {
        case .mercury: (0.85, 0.8, 0.75)
        case .venus: (1, 1, 0.92)
        case .mars: (1, 0.55, 0.35)
        case .jupiter: (1, 0.9, 0.75)
        case .saturn: (1, 0.92, 0.7)
        case .uranus: (0.6, 0.9, 0.95)
        case .neptune: (0.45, 0.62, 1)
        case nil: (1, 1, 1)
        }
    }

    /// Typical apparent radius in arcseconds.
    private static func angularRadius(_ planet: Planet) -> Double {
        switch planet {
        case .mercury: 3.5
        case .venus: 12.5
        case .mars: 5
        case .jupiter: 22
        case .saturn: 9
        case .uranus: 1.9
        case .neptune: 1.2
        }
    }

    // MARK: Drawing

    private func prepare(width: Int, height: Int) {
        guard width != self.width || height != self.height else { return }
        self.width = width
        self.height = height
        let count = width * height
        red = [Float](repeating: 0, count: count)
        green = red
        blue = red
        moonPlane = red
        alpha = [Float](repeating: 255, count: count)
        interleaved = [UInt8](repeating: 0, count: count * 4)
        var generator = SplitMix(seed: 0x5C0_9E05)
        noise = (0 ..< count + Self.noiseSlack).map { _ in Float(Self.gaussian(using: &generator)) }
        smoothedExposure = nil
    }

    private func withPlane(_ index: Int, _ body: (UnsafeMutablePointer<Float>) -> Void) {
        switch index {
        case 0: red.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
        case 1: green.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
        default: blue.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
        }
    }

    private func fill(_ plane: inout [Float], _ value: Float) {
        var value = value
        plane.withUnsafeMutableBufferPointer { vDSP_vfill(&value, $0.baseAddress!, 1, vDSP_Length($0.count)) }
    }

    /// A planet's disc, limb-darkened and edged smoothly, with Jupiter's belts, Mars's polar cap or Saturn's rings.
    private func draw(_ disc: Disc, scale: Double) {
        let brightness = Self.surfaceBrightness(disc.body) * scale
        let tint = Self.color(disc.body)
        let reach = disc.body == .saturn ? disc.radius * 2.4 : disc.radius + 1
        let x0 = max(0, Int(disc.x - reach)), x1 = min(width - 1, Int(disc.x + reach))
        let y0 = max(0, Int(disc.y - reach)), y1 = min(height - 1, Int(disc.y + reach))
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0 ... y1 {
            for x in x0 ... x1 {
                let dx = Double(x) + 0.5 - disc.x, dy = Double(y) + 0.5 - disc.y
                let r = (dx * dx + dy * dy).squareRoot()
                var value = 0.0, color = tint
                let globe = min(1, max(0, disc.radius - r + 0.5))
                if globe > 0 {
                    let mu = max(0, 1 - (r / disc.radius) * (r / disc.radius)).squareRoot()
                    value = globe * (0.55 + 0.45 * mu)
                    let latitude = dy / disc.radius
                    switch disc.body {
                    case .jupiter where abs(latitude) < 0.8:
                        let belt = 0.5 + 0.5 * sin(latitude * .pi * 4.5 + 0.6)
                        color = (tint.r - 0.25 * belt, tint.g - 0.3 * belt, tint.b - 0.3 * belt)
                    case .mars where latitude < -0.78:
                        color = (1, 1, 1)
                    default:
                        break
                    }
                }
                if disc.body == .saturn {
                    // Rings seen nearly edge-on, in front of the globe below its equator and behind it above.
                    let e = (dx * dx + (dy / 0.14) * (dy / 0.14)).squareRoot() / disc.radius
                    let inRing = (1.53 ... 1.95).contains(e) || (2.03 ... 2.27).contains(e)
                    if inRing, globe == 0 || dy > 0 {
                        value = 0.8
                        color = (0.95, 0.88, 0.7)
                    }
                }
                guard value > 0 else { continue }
                let index = y * width + x, amount = value * brightness
                red[index] += Float(amount * color.r)
                green[index] += Float(amount * color.g)
                blue[index] += Float(amount * color.b)
            }
        }
    }

    /// The Moon's surface (a texture made once), placed and scaled into the frame.
    private func addMoon(_ moon: (x: Double, y: Double, radius: Double), texture moonTexture: [Float], brightness: Float) {
        let size = Self.moonTextureSize
        let pixelsPerTexel = moon.radius / Double(size / 2 - 6)
        var transform = vImage_AffineTransform(a: Float(pixelsPerTexel), b: 0, c: 0, d: Float(pixelsPerTexel),
                                               tx: Float(moon.x - Double(size) / 2 * pixelsPerTexel),
                                               ty: Float(moon.y - Double(size) / 2 * pixelsPerTexel))
        var moonTexture = moonTexture // vImage wants a mutable pointer; it doesn't write to the source
        moonTexture.withUnsafeMutableBufferPointer { texture in
            moonPlane.withUnsafeMutableBufferPointer { plane in
                var source = vImage_Buffer(data: texture.baseAddress, height: vImagePixelCount(size), width: vImagePixelCount(size),
                                           rowBytes: size * MemoryLayout<Float>.size)
                var destination = vImage_Buffer(data: plane.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                                rowBytes: width * MemoryLayout<Float>.size)
                vImageAffineWarp_PlanarF(&source, &destination, nil, &transform, 0, vImage_Flags(kvImageBackgroundColorFill))
            }
        }
        let count = vDSP_Length(width * height)
        moonPlane.withUnsafeBufferPointer { plane in
            for (index, tint) in [Float(0.95), 0.93, 0.9].enumerated() {
                var amount = brightness * tint
                withPlane(index) { vDSP_vsma(plane.baseAddress!, 1, &amount, $0, 1, $0, 1, count) }
            }
        }
    }

    private func convertToBGRA() {
        var maximum: [Float] = [255, 255, 255, 255], minimum: [Float] = [0, 0, 0, 0]
        let w = vImagePixelCount(width), h = vImagePixelCount(height), planeBytes = width * MemoryLayout<Float>.size
        blue.withUnsafeMutableBufferPointer { b in
            green.withUnsafeMutableBufferPointer { g in
                red.withUnsafeMutableBufferPointer { r in
                    alpha.withUnsafeMutableBufferPointer { a in
                        interleaved.withUnsafeMutableBufferPointer { out in
                            // vImage names the channels A, R, G, B; handing it B, G, R, A in that order gives BGRA.
                            var p0 = vImage_Buffer(data: b.baseAddress, height: h, width: w, rowBytes: planeBytes)
                            var p1 = vImage_Buffer(data: g.baseAddress, height: h, width: w, rowBytes: planeBytes)
                            var p2 = vImage_Buffer(data: r.baseAddress, height: h, width: w, rowBytes: planeBytes)
                            var p3 = vImage_Buffer(data: a.baseAddress, height: h, width: w, rowBytes: planeBytes)
                            var destination = vImage_Buffer(data: out.baseAddress, height: h, width: w, rowBytes: width * 4)
                            vImageConvert_PlanarFToARGB8888(&p0, &p1, &p2, &p3, &destination, &maximum, &minimum, vImage_Flags(kvImageNoFlags))
                        }
                    }
                }
            }
        }
    }

    private func blur(into base: UnsafeMutableRawPointer, rowBytes: Int, kernel: UInt32) {
        let w = vImagePixelCount(width), h = vImagePixelCount(height)
        interleaved.withUnsafeMutableBufferPointer { source in
            var input = vImage_Buffer(data: source.baseAddress, height: h, width: w, rowBytes: width * 4)
            var output = vImage_Buffer(data: base, height: h, width: w, rowBytes: rowBytes)
            let flags = vImage_Flags(kvImageEdgeExtend)
            let needed = vImageTentConvolve_ARGB8888(&input, &output, nil, 0, 0, kernel, kernel, nil, flags | vImage_Flags(kvImageGetTempBufferSize))
            if needed > blurTemp.count { blurTemp = [UInt8](repeating: 0, count: needed) }
            blurTemp.withUnsafeMutableBufferPointer { temp in
                _ = vImageTentConvolve_ARGB8888(&input, &output, temp.baseAddress, 0, 0, kernel, kernel, nil, flags)
            }
        }
    }

    /// Adds light to one pixel of the BGRA frame, saturating at white.
    @inline(__always)
    private func add(_ pixels: UnsafeMutablePointer<UInt8>, rowBytes: Int, _ x: Int, _ y: Int, _ value: Double) {
        guard x >= 0, y >= 0, x < width, y < height, value >= 0.5 else { return }
        let pixel = pixels + y * rowBytes + x * 4
        let amount = Int(value.rounded())
        for channel in 0 ..< 3 { pixel[channel] = UInt8(min(255, Int(pixel[channel]) + amount)) }
    }

    private func drawStar(_ pixels: UnsafeMutablePointer<UInt8>, rowBytes: Int, x: Double, y: Double, total: Double, sigma: Double) {
        let peak = total / (2 * .pi * sigma * sigma), reach = Int((sigma * 4).rounded(.up))
        let cx = Int(x), cy = Int(y)
        for py in cy - reach ... cy + reach {
            for px in cx - reach ... cx + reach {
                let dx = Double(px) + 0.5 - x, dy = Double(py) + 0.5 - y
                add(pixels, rowBytes: rowBytes, px, py, peak * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma)))
            }
        }
    }

    /// A star well out of focus in a Schmidt-Cassegrain: a bright ring with the secondary mirror's shadow inside.
    private static func doughnutArea(_ radius: Double) -> Double { .pi * radius * radius * (1 - 0.35 * 0.35) }

    private func drawDoughnut(_ pixels: UnsafeMutablePointer<UInt8>, rowBytes: Int, x: Double, y: Double, total: Double, radius: Double) {
        let level = total / Self.doughnutArea(radius), inner = radius * 0.35, reach = Int((radius + 1).rounded(.up))
        let cx = Int(x), cy = Int(y)
        for py in cy - reach ... cy + reach {
            for px in cx - reach ... cx + reach {
                let dx = Double(px) + 0.5 - x, dy = Double(py) + 0.5 - y
                let r = (dx * dx + dy * dy).squareRoot()
                let coverage = min(1, max(0, radius - r + 0.5)) * min(1, max(0, r - inner + 0.5))
                add(pixels, rowBytes: rowBytes, px, py, level * coverage)
            }
        }
    }

    // MARK: Moon texture and random numbers

    /// A grey disc with maria and craters lit from one side, 1024 texels across, made once.
    private static func makeMoonTexture() -> [Float] {
        let size = moonTextureSize, center = Double(size) / 2, radius = center - 6
        var generator = SplitMix(seed: 0x400_0000)
        func random(_ range: ClosedRange<Double>) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * generator.nextUnit() }
        var texture = [Float](repeating: 0, count: size * size)

        // Albedo: bright highlands, dark maria, and some mottling so it's never flat. Worked out on a coarse grid (it
        // changes slowly) and filled in between.
        let maria = (0 ..< 11).map { _ in (x: random(-0.6 ... 0.6), y: random(-0.65 ... 0.45), r: random(0.08 ... 0.3)) }
        let mottle = (0 ..< 40).map { _ in (x: random(-1 ... 1), y: random(-1 ... 1), r: random(0.03 ... 0.12), a: random(-0.06 ... 0.06)) }
        let grid = 129, cell = Double(size) / Double(grid - 1)
        var coarse = [Double](repeating: 0.78, count: grid * grid)
        for gy in 0 ..< grid {
            for gx in 0 ..< grid {
                let u = (Double(gx) * cell - center) / radius, v = (Double(gy) * cell - center) / radius
                var albedo = 0.78
                for mare in maria { albedo -= 0.26 * exp(-((u - mare.x) * (u - mare.x) + (v - mare.y) * (v - mare.y)) / (mare.r * mare.r)) }
                for spot in mottle { albedo += spot.a * exp(-((u - spot.x) * (u - spot.x) + (v - spot.y) * (v - spot.y)) / (spot.r * spot.r)) }
                coarse[gy * grid + gx] = albedo
            }
        }
        for y in 0 ..< size {
            for x in 0 ..< size {
                let u = (Double(x) + 0.5 - center) / radius, v = (Double(y) + 0.5 - center) / radius
                let r2 = u * u + v * v
                guard r2 < 1.02 else { continue }
                let fx = Double(x) / cell, fy = Double(y) / cell
                let gx = min(grid - 2, Int(fx)), gy = min(grid - 2, Int(fy)), tx = fx - Double(gx), ty = fy - Double(gy)
                let top = coarse[gy * grid + gx] * (1 - tx) + coarse[gy * grid + gx + 1] * tx
                let bottom = coarse[(gy + 1) * grid + gx] * (1 - tx) + coarse[(gy + 1) * grid + gx + 1] * tx
                var albedo = top * (1 - ty) + bottom * ty
                albedo += 0.03 * (generator.nextUnit() - 0.5)
                let edge = min(1, max(0, (1 - r2.squareRoot()) * radius + 0.5))
                texture[y * size + x] = Float(max(0.15, albedo) * (0.8 + 0.2 * max(0, 1 - r2).squareRoot()) * edge)
            }
        }

        // Craters, mostly small: a flat floor, the wall toward the light in shadow and the far wall lit, a thin rim.
        for _ in 0 ..< 2500 {
            let cr = 1.2 + 40 * pow(random(0 ... 1), 7)
            let cx = random(0 ... Double(size)), cy = random(0 ... Double(size))
            let reach = Int(cr * 1.3) + 1
            for y in max(0, Int(cy) - reach) ... min(size - 1, Int(cy) + reach) {
                for x in max(0, Int(cx) - reach) ... min(size - 1, Int(cx) + reach) {
                    let index = y * size + x
                    guard texture[index] > 0 else { continue }
                    let dx = (Double(x) - cx) / cr, dy = (Double(y) - cy) / cr
                    let d = (dx * dx + dy * dy).squareRoot()
                    let shade: Double
                    if d < 0.95 {
                        let wall = min(1, max(0, (d - 0.45) / 0.5)) // light from the right: the left wall in shadow
                        shade = wall * (dx < 0 ? 0.3 * dx : 0.1 * dx) - 0.02
                    } else if d < 1.12 {
                        shade = 0.04 * (1 - abs(d - 1.03) / 0.09)
                    } else {
                        continue
                    }
                    texture[index] = max(0.04, texture[index] + Float(shade))
                }
            }
        }
        return texture
    }

    private static func gaussian() -> Double {
        var generator = SystemRandomNumberGenerator()
        return gaussian(using: &generator)
    }

    private static func gaussian<G: RandomNumberGenerator>(using generator: inout G) -> Double {
        let u1 = max(Double.leastNonzeroMagnitude, Double.random(in: 0 ..< 1, using: &generator)), u2 = Double.random(in: 0 ..< 1, using: &generator)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// A small, fast, seeded random number generator, so the noise stock and the Moon look the same every run.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
