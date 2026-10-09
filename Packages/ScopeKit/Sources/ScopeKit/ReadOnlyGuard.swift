/// Hand-controller (NexStar serial protocol) queries. Only read-only commands exist in this enum,
/// so there is no way to construct a motion or "set" command through it.
public enum HandControllerCommand: Character, CaseIterable, Sendable {
    case version = "V"
    case model = "m"
    case alignmentComplete = "J"
    case gotoInProgress = "L"
    case trackingMode = "t"
    case preciseRaDec = "e"
    case preciseAzAlt = "z"

    public var byte: UInt8 { rawValue.asciiValue! }

    /// Total reply length including the trailing "#".
    public var replyLength: Int {
        switch self {
        case .version: 3
        case .model, .alignmentComplete, .gotoInProgress, .trackingMode: 2
        case .preciseRaDec, .preciseAzAlt: 18
        }
    }

    public var label: String {
        switch self {
        case .version: "version"
        case .model: "model"
        case .alignmentComplete: "alignment"
        case .gotoInProgress: "goto status"
        case .trackingMode: "tracking mode"
        case .preciseRaDec: "RA/Dec"
        case .preciseAzAlt: "Az/Alt"
        }
    }
}

/// AUX bus devices (used by the SkyPortal WiFi module).
public enum AuxDevice: UInt8, Sendable, CaseIterable {
    case mainboard = 0x01
    case handController = 0x04
    case nexStarPlusHandController = 0x0D
    case azimuthMotor = 0x10
    case altitudeMotor = 0x11
    case focuser = 0x12
    case app = 0x20
    case gps = 0xB0
    case starSense = 0xB4
    case wifi = 0xB5

    public var label: String {
        switch self {
        case .mainboard: "Main board"
        case .handController: "Hand controller"
        case .nexStarPlusHandController: "NexStar+ hand controller"
        case .azimuthMotor: "Azimuth motor"
        case .altitudeMotor: "Altitude motor"
        case .focuser: "Focus motor"
        case .app: "App"
        case .gps: "GPS"
        case .starSense: "StarSense camera"
        case .wifi: "WiFi module"
        }
    }
}

/// AUX bus queries. Like `HandControllerCommand`, only read-only commands are representable.
public enum AuxQuery: UInt8, CaseIterable, Sendable {
    case getPosition = 0x01
    case slewDone = 0x13
    /// FOC_GET_HS_POSITIONS: the focus motor's calibrated end positions.
    case focuserLimits = 0x2C
    case getVersion = 0xFE

    /// The devices this query may be sent to, or nil for any. A command number can mean something different on
    /// another device, so a query that is only read-only on some devices is limited to those.
    public var destinations: Set<AuxDevice>? {
        switch self {
        case .getPosition, .slewDone, .getVersion: nil
        case .focuserLimits: [.focuser] // 0x2C on the motor controllers is MC_SET_CORDWRAP_POS
        }
    }
}

/// Last line of defence: every byte sequence is checked here immediately before it is written.
public enum ReadOnlyGuard {
    static let handControllerBytes = Set(HandControllerCommand.allCases.map(\.byte))

    public static func checkHandController(_ payload: [UInt8]) throws {
        guard payload.count == 1, handControllerBytes.contains(payload[0]) else {
            throw MountError.blockedCommand(Hex.string(payload))
        }
    }

    public static func checkAux(_ payload: [UInt8]) throws {
        // A read-only AUX query is exactly: 3B 03 <src> <dst> <cmd> <checksum>, with no data bytes, sent to a
        // device on which that command is read-only.
        guard payload.count == 6, payload[0] == AuxPacket.preamble, payload[1] == 3,
              let query = AuxQuery(rawValue: payload[4]),
              query.destinations.map({ $0.contains { $0.rawValue == payload[3] } }) ?? true,
              let packet = AuxPacket.decodeSingle(payload), packet.data.isEmpty
        else {
            throw MountError.blockedCommand(Hex.string(payload))
        }
    }
}
