import Foundation

/// Talks the AUX bus protocol, as exposed by the SkyPortal WiFi module (default 1.2.3.4:2000).
/// The bus is shared: we also see our own echoed requests and other devices' chatter, so replies are
/// matched on source, destination and command.
public actor AuxClient: MountClient {
    private let transport: MountTransport
    private let log: TrafficLogger?
    private var buffer: [UInt8] = []
    /// Replies addressed to us that this exchange hasn't matched yet, oldest first. Keeps a reply that arrives
    /// ahead of the one being waited for (stop waits on two motors that answer in either order). Cleared when the
    /// next exchange begins, so a late reply to an earlier request can't be taken for a reply to a new one.
    private var pending: [AuxPacket] = []
    private static let maxPending = 32
    private var devices: [DeviceInfo] = []
    private var hasFocuser = false
    private var focuserLimits: ClosedRange<Int>?
    /// The last focuser position read, and how many readings in a row have failed since.
    private var lastFocuserPosition: Int?
    private var focuserMisses = 0
    /// Readings in a row that may fail before the focuser's position is reported as unknown.
    static let focuserMissesAllowed = 2
    private var calibration: AxisCalibration?
    private let exchangeLock = ExchangeLock()
    /// Asked for the Sun rules just before each move is written (see `MotionPolicy`).
    private let motionPolicy: @Sendable () async -> MotionPolicy

    /// `motionPolicy` is asked for the current Sun rules immediately before each move; by default every move is
    /// refused.
    public init(transport: MountTransport, log: TrafficLogger? = nil,
                motionPolicy: @escaping @Sendable () async -> MotionPolicy = { .refuseAll }) {
        self.transport = transport
        self.log = log
        self.motionPolicy = motionPolicy
    }

    public func connect() async throws {
        log?(TrafficEntry(.note, "Connecting to AUX bus at \(transport.displayName)…"))
        try await transport.open(timeout: .seconds(5))
        buffer.removeAll()
        pending.removeAll()

        devices = []
        for device in [AuxDevice.azimuthMotor, .altitudeMotor] {
            let reply = try await request(.getVersion, to: device)
            devices.append(DeviceInfo(name: device.label, version: Self.version(reply)))
        }
        for device in [AuxDevice.focuser, .starSense, .wifi] {
            if let reply = try? await request(.getVersion, to: device, timeout: .milliseconds(600)) {
                devices.append(DeviceInfo(name: device.label, version: Self.version(reply)))
                if device == .focuser { hasFocuser = true }
            }
        }
        log?(TrafficEntry(.note, "Found: " + devices.map(\.name).joined(separator: ", ")))

        if hasFocuser {
            focuserLimits = (try? await request(.focuserLimits, to: .focuser, timeout: .milliseconds(600))).flatMap(FocusCommand.limits(fromReply:))
            log?(TrafficEntry(.note, focuserLimits.map { "Focus motor calibrated range: \($0.lowerBound)–\($0.upperBound)" }
                ?? "Focus motor didn't report calibrated limits, so focus moves are locked."))
        }
    }

    /// Asks the azimuth motor for its version: a quick, read-only way to tell an AUX bus from anything else.
    /// Expects the transport to be open already.
    func identify(timeout: Duration = .milliseconds(800)) async throws -> Bool {
        let reply = try await request(.getVersion, to: .azimuthMotor, timeout: timeout)
        return reply.count >= 2
    }

    public func readStatus() async throws -> MountStatus {
        var status = MountStatus(protocolKind: .aux)
        status.devices = devices

        let az = try await position(of: .azimuthMotor)
        let alt = try await position(of: .altitudeMotor)
        let motor = Horizontal(azimuth: az, altitude: Angles.signed(alt))
        status.axisAngles = motor
        status.calibration = calibration
        status.horizontal = (calibration ?? AxisCalibration()).sky(fromMotor: motor)

        let azDone = try await request(.slewDone, to: .azimuthMotor)
        let altDone = try await request(.slewDone, to: .altitudeMotor)
        status.slewing = !(azDone.first == 0xFF && altDone.first == 0xFF)

        // Known since connecting, so reported even when this poll's focuser reading times out (one slow reply
        // mustn't make the focuser look uncalibrated).
        if hasFocuser { status.focuserLimits = focuserLimits }
        var focuserAnswered = false
        if hasFocuser, let reply = try? await request(.getPosition, to: .focuser, timeout: .milliseconds(600)), reply.count >= 3 {
            lastFocuserPosition = Int(reply[0]) << 16 | Int(reply[1]) << 8 | Int(reply[2])
            focuserMisses = 0
            focuserAnswered = true
        } else if hasFocuser {
            focuserMisses += 1
        }
        // A missed reading or two keeps the last position, so the Focus panel doesn't flicker; moves always read the
        // position afresh, so this is only for display.
        if hasFocuser, focuserMisses <= Self.focuserMissesAllowed, let position = lastFocuserPosition {
            status.focuserPosition = position
            if focuserAnswered, let done = try? await request(.slewDone, to: .focuser, timeout: .milliseconds(600)) {
                status.focuserMoving = done.first != 0xFF
            }
        }

        status.updated = .now
        return status
    }

    public func disconnect() {
        transport.close()
    }

    private func position(of device: AuxDevice) async throws -> Double {
        let raw = try Self.rawPosition(try await request(.getPosition, to: device), of: device)
        return Angles.degrees(fraction: raw, bits: 24)
    }

    private static func rawPosition(_ reply: [UInt8], of device: AuxDevice) throws -> UInt32 {
        guard reply.count >= 3 else {
            throw MountError.unexpectedReply(command: "\(device.label) position", bytes: reply)
        }
        return UInt32(reply[0]) << 16 | UInt32(reply[1]) << 8 | UInt32(reply[2])
    }

    private static func version(_ data: [UInt8]) -> String {
        switch data.count {
        case 4: "\(data[0]).\(data[1]).\(Int(data[2]) << 8 | Int(data[3]))"
        case 2: "\(data[0]).\(data[1])"
        default: data.map(String.init).joined(separator: ".")
        }
    }

    public func stop() async throws {
        await beginExchange()
        defer { exchangeLock.release() }

        // Tell both motors before waiting on either, so a slow reply from one can't delay stopping the other.
        for (device, bytes) in StopCommand.aux {
            try StopCommand.check(bytes)
            try await transport.write(bytes)
            log?(TrafficEntry(.sent, "\(Hex.string(bytes))  (stop → \(device.label))"))
        }
        if hasFocuser {
            try StopCommand.check(StopCommand.focuser)
            try await transport.write(StopCommand.focuser)
            log?(TrafficEntry(.sent, "\(Hex.string(StopCommand.focuser))  (stop → \(AuxDevice.focuser.label))"))
        }
        for (device, _) in StopCommand.aux {
            _ = try await reply(from: device, command: StopCommand.auxCommand, timeout: .seconds(1),
                                context: "stop acknowledgement from \(device.label)")
        }
        if hasFocuser { // best effort: the mount's motors matter most
            _ = try? await reply(from: .focuser, command: StopCommand.auxCommand, timeout: .milliseconds(500), context: "focuser stop")
        }
    }

    public func stopFocuser() async throws {
        guard hasFocuser else { return }
        await beginExchange()
        defer { exchangeLock.release() }
        try StopCommand.check(StopCommand.focuser)
        try await transport.write(StopCommand.focuser)
        log?(TrafficEntry(.sent, "\(Hex.string(StopCommand.focuser))  (stop → \(AuxDevice.focuser.label))"))
        _ = try await reply(from: .focuser, command: StopCommand.auxCommand, timeout: .seconds(1),
                            context: "stop acknowledgement from \(AuxDevice.focuser.label)")
    }

    public func calibrate(azimuth: Double?, altitude: Double?) async throws -> AxisCalibration {
        await beginExchange()
        defer { exchangeLock.release() }
        for motor in [AuxDevice.azimuthMotor, .altitudeMotor] {
            guard try await exchange(.slewDone, to: motor).first == 0xFF else {
                throw MountError.refused("The mount is moving. Wait for it to stop, then calibrate.")
            }
        }
        let az = Angles.degrees(fraction: try Self.rawPosition(try await exchange(.getPosition, to: .azimuthMotor), of: .azimuthMotor), bits: 24)
        let alt = Angles.degrees(fraction: try Self.rawPosition(try await exchange(.getPosition, to: .altitudeMotor), of: .altitudeMotor), bits: 24)
        let updated = (calibration ?? AxisCalibration()).pointing(motor: Horizontal(azimuth: az, altitude: Angles.signed(alt)),
                                                                  azimuth: azimuth, altitude: altitude)
        calibration = updated
        log?(TrafficEntry(.note, String(format: "Calibrated: azimuth offset %.2f°, altitude offset %.2f°", updated.azimuthOffset, updated.altitudeOffset)))
        return updated
    }

    public func setCalibration(_ calibration: AxisCalibration?) {
        self.calibration = calibration
    }

    public func focus(by steps: Int) async throws {
        try await moveFocuser { current, limits in
            let maxStep = FocusCommand.maxStep(limits)
            guard steps != 0, abs(steps) <= maxStep else {
                throw MountError.refused("A focus step must be between 1 and \(maxStep) steps.")
            }
            guard limits.contains(current + steps) else {
                throw MountError.refused("That would go past the focus motor's calibrated \(steps > 0 ? "upper" : "lower") limit (\(steps > 0 ? limits.upperBound : limits.lowerBound)).")
            }
            return current + steps
        }
    }

    public func focus(to position: Int) async throws {
        try await moveFocuser { current, limits in
            let maxStep = FocusCommand.maxStep(limits)
            guard position != current else { return nil } // already there
            guard limits.contains(position) else {
                throw MountError.refused("Position \(position) is outside the focus motor's calibrated range (\(limits.lowerBound)–\(limits.upperBound)).")
            }
            guard abs(position - current) <= maxStep else {
                throw MountError.refused("Position \(position) is \(abs(position - current)) steps away, more than one move allows (\(maxStep)). Step toward it first.")
            }
            return position
        }
    }

    public func focusMove(positive: Bool, onSend: @escaping @Sendable () -> Void) async throws {
        try await moveFocuser(onSend: onSend) { current, limits in
            let reach = FocusCommand.holdReach(limits)
            let target = min(limits.upperBound, max(limits.lowerBound, current + (positive ? reach : -reach)))
            guard target != current else {
                throw MountError.refused("The focuser is already at its calibrated \(positive ? "upper" : "lower") limit.")
            }
            return target
        }
    }

    /// Sends one bounded focus GoTo. `target` gets the current position and calibrated range and returns where to
    /// go, or nil if no move is needed.
    private func moveFocuser(onSend: () -> Void = {}, _ target: (Int, ClosedRange<Int>) throws -> Int?) async throws {
        guard hasFocuser else { throw MountError.refused("No focus motor found on the AUX bus.") }
        guard let limits = focuserLimits else {
            throw MountError.refused("The focus motor hasn't reported calibrated limits, so focusing is locked. Calibrate it from the hand controller or SkyPortal, then reconnect.")
        }
        await beginExchange()
        defer { exchangeLock.release() }

        guard try await exchange(.slewDone, to: .focuser).first == 0xFF else {
            throw MountError.refused("The focuser is still moving.")
        }
        let reply = try await exchange(.getPosition, to: .focuser)
        guard reply.count >= 3 else { throw MountError.unexpectedReply(command: "focuser position", bytes: reply) }
        let current = Int(reply[0]) << 16 | Int(reply[1]) << 8 | Int(reply[2])
        guard let goal = try target(current, limits) else { return }

        let bytes = FocusCommand.packet(to: goal)
        try FocusCommand.check(bytes, current: current, limits: limits)
        onSend()
        try await transport.write(bytes)
        log?(TrafficEntry(.sent, "\(Hex.string(bytes))  (focus \(current) → \(goal))"))
        _ = try await self.reply(from: .focuser, command: FocusCommand.gotoCommand, timeout: .seconds(1),
                                 context: "focus acknowledgement")
    }

    public func nudge(_ axis: NudgeAxis, by degrees: Double) async throws {
        guard degrees.isFinite, degrees != 0, abs(degrees) <= axis.maxStepDegrees else {
            throw MountError.refused("A \(axis.rawValue) nudge must be between 0° and \(axis.maxStepDegrees)°.")
        }
        try await moveMotor(axis) { _ in degrees }
    }

    @discardableResult
    public func move(_ axis: NudgeAxis, positive: Bool, continuing: Bool, onSend: @escaping @Sendable () -> Void) async throws -> Double {
        let end = try await moveMotor(axis, alreadyTurning: continuing, onSend: onSend) { angle in
            let sign = positive ? 1.0 : -1.0
            guard axis == .altitude else { return sign * axis.maxStepDegrees }
            // Head for the band edge rather than refusing outright when it's closer than a full step.
            let limits = NudgeCommand.altitudeLimits
            let room = (positive ? limits.upperBound - angle : angle - limits.lowerBound) - 0.001
            guard room >= 0.01 else {
                throw MountError.refused(String(format: "Already at the %@ altitude limit (%.0f°).",
                                                positive ? "upper" : "lower", positive ? limits.upperBound : limits.lowerBound))
            }
            return sign * min(axis.maxStepDegrees, room)
        }
        guard let end else { throw MountError.refused("Nothing to move.") }
        return end
    }

    public func motorAngle(_ axis: NudgeAxis) async throws -> Double {
        let angle = try await position(of: axis.motor)
        return axis == .altitude ? Angles.signed(angle) : angle
    }

    public func move(_ axis: NudgeAxis, toward target: Double, positive: Bool, onSend: @escaping @Sendable () -> Void) async throws -> Bool {
        var arrives = false
        try await moveMotor(axis, onSend: onSend) { angle in
            let remaining: Double
            if axis == .azimuth {
                let sky = Astronomy.normalize(angle - (calibration?.azimuthOffset ?? 0))
                let ahead = Astronomy.normalize(positive ? target - sky : sky - target)
                // A hair past the target is there, not a full turn short of it.
                let distance = ahead > 360 - Self.arrivalTolerance ? 0 : ahead
                remaining = positive ? distance : -distance
            } else {
                remaining = target - angle
            }
            arrives = abs(remaining) <= axis.maxStepDegrees
            guard abs(remaining) > Self.arrivalTolerance else { return nil }
            return arrives ? remaining : (remaining > 0 ? 1 : -1) * axis.maxStepDegrees
        }
        return arrives
    }

    /// How close to a target counts as there.
    static let arrivalTolerance = 0.01

    public func isMoving(_ axis: NudgeAxis) async throws -> Bool {
        try await request(.slewDone, to: axis.motor).first != 0xFF
    }

    /// Sends one bounded slow GoTo. `step` receives the motor's current angle (signed for altitude) and returns the
    /// move in degrees, or nil if no move is needed. Everything happens under one lock hold, so the position the
    /// target is based on can't go stale between reading it and sending the move. `onSend` runs just before the
    /// move is written. `alreadyTurning` lets it go out while this axis is still moving (the next step of a hold);
    /// the other axis must always be still. Returns where the move ends as a motor angle (signed for altitude), or
    /// nil if no move was needed.
    @discardableResult
    private func moveMotor(_ axis: NudgeAxis, alreadyTurning: Bool = false, onSend: () -> Void = {},
                           step: (Double) throws -> Double?) async throws -> Double? {
        await beginExchange()
        defer { exchangeLock.release() }

        for motor in [AuxDevice.azimuthMotor, .altitudeMotor] where !(alreadyTurning && motor == axis.motor) {
            guard try await exchange(.slewDone, to: motor).first == 0xFF else {
                throw MountError.refused("The mount is already moving. Wait for it to stop, then try again.")
            }
        }
        let current = try Self.rawPosition(try await exchange(.getPosition, to: axis.motor), of: axis.motor)
        let angle = Angles.degrees(fraction: current, bits: 24)
        let altitudeOffset = calibration?.altitudeOffset ?? 0
        // Altitude limits apply to the real (calibrated) altitude, not the raw motor count.
        guard let degrees = try step(axis == .altitude ? Angles.signed(angle) - altitudeOffset : angle) else { return nil }

        if axis == .altitude {
            let altitude = Angles.signed(angle) - altitudeOffset
            let limits = NudgeCommand.altitudeLimits
            guard NudgeCommand.altitudeMoveAllowed(from: altitude, to: altitude + degrees) else {
                throw MountError.refused(String(
                    format: "Up/down moves stay between %.0f° and %.0f° altitude, or head back toward that band (the scope reads %.1f°).",
                    limits.lowerBound, limits.upperBound, altitude))
            }
        }

        // The Sun rules, from where both axes point now, whoever asked for the move.
        let other: AuxDevice = axis == .azimuth ? .altitudeMotor : .azimuthMotor
        let otherAngle = Angles.degrees(fraction: try Self.rawPosition(try await exchange(.getPosition, to: other), of: other), bits: 24)
        let motor = axis == .azimuth ? Horizontal(azimuth: angle, altitude: Angles.signed(otherAngle))
                                     : Horizontal(azimuth: otherAngle, altitude: Angles.signed(angle))
        let pointing = (calibration ?? AxisCalibration()).sky(fromMotor: motor)
        if let problem = await motionPolicy().problem(axis, by: degrees, from: pointing) {
            throw MountError.refused(problem)
        }

        let bytes = NudgeCommand.packet(axis, from: current, by: degrees)
        try NudgeCommand.check(bytes, axis: axis, currentPosition: current, altitudeOffset: altitudeOffset)
        onSend()
        try await transport.write(bytes)
        log?(TrafficEntry(.sent, "\(Hex.string(bytes))  (move \(String(format: "%+.2f", degrees))° → \(axis.motor.label))"))
        _ = try await reply(from: axis.motor, command: NudgeCommand.auxCommand, timeout: .seconds(1),
                            context: "move acknowledgement from \(axis.motor.label)")
        return axis == .altitude ? Angles.signed(angle) + degrees : Astronomy.normalize(angle + degrees)
    }

    func request(_ query: AuxQuery, to device: AuxDevice, timeout: Duration = .seconds(1.5)) async throws -> [UInt8] {
        await beginExchange()
        defer { exchangeLock.release() }
        return try await exchange(query, to: device, timeout: timeout)
    }

    /// Takes the exchange lock and drops replies left over from an earlier exchange. Release with
    /// `exchangeLock.release()`.
    private func beginExchange() async {
        await exchangeLock.acquire()
        pending.removeAll()
    }

    /// Sends one query and waits for its reply. The caller must hold `exchangeLock`.
    private func exchange(_ query: AuxQuery, to device: AuxDevice, timeout: Duration = .seconds(1.5)) async throws -> [UInt8] {
        let packet = AuxPacket.query(query, to: device)
        let bytes = packet.encoded()
        try ReadOnlyGuard.checkAux(bytes)

        try await transport.write(bytes)
        log?(TrafficEntry(.sent, "\(Hex.string(bytes))  (\(query) → \(device.label))"))
        return try await reply(from: device, command: query.rawValue, timeout: timeout, context: "\(query) from \(device.label)")
    }

    private func reply(from device: AuxDevice, command: UInt8, timeout: Duration, context: String) async throws -> [UInt8] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            // Echoes of our own requests and other devices' chatter aren't addressed to us and are of no use.
            pending += AuxPacket.extract(from: &buffer).filter { $0.destination == AuxDevice.app.rawValue }
            if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
            if let index = pending.firstIndex(where: { $0.source == device.rawValue && $0.command == command }) {
                let reply = pending.remove(at: index)
                log?(TrafficEntry(.received, "\(Hex.string(reply.encoded()))  (\(device.label))"))
                return reply.data
            }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw MountError.timeout(context) }
            buffer += try await transport.read(maxLength: 4096, timeout: remaining)
        }
    }
}
