import Foundation

/// Something scopeOS can point at: a star (J2000 position, brought up to date), the Moon or a planet.
public struct SkyTarget: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case star(j2000: Equatorial)
        case moon
        case planet(Planet)
        /// A fixed point on the sky, already for the equinox of date (e.g. one picked on the sky map).
        case point(Equatorial)
    }

    public let name: String
    public let kind: Kind

    public var id: String { name }

    /// A star's catalogue position; nil for the Moon and planets, which move.
    public var j2000: Equatorial? {
        if case .star(let position) = kind { position } else { nil }
    }

    public init(name: String, j2000: Equatorial) {
        self.name = name
        kind = .star(j2000: j2000)
    }

    private init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    public static let moon = SkyTarget(name: "Moon", kind: .moon)
    public static func point(_ position: Equatorial, name: String = "Selected spot") -> SkyTarget {
        SkyTarget(name: name, kind: .point(position))
    }
    public static func planet(_ planet: Planet) -> SkyTarget { SkyTarget(name: planet.name, kind: .planet(planet)) }

    /// RA in hours, minutes, seconds; Dec in degrees, arcminutes, arcseconds (negative degrees for the south).
    init(_ name: String, ra: (Double, Double, Double), dec: (Double, Double, Double)) {
        let sign: Double = dec.0 < 0 ? -1 : 1
        self.init(name: name, j2000: Equatorial(raHours: ra.0 + ra.1 / 60 + ra.2 / 3600,
                                                decDegrees: sign * (abs(dec.0) + dec.1 / 60 + dec.2 / 3600)))
    }

    /// Where it is on `date`, seen from the Earth's centre. Stars are precessed from J2000; their proper motion is
    /// ignored, a few hundredths of a degree at most for bright stars, well inside what a calibration can achieve.
    public func position(at date: Date) -> Equatorial {
        switch kind {
        case .star(let j2000): Astronomy.precess(j2000, to: date)
        case .moon: SolarSystem.moonPosition(at: date).position
        case .planet(let planet): SolarSystem.position(of: planet, at: date)
        case .point(let position): position
        }
    }

    /// Where it appears in the observer's sky (for the Moon, allowing for its parallax).
    public func horizontal(at date: Date, observer: Observer) -> Horizontal {
        if kind == .moon { return SolarSystem.moonHorizontal(at: date, observer: observer) }
        return Astronomy.horizontal(position(at: date), at: date, observer: observer)
    }

    public static let polaris = SkyTarget("Polaris", ra: (2, 31, 49.09), dec: (89, 15, 50.8))

    /// Polaris, then the brightest stars seen from mid-northern latitudes, brightest first.
    public static let brightStars: [SkyTarget] = [
        polaris,
        SkyTarget("Sirius", ra: (6, 45, 8.92), dec: (-16, 42, 58.0)),
        SkyTarget("Arcturus", ra: (14, 15, 39.67), dec: (19, 10, 56.7)),
        SkyTarget("Vega", ra: (18, 36, 56.34), dec: (38, 47, 1.3)),
        SkyTarget("Capella", ra: (5, 16, 41.36), dec: (45, 59, 52.8)),
        SkyTarget("Rigel", ra: (5, 14, 32.27), dec: (-8, 12, 5.9)),
        SkyTarget("Procyon", ra: (7, 39, 18.12), dec: (5, 13, 30.0)),
        SkyTarget("Betelgeuse", ra: (5, 55, 10.31), dec: (7, 24, 25.4)),
        SkyTarget("Altair", ra: (19, 50, 47.0), dec: (8, 52, 6.0)),
        SkyTarget("Aldebaran", ra: (4, 35, 55.24), dec: (16, 30, 33.5)),
        SkyTarget("Spica", ra: (13, 25, 11.58), dec: (-11, 9, 40.8)),
        SkyTarget("Antares", ra: (16, 29, 24.46), dec: (-26, 25, 55.2)),
        SkyTarget("Pollux", ra: (7, 45, 18.95), dec: (28, 1, 34.3)),
        SkyTarget("Fomalhaut", ra: (22, 57, 39.05), dec: (-29, 37, 20.1)),
        SkyTarget("Deneb", ra: (20, 41, 25.9), dec: (45, 16, 49.0)),
        SkyTarget("Regulus", ra: (10, 8, 22.31), dec: (11, 58, 2.0)),
    ]
}

extension Astronomy {
    /// Precesses J2000 coordinates to `date` (IAU 1976 angles, Meeus, *Astronomical Algorithms*, ch. 21).
    /// Nutation and aberration are left out: together under about 0.01°.
    public static func precess(_ j2000: Equatorial, to date: Date) -> Equatorial {
        let t = (julianDate(date) - 2_451_545.0) / 36_525
        func arcseconds(_ value: Double) -> Double { radians(value / 3600) }
        let zeta = arcseconds(2306.2181 * t + 0.30188 * t * t + 0.017998 * t * t * t)
        let z = arcseconds(2306.2181 * t + 1.09468 * t * t + 0.018203 * t * t * t)
        let theta = arcseconds(2004.3109 * t - 0.42665 * t * t - 0.041833 * t * t * t)

        let ra0 = radians(j2000.raHours * 15), dec0 = radians(j2000.decDegrees)
        let a = cos(dec0) * sin(ra0 + zeta)
        let b = cos(theta) * cos(dec0) * cos(ra0 + zeta) - sin(theta) * sin(dec0)
        let c = sin(theta) * cos(dec0) * cos(ra0 + zeta) + cos(theta) * sin(dec0)
        // atan2 rather than asin keeps the declination exact near the pole (Polaris).
        return Equatorial(raHours: normalize(degrees(atan2(a, b) + z)) / 15, decDegrees: degrees(atan2(c, (a * a + b * b).squareRoot())))
    }
}
