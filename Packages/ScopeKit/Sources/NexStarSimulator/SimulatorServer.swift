import Foundation
import Network
import ScopeKit

/// Serves a `SimulatedMount` over TCP, speaking either the hand-controller protocol or the AUX bus protocol.
public final class SimulatorServer: @unchecked Sendable {
    public enum Flavor: Sendable { case handController, aux }

    public let flavor: Flavor
    /// The mount this server reports and moves. Pass the same one to an AUX and a hand-controller server to have both
    /// describe one telescope.
    public let mount: SimulatedMount
    public var sky: SimulatedSky { mount.sky }
    /// Whether a Celestron focus motor is fitted (AUX flavor only).
    public var hasFocuser: Bool { mount.hasFocuser }
    public static var focuserLimits: ClosedRange<Int> { SimulatedMount.focuserLimits }
    public var onEvent: (@Sendable (String) -> Void)?

    private let listener: NWListener
    private let queue: DispatchQueue
    /// Only touched on `queue`.
    private var sessions: [ObjectIdentifier: Session] = [:]

    /// Pass port 0 to pick a free port; read `port` after `start()` returns. `sky`, `focuser` and `secondsPerDegree`
    /// make a mount of its own unless one is given.
    public convenience init(flavor: Flavor, port: UInt16, sky: SimulatedSky = SimulatedSky(), loopbackOnly: Bool = true,
                            focuser: Bool = false, secondsPerDegree: Double = 1.5) throws {
        try self.init(flavor: flavor, port: port, mount: SimulatedMount(sky: sky, focuser: focuser, secondsPerDegree: secondsPerDegree),
                      loopbackOnly: loopbackOnly)
    }

