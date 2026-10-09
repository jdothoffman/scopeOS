import Foundation

public enum MountProtocol: String, Sendable {
    case handController = "Hand controller (NexStar)"
    case aux = "AUX bus (WiFi module)"
}

public enum TrackingMode: UInt8, Sendable {
    case off = 0
    case altAz = 1
    case equatorialNorth = 2
    case equatorialSouth = 3

    public var label: String {
        switch self {
        case .off: "Off"
        case .altAz: "Alt-Az"
        case .equatorialNorth: "EQ North"
        case .equatorialSouth: "EQ South"
        }
    }
}

public struct Equatorial: Equatable, Sendable {
    public var raHours: Double
    public var decDegrees: Double

    public init(raHours: Double, decDegrees: Double) {
        self.raHours = raHours
        self.decDegrees = decDegrees
    }
}

public struct Horizontal: Equatable, Sendable {
    public var azimuth: Double
    public var altitude: Double

    public init(azimuth: Double, altitude: Double) {
        self.azimuth = azimuth
        self.altitude = altitude
    }
}

public struct DeviceInfo: Equatable, Sendable {
    public var name: String
    public var version: String
}

public struct MountStatus: Equatable, Sendable {
    public var protocolKind: MountProtocol
    public var model: String?
    public var devices: [DeviceInfo] = []
    public var aligned: Bool?
    public var slewing: Bool?
    public var tracking: TrackingMode?
    public var equatorial: Equatorial?
    /// For the hand controller these are true sky azimuth/altitude. Over the AUX bus they are the
    /// motor axis angles, which match the sky only as well as the mount's alignment set them.
    public var horizontal: Horizontal?
    /// Over the AUX bus: the raw motor angles `horizontal` was calculated from, and the calibration applied
    /// (nil means none: the readings assume the scope was switched on level and pointing north).
    public var axisAngles: Horizontal?
    public var calibration: AxisCalibration?
    public var focuserPosition: Int?
    /// The focus motor's calibrated range; nil if it hasn't been calibrated (focus moves are then refused).
    public var focuserLimits: ClosedRange<Int>?
    public var focuserMoving: Bool?
    public var updated: Date

    public init(protocolKind: MountProtocol, updated: Date = .now) {
        self.protocolKind = protocolKind
        self.updated = updated
    }
}

enum NexStarModels {
    static func name(for code: UInt8) -> String {
        switch code {
        case 1: "GPS Series"
        case 3: "i-Series"
        case 4: "i-Series SE"
        case 5: "CGE"
        case 6: "Advanced GT"
        case 7: "SLT"
        case 9: "CPC"
        case 10: "GT"
        case 11: "4/5 SE"
        case 12: "6/8 SE"
        case 13: "CGE Pro"
        case 14: "CGEM DX"
        case 15: "LCM"
        case 16: "Sky Prodigy"
        case 17: "CPC Deluxe"
        case 18: "GT 16"
        case 19: "StarSeeker"
        case 20: "AVX"
        case 21: "Cosmos"
        case 22: "Evolution"
        case 23: "CGX"
        case 24: "CGXL"
        case 25: "Astro Fi"
        case 26: "SkyWatcher"
        default: "Unknown (code \(code))"
        }
    }
}
