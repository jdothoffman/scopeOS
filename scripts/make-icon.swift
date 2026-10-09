// Draws scopeOS's app icon (a telescope under a night sky, aimed at Polaris) and writes every size the asset
// catalog needs.
//   swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset
import AppKit

let canvas: CGFloat = 1024

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func drawIcon(in cg: CGContext) {
    // macOS icon grid: an 824-point rounded square, centred, with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0, 0, 0, 0.45))
    cg.addPath(shape)
    cg.setFillColor(color(0.03, 0.05, 0.12))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Sky: deep navy at the top, lifting toward the horizon.
    let sky = CGGradient(colorsSpace: space, colors: [color(0.02, 0.03, 0.10), color(0.07, 0.09, 0.24), color(0.16, 0.13, 0.36)] as CFArray,
                         locations: [0, 0.55, 1])!
    cg.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // A faint violet glow, like the Milky Way, across the upper left.
    let glow = CGGradient(colorsSpace: space, colors: [color(0.63, 0.5, 1.0, 0.30), color(0.63, 0.5, 1.0, 0)] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 700), startRadius: 0, endCenter: CGPoint(x: 300, y: 700), endRadius: 380, options: [])

    // Stars, scattered the same way every run.
    var seed: UInt64 = 0x5C09E40
    func random() -> CGFloat {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(seed >> 33) / CGFloat(1 << 31)
    }
    for _ in 0 ..< 90 {
        let point = CGPoint(x: 110 + random() * 804, y: 300 + random() * 620)
        let radius = 1.6 + pow(random(), 3) * 4.2
        let blue = random() < 0.35
        cg.setFillColor(blue ? color(0.75, 0.85, 1.0, 0.55 + random() * 0.45) : color(1, 1, 1, 0.45 + random() * 0.55))
        cg.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }

    // Polaris: a bright cyan-white star with a glow and a four-point sparkle.
    let polaris = CGPoint(x: 735, y: 765)
    let halo = CGGradient(colorsSpace: space, colors: [color(0.33, 0.83, 1.0, 0.75), color(0.33, 0.83, 1.0, 0)] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(halo, startCenter: polaris, startRadius: 0, endCenter: polaris, endRadius: 110, options: [])
    func sparkle(length: CGFloat, width: CGFloat, angle: CGFloat) {
        cg.saveGState()
        cg.translateBy(x: polaris.x, y: polaris.y)
        cg.rotate(by: angle)
        cg.move(to: CGPoint(x: -length, y: 0))
        cg.addQuadCurve(to: CGPoint(x: 0, y: width), control: CGPoint(x: -width, y: width * 0.25))
        cg.addQuadCurve(to: CGPoint(x: length, y: 0), control: CGPoint(x: width, y: width * 0.25))
        cg.addQuadCurve(to: CGPoint(x: 0, y: -width), control: CGPoint(x: width, y: -width * 0.25))
        cg.addQuadCurve(to: CGPoint(x: -length, y: 0), control: CGPoint(x: -width, y: -width * 0.25))
        cg.setFillColor(color(0.92, 0.98, 1.0))
        cg.fillPath()
        cg.restoreGState()
    }
    sparkle(length: 78, width: 13, angle: 0)
    sparkle(length: 78, width: 13, angle: .pi / 2)
    sparkle(length: 34, width: 7, angle: .pi / 4)
    sparkle(length: 34, width: 7, angle: -.pi / 4)

    // The telescope's line of sight, fading out toward the star.
    let pivot = CGPoint(x: 420, y: 470)
    let angle = atan2(polaris.y - pivot.y, polaris.x - pivot.x)
    let aperture = CGPoint(x: pivot.x + cos(angle) * 225, y: pivot.y + sin(angle) * 225)
    cg.saveGState()
    cg.setLineWidth(10)
    cg.setLineCap(.round)
    cg.move(to: aperture)
    cg.addLine(to: CGPoint(x: polaris.x - cos(angle) * 40, y: polaris.y - sin(angle) * 40))
    cg.replacePathWithStrokedPath()
    cg.clip()
    let beam = CGGradient(colorsSpace: space, colors: [color(0.33, 0.83, 1.0, 0.45), color(0.33, 0.83, 1.0, 0)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(beam, start: aperture, end: polaris, options: [])
    cg.restoreGState()

    // Hills along the horizon.
    cg.move(to: CGPoint(x: 100, y: 100))
    cg.addLine(to: CGPoint(x: 100, y: 250))
    cg.addCurve(to: CGPoint(x: 560, y: 215), control1: CGPoint(x: 250, y: 300), control2: CGPoint(x: 420, y: 250))
    cg.addCurve(to: CGPoint(x: 924, y: 285), control1: CGPoint(x: 700, y: 185), control2: CGPoint(x: 820, y: 300))
    cg.addLine(to: CGPoint(x: 924, y: 100))
    cg.closePath()
    cg.setFillColor(color(0.015, 0.02, 0.05))
    cg.fillPath()

    // Tripod and mount head.
    let leg = color(0.58, 0.64, 0.78)
    cg.setStrokeColor(leg)
    cg.setLineWidth(16)
    cg.setLineCap(.round)
    let head = CGPoint(x: 395, y: 345)
    for foot in [CGPoint(x: 285, y: 175), CGPoint(x: 505, y: 175), CGPoint(x: 410, y: 160)] {
        cg.move(to: head)
        cg.addLine(to: foot)
    }
    cg.strokePath()
    cg.setFillColor(color(0.30, 0.34, 0.46))
    cg.addPath(CGPath(roundedRect: CGRect(x: 345, y: 330, width: 100, height: 46), cornerWidth: 12, cornerHeight: 12, transform: nil))
    cg.fillPath()

    // Single fork arm, like the NexStar SE.
    cg.setFillColor(color(0.20, 0.23, 0.33))
    cg.addPath(CGPath(roundedRect: CGRect(x: 372, y: 360, width: 62, height: 130), cornerWidth: 20, cornerHeight: 20, transform: nil))
    cg.fillPath()

    // The tube, aimed at Polaris.
    cg.saveGState()
    cg.translateBy(x: pivot.x, y: pivot.y)
    cg.rotate(by: angle)
    let tube = CGPath(roundedRect: CGRect(x: -160, y: -62, width: 375, height: 124), cornerWidth: 26, cornerHeight: 26, transform: nil)
    cg.saveGState()
    cg.addPath(tube)
    cg.clip()
    let shine = CGGradient(colorsSpace: space, colors: [color(0.97, 0.98, 1.0), color(0.80, 0.84, 0.93), color(0.55, 0.60, 0.74)] as CFArray,
                           locations: [0, 0.45, 1])!
    cg.drawLinearGradient(shine, start: CGPoint(x: 0, y: 62), end: CGPoint(x: 0, y: -62), options: [])
    cg.restoreGState()
    // Rear cell, front ring (in the app's accent colour) and a finder scope.
    cg.setFillColor(color(0.22, 0.25, 0.34))
    cg.addPath(CGPath(roundedRect: CGRect(x: -178, y: -54, width: 40, height: 108), cornerWidth: 12, cornerHeight: 12, transform: nil))
    cg.fillPath()
    cg.setFillColor(color(0.33, 0.83, 1.0))
    cg.addPath(CGPath(roundedRect: CGRect(x: 190, y: -70, width: 44, height: 140), cornerWidth: 14, cornerHeight: 14, transform: nil))
    cg.fillPath()
    cg.setFillColor(color(0.85, 0.88, 0.95))
    cg.addPath(CGPath(roundedRect: CGRect(x: -40, y: 70, width: 120, height: 28), cornerWidth: 10, cornerHeight: 10, transform: nil))
    cg.fillPath()
    cg.setFillColor(color(0.55, 0.60, 0.74))
    cg.fill(CGRect(x: -10, y: 60, width: 14, height: 12))
    cg.fill(CGRect(x: 50, y: 60, width: 14, height: 12))
    cg.restoreGState()

    cg.restoreGState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    cg.interpolationQuality = .high
    cg.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    drawIcon(in: cg)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(output.path)")
