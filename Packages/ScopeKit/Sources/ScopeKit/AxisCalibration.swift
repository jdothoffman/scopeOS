/// Turns the WiFi module's motor angles into real sky directions. The motors only count from wherever they were
/// at power-on (level and pointing north gives true angles); calibration records how far off that start was.
/// Sky angle = motor angle − offset.
public struct AxisCalibration: Equatable, Sendable {
    public var azimuthOffset: Double
    public var altitudeOffset: Double

    public init(azimuthOffset: Double = 0, altitudeOffset: Double = 0) {
        self.azimuthOffset = azimuthOffset
        self.altitudeOffset = altitudeOffset
    }

    public func sky(fromMotor motor: Horizontal) -> Horizontal {
        Horizontal(azimuth: Astronomy.normalize(motor.azimuth - azimuthOffset), altitude: motor.altitude - altitudeOffset)
    }

    /// Offsets that make the current motor angles read as `sky`, keeping this calibration for any axis left nil.
    public func pointing(motor: Horizontal, azimuth: Double?, altitude: Double?) -> AxisCalibration {
        var result = self
        if let azimuth {
            var offset = Astronomy.normalize(motor.azimuth - azimuth)
            if offset > 180 { offset -= 360 }
            result.azimuthOffset = offset
        }
        if let altitude { result.altitudeOffset = motor.altitude - altitude }
        return result
    }
}
