import ScopeKit
import SwiftUI

/// The sky around where the telescope points, from its angles, your location and the time: stars, constellations,
/// the Moon and planets, the Sun's keep-out zone. Click anything (or any point) to see what it is and go there.
struct SkyTab: View {
    @State private var view = SkyMapView()
    @State private var selection: SkySelection?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SkyMapCard(view: $view, selection: $selection)
            VStack(spacing: 16) {
                SkySelectionCard(view: $view, selection: $selection)
                ControlCard()
            }
            .frame(width: 330)
        }
    }
}

/// Where the map looks and how wide.
struct SkyMapView: Equatable {
    /// Keep the map centred on the telescope.
    var follow = true
    /// Where it looks when not following (or before there's a reading).
    var center = Horizontal(azimuth: 180, altitude: 45)
    /// Degrees from the centre to the edge of the shorter side.
    var fieldRadius = 30.0

    static let fieldRange = 3.0 ... 90.0
}

/// What's selected on the map.
enum SkySelection: Equatable {
    case star(hr: Int)
    case body(SkyTarget)
    /// Empty sky, equinox of date.
    case spot(Equatorial)

    @MainActor var target: SkyTarget? {
        switch self {
        case .star(let hr): SkyMapData.star(hr: hr)?.star.target
        case .body(let target): target
        case .spot(let position): .point(position)
        }
    }
}

/// The catalogue brought up to date once (precession moves stars a little each year), for drawing.
@MainActor
enum SkyMapData {
    struct Star {
        let star: CatalogStar
        let position: Equatorial
    }

    struct Figure {
        let constellation: Constellation
        let label: Equatorial
        let lines: [[Equatorial]]
    }

    static let stars: [Star] = SkyCatalog.stars.map { Star(star: $0, position: Astronomy.precess($0.j2000, to: .now)) }
    static let figures: [Figure] = SkyCatalog.constellations.map { constellation in
        Figure(constellation: constellation, label: Astronomy.precess(constellation.label, to: .now),
               lines: constellation.lines.map { $0.map { Astronomy.precess($0, to: .now) } })
    }
    private static let byHR = Dictionary(uniqueKeysWithValues: stars.map { ($0.star.hr, $0) })

    static func star(hr: Int) -> Star? { byHR[hr] }

    /// The Moon and planets, as targets.
    static let bodies: [SkyTarget] = [.moon] + Planet.allCases.map(SkyTarget.planet)
}

struct SkyMapCard: View {
    @Environment(MonitorModel.self) private var model
    @Environment(LocationModel.self) private var location
    @Binding var view: SkyMapView
    @Binding var selection: SkySelection?
    @State private var dragStart: SkyProjection?
    @State private var zoomStart: Double?

