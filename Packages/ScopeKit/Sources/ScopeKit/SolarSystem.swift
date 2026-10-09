import Foundation

/// The planets the sky map shows.
public enum Planet: String, CaseIterable, Sendable {
    case mercury, venus, mars, jupiter, saturn, uranus, neptune

    public var name: String { rawValue.capitalized }
}

/// Positions of the Moon and planets from mean orbital elements with the main perturbations (Paul Schlyter, "How to
/// compute planetary positions"). Good to a few arcminutes, ample for a sky map and for Go to with a calibration
/// measured in tenths of a degree. Positions are geocentric, for the equinox of date.
public enum SolarSystem {
    /// Mean orbital elements: ascending node N, inclination i, argument of perihelion w (degrees), semi-major axis a,
    /// eccentricity e, mean anomaly M (degrees), each `value + rate × d`.
    private struct Elements {
        let n: (Double, Double), i: (Double, Double), w: (Double, Double)
        let a: (Double, Double), e: (Double, Double), m: (Double, Double)

        func at(_ d: Double) -> (n: Double, i: Double, w: Double, a: Double, e: Double, m: Double) {
            (n.0 + n.1 * d, i.0 + i.1 * d, w.0 + w.1 * d, a.0 + a.1 * d, e.0 + e.1 * d, Astronomy.normalize(m.0 + m.1 * d))
        }
    }

    private static let sun = Elements(n: (0, 0), i: (0, 0), w: (282.9404, 4.70935e-5), a: (1, 0), e: (0.016709, -1.151e-9), m: (356.0470, 0.9856002585))
    private static let moon = Elements(n: (125.1228, -0.0529538083), i: (5.1454, 0), w: (318.0634, 0.1643573223), a: (60.2666, 0),
                                       e: (0.054900, 0), m: (115.3654, 13.0649929509))

    private static func elements(_ planet: Planet) -> Elements {
        switch planet {
        case .mercury: Elements(n: (48.3313, 3.24587e-5), i: (7.0047, 5.00e-8), w: (29.1241, 1.01444e-5), a: (0.387098, 0),
                                e: (0.205635, 5.59e-10), m: (168.6562, 4.0923344368))
        case .venus: Elements(n: (76.6799, 2.46590e-5), i: (3.3946, 2.75e-8), w: (54.8910, 1.38374e-5), a: (0.723330, 0),
                              e: (0.006773, -1.302e-9), m: (48.0052, 1.6021302244))
        case .mars: Elements(n: (49.5574, 2.11081e-5), i: (1.8497, -1.78e-8), w: (286.5016, 2.92961e-5), a: (1.523688, 0),
                             e: (0.093405, 2.516e-9), m: (18.6021, 0.5240207766))
        case .jupiter: Elements(n: (100.4542, 2.76854e-5), i: (1.3030, -1.557e-7), w: (273.8777, 1.64505e-5), a: (5.20256, 0),
                                e: (0.048498, 4.469e-9), m: (19.8950, 0.0830853001))
        case .saturn: Elements(n: (113.6634, 2.38980e-5), i: (2.4886, -1.081e-7), w: (339.3939, 2.97661e-5), a: (9.55475, 0),
                               e: (0.055546, -9.499e-9), m: (316.9670, 0.0334442282))
        case .uranus: Elements(n: (74.0005, 1.3978e-5), i: (0.7733, 1.9e-8), w: (96.6612, 3.0565e-5), a: (19.18171, -1.55e-8),
                               e: (0.047318, 7.45e-9), m: (142.5905, 0.011725806))
        case .neptune: Elements(n: (131.7806, 3.0173e-5), i: (1.7700, -2.55e-7), w: (272.8461, -6.027e-6), a: (30.05826, 3.313e-8),
                                e: (0.008606, 2.15e-9), m: (260.2471, 0.005995147))
        }
    }

    /// Days since 2000 Jan 0.0 UT, the elements' epoch.
    private static func day(_ date: Date) -> Double { Astronomy.julianDate(date) - 2_451_543.5 }

    private static func sin(_ degrees: Double) -> Double { Foundation.sin(degrees * .pi / 180) }
    private static func cos(_ degrees: Double) -> Double { Foundation.cos(degrees * .pi / 180) }
    private static func atan2(_ y: Double, _ x: Double) -> Double { Foundation.atan2(y, x) * 180 / .pi }

    /// Position in the orbit's plane, then ecliptic rectangular coordinates (in the orbit's distance units).
    private static func ecliptic(_ el: (n: Double, i: Double, w: Double, a: Double, e: Double, m: Double)) -> (x: Double, y: Double, z: Double) {
        var eccentric = el.m + el.e * 180 / .pi * sin(el.m) * (1 + el.e * cos(el.m))
        for _ in 0 ..< 10 { // Kepler's equation; converges fast for these small eccentricities
            let next = eccentric - (eccentric - el.e * 180 / .pi * sin(eccentric) - el.m) / (1 - el.e * cos(eccentric))
            if abs(next - eccentric) < 1e-7 { eccentric = next; break }
            eccentric = next
        }
        let xv = el.a * (cos(eccentric) - el.e), yv = el.a * (1 - el.e * el.e).squareRoot() * sin(eccentric)
        let v = atan2(yv, xv), r = (xv * xv + yv * yv).squareRoot()
        return (r * (cos(el.n) * cos(v + el.w) - sin(el.n) * sin(v + el.w) * cos(el.i)),
                r * (sin(el.n) * cos(v + el.w) + cos(el.n) * sin(v + el.w) * cos(el.i)),
                r * sin(v + el.w) * sin(el.i))
    }

