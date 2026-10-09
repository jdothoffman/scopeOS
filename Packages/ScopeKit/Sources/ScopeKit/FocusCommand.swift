/// The only command scopeOS sends that moves the focus motor: a GoTo to an absolute position. The target must lie
/// inside the motor's calibrated range and within `maxStepFraction` of that range from where the motor is now, so
/// it can never be driven into its end stops, and a dropped connection leaves it stopping at the target on its own.
/// Checked immediately before it is written, against the position read just beforehand.
public enum FocusCommand {
    /// AUX MC_GOTO_FAST: move to a 24-bit position, then stop.
    public static let gotoCommand: UInt8 = 0x02
    /// Largest single move, as a share of the calibrated range.
    public static let maxStepFraction = 0.2
    /// How far a press-and-hold heads before stopping by itself, as a share of the calibrated range.
    public static let holdReachFraction = 0.1

    public static func maxStep(_ limits: ClosedRange<Int>) -> Int {
        max(1, Int(Double(limits.upperBound - limits.lowerBound) * maxStepFraction))
    }

    public static func holdReach(_ limits: ClosedRange<Int>) -> Int {
        max(1, Int(Double(limits.upperBound - limits.lowerBound) * holdReachFraction))
    }

    public static func packet(to target: Int) -> [UInt8] {
        let data = [UInt8(target >> 16 & 0xFF), UInt8(target >> 8 & 0xFF), UInt8(target & 0xFF)]
        return AuxPacket(source: AuxDevice.app.rawValue, destination: AuxDevice.focuser.rawValue, command: gotoCommand, data: data).encoded()
    }

    public static func check(_ payload: [UInt8], current: Int, limits: ClosedRange<Int>) throws {
        guard payload.count == 9, let packet = AuxPacket.decodeSingle(payload),
              packet.source == AuxDevice.app.rawValue, packet.destination == AuxDevice.focuser.rawValue,
              packet.command == gotoCommand, packet.data.count == 3,
              limits.lowerBound >= 0, limits.upperBound < 1 << 24, limits.upperBound > limits.lowerBound
        else {
            throw MountError.blockedCommand(Hex.string(payload))
        }
        let target = Int(packet.data[0]) << 16 | Int(packet.data[1]) << 8 | Int(packet.data[2])
        guard limits.contains(target) else {
            throw MountError.blockedCommand("\(Hex.string(payload)) targets focus position \(target), outside \(limits)")
        }
        guard abs(target - current) <= maxStep(limits) else {
            throw MountError.blockedCommand("\(Hex.string(payload)) moves the focuser \(abs(target - current)) steps, more than \(maxStep(limits))")
        }
    }

    /// Parses the focus motor's calibrated limits (FOC_GET_HS_POSITIONS: low then high, 32-bit big-endian).
    /// Returns nil unless they describe a sensible range, i.e. the motor has been calibrated.
    public static func limits(fromReply data: [UInt8]) -> ClosedRange<Int>? {
        guard data.count >= 8 else { return nil }
        let value = { (offset: Int) in data[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) } }
        let low = value(0), high = value(4)
        guard low >= 0, high < 1 << 24, high - low >= 100 else { return nil }
        return low ... high
    }
}