    var body: some View {
        Card(title: "Sky map", systemImage: "sparkles") {
            if let observer = location.observer {
                VStack(spacing: 10) {
                    GeometryReader { geometry in
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let map = SkyMapRenderer(projection: projection(size: geometry.size), date: context.date, observer: observer,
                                                     telescope: model.status?.horizontal, selection: selection)
                            Canvas { canvas, _ in map.draw(in: &canvas) }
                                .contentShape(Rectangle())
                                .onTapGesture { point in
                                    selection = map.hitTest(point)
                                }
                                .gesture(drag(geometry.size).simultaneously(with: zoom))
                        }
                    }
                    // As tall as the window allows, leaving room for the card's title and the toolbar below.
                    .containerRelativeFrame(.vertical) { height, _ in max(340, height - 140) }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    toolbar
                }
            } else {
                Text("Set your location in the Setup tab to see the sky map.")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
    }

    /// The telescope's direction when following it, else wherever the map was left.
    private var center: Horizontal {
        if view.follow, let pointing = model.status?.horizontal { return pointing }
        return view.center
    }

    private func projection(size: CGSize) -> SkyProjection {
        SkyProjection(center: center, fieldRadius: view.fieldRadius,
                      origin: CGPoint(x: size.width / 2, y: size.height / 2), radius: min(size.width, size.height) / 2)
    }

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = dragStart ?? projection(size: size)
                if dragStart == nil {
                    dragStart = start
                    view.follow = false
                }
                // The point under the pointer stays under it.
                view.center = start.sky(at: CGPoint(x: start.origin.x - value.translation.width, y: start.origin.y - value.translation.height))
            }
            .onEnded { _ in dragStart = nil }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? view.fieldRadius
                zoomStart = start
                view.fieldRadius = min(SkyMapView.fieldRange.upperBound, max(SkyMapView.fieldRange.lowerBound, start / value.magnification))
            }
            .onEnded { _ in zoomStart = nil }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                view.follow = true
            } label: {
                Label(view.follow ? "Following the telescope" : "Follow the telescope", systemImage: "scope")
            }
            .disabled(view.follow || model.status?.horizontal == nil)
            .help("Keep the map centred on where the telescope points")
            Spacer()
            Text(String(format: "%.0f° across", 2 * view.fieldRadius))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Button("Zoom out", systemImage: "minus.magnifyingglass") { setField(view.fieldRadius * 1.4) }
                .labelStyle(.iconOnly)
            Button("Zoom in", systemImage: "plus.magnifyingglass") { setField(view.fieldRadius / 1.4) }
                .labelStyle(.iconOnly)
        }
        .controlSize(.small)
    }

    private func setField(_ radius: Double) {
        view.fieldRadius = min(SkyMapView.fieldRange.upperBound, max(SkyMapView.fieldRange.lowerBound, radius))
    }
}

/// Draws one frame of the map and finds what's under a click.
@MainActor
struct SkyMapRenderer {
    let projection: SkyProjection
    let date: Date
    let observer: Observer
    let telescope: Horizontal?
    let selection: SkySelection?

    /// Fainter stars appear as you zoom in.
    private var magnitudeLimit: Double { projection.fieldRadius > 45 ? 4.5 : projection.fieldRadius > 22 ? 5.5 : 6.5 }
    /// Proper names appear for brighter stars when zoomed out, all named stars when zoomed in.
    private var nameLimit: Double { projection.fieldRadius > 45 ? 1.5 : projection.fieldRadius > 22 ? 2.5 : 5 }
    private var pointsPerDegree: Double { projection.radius / projection.fieldRadius }

    private func horizontal(_ position: Equatorial) -> Horizontal { Astronomy.horizontal(position, at: date, observer: observer) }

