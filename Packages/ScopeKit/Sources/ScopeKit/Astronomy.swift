import Foundation

public enum Astronomy {
    /// Low-precision solar position (Astronomical Almanac), good to about 0.01° — plenty for a safety margin.
    public static func sunPosition(at date: Date) -> Equatorial {
        let n = julianDate(date) - 2_451_545.0
        let meanLongitude = normalize(280.460 + 0.985_647_4 * n)
        let meanAnomaly = radians(normalize(357.528 + 0.985_600_3 * n))
        let eclipticLongitude = radians(meanLongitude + 1.915 * sin(meanAnomaly) + 0.020 * sin(2 * meanAnomaly))
        let obliquity = radians(23.439 - 0.000_000_4 * n)

        let ra = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude))
        let dec = asin(sin(obliquity) * sin(eclipticLongitude))
        return Equatorial(raHours: normalize(degrees(ra)) / 15, decDegrees: degrees(dec))
    }

    /// Local sidereal time in hours (0–24) for an east-positive `longitude` in degrees.
    public static func localSiderealHours(at date: Date, longitude: Double) -> Double {
        let d = julianDate(date) - 2_451_545.0
        let gmst = 280.460_618_37 + 360.985_647_366_29 * d
        return normalize(gmst + longitude) / 15
    }

    /// Where an equatorial position appears in the observer's sky. Azimuth runs from north through east.
    public static func horizontal(_ position: Equatorial, at date: Date, observer: Observer) -> Horizontal {
        let hourAngle = radians(localSiderealHours(at: date, longitude: observer.longitude) * 15 - position.raHours * 15)
        let dec = radians(position.decDegrees), lat = radians(observer.latitude)
        let sinAltitude = sin(dec) * sin(lat) + cos(dec) * cos(lat) * cos(hourAngle)
        let y = -cos(dec) * sin(hourAngle)
        let x = sin(dec) * cos(lat) - cos(dec) * sin(lat) * cos(hourAngle)
        return Horizontal(azimuth: normalize(degrees(atan2(y, x))), altitude: degrees(asin(min(1, max(-1, sinAltitude)))))
    }

    /// Great-circle angle between two horizontal positions, in degrees.
    public static func separation(_ a: Horizontal, _ b: Horizontal) -> Double {
        separation(Equatorial(raHours: a.azimuth / 15, decDegrees: a.altitude), Equatorial(raHours: b.azimuth / 15, decDegrees: b.altitude))
    }

    /// Great-circle angle between two sky positions, in degrees.
    public static func separation(_ a: Equatorial, _ b: Equatorial) -> Double {
        let ra1 = radians(a.raHours * 15), ra2 = radians(b.raHours * 15)
        let dec1 = radians(a.decDegrees), dec2 = radians(b.decDegrees)
        let cosine = sin(dec1) * sin(dec2) + cos(dec1) * cos(dec2) * cos(ra1 - ra2)
        return degrees(acos(min(1, max(-1, cosine))))
    }

    public static func julianDate(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    }

    public static func normalize(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}

/// A place on Earth. Longitude is positive east of Greenwich.
public struct Observer: Equatable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool { (-90 ... 90).contains(latitude) && (-180 ... 180).contains(longitude) }
}

/// How dark the sky is, from the Sun's altitude (standard twilight boundaries).
public enum SkyDarkness: Sendable, Equatable {
    case day, civilTwilight, nauticalTwilight, astronomicalTwilight, night

    public init(sunAltitude: Double) {
        if sunAltitude >= -0.833 { // upper limb on the horizon, allowing for refraction
            self = .day
        } else if sunAltitude >= -6 {
            self = .civilTwilight
        } else if sunAltitude >= -12 {
            self = .nauticalTwilight
        } else if sunAltitude >= -18 {
            self = .astronomicalTwilight
        } else {
            self = .night
        }
    }

    public var label: String {
        switch self {
        case .day: "Daylight"
        case .civilTwilight: "Civil twilight"
        case .nauticalTwilight: "Nautical twilight"
        case .astronomicalTwilight: "Astronomical twilight"
        case .night: "Dark sky"
        }
    }
}

public enum SkyFormat {
    public static func latitude(_ value: Double) -> String {
        String(format: "%.4f° %@", abs(value), value < 0 ? "S" : "N")
    }

    public static func longitude(_ value: Double) -> String {
        String(format: "%.4f° %@", abs(value), value < 0 ? "W" : "E")
    }

    public static func hoursMinutesSeconds(_ hours: Double) -> String {
        let (h, m, s) = sexagesimal(hours, secondsDecimals: 0)
        return String(format: "%02d:%02d:%02.0f", h % 24, m, s)
    }

    public static func rightAscension(_ hours: Double) -> String {
        let (h, m, s) = sexagesimal(hours, secondsDecimals: 1)
        return String(format: "%02dh %02dm %04.1fs", h % 24, m, s)
    }

    public static func declination(_ degrees: Double) -> String {
        let sign = degrees < 0 ? "−" : "+"
        let (d, m, s) = sexagesimal(abs(degrees), secondsDecimals: 0)
        return String(format: "%@%02d° %02d′ %02.0f″", sign, d, m, s)
    }

    public static func degrees(_ value: Double, decimals: Int = 2) -> String {
        String(format: "%.\(decimals)f°", value)
    }

    public static func compassPoint(_ azimuth: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((Astronomy.normalize(azimuth) / 22.5).rounded()) % points.count
        return points[index]
    }

    /// Splits a value into whole units, minutes and seconds, carrying rounding so we never print "60s".
    static func sexagesimal(_ value: Double, secondsDecimals: Int) -> (Int, Int, Double) {
        let scale = pow(10, Double(secondsDecimals))
        let totalSeconds = (value * 3600 * scale).rounded() / scale
        let whole = Int(totalSeconds / 3600)
        let minutes = Int((totalSeconds - Double(whole) * 3600) / 60)
        let seconds = totalSeconds - Double(whole) * 3600 - Double(minutes) * 60
        return (whole, minutes, max(0, seconds))
    }
}
