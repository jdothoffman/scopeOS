public enum NudgeAxis: String, Sendable, CaseIterable {
    case azimuth, altitude

    public var motor: AuxDevice {
        switch self {
        case .azimuth: .azimuthMotor
        case .altitude: .altitudeMotor
        }
    }

    /// Largest single nudge. Altitude is kept smaller: moving it is how a tube or camera gets driven into the base.
    public var maxStepDegrees: Double {
        switch self {
        case .azimuth: 5
        case .altitude: 1.5
        }
    }
}

/// The only command scopeOS sends that moves the mount: a slow GoTo of one motor to a target at most
/// `axis.maxStepDegrees` from where the motor is now. The motor stops by itself at the target, so a dropped
/// connection can't leave it turning. Like `StopCommand`, it is checked immediately before it is written, here
/// against the motor position read just beforehand.
public enum NudgeCommand {
    /// AUX MC_GOTO_SLOW: move to a 24-bit position at slow speed, then stop.
    public static let auxCommand: UInt8 = 0x17

    /// Altitude nudges must land inside this band (motor angle, degrees): above the horizon, and short of the
    /// zenith, where accessories on the back of the tube can hit the base.
    public static let altitudeLimits = 0.0 ... 75.0

    static let countsPerTurn = 1 << 24

    /// The packet that moves `axis` by `degrees` from `current` (a 24-bit fraction of a turn).
    public static func packet(_ axis: NudgeAxis, from current: UInt32, by degrees: Double) -> [UInt8] {
        let steps = Int((degrees / 360 * Double(countsPerTurn)).rounded())
        let target = ((Int(current) + steps) % countsPerTurn + countsPerTurn) % countsPerTurn
        let data = [UInt8(target >> 16 & 0xFF), UInt8(target >> 8 & 0xFF), UInt8(target & 0xFF)]
        return AuxPacket(source: AuxDevice.app.rawValue, destination: axis.motor.rawValue, command: auxCommand, data: data).encoded()
    }

    /// Whether an altitude move from `from` to `to` (sky degrees) keeps to `altitudeLimits`: it ends inside the band,
    /// or it starts outside and heads back toward it (never further out, never past the far side). Without the second
    /// part a scope that ended up outside the band, however it got there, could not be moved back.
    public static func altitudeMoveAllowed(from: Double, to: Double) -> Bool {
        if altitudeLimits.contains(to) { return true }
        if from < altitudeLimits.lowerBound { return to > from && to <= altitudeLimits.upperBound }
        if from > altitudeLimits.upperBound { return to < from && to >= altitudeLimits.lowerBound }
        return false
    }

    /// `altitudeOffset` is the calibration offset: the altitude band applies to the real sky altitude.
    public static func check(_ payload: [UInt8], axis: NudgeAxis, currentPosition current: UInt32, altitudeOffset: Double = 0) throws {
        guard payload.count == 9, let packet = AuxPacket.decodeSingle(payload), abs(altitudeOffset) <= 180,
              packet.source == AuxDevice.app.rawValue, packet.destination == axis.motor.rawValue,
              packet.command == auxCommand, packet.data.count == 3, Int(current) < countsPerTurn
        else {
            throw MountError.blockedCommand(Hex.string(payload))
        }
        let target = Int(packet.data[0]) << 16 | Int(packet.data[1]) << 8 | Int(packet.data[2])
        // Shortest way round, so a step across 0°/360° counts as small.
        var delta = (target - Int(current)) % countsPerTurn
        if delta > countsPerTurn / 2 { delta -= countsPerTurn }
        if delta < -countsPerTurn / 2 { delta += countsPerTurn }
        let degrees = Double(abs(delta)) / Double(countsPerTurn) * 360
        // Half a count of slack for rounding in `packet`.
        guard degrees <= axis.maxStepDegrees + 0.5 * 360 / Double(countsPerTurn) else {
            throw MountError.blockedCommand("\(Hex.string(payload)) moves \(degrees)°, more than \(axis.maxStepDegrees)°")
        }
        if axis == .altitude {
            let currentAltitude = Angles.signed(Angles.degrees(fraction: current, bits: 24)) - altitudeOffset
            let targetAltitude = Angles.signed(Angles.degrees(fraction: UInt32(target), bits: 24)) - altitudeOffset
            guard altitudeMoveAllowed(from: currentAltitude, to: targetAltitude) else {
                throw MountError.blockedCommand("\(Hex.string(payload)) moves altitude \(currentAltitude)° to \(targetAltitude)°, outside \(altitudeLimits)")
            }
        }
    }
}
