/// The only commands scopeOS sends that act on the mount. Each one stops motion; none can start it.
/// Like `ReadOnlyGuard`, every stop is checked against this exact list immediately before it is written.
public enum StopCommand {
    /// NexStar "Cancel GOTO", answered with "#".
    public static let handController: [UInt8] = [UInt8(ascii: "M")]

    /// AUX MC_MOVE_POS: move at a fixed rate. Sent only with rate 0, which stops the motor.
    public static let auxCommand: UInt8 = 0x24

    /// One rate-0 packet per motor. Each motor acknowledges with an empty reply.
    public static let aux: [(device: AuxDevice, bytes: [UInt8])] = [AuxDevice.azimuthMotor, .altitudeMotor].map {
        ($0, AuxPacket(source: AuxDevice.app.rawValue, destination: $0.rawValue, command: auxCommand, data: [0]).encoded())
    }

    /// Rate 0 to the focus motor only, so stopping a focus move leaves the mount's tracking alone.
    public static let focuser: [UInt8] =
        AuxPacket(source: AuxDevice.app.rawValue, destination: AuxDevice.focuser.rawValue, command: auxCommand, data: [0]).encoded()

    public static func check(_ payload: [UInt8]) throws {
        guard payload == handController || payload == focuser || aux.contains(where: { $0.bytes == payload }) else {
            throw MountError.blockedCommand(Hex.string(payload))
        }
    }
}
