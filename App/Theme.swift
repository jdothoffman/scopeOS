import Observation
import SwiftUI

/// App-wide look. Night vision swaps the palette for dim red on black, which keeps dark-adapted eyes intact.
@MainActor
@Observable
final class Appearance {
    static let shared = Appearance()

    var nightVision: Bool { didSet { UserDefaults.standard.set(nightVision, forKey: "nightVision") } }

    private init() {
        nightVision = UserDefaults.standard.bool(forKey: "nightVision")
    }
}

/// Colors read `Appearance.shared`, so any view using them redraws when night vision is toggled.
///
/// The look is a precision instrument rather than a spaceship: warm amber on near-black, like lamp-lit dials, with
/// hairline scales and engineering type. Amber dims naturally into night vision's red, so the two modes read as one
/// design turned down rather than two themes.
@MainActor
enum Theme {
    private static var night: Bool { Appearance.shared.nightVision }
    private static func red(_ level: Double) -> Color { Color(red: level, green: level * 0.16, blue: level * 0.13) }

    static var backgroundTop: Color { night ? .black : Color(red: 0.039, green: 0.039, blue: 0.043) }
    static var backgroundBottom: Color { night ? red(0.04) : Color(red: 0.055, green: 0.053, blue: 0.058) }

    static var accent: Color { night ? red(0.92) : Color(red: 1.0, green: 0.71, blue: 0.29) }
    /// Cool counterpart to the amber: constellation lines, the second readout family.
    static var cool: Color { night ? red(0.66) : Color(red: 0.56, green: 0.7, blue: 0.86) }
    static var ok: Color { night ? red(0.66) : Color(red: 0.5, green: 0.86, blue: 0.56) }
    static var warning: Color { night ? Color(red: 1.0, green: 0.4, blue: 0.2) : Color(red: 1.0, green: 0.47, blue: 0.22) }
    static var danger: Color { night ? Color(red: 1.0, green: 0.2, blue: 0.18) : Color(red: 0.95, green: 0.22, blue: 0.2) }

    static var textPrimary: Color { night ? red(0.88) : Color(red: 0.93, green: 0.91, blue: 0.87) }
    static var textSecondary: Color { night ? red(0.6) : Color(red: 0.62, green: 0.6, blue: 0.56) }
    static var textTertiary: Color { night ? red(0.4) : Color(red: 0.43, green: 0.42, blue: 0.4) }

    static var panel: Color { night ? red(1).opacity(0.03) : Color.white.opacity(0.022) }
    static var hairline: Color { night ? red(1).opacity(0.16) : Color.white.opacity(0.09) }
    /// Scale ticks and graticule lines.
    static var scale: Color { night ? red(0.5) : Color(red: 0.72, green: 0.7, blue: 0.66) }

    /// Multiplied over the whole window in night vision, so system controls can't stay white either.
    static var windowFilter: Color { night ? Color(red: nightFilter.red, green: nightFilter.green, blue: nightFilter.blue) : .white }
    /// Red stays at exactly 1: the camera preview is already red-only from its own filter (SwiftUI's multiply isn't
    /// guaranteed to reach an AppKit view), so this leaves it unchanged whether or not it reaches it. Below 1 the
    /// preview would be dimmed twice.
    static let nightFilter = (red: 1.0, green: 0.14, blue: 0.11)
    static func starColor(blue: Bool) -> Color { night ? red(0.7) : blue ? Color(red: 0.75, green: 0.85, blue: 1.0) : .white }

    /// Engineering type for titles and labels (macOS ships it, bold only).
    static func display(_ size: CGFloat) -> Font { .custom("DINCondensed-Bold", fixedSize: size) }
    /// Readout figures: DIN with equal-width digits, so values don't jitter as they change.
    static func numeric(_ size: CGFloat) -> Font { .custom("DINAlternate-Bold", fixedSize: size) }

    static func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(display(12))
            .tracking(1.8)
            .foregroundStyle(textSecondary)
    }
}

extension View {
    /// Instrument panel: faint fill, hairline frame, small brackets marking the corners.
    func panel(cornerRadius: CGFloat = 3) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Theme.panel, in: shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
            .overlay(CornerBrackets().stroke(Theme.accent.opacity(0.55), lineWidth: 1.5))
    }

    /// Soft light around an element; much fainter in night vision, where every bit of brightness counts. Kept for
    /// lit things (indicator lamps, the reticle), not for panels or text.
    func glow(_ color: Color, radius: CGFloat = 8) -> some View {
        let night = Appearance.shared.nightVision
        return shadow(color: color.opacity(night ? 0.2 : 0.45), radius: night ? radius * 0.3 : radius * 0.6)
    }
}

/// Short L-shaped marks in each corner of a rect, like a viewfinder's frame.
struct CornerBrackets: Shape {
    var length: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = rect.insetBy(dx: 0.75, dy: 0.75)
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1, 1),
                                 (CGPoint(x: r.minX, y: r.maxY), 1, -1), (CGPoint(x: r.maxX, y: r.maxY), -1, -1)] {
            path.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
        }
        return path
    }
}

/// Backdrop: near-black with a faint plotting grid, like the face of a chart table. The sky map is the only stars in
/// the app, so it stands out.
struct SpaceBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.backgroundTop, Theme.backgroundBottom], startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                let spacing: CGFloat = 48
                var minor = Path()
                for x in stride(from: spacing, to: size.width, by: spacing) {
                    minor.move(to: CGPoint(x: x, y: 0))
                    minor.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: spacing, to: size.height, by: spacing) {
                    minor.move(to: CGPoint(x: 0, y: y))
                    minor.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(minor, with: .color(Theme.scale.opacity(0.035)), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
    }
}

struct StatusPill: View {
    let label: String
    let color: Color
    var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 7, height: 7)
                .glow(color, radius: pulsing ? 6 : 2)
            Text(label.uppercased())
                .font(Theme.display(13))
                .tracking(1.6)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 2) // DIN Condensed sits high in its line box
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(color.opacity(0.4), lineWidth: 1))
    }
}