    func draw(in context: inout GraphicsContext) {
        let size = CGSize(width: projection.origin.x * 2, height: projection.origin.y * 2)
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .radialGradient(Gradient(colors: [Color(red: 0.03, green: 0.036, blue: 0.055), Color(red: 0.008, green: 0.01, blue: 0.018)]),
                                           center: projection.origin, startRadius: 0, endRadius: max(size.width, size.height) / 1.2))
        drawGrid(&context)
        drawConstellations(&context)
        drawStars(&context)
        drawSolarSystem(&context)
        drawGround(&context, size: size)
        drawTelescope(&context)
        drawSelection(&context)
    }

    // MARK: Layers

    /// Altitude circles every 30°, azimuth lines every 30°, compass points along the horizon.
    private func drawGrid(_ context: inout GraphicsContext) {
        for altitude in [30.0, 60] {
            stroke(&context, points: stride(from: 0.0, through: 360, by: 2).map { Horizontal(azimuth: $0, altitude: altitude) },
                   color: Theme.accent.opacity(0.10), dash: [3, 4])
        }
        for azimuth in stride(from: 0.0, to: 360, by: 30) {
            stroke(&context, points: stride(from: 0.0, through: 88, by: 2).map { Horizontal(azimuth: azimuth, altitude: $0) },
                   color: Theme.accent.opacity(0.07))
        }
    }

    private func drawConstellations(_ context: inout GraphicsContext) {
        for figure in SkyMapData.figures {
            for line in figure.lines {
                stroke(&context, points: line.map(horizontal), color: Theme.cool.opacity(0.35), aboveHorizonOnly: true)
            }
            let label = horizontal(figure.label)
            if label.altitude > 0, let point = projection.point(for: label, limit: 80) {
                context.draw(Text(figure.constellation.name.uppercased()).font(Theme.display(12)).tracking(2)
                    .foregroundStyle(Theme.cool.opacity(0.7)), at: point)
            }
        }
    }

    private func drawStars(_ context: inout GraphicsContext) {
        let limit = magnitudeLimit
        for entry in SkyMapData.stars {
            guard entry.star.magnitude <= limit else { break } // brightest first
            let sky = horizontal(entry.position)
            guard sky.altitude > -1, let point = projection.point(for: sky, limit: 80) else { continue }
            let radius = max(0.7, 0.6 * (limit + 1.4 - entry.star.magnitude))
            context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)),
                         with: .color(Theme.starColor(blue: false).opacity(min(1, 0.45 + 0.12 * (limit - entry.star.magnitude)))))
            if !entry.star.name.isEmpty, entry.star.magnitude <= nameLimit {
                context.draw(Text(entry.star.name).font(.system(size: 10)).foregroundStyle(Theme.textSecondary),
                             at: CGPoint(x: point.x + radius + 4, y: point.y), anchor: .leading)
            }
        }
    }

    private func drawSolarSystem(_ context: inout GraphicsContext) {
        // The Sun and its keep-out zone, which no move may enter.
        let sun = horizontal(Astronomy.sunPosition(at: date))
        if sun.altitude > -SunSafety.keepOutDegrees {
            let ring = stride(from: 0.0, through: 360, by: 4).map { offset(sun, by: SunSafety.keepOutDegrees, bearing: $0) }
            let points = ring.compactMap { projection.point(for: $0, limit: 120) }
            if points.count == ring.count {
                var zone = Path()
                zone.addLines(points)
                zone.closeSubpath()
                context.fill(zone, with: .color(Theme.danger.opacity(0.08)))
                context.stroke(zone, with: .color(Theme.danger.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            if let point = projection.point(for: sun, limit: 80) {
                dot(&context, at: point, radius: 7, color: Theme.warning, label: "Sun")
            }
        }
        for body in SkyMapData.bodies {
            let sky = body.horizontal(at: date, observer: observer)
            guard sky.altitude > -1, let point = projection.point(for: sky, limit: 80) else { continue }
            if body.kind == .moon {
                dot(&context, at: point, radius: max(6, 0.26 * pointsPerDegree), color: Color(white: 0.85), label: "Moon")
            } else {
                dot(&context, at: point, radius: 4, color: color(of: body), label: body.name)
            }
        }
    }

    /// Below the horizon, filled in coarse cells (cheap at once a second), with the horizon line drawn over it.
    private func drawGround(_ context: inout GraphicsContext, size: CGSize) {
        let cell: CGFloat = 6
        var ground = Path()
        var y: CGFloat = 0
        while y < size.height {
            var x: CGFloat = 0
            while x < size.width {
                if projection.sky(at: CGPoint(x: x + cell / 2, y: y + cell / 2)).altitude < 0 {
                    ground.addRect(CGRect(x: x, y: y, width: cell + 0.5, height: cell + 0.5))
                }
                x += cell
            }
            y += cell
        }
        context.fill(ground, with: .color(Color(red: 0.03, green: 0.028, blue: 0.026).opacity(0.92)))
        stroke(&context, points: stride(from: 0.0, through: 360, by: 1).map { Horizontal(azimuth: $0, altitude: 0) },
               color: Theme.accent.opacity(0.5), width: 1.2)
        for (label, azimuth) in [("N", 0.0), ("NE", 45), ("E", 90), ("SE", 135), ("S", 180), ("SW", 225), ("W", 270), ("NW", 315)] {
            if let point = projection.point(for: Horizontal(azimuth: azimuth, altitude: -2), limit: 85) {
                context.draw(Text(label).font(Theme.display(15))
                    .foregroundStyle(label == "N" ? Theme.accent : Theme.textSecondary), at: point)
            }
        }
    }

    /// The telescope's crosshair, with a 1° circle for scale.
    private func drawTelescope(_ context: inout GraphicsContext) {
        guard let telescope, let point = projection.point(for: telescope, limit: 85) else { return }
        let degree = pointsPerDegree
        var reticle = Path(ellipseIn: CGRect(x: point.x - degree, y: point.y - degree, width: 2 * degree, height: 2 * degree))
        for (dx, dy) in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1)] {
            reticle.move(to: CGPoint(x: point.x + dx * (degree + 4), y: point.y + dy * (degree + 4)))
            reticle.addLine(to: CGPoint(x: point.x + dx * (degree + 14), y: point.y + dy * (degree + 14)))
        }
        context.stroke(reticle, with: .color(Theme.accent), lineWidth: 1.5)
    }

    private func drawSelection(_ context: inout GraphicsContext) {
        guard let selection, let sky = position(of: selection), let point = projection.point(for: sky, limit: 85) else { return }
        context.stroke(Path(ellipseIn: CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)),
                       with: .color(Theme.ok), lineWidth: 1.5)
    }

    // MARK: Hit testing

    /// What's under `point`: the Moon or a planet first, then the nearest bright-enough star, else that spot of sky.
    func hitTest(_ point: CGPoint) -> SkySelection {
        func distance(_ other: CGPoint) -> CGFloat { hypot(other.x - point.x, other.y - point.y) }
        let body = SkyMapData.bodies.compactMap { body -> (SkyTarget, CGFloat)? in
            let sky = body.horizontal(at: date, observer: observer)
            guard sky.altitude > -1, let at = projection.point(for: sky, limit: 80) else { return nil }
            let reach = body.kind == .moon ? max(14, 0.26 * pointsPerDegree + 4) : 14
            return distance(at) <= reach ? (body, distance(at)) : nil
        }.min { $0.1 < $1.1 }
        if let body { return .body(body.0) }

        var best: (hr: Int, score: Double)?
        for entry in SkyMapData.stars {
            guard entry.star.magnitude <= magnitudeLimit else { break }
            let sky = horizontal(entry.position)
            guard sky.altitude > -1, let at = projection.point(for: sky, limit: 80) else { continue }
            let gap = distance(at)
            guard gap <= 12 else { continue }
            let score = Double(gap) + 2 * entry.star.magnitude // nearer and brighter wins
            if best.map({ score < $0.score }) ?? true { best = (entry.star.hr, score) }
        }
        if let best { return .star(hr: best.hr) }
        return .spot(Astronomy.equatorial(from: projection.sky(at: point), at: date, observer: observer))
    }

    private func position(of selection: SkySelection) -> Horizontal? {
        switch selection {
        case .star(let hr): SkyMapData.star(hr: hr).map { horizontal($0.position) }
        case .body(let body): body.horizontal(at: date, observer: observer)
        case .spot(let position): horizontal(position)
        }
    }

    // MARK: Helpers

    /// Strokes a line through sky positions, broken where it leaves the view (or, optionally, dips below the horizon).
    private func stroke(_ context: inout GraphicsContext, points: [Horizontal], color: Color, width: CGFloat = 1,
                        dash: [CGFloat] = [], aboveHorizonOnly: Bool = false) {
        var path = Path()
        var previous: CGPoint?
        for sky in points {
            guard !aboveHorizonOnly || sky.altitude > -1, let point = projection.point(for: sky, limit: 85) else {
                previous = nil
                continue
            }
            // A jump across most of the view means the line went round behind the viewer.
            if let previous, hypot(point.x - previous.x, point.y - previous.y) < projection.radius {
                path.addLine(to: point)
            } else {
                path.move(to: point)
            }
            previous = point
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, dash: dash))
    }

    private func dot(_ context: inout GraphicsContext, at point: CGPoint, radius: Double, color: Color, label: String) {
        context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)), with: .color(color))
        context.draw(Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(color),
                     at: CGPoint(x: point.x + radius + 5, y: point.y), anchor: .leading)
    }

    private func color(of body: SkyTarget) -> Color {
        guard case .planet(let planet) = body.kind else { return .white }
        return switch planet {
        case .mercury: Color(white: 0.75)
        case .venus: Color(red: 1, green: 0.97, blue: 0.85)
        case .mars: Color(red: 1, green: 0.45, blue: 0.3)
        case .jupiter: Color(red: 0.95, green: 0.85, blue: 0.7)
        case .saturn: Color(red: 0.95, green: 0.82, blue: 0.5)
        case .uranus: Color(red: 0.6, green: 0.9, blue: 0.95)
        case .neptune: Color(red: 0.45, green: 0.6, blue: 1)
        }
    }

    /// The point `distance` degrees from `start` in direction `bearing` (degrees, from up through the right).
    private func offset(_ start: Horizontal, by distance: Double, bearing: Double) -> Horizontal {
        let rad = Double.pi / 180
        let alt0 = start.altitude * rad, d = distance * rad, b = bearing * rad
        let alt = asin(sin(alt0) * cos(d) + cos(alt0) * sin(d) * cos(b))
        let az = start.azimuth * rad + atan2(sin(b) * sin(d) * cos(alt0), cos(d) - sin(alt0) * sin(alt))
        return Horizontal(azimuth: Astronomy.normalize(az / rad), altitude: alt / rad)
    }
}

