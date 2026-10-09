import CoreGraphics
import Foundation

/// A star from the bundled catalogue (see Resources/NOTICE.txt).
public struct CatalogStar: Identifiable, Sendable {
    /// Harvard Revised (Bright Star Catalogue) number.
    public let hr: Int
    public let j2000: Equatorial
    public let magnitude: Double
    /// Bayer or Flamsteed designation, e.g. "α Lyr" or "33 Psc"; empty if it has neither.
    public let designation: String
    /// IAU proper name, e.g. "Vega"; empty if it has none.
    public let name: String

    public var id: Int { hr }
    /// The best name to show: proper name, then designation, then the catalogue number.
    public var label: String { !name.isEmpty ? name : !designation.isEmpty ? designation : "HR \(hr)" }
    public var target: SkyTarget { SkyTarget(name: label, j2000: j2000) }
}

/// A constellation's stick figure and where to put its name (J2000).
public struct Constellation: Identifiable, Sendable {
    /// IAU abbreviation, e.g. "UMa".
    public let id: String
    public let name: String
    public let label: Equatorial
    public let lines: [[Equatorial]]
}

/// The sky map's bundled data, loaded once on first use.
public enum SkyCatalog {
    /// Stars to magnitude 6.5, brightest first.
    public static let stars: [CatalogStar] = loadStars()
    public static let constellations: [Constellation] = loadConstellations()

    private static func loadStars() -> [CatalogStar] {
        guard let url = Bundle.module.url(forResource: "stars", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 6, let hr = Int(fields[0]), let ra = Double(fields[1]), let dec = Double(fields[2]),
                  let magnitude = Double(fields[3]) else { return nil }
            return CatalogStar(hr: hr, j2000: Equatorial(raHours: ra, decDegrees: dec), magnitude: magnitude,
                               designation: String(fields[4]), name: String(fields[5]))
        }
        .sorted { $0.magnitude < $1.magnitude }
    }

    private struct ConstellationRecord: Decodable {
        let id: String
        let name: String
        let label: [Double]
        let lines: [[[Double]]]
    }

    private static func loadConstellations() -> [Constellation] {
        guard let url = Bundle.module.url(forResource: "constellations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([ConstellationRecord].self, from: data) else { return [] }
        func point(_ pair: [Double]) -> Equatorial { Equatorial(raHours: pair[0], decDegrees: pair[1]) }
        return records.map { record in
            Constellation(id: record.id, name: record.name, label: point(record.label),
                          lines: record.lines.map { $0.filter { $0.count == 2 }.map(point) })
        }
    }
}

extension Astronomy {
    /// The equatorial position (of date) that appears at `horizontal` in the observer's sky: the inverse of
    /// `horizontal(_:at:observer:)`.
    public static func equatorial(from horizontal: Horizontal, at date: Date, observer: Observer) -> Equatorial {
        let azimuth = radians(horizontal.azimuth), altitude = radians(horizontal.altitude), lat = radians(observer.latitude)
        let sinDec = sin(altitude) * sin(lat) + cos(altitude) * cos(lat) * cos(azimuth)
        let y = -cos(altitude) * sin(azimuth)
        let x = sin(altitude) * cos(lat) - cos(altitude) * sin(lat) * cos(azimuth)
        let hourAngle = degrees(atan2(y, x))
        let ra = normalize(localSiderealHours(at: date, longitude: observer.longitude) * 15 - hourAngle)
        return Equatorial(raHours: ra / 15, decDegrees: degrees(asin(min(1, max(-1, sinDec)))))
    }
}

/// A stereographic view of the sky around `center`, as seen looking out along it: azimuth increases to the right,
/// altitude upwards. Stereographic keeps shapes (constellations look right) and maps circles on the sky to circles.
public struct SkyProjection: Sendable {
    public var center: Horizontal
    /// Degrees from the centre to `radius` points away.
    public var fieldRadius: Double
    /// The view's centre and the distance (points) that `fieldRadius` maps to.
    public var origin: CGPoint
    public var radius: Double

    public init(center: Horizontal, fieldRadius: Double, origin: CGPoint, radius: Double) {
        self.center = center
        self.fieldRadius = fieldRadius
        self.origin = origin
        self.radius = radius
    }

    private var scale: Double { radius / (2 * tan(fieldRadius * .pi / 360)) }

    /// Where `sky` appears, or nil if it is more than `limit` degrees from the centre.
    public func point(for sky: Horizontal, limit: Double = 100) -> CGPoint? {
        let phi = sky.altitude * .pi / 180, phi0 = center.altitude * .pi / 180
        let dLambda = (sky.azimuth - center.azimuth) * .pi / 180
        let cosDistance = sin(phi0) * sin(phi) + cos(phi0) * cos(phi) * cos(dLambda)
        guard cosDistance > cos(limit * .pi / 180) else { return nil }
        let k = 2 / (1 + cosDistance)
        let x = k * cos(phi) * sin(dLambda)
        let y = k * (cos(phi0) * sin(phi) - sin(phi0) * cos(phi) * cos(dLambda))
        return CGPoint(x: origin.x + scale * x, y: origin.y - scale * y)
    }

    /// The sky position at `point`.
    public func sky(at point: CGPoint) -> Horizontal {
        let x = (point.x - origin.x) / scale, y = (origin.y - point.y) / scale
        let rho = (x * x + y * y).squareRoot()
        guard rho > 1e-12 else { return center }
        let c = 2 * atan(rho / 2)
        let phi0 = center.altitude * .pi / 180
        let phi = asin(cos(c) * sin(phi0) + y * sin(c) * cos(phi0) / rho)
        let lambda = atan2(x * sin(c), rho * cos(phi0) * cos(c) - y * sin(phi0) * sin(c))
        return Horizontal(azimuth: Astronomy.normalize(center.azimuth + lambda * 180 / .pi), altitude: phi * 180 / .pi)
    }
}
