import Foundation

/// Talks the NexStar serial protocol to a hand controller (USB, or a serial-to-WiFi bridge like SkyFi).
public actor HandControllerClient: MountClient {
    private let transport: MountTransport
    private let log: TrafficLogger?
    private var model: String?
    private var firmware: String?
    private let exchangeLock = ExchangeLock()

    public init(transport: MountTransport, log: TrafficLogger? = nil) {
        self.transport = transport
        self.log = log
    }

    public func connect() async throws {
        log?(TrafficEntry(.note, "Connecting to hand controller at \(transport.displayName)…"))
        try await transport.open(timeout: .seconds(5))
        let version = try await query(.version)
        firmware = "\(version[0]).\(version[1])"
        let modelReply = try await query(.model)
        model = NexStarModels.name(for: modelReply[0])
        log?(TrafficEntry(.note, "Connected: \(model ?? "?"), firmware \(firmware ?? "?")"))
    }

    public func readStatus() async throws -> MountStatus {
        var status = MountStatus(protocolKind: .handController)
        status.model = model
        if let firmware { status.devices = [DeviceInfo(name: "Hand controller", version: firmware)] }

        status.aligned = try await query(.alignmentComplete)[0] == 1
        status.slewing = try await query(.gotoInProgress)[0] == UInt8(ascii: "1")
        status.tracking = TrackingMode(rawValue: try await query(.trackingMode)[0])

        let raDecReply = try await query(.preciseRaDec)
        guard let (ra, dec) = Angles.parsePrecisePair(raDecReply) else {
            throw MountError.unexpectedReply(command: HandControllerCommand.preciseRaDec.label, bytes: raDecReply)
        }
        status.equatorial = Equatorial(raHours: ra / 15, decDegrees: Angles.signed(dec))

        let azAltReply = try await query(.preciseAzAlt)
        guard let (az, alt) = Angles.parsePrecisePair(azAltReply) else {
            throw MountError.unexpectedReply(command: HandControllerCommand.preciseAzAlt.label, bytes: azAltReply)
        }
        status.horizontal = Horizontal(azimuth: az, altitude: Angles.signed(alt))

        status.updated = .now
        return status
    }

    public func disconnect() {
        transport.close()
    }

    public func stop() async throws {
        await exchangeLock.acquire()
        defer { exchangeLock.release() }

        let payload = StopCommand.handController
        try StopCommand.check(payload)
        _ = try await exchange(payload, replyLength: 1, label: "cancel GoTo")
    }

    public func nudge(_ axis: NudgeAxis, by degrees: Double) async throws {
        throw MountError.refused("Nudging is only available over the WiFi module.")
    }

    public func move(_ axis: NudgeAxis, positive: Bool, continuing: Bool, onSend: @escaping @Sendable () -> Void) async throws -> Double {
        throw MountError.refused("Moving is only available over the WiFi module.")
    }

    public func motorAngle(_ axis: NudgeAxis) async throws -> Double {
        throw MountError.refused("Motor angles are only available over the WiFi module.")
    }

    public func move(_ axis: NudgeAxis, toward target: Double, positive: Bool, onSend: @escaping @Sendable () -> Void) async throws -> Bool {
        throw MountError.refused("Moving is only available over the WiFi module.")
    }

    public func isMoving(_ axis: NudgeAxis) async throws -> Bool {
        throw MountError.refused("Moving is only available over the WiFi module.")
    }

    public func focus(to position: Int) async throws {
        throw MountError.refused("The focus motor is only available over the WiFi module.")
    }

    public func focus(by steps: Int) async throws {
        throw MountError.refused("The focus motor is only available over the WiFi module.")
    }

    public func focusMove(positive: Bool, onSend: @escaping @Sendable () -> Void) async throws {
        throw MountError.refused("The focus motor is only available over the WiFi module.")
    }

    public func stopFocuser() async throws {}

    public func calibrate(azimuth: Double?, altitude: Double?) async throws -> AxisCalibration {
        throw MountError.refused("Not needed over USB: the hand controller already reports real sky positions.")
    }

    public func setCalibration(_ calibration: AxisCalibration?) {}

    func query(_ command: HandControllerCommand) async throws -> [UInt8] {
        await exchangeLock.acquire()
        defer { exchangeLock.release() }

        let payload = [command.byte]
        try ReadOnlyGuard.checkHandController(payload)
        return try await exchange(payload, replyLength: command.replyLength, label: command.label)
    }

    /// Writes an already-checked payload and reads a fixed-length reply ending in "#".
    private func exchange(_ payload: [UInt8], replyLength: Int, label: String) async throws -> [UInt8] {
        transport.discardBuffered()
        try await transport.write(payload)
        log?(TrafficEntry(.sent, "\(String(decoding: payload, as: UTF8.self))  (\(label))"))

        var reply: [UInt8] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while reply.count < replyLength {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw MountError.timeout(label) }
            reply += try await transport.read(maxLength: replyLength - reply.count, timeout: remaining)
        }
        log?(TrafficEntry(.received, Hex.string(reply)))

        guard reply.last == UInt8(ascii: "#") else {
            throw MountError.unexpectedReply(command: label, bytes: reply)
        }
        return reply
    }
}
