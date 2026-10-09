import Foundation
import Testing
@testable import NexStarSimulator
@testable import ScopeKit

@Suite("Moving in steps", .serialized)
struct DriveTests {
    /// A tracking simulator whose motors turn quickly (a 5° step takes 0.3 s), a connected client, and the
    /// traffic it sends.
    private func fastMount(secondsPerDegree: Double = 0.05) async throws -> (SimulatorServer, AuxClient, Box<[String]>) {
        let server = try SimulatorServer(flavor: .aux, port: 0, sky: SimulatedSky(trackSeconds: 60, slewSeconds: 5), secondsPerDegree: secondsPerDegree)
        try await server.start()
        let sent = Box<[String]>([])
        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)), log: { entry in
            if entry.direction == .sent { _ = sent.swap(sent.swap([]) + [entry.text]) }
        }, motionPolicy: { .darkTestSky })
        try await client.connect()
        return (server, client, sent)
    }

    private func waitFor(_ ending: Box<HeldMove.Ending?>, timeout: Duration = .seconds(10)) async throws -> HeldMove.Ending? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let value = ending.swap(nil)
            if let value { return value }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    @Test func holdingKeepsMovingPastOneStep() async throws {
        let (server, client, _) = try await fastMount()
        defer { server.stop() }
        let held = HeldMove(client: client)

        let start = try #require(try await client.readStatus().horizontal).azimuth
        try await held.begin(.azimuth, positive: true)
        try await Task.sleep(for: .seconds(2))
        try await held.end()
        try await Task.sleep(for: .milliseconds(400))
        let after = try await client.readStatus()
        await client.disconnect()

        #expect(after.slewing == false)
        let moved = Astronomy.normalize(try #require(after.horizontal).azimuth - start)
        #expect(moved > NudgeAxis.azimuth.maxStepDegrees + 1, "moved \(moved)°: a hold should keep sending steps")
    }

    /// The next step of a hold goes out before the current one ends, so the motor never stops in between.
    @Test func aHoldCarriesStraightOnBetweenSteps() async throws {
        let (server, client, _) = try await fastMount(secondsPerDegree: 0.3) // a 5° step takes 1.5 s
        defer { server.stop() }
        let held = HeldMove(client: client)

        let start = try #require(try await client.readStatus().horizontal).azimuth
        try await held.begin(.azimuth, positive: true)
        // Sampled every 20 ms: a pause between steps (the motor reaching a step's end before the next one is
        // sent) would show up as at least one "stopped".
        var moving: [Bool] = []
        let until = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < until {
            moving.append(try await client.isMoving(.azimuth))
            try await Task.sleep(for: .milliseconds(20))
        }
        try await held.end()
        let after = try #require(try await client.readStatus().horizontal).azimuth
        await client.disconnect()

        #expect(!moving.dropFirst(5).contains(false), "the motor stopped between steps \(moving.filter { !$0 }.count) times")
        #expect(Astronomy.normalize(after - start) > NudgeAxis.azimuth.maxStepDegrees, "more than one step")
    }

    @Test func holdingUpStopsAtTheAltitudeLimit() async throws {
        let (server, client, _) = try await fastMount()
        defer { server.stop() }
        await client.setCalibration(AxisCalibration(altitudeOffset: -35)) // reads about 73°
        let ending = Box<HeldMove.Ending?>(nil)
        let held = HeldMove(client: client)

        try await held.begin(.altitude, positive: true, onEnded: { _ = ending.swap($0) })
        let ended = try await waitFor(ending)
        try await Task.sleep(for: .milliseconds(500)) // the step already under way ends by itself at the limit
        let after = try await client.readStatus()
        await client.disconnect()

        guard case .stopped(let reason) = ended else { Issue.record("ended \(String(describing: ended))"); return }
        #expect(reason.contains("altitude limit"))
        let altitude = try #require(after.horizontal).altitude
        #expect(altitude > 74.9 && altitude < 75.05, "altitude \(altitude)°") // the limit, plus a little sidereal drift
        #expect(after.slewing == false)
    }

    @Test func aDeclinedStepEndsTheHoldWithoutAStop() async throws {
        let (server, client, sent) = try await fastMount()
        defer { server.stop() }
        let ending = Box<HeldMove.Ending?>(nil)
        let held = HeldMove(client: client)

        let start = try #require(try await client.readStatus().horizontal).azimuth
        try await held.begin(.azimuth, positive: true, mayContinue: { _, _ in "Too close to the Sun." }, onEnded: { _ = ending.swap($0) })
        let ended = try await waitFor(ending)
        try await Task.sleep(for: .milliseconds(500)) // the step under way ends by itself
        let after = try #require(try await client.readStatus().horizontal).azimuth
        await client.disconnect()

        #expect(ended == .stopped("Too close to the Sun."))
        #expect(abs(Astronomy.normalize(after - start) - NudgeAxis.azimuth.maxStepDegrees) < 0.1, "only the first step")
        #expect(sent.swap([]).filter { $0.contains("stop →") }.isEmpty, "the step had finished, so there was nothing to stop")
    }

    @Test func aStopThatFailsIsReportedNotPassedOffAsStopped() async throws {
        let (server, client, _) = try await fastMount(secondsPerDegree: 0.3)
        let ending = Box<HeldMove.Ending?>(nil)
        let held = HeldMove(client: client)

        try await held.begin(.azimuth, positive: true, onEnded: { _ = ending.swap($0) })
        server.stop() // the link drops mid-hold, so the stop can't go out
        let ended = try await waitFor(ending)
        await client.disconnect()

        guard case .stopFailed = ended else { Issue.record("ended \(String(describing: ended))"); return }
    }

    @Test func goToArrivesOneAxisAfterTheOther() async throws {
        let (server, client, sent) = try await fastMount()
        defer { server.stop() }
        let ending = Box<HeldMove.Ending?>(nil)
        let held = HeldMove(client: client)

        let start = try #require(try await client.readStatus().horizontal)
        let target = Horizontal(azimuth: Astronomy.normalize(start.azimuth - 12), altitude: start.altitude + 3)
        try await held.goTo([.init(axis: .altitude, target: target.altitude, positive: true),
                             .init(axis: .azimuth, target: target.azimuth, positive: false)], onEnded: { _ = ending.swap($0) })
        let ended = try await waitFor(ending)
        let after = try await client.readStatus()
        await client.disconnect()

        #expect(ended == .arrived)
        #expect(after.slewing == false)
        let reached = try #require(after.horizontal)
        #expect(abs(reached.altitude - target.altitude) < 0.05)
        #expect(abs(Astronomy.normalize(reached.azimuth - target.azimuth + 180) - 180) < 0.05) // only sidereal drift
        let moves = sent.swap([]).filter { $0.contains("(move ") }
        let lastAltitude = try #require(moves.lastIndex { $0.contains("Altitude motor") })
        let firstAzimuth = try #require(moves.firstIndex { $0.contains("Azimuth motor") })
        #expect(lastAltitude < firstAzimuth, "altitude leg first, then azimuth")
    }

    /// Left below the horizon (as a misbehaving move once did), Return to home can still lift the scope back up.
    @Test func aGoToCanClimbBackFromBelowTheHorizon() async throws {
        let (server, client, _) = try await fastMount()
        defer { server.stop() }
        await client.setCalibration(AxisCalibration(altitudeOffset: 40)) // the simulator's 38° reads as 2° below
        let ending = Box<HeldMove.Ending?>(nil)
        let held = HeldMove(client: client)

        try await held.goTo([.init(axis: .altitude, target: 3, positive: true)], onEnded: { _ = ending.swap($0) })
        let ended = try await waitFor(ending)
        let after = try #require(try await client.readStatus().horizontal).altitude
        await client.disconnect()

        #expect(ended == .arrived)
        #expect(abs(after - 3) < 0.05, "altitude \(after)°")
    }

    @Test func endingAGoToStopsIt() async throws {
        let (server, client, _) = try await fastMount()
        defer { server.stop() }
        let held = HeldMove(client: client)

        let start = try #require(try await client.readStatus().horizontal).azimuth
        try await held.goTo([.init(axis: .azimuth, target: Astronomy.normalize(start + 60), positive: true)])
        try await Task.sleep(for: .milliseconds(700))
        try await held.end()
        try await Task.sleep(for: .milliseconds(400))
        let after = try await client.readStatus()
        await client.disconnect()

        #expect(after.slewing == false)
        let moved = Astronomy.normalize(try #require(after.horizontal).azimuth - start)
        #expect(moved > 1 && moved < 30)
    }

    /// A mount scripted to sit still at `azimuth`; returns the GoTo targets it was sent, in degrees.
    private func stillMount(azimuth: Double) -> (AuxClient, ScriptedTransport) {
        let transport = ScriptedTransport()
        transport.onWrite = { bytes in
            guard let packet = AuxPacket.decodeSingle(bytes) else { return [] }
            let reply: [UInt8]? = switch packet.command {
            case AuxQuery.slewDone.rawValue: [0xFF]
            case AuxQuery.getPosition.rawValue: Encode.fraction24(packet.destination == AuxDevice.azimuthMotor.rawValue ? azimuth : 40)
            case NudgeCommand.auxCommand: []
            default: nil
            }
            return reply.map { AuxPacket(source: packet.destination, destination: AuxDevice.app.rawValue, command: packet.command, data: $0).encoded() } ?? []
        }
        return (AuxClient(transport: transport, motionPolicy: { .darkTestSky }), transport)
    }

    private func gotoTargets(_ transport: ScriptedTransport) -> [Double] {
        transport.written.compactMap(AuxPacket.decodeSingle).filter { $0.command == NudgeCommand.auxCommand }.map {
            Double(Int($0.data[0]) << 16 | Int($0.data[1]) << 8 | Int($0.data[2])) / 16_777_216 * 360
        }
    }

    @Test func aStepTowardATargetGoesTheChosenWayRound() async throws {
        // Target 6° from 10°: going up means the long way, one full step at a time; going down arrives.
        let (up, upTransport) = stillMount(azimuth: 10)
        #expect(try await up.move(.azimuth, toward: 6, positive: true, onSend: {}) == false)
        #expect(gotoTargets(upTransport).map { ($0 * 100).rounded() / 100 } == [15])

        let (down, downTransport) = stillMount(azimuth: 10)
        #expect(try await down.move(.azimuth, toward: 6, positive: false, onSend: {}) == true)
        #expect(gotoTargets(downTransport).map { ($0 * 100).rounded() / 100 } == [6])
    }

    @Test func aStepAlreadyAtItsTargetSendsNothing() async throws {
        let (client, transport) = stillMount(azimuth: 359.995)
        #expect(try await client.move(.azimuth, toward: 0, positive: true, onSend: {}) == true)
        #expect(try await client.move(.azimuth, toward: 359.99, positive: true, onSend: {}) == true, "just past it isn't a full turn short")
        #expect(gotoTargets(transport).isEmpty)
    }
}