    private static func equatorial(_ x: Double, _ y: Double, _ z: Double, day d: Double) -> Equatorial {
        let obliquity = 23.4393 - 3.563e-7 * d
        let ye = y * cos(obliquity) - z * sin(obliquity), ze = y * sin(obliquity) + z * cos(obliquity)
        return Equatorial(raHours: Astronomy.normalize(atan2(ye, x)) / 15, decDegrees: atan2(ze, (x * x + ye * ye).squareRoot()))
    }

    /// Where `planet` appears from the Earth's centre.
    public static func position(of planet: Planet, at date: Date) -> Equatorial {
        let d = day(date)
        let p = ecliptic(elements(planet).at(d))
        var longitude = atan2(p.y, p.x), latitude = atan2(p.z, (p.x * p.x + p.y * p.y).squareRoot())
        let distance = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()

        // Jupiter, Saturn and Uranus pull on each other enough to matter.
        let mj = elements(.jupiter).at(d).m, ms = elements(.saturn).at(d).m, mu = elements(.uranus).at(d).m
        switch planet {
        case .jupiter:
            longitude += -0.332 * sin(2 * mj - 5 * ms - 67.6) - 0.056 * sin(2 * mj - 2 * ms + 21) + 0.042 * sin(3 * mj - 5 * ms + 21)
                - 0.036 * sin(mj - 2 * ms) + 0.022 * cos(mj - ms) + 0.023 * sin(2 * mj - 3 * ms + 52) - 0.016 * sin(mj - 5 * ms - 69)
        case .saturn:
            longitude += 0.812 * sin(2 * mj - 5 * ms - 67.6) - 0.229 * cos(2 * mj - 4 * ms - 2) + 0.119 * sin(mj - 2 * ms - 3)
                + 0.046 * sin(2 * mj - 6 * ms - 69) + 0.014 * sin(mj - 3 * ms + 32)
            latitude += -0.020 * cos(2 * mj - 4 * ms - 2) + 0.018 * sin(2 * mj - 6 * ms - 49)
        case .uranus:
            longitude += 0.040 * sin(ms - 2 * mu + 6) + 0.035 * sin(ms - 3 * mu + 33) - 0.015 * sin(mj - mu + 20)
        default:
            break
        }
        let xh = distance * cos(longitude) * cos(latitude), yh = distance * sin(longitude) * cos(latitude), zh = distance * sin(latitude)

        // The Sun's position from the Earth, added to move the origin from the Sun to the Earth.
        let s = sun.at(d)
        let earthToSun = ecliptic(s)
        return equatorial(xh + earthToSun.x, yh + earthToSun.y, zh, day: d)
    }

    /// Where the Moon appears from the Earth's centre, and its distance in Earth radii.
    public static func moonPosition(at date: Date) -> (position: Equatorial, earthRadii: Double) {
        let d = day(date)
        let el = moon.at(d)
        let p = ecliptic(el)
        var longitude = atan2(p.y, p.x), latitude = atan2(p.z, (p.x * p.x + p.y * p.y).squareRoot())
        var distance = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()

        let s = sun.at(d)
        let ms = s.m, mm = el.m
        let sunLongitude = s.n + s.w + s.m, moonLongitude = el.n + el.w + el.m
        let elongation = moonLongitude - sunLongitude, argument = moonLongitude - el.n
        longitude += -1.274 * sin(mm - 2 * elongation) + 0.658 * sin(2 * elongation) - 0.186 * sin(ms)
            - 0.059 * sin(2 * mm - 2 * elongation) - 0.057 * sin(mm - 2 * elongation + ms) + 0.053 * sin(mm + 2 * elongation)
            + 0.046 * sin(2 * elongation - ms) + 0.041 * sin(mm - ms) - 0.035 * sin(elongation) - 0.031 * sin(mm + ms)
            - 0.015 * sin(2 * argument - 2 * elongation) + 0.011 * sin(mm - 4 * elongation)
        latitude += -0.173 * sin(argument - 2 * elongation) - 0.055 * sin(mm - argument - 2 * elongation)
            - 0.046 * sin(mm + argument - 2 * elongation) + 0.033 * sin(argument + 2 * elongation) + 0.017 * sin(2 * mm + argument)
        distance += -0.58 * cos(mm - 2 * elongation) - 0.46 * cos(2 * elongation)

        let x = distance * cos(longitude) * cos(latitude), y = distance * sin(longitude) * cos(latitude), z = distance * sin(latitude)
        return (equatorial(x, y, z, day: d), distance)
    }

    /// The Moon's altitude is lowered by parallax: it's close enough that seen from the Earth's surface rather than
    /// its centre it sits up to about a degree lower.
    public static func moonHorizontal(at date: Date, observer: Observer) -> Horizontal {
        let (position, earthRadii) = moonPosition(at: date)
        var sky = Astronomy.horizontal(position, at: date, observer: observer)
        let parallax = asin(cos(sky.altitude) / earthRadii) * 180 / .pi
        sky.altitude -= parallax
        return sky
    }
}
