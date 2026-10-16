import Foundation

/// How each axis of a calibration was set (Calibrate › level, true north, Polaris), so the home position can say what
/// it rests on.
struct CalibrationBasis: Equatable {
    enum Source: String, Equatable {
        /// Never set: the motors count from power-on, which assumes the scope was switched on level and pointing north.
        case switchedOn
        case trueNorth
        case level
        case polaris
        /// A home position saved before scopeOS kept track of how it was calibrated.
        case unrecorded

        var label: String {
            switch self {
            case .switchedOn: "the switch-on position"
            case .trueNorth: "true north"
            case .level: "a level tube"
            case .polaris: "Polaris"
            case .unrecorded: "not recorded"
            }
        }
    }

    var azimuth: Source
    var altitude: Source

    /// Nothing calibrated yet.
    static let switchedOn = CalibrationBasis(azimuth: .switchedOn, altitude: .switchedOn)
    static let unrecorded = CalibrationBasis(azimuth: .unrecorded, altitude: .unrecorded)

    /// "azimuth from true north, altitude from a level tube", or "both axes from Polaris".
    var summary: String {
        switch (azimuth, altitude) {
        case (.unrecorded, .unrecorded): "how it was calibrated wasn't recorded (saved before scopeOS kept track)"
        case (.polaris, .polaris): "both axes from Polaris"
        default: "azimuth from \(azimuth.label), altitude from \(altitude.label)"
        }
    }

    /// This basis with the axes just calibrated replaced by `source`.
    func setting(azimuth setAzimuth: Bool, altitude setAltitude: Bool, from source: Source) -> CalibrationBasis {
        CalibrationBasis(azimuth: setAzimuth ? source : azimuth, altitude: setAltitude ? source : altitude)
    }
}