/// What's selected on the map, and Go to.
struct SkySelectionCard: View {
    @Environment(MonitorModel.self) private var model
    @Environment(LocationModel.self) private var location
    @Binding var view: SkyMapView
    @Binding var selection: SkySelection?

    var body: some View {
        if let selection, let target = selection.target, let observer = location.observer {
            Card(title: "Selected", systemImage: "scope") {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    details(selection, target: target, observer: observer, date: context.date)
                }
            }
        } else {
            Card(title: "Tonight", systemImage: "moon.stars") {
                TonightList(selection: $selection)
            }
        }
    }

    private func details(_ selection: SkySelection, target: SkyTarget, observer: Observer, date: Date) -> some View {
        let sky = target.horizontal(at: date, observer: observer)
        let equatorial = target.position(at: date)
        let sun = Astronomy.separation(sky, Astronomy.horizontal(Astronomy.sunPosition(at: date), at: date, observer: observer))
        let problem = model.goToProblem(target)
        return VStack(alignment: .leading, spacing: 8) {
            Text(target.name)
                .font(.system(size: 18, weight: .semibold))
            Text(subtitle(selection))
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            VStack(spacing: 6) {
                InfoRow(label: "Azimuth", value: "\(SkyFormat.degrees(sky.azimuth, decimals: 1)) \(SkyFormat.compassPoint(sky.azimuth))")
                InfoRow(label: "Altitude", value: SkyFormat.degrees(sky.altitude, decimals: 1),
                        color: sky.altitude < 0 ? Theme.warning : Theme.textPrimary)
                InfoRow(label: "RA / Dec", value: "\(SkyFormat.rightAscension(equatorial.raHours))  \(SkyFormat.declination(equatorial.decDegrees))")
                InfoRow(label: "From the Sun", value: String(format: "%.0f°", sun),
                        color: sun < SunSafety.keepOutDegrees ? Theme.danger : Theme.textPrimary)
            }
            HStack(spacing: 8) {
                Button("Go to", systemImage: "location.north.line") { model.requestGoTo(target) }
                    .disabled(problem != nil)
                Button("Centre") {
                    view.follow = false
                    view.center = sky
                }
                .help("Centre the map here")
                Spacer()
                Button("Clear") { self.selection = nil }
            }
            .controlSize(.small)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func subtitle(_ selection: SkySelection) -> String {
        switch selection {
        case .star(let hr):
            guard let star = SkyMapData.star(hr: hr)?.star else { return "" }
            let designation = star.name.isEmpty ? "" : "\(star.designation) · "
            return designation + String(format: "magnitude %.1f · HR %d", star.magnitude, star.hr)
        case .body(let body): return body.kind == .moon ? "Earth's moon" : "Planet"
        case .spot: return "A point on the sky"
        }
    }
}
