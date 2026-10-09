import ScopeKit
import SwiftUI

/// Azimuth as a heading tape: a compass scale that slides under a fixed index, like an aircraft's heading strip.
/// Readings arrive about once a second; the tape glides between them, so a slew shows as motion, not jumps.
struct AzimuthTape: View {
    let azimuth: Double
    var moving = false
    /// Degrees across the full width.
    var span: Double = 90

    /// `azimuth` unwrapped into a continuous value, so 359° → 1° glides 2° forward rather than 358° back.
    @State private var unwrapped: Double?

    var body: some View {
        AzimuthScale(value: unwrapped ?? azimuth, span: span, moving: moving)
            .onAppear { unwrapped = azimuth }
            .onChange(of: azimuth) { _, new in
                let old = unwrapped ?? new
                let delta = (new - old).truncatingRemainder(dividingBy: 360)
                let step = delta > 180 ? delta - 360 : delta < -180 ? delta + 360 : delta
                withAnimation(.linear(duration: 0.9)) { unwrapped = old + step }
            }
    }
}

private struct AzimuthScale: View, @preconcurrency Animatable {
    var value: Double
    let span: Double
    let moving: Bool

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        let index = moving ? Theme.warning : Theme.accent
        let scale = Theme.scale, accent = Theme.accent, secondary = Theme.textSecondary
        Canvas { context, size in
            let perDegree = size.width / span
            let mid = size.width / 2
            var minor = Path(), major = Path()
            for degree in Int((value - span / 2).rounded(.down)) ... Int((value + span / 2).rounded(.up)) {
                let x = mid + (Double(degree) - value) * perDegree
                let heading = ((degree % 360) + 360) % 360
                if heading % 5 == 0 {
                    major.move(to: CGPoint(x: x, y: 0))
                    major.addLine(to: CGPoint(x: x, y: heading % 10 == 0 ? 14 : 9))
                } else {
                    minor.move(to: CGPoint(x: x, y: 0))
                    minor.addLine(to: CGPoint(x: x, y: 5))
                }
                let label: Text
                if let point = Self.cardinals[heading] {
                    label = Text(point).font(Theme.display(heading % 90 == 0 ? 18 : 14)).foregroundStyle(heading % 90 == 0 ? accent : secondary)
                } else if heading % 10 == 0 {
                    label = Text(String(format: "%03d", heading)).font(Theme.numeric(11)).foregroundStyle(secondary)
                } else {
                    continue
                }
                context.draw(label, at: CGPoint(x: x, y: 20), anchor: .top)
            }
            context.stroke(minor, with: .color(scale.opacity(0.35)), lineWidth: 1)
            context.stroke(major, with: .color(scale.opacity(0.75)), lineWidth: 1)
            var rule = Path()
            rule.move(to: .zero)
            rule.addLine(to: CGPoint(x: size.width, y: 0))
            context.stroke(rule, with: .color(scale.opacity(0.5)), lineWidth: 1)

            // Fixed index: a notch from above and a hairline through the scale.
            var notch = Path()
            notch.move(to: CGPoint(x: mid - 6, y: -1))
            notch.addLine(to: CGPoint(x: mid + 6, y: -1))
            notch.addLine(to: CGPoint(x: mid, y: 8))
            notch.closeSubpath()
            context.fill(notch, with: .color(index))
            var line = Path()
            line.move(to: CGPoint(x: mid, y: 8))
            line.addLine(to: CGPoint(x: mid, y: size.height))
            context.stroke(line, with: .color(index.opacity(0.8)), lineWidth: 1.5)
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                     .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
    }

    private static let cardinals = [0: "N", 45: "NE", 90: "E", 135: "SE", 180: "S", 225: "SW", 270: "W", 315: "NW"]
}

/// Altitude as a vertical tape, with the band the up/down arrows are held to marked off: outside it is hatched.
/// Glides between readings when the caller animates `altitude`.
struct AltitudeTape: View, @preconcurrency Animatable {
    var altitude: Double
    var moving = false
    /// Degrees from top to bottom.
    var span: Double = 50
    var band: ClosedRange<Double> = NudgeCommand.altitudeLimits

    var animatableData: Double {
        get { altitude }
        set { altitude = newValue }
    }

    var body: some View {
        let index = moving ? Theme.warning : Theme.accent
        let scale = Theme.scale, secondary = Theme.textSecondary, hatch = Theme.warning
        Canvas { context, size in
            let perDegree = size.height / span
            let mid = size.height / 2
            func y(_ degree: Double) -> Double { mid - (degree - altitude) * perDegree }

            // Outside the band: hatched, with a firm edge where the band ends.
            for (from, to, edge) in [(band.upperBound, 90.0, band.upperBound), (-90.0, band.lowerBound, band.lowerBound)] {
                let top = max(0, y(to)), bottom = min(size.height, y(from))
                guard bottom > top else { continue }
                let zone = CGRect(x: 0, y: top, width: size.width, height: bottom - top)
                var stripes = Path()
                for offset in stride(from: -size.width, to: zone.height + size.width, by: 7) {
                    stripes.move(to: CGPoint(x: 0, y: zone.minY + offset))
                    stripes.addLine(to: CGPoint(x: size.width, y: zone.minY + offset + size.width))
                }
                var clipped = context
                clipped.clip(to: Path(zone))
                clipped.stroke(stripes, with: .color(hatch.opacity(0.22)), lineWidth: 1)
                var limit = Path()
                limit.move(to: CGPoint(x: 0, y: y(edge)))
                limit.addLine(to: CGPoint(x: size.width, y: y(edge)))
                context.stroke(limit, with: .color(hatch.opacity(0.7)), lineWidth: 1)
            }

            var minor = Path(), major = Path()
            for degree in Int((altitude - span / 2).rounded(.down)) ... Int((altitude + span / 2).rounded(.up)) where abs(degree) <= 90 {
                let yy = y(Double(degree))
                if degree % 5 == 0 {
                    major.move(to: CGPoint(x: 0, y: yy))
                    major.addLine(to: CGPoint(x: degree % 10 == 0 ? 14 : 9, y: yy))
                } else {
                    minor.move(to: CGPoint(x: 0, y: yy))
                    minor.addLine(to: CGPoint(x: 5, y: yy))
                }
                if degree % 10 == 0 {
                    context.draw(Text("\(degree)°").font(Theme.numeric(11)).foregroundStyle(secondary),
                                 at: CGPoint(x: 20, y: yy), anchor: .leading)
                }
            }
            context.stroke(minor, with: .color(scale.opacity(0.35)), lineWidth: 1)
            context.stroke(major, with: .color(scale.opacity(0.75)), lineWidth: 1)
            var rule = Path()
            rule.move(to: .zero)
            rule.addLine(to: CGPoint(x: 0, y: size.height))
            context.stroke(rule, with: .color(scale.opacity(0.5)), lineWidth: 1)

            var notch = Path()
            notch.move(to: CGPoint(x: -1, y: mid - 6))
            notch.addLine(to: CGPoint(x: -1, y: mid + 6))
            notch.addLine(to: CGPoint(x: 8, y: mid))
            notch.closeSubpath()
            context.fill(notch, with: .color(index))
            var line = Path()
            line.move(to: CGPoint(x: 8, y: mid))
            line.addLine(to: CGPoint(x: 16, y: mid))
            context.stroke(line, with: .color(index.opacity(0.8)), lineWidth: 1.5)
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                     .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}