    public init(flavor: Flavor, port: UInt16, mount: SimulatedMount, loopbackOnly: Bool = true) throws {
        self.flavor = flavor
        self.mount = mount
        queue = DispatchQueue(label: "NexStarSimulator.\(flavor)")
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        }
    }

    public var port: UInt16? { listener.port?.rawValue }

    public func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Box(false)
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    if resumed.swap(true) == false { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    // .waiting means the port is taken (e.g. scopesim already running); don't hang until it frees up.
                    if resumed.swap(true) == false { continuation.resume(throwing: error) }
                    listener?.cancel()
                case .cancelled:
                    if resumed.swap(true) == false { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Stops listening and drops every connected client.
    public func stop() {
        listener.cancel()
        queue.async { [self] in
            sessions.values.forEach { $0.close() }
        }
    }

    private func currentState() -> SimulatedSky.State { mount.state() }

    fileprivate func isTurning(_ motor: AuxDevice) -> Bool { mount.isTurning(motor) }

    private func stopMotion() {
        if mount.stop() { onEvent?("Stop received: holding position") }
    }

    /// Turns a simulated motor to `target` (24-bit fraction of a turn).
    private func nudge(_ motor: AuxDevice, to target: [UInt8]) {
        let degrees = Double(Int(target[0]) << 16 | Int(target[1]) << 8 | Int(target[2])) / 16_777_216 * 360
        let delta = mount.move(motor, to: degrees)
        onEvent?(String(format: "Nudge received: %@ %+.2f°", motor.label, delta))
    }

    /// The simulated focus motor: position, calibrated limits, GoTo, slew-done and stop.
    fileprivate func replyToFocuser(_ packet: AuxPacket, reply: ([UInt8]) -> Void) {
        let now = Date()
        func bytes24(_ value: Int) -> [UInt8] { [UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func bytes32(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF)] + bytes24(value) }
        switch packet.command {
        case AuxQuery.getVersion.rawValue: reply([1, 4])
        case AuxQuery.getPosition.rawValue: reply(bytes24(mount.focuserPosition(at: now)))
        case AuxQuery.slewDone.rawValue: reply([mount.focuserMoving(at: now) ? 0x00 : 0xFF])
        case AuxQuery.focuserLimits.rawValue: reply(bytes32(Self.focuserLimits.lowerBound) + bytes32(Self.focuserLimits.upperBound))
        case FocusCommand.gotoCommand where packet.data.count == 3:
            let target = Int(packet.data[0]) << 16 | Int(packet.data[1]) << 8 | Int(packet.data[2])
            mount.moveFocuser(to: target, at: now)
            onEvent?("Focus GoTo received: \(target)")
            reply([])
        case StopCommand.auxCommand where packet.data == [0]:
            mount.stopFocuser(at: now)
            reply([])
        default:
            onEvent?("⚠️ Unexpected focuser packet: \(Hex.string(packet.encoded()))")
        }
    }

    private func accept(_ connection: NWConnection) {
        onEvent?("Client connected (\(flavor))")
        let session = Session(connection: connection, server: self)
        sessions[ObjectIdentifier(session)] = session
        connection.start(queue: queue)
        session.receive()
    }

    private final class Session: @unchecked Sendable {
        let connection: NWConnection
        let server: SimulatorServer
        var buffer: [UInt8] = []
        var chatter: DispatchSourceTimer?

        init(connection: NWConnection, server: SimulatorServer) {
            self.connection = connection
            self.server = server
            if server.flavor == .aux { startChatter() }
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [self] data, _, isComplete, error in
                if let data { handle([UInt8](data)) }
                if error != nil || isComplete {
                    close()
                    server.onEvent?("Client disconnected (\(server.flavor))")
                    return
                }
                receive()
            }
        }

        func close() {
            chatter?.cancel()
            connection.cancel()
            server.sessions.removeValue(forKey: ObjectIdentifier(self))
        }

        func send(_ bytes: [UInt8]) {
            connection.send(content: Data(bytes), completion: .idempotent)
        }

        func handle(_ bytes: [UInt8]) {
            switch server.flavor {
            case .handController:
                bytes.forEach(replyToHandController)
            case .aux:
                buffer += bytes
                for packet in AuxPacket.extract(from: &buffer) {
                    send(packet.encoded()) // the real bus echoes every packet back
                    replyToAux(packet)
                }
            }
        }

        func replyToHandController(_ command: UInt8) {
            let state = server.currentState()
            switch Character(UnicodeScalar(command)) {
            case "V": send([5, 35, 0x23]) // minor version 35 == "#", so readers must count bytes, not scan for "#"
            case "m": send([12, 0x23])
            case "J": send([1, 0x23])
            case "L": send([state.slewing ? UInt8(ascii: "1") : UInt8(ascii: "0"), 0x23])
            case "t": send([1, 0x23])
            case "e":
                let ra = Encode.fraction32(state.equatorial.raHours * 15)
                let dec = Encode.fraction32(state.equatorial.decDegrees)
                send(Array(String(format: "%08X,%08X#", ra, dec).utf8))
            case "M":
                server.stopMotion()
                send([0x23])
            case "z":
                let az = Encode.fraction32(state.horizontal.azimuth)
                let alt = Encode.fraction32(state.horizontal.altitude)
                send(Array(String(format: "%08X,%08X#", az, alt).utf8))
            default:
                server.onEvent?("⚠️ Received non-read-only command byte 0x\(String(format: "%02X", command))")
                send([0x23])
            }
        }

        func replyToAux(_ packet: AuxPacket) {
            let state = server.currentState()
            let app = AuxDevice.app.rawValue
            guard packet.source == app else { return }

            func reply(_ data: [UInt8]) {
                send(AuxPacket(source: packet.destination, destination: app, command: packet.command, data: data).encoded())
            }

            let motors = [AuxDevice.azimuthMotor.rawValue, AuxDevice.altitudeMotor.rawValue]
            if server.hasFocuser, packet.destination == AuxDevice.focuser.rawValue {
                server.replyToFocuser(packet, reply: reply)
                return
            }
            if packet.command == StopCommand.auxCommand, packet.data == [0], motors.contains(packet.destination) {
                server.stopMotion()
                reply([])
                return
            }
            if packet.command == NudgeCommand.auxCommand, let motor = AuxDevice(rawValue: packet.destination),
               motors.contains(motor.rawValue), packet.data.count == 3 {
                server.nudge(motor, to: packet.data)
                reply([])
                return
            }

            switch (AuxDevice(rawValue: packet.destination), AuxQuery(rawValue: packet.command)) {
            case (.azimuthMotor, .getPosition): reply(Encode.fraction24(state.horizontal.azimuth))
            case (.altitudeMotor, .getPosition): reply(Encode.fraction24(state.horizontal.altitude))
            case (.azimuthMotor, .slewDone): reply([server.isTurning(.azimuthMotor) ? 0x00 : 0xFF])
            case (.altitudeMotor, .slewDone): reply([server.isTurning(.altitudeMotor) ? 0x00 : 0xFF])
            case (.azimuthMotor, .getVersion), (.altitudeMotor, .getVersion): reply([7, 11, 0x14, 0x5A])
            case (.wifi, .getVersion): reply([1, 2])
            case (.focuser, _), (.starSense, _):
                break // not fitted in the simulator: lets clients exercise their timeout path
            default:
                server.onEvent?("⚠️ Unexpected AUX packet: \(Hex.string(packet.encoded()))")
            }
        }

        /// Imitates a hand controller polling the motors, so clients must filter replies meant for someone else.
        func startChatter() {
            let timer = DispatchSource.makeTimerSource(queue: server.queue)
            timer.schedule(deadline: .now() + 0.3, repeating: 0.7)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let hc = AuxDevice.nexStarPlusHandController.rawValue
                let az = AuxDevice.azimuthMotor.rawValue
                send(AuxPacket(source: hc, destination: az, command: 0x01).encoded())
                send(AuxPacket(source: az, destination: hc, command: 0x01, data: Encode.fraction24(server.currentState().horizontal.azimuth)).encoded())
            }
            timer.resume()
            chatter = timer
        }
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    func swap(_ newValue: T) -> T {
        lock.withLock {
            defer { value = newValue }
            return value
        }
    }
}
