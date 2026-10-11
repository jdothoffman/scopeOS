/// The fast move Go to and Return to home use for the long part of a leg: a fast GoTo of one motor, at the mount's
/// normal slewing speed, to an end point worked out and checked beforehand. The motor stops there by itself, so a
/// dropped connection can't leave it turning, and the whole way is checked against the Sun before it is sent
/// (`MotionPolicy`). Like `NudgeCommand`, it is checked immediately before it is written, against the motor position
/// read just beforehand, and only goes out with both motors at rest.
///
/// What the mount taught us (NEXT_STEPS, 2026-10-09): the fast GoTo follows the raw position count rather than the
/// short way round, so it must never be asked to cross the motor's zero; a target isn't re-sent while it's moving
/// fast; and the final approach is a separate slow GoTo from rest (`NudgeCommand`).
public enum SlewCommand {
    /// AUX MC_GOTO_FAST: move to a 24-bit position at full speed, then stop.
    public static let auxCommand: UInt8 = 0x02
    /// Legs shorter than this go in slow steps only.
    public static let minimumDegrees = 3.0
    /// A slew stops this far short of the target, so the last of the way is a slow GoTo from rest.
    public static let shortOfTarget = 0.5
    /// Both ends of a slew stay this far from the motor's zero; the slow steps cross it.
    public static let zeroMargin = 1.0

    /// The longest single slew: half a turn of azimuth, and more than the altitude band.
    public static func maxDegrees(_ axis: NudgeAxis) -> Double { axis == .azimuth ? 180 : 90 }

    static let countsPerTurn = NudgeCommand.countsPerTurn

    /// The slew for a move of `degrees` from raw motor angle `raw` (0°–360°, as the motor counts): cut short to stay
    /// clear of the motor's zero, or nil when the motor is too close to its zero, or what's left is too short to be
    /// worth slewing.
    public static func plan(_ axis: NudgeAxis, degrees: Double, fromRaw raw: Double) -> Double? {
        guard degrees.isFinite, raw >= zeroMargin, raw <= 360 - zeroMargin else { return nil }
        var move = max(-maxDegrees(axis), min(maxDegrees(axis), degrees))
        if raw + move > 360 - zeroMargin { move = 360 - zeroMargin - raw }
        if raw + move < zeroMargin { move = zeroMargin - raw }
        return abs(move) >= minimumDegrees ? move : nil
    }

    /// The packet that slews `axis` by `degrees` from `current` (a 24-bit fraction of a turn), counting straight
    /// up or down from it, never round through zero.
    public static func packet(_ axis: NudgeAxis, from current: UInt32, by degrees: Double) -> [UInt8] {
        let target = min(countsPerTurn - 1, max(0, Int(current) + Int((degrees / 360 * Double(countsPerTurn)).rounded())))
        let data = [UInt8(target >> 16 & 0xFF), UInt8(target >> 8 & 0xFF), UInt8(target & 0xFF)]
        return AuxPacket(source: AuxDevice.app.rawValue, destination: axis.motor.rawValue, command: auxCommand, data: data).encoded()
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
        func degrees(_ counts: Int) -> Double { Double(counts) / Double(countsPerTurn) * 360 }
        // Never across the motor's zero: both ends clear of it (with a hair of slack for rounding).
        let clear = (zeroMargin - 0.001) ... (360 - zeroMargin + 0.001)
        guard clear.contains(degrees(Int(current))), clear.contains(degrees(target)) else {
            throw MountError.blockedCommand("\(Hex.string(payload)) slews from \(degrees(Int(current)))° to \(degrees(target))°, too near the motor's zero")
        }
        let distance = abs(degrees(target - Int(current)))
        guard distance <= maxDegrees(axis) + 0.001 else {
            throw MountError.blockedCommand("\(Hex.string(payload)) slews \(distance)°, more than \(maxDegrees(axis))°")
        }
        if axis == .altitude {
            let from = Angles.signed(degrees(Int(current))) - altitudeOffset
            let to = Angles.signed(degrees(target)) - altitudeOffset
            guard NudgeCommand.altitudeMoveAllowed(from: from, to: to) else {
                throw MountError.blockedCommand("\(Hex.string(payload)) slews altitude \(from)° to \(to)°, outside \(NudgeCommand.altitudeLimits)")
            }
        }
    }
}
