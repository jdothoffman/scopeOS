import Foundation
import Testing
@testable import NexStarSimulator
@testable import ScopeKit

@Suite("End to end against the simulator", .serialized)
struct SimulatorIntegrationTests {
    @Test func handControllerOverTCP() async throws {
        let sky = SimulatedSky(trackSeconds: 60, slewSeconds: 5)
        let server = try SimulatorServer(flavor: .handController, port: 0, sky: sky)
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.port)

        let client = HandControllerClient(transport: TCPTransport(host: "127.0.0.1", port: port))
        try await client.connect()
        let status = try await client.readStatus()
        await client.disconnect()

        #expect(status.model == "6/8 SE")
        #expect(status.devices.first?.version == "5.35")
        #expect(status.aligned == true)
        #expect(status.slewing == false)
        #expect(status.tracking == .altAz)
        let eq = try #require(status.equatorial)
        #expect(abs(eq.raHours - 23.35) < 0.001)
        #expect(abs(eq.decDegrees + 6.9) < 0.001)
        let h = try #require(status.horizontal)
        #expect(abs(h.azimuth - 165) < 1)
        #expect(abs(h.altitude - 38) < 1)
    }

    @Test func auxOverTCPFiltersEchoesAndChatterAndToleratesMissingFocuser() async throws {
        let sky = SimulatedSky(trackSeconds: 60, slewSeconds: 5)
        let server = try SimulatorServer(flavor: .aux, port: 0, sky: sky)
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.port)

        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: port), motionPolicy: { .darkTestSky })
        try await client.connect()
        // Poll several times so background chatter from the simulated hand controller is interleaved.
        var status: MountStatus?
        for _ in 0 ..< 4 {
            status = try await client.readStatus()
            try await Task.sleep(for: .milliseconds(300))
        }
        await client.disconnect()

        let s = try #require(status)
        #expect(s.equatorial == nil)
        #expect(s.slewing == false)
        #expect(s.focuserPosition == nil)
        #expect(s.devices.map(\.name).contains("Azimuth motor"))
        #expect(s.devices.first?.version == "7.11.5210")
        #expect(!s.devices.map(\.name).contains("Focus motor"))
        let h = try #require(s.horizontal)
        #expect(abs(h.azimuth - 165) < 1)
        #expect(abs(h.altitude - 38) < 1)
    }

    @Test func reportsSlewingDuringSimulatedSlew() async throws {
        let sky = SimulatedSky(trackSeconds: 0.01, slewSeconds: 30)
        let server = try SimulatorServer(flavor: .aux, port: 0, sky: sky)
        try await server.start()
        defer { server.stop() }

        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)), motionPolicy: { .darkTestSky })
        try await client.connect()
        let status = try await client.readStatus()
        await client.disconnect()
        #expect(status.slewing == true)
    }

    @Test(arguments: [SimulatorServer.Flavor.handController, .aux])
    func stopHaltsASlew(_ flavor: SimulatorServer.Flavor) async throws {
        let sky = SimulatedSky(trackSeconds: 0.01, slewSeconds: 30, start: .now.addingTimeInterval(-1))
        let server = try SimulatorServer(flavor: flavor, port: 0, sky: sky)
        try await server.start()
        defer { server.stop() }
        let transport = TCPTransport(host: "127.0.0.1", port: try #require(server.port))
        let client: any MountClient = flavor == .aux ? AuxClient(transport: transport, motionPolicy: { .darkTestSky }) : HandControllerClient(transport: transport)

        try await client.connect()
        #expect(try await client.readStatus().slewing == true)
        try await client.stop()
        let before = try #require(try await client.readStatus().horizontal)
        try await Task.sleep(for: .milliseconds(400))
        let after = try await client.readStatus()
        await client.disconnect()

        #expect(after.slewing == false)
        #expect(after.horizontal == before)
    }

    @Test func stopDuringAPollDoesNotDisturbIt() async throws {
        let server = try SimulatorServer(flavor: .aux, port: 0, sky: SimulatedSky(trackSeconds: 60, slewSeconds: 5))
        try await server.start()
        defer { server.stop() }
        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)), motionPolicy: { .darkTestSky })
        try await client.connect()

        for _ in 0 ..< 3 {
            async let status = client.readStatus()
            try await client.stop()
            #expect(try await status.horizontal != nil)
        }
        await client.disconnect()
    }

    @Test(arguments: [0.5, -1.0])
    func nudgeTurnsTheAzimuthMotorByTheStep(_ step: Double) async throws {
        let server = try SimulatorServer(flavor: .aux, port: 0, sky: SimulatedSky(trackSeconds: 60, slewSeconds: 5))
        try await server.start()
        defer { server.stop() }
        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)), motionPolicy: { .darkTestSky })
        try await client.connect()

        let before = try #require(try await client.readStatus().horizontal)
        try await client.nudge(.azimuth, by: step)
        #expect(try await client.readStatus().slewing == true)
        try await Task.sleep(for: .seconds(abs(step) * 1.5 + 0.3))
        let after = try await client.readStatus()
        await client.disconnect()

        #expect(after.slewing == false)
        let h = try #require(after.horizontal)
        #expect(abs(h.azimuth - before.azimuth - step) < 0.05)
        #expect(abs(h.altitude - before.altitude) < 0.05)
    }

    @Test(arguments: [0.1, -0.1])
    func altitudeNudgeMovesOnlyTheAltitudeMotor(_ step: Double) async throws {
        let server = try SimulatorServer(flavor: .aux, port: 0, sky: SimulatedSky(trackSeconds: 60, slewSeconds: 5))
        try await server.start()
        defer { server.stop() }
        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)), motionPolicy: { .darkTestSky })
        try await client.connect()

        let before = try #require(try await client.readStatus().horizontal)
        try await client.nudge(.altitude, by: step)
        try await Task.sleep(for: .seconds(0.6))
        let after = try await client.readStatus()
        await client.disconnect()

        #expect(after.slewing == false)
        let h = try #require(after.horizontal)
        #expect(abs(h.altitude - before.altitude - step) < 0.01)
        #expect(abs(h.azimuth - before.azimuth) < 0.01)
    }

    @Test func nudgeIsRefusedWhileTheMountIsMoving() async throws {
        let sky = SimulatedSky(trackSeconds: 0.01, slewSeconds: 30, start: .now.addingTimeInterval(-1))
        let server = try SimulatorServer(flavor: .aux, port: 0, sky: sky)
        try await server.start()
        defer { server.stop() }
        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)), motionPolicy: { .darkTestSky })
        try await client.connect()

        await #expect(throws: MountError.self) { try await client.nudge(.azimuth, by: 0.5) }
        await client.disconnect()
    }

    @Test func stopHaltsANudgePartWay() async throws {
        let server = try SimulatorServer(flavor: .aux, port: 0, sky: SimulatedSky(trackSeconds: 60, slewSeconds: 5))
        try await server.start()
        defer { server.stop() }
        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)), motionPolicy: { .darkTestSky })
        try await client.connect()

        let start = try #require(try await client.readStatus().horizontal).azimuth
        try await client.nudge(.azimuth, by: 1)
        try await Task.sleep(for: .milliseconds(300))
        try await client.stop()
        let stopped = try #require(try await client.readStatus().horizontal).azimuth
        try await Task.sleep(for: .seconds(1.5))
        let later = try await client.readStatus()
        await client.disconnect()

        #expect(later.slewing == false)
        #expect(stopped - start > 0.05 && stopped - start < 0.9)
        #expect(abs(try #require(later.horizontal).azimuth - stopped) < 0.02) // only sidereal drift
    }

    /// A simulator that's tracking (not slewing) for the whole test, and a connected AUX client.
    private func trackingMount() async throws -> (SimulatorServer, AuxClient) {
        let server = try SimulatorServer(flavor: .aux, port: 0, sky: SimulatedSky(trackSeconds: 60, slewSeconds: 5))
        try await server.start()
        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)), motionPolicy: { .darkTestSky })
        try await client.connect()
        return (server, client)
    }

    @Test func timeLimitStopsAHeldMove() async throws {
        let (server, client) = try await trackingMount()
        defer { server.stop() }
        let timedOut = Box(false)
        let held = HeldMove(client: client, timeLimit: .milliseconds(500))

        let start = try #require(try await client.readStatus().horizontal).azimuth
        try await held.begin(.azimuth, positive: true, onEnded: { _ in _ = timedOut.swap(true) })
        try await Task.sleep(for: .seconds(1.2)) // never released
        let stopped = try await client.readStatus()
        try await Task.sleep(for: .seconds(1))
        let later = try #require(try await client.readStatus().horizontal).azimuth
        await client.disconnect()

        #expect(timedOut.swap(false))
        #expect(stopped.slewing == false)
        let moved = try #require(stopped.horizontal).azimuth - start
        #expect(moved > 0.1 && moved < 1) // about 0.5 s of travel, far short of the 5° target
        #expect(abs(later - start - moved) < 0.02)
    }

    @Test func releasingStopsAHeldMoveAndTheTimerStaysQuiet() async throws {
        let (server, client) = try await trackingMount()
        defer { server.stop() }
        let timedOut = Box(false)
        let held = HeldMove(client: client, timeLimit: .seconds(1))

        let start = try #require(try await client.readStatus().horizontal).azimuth
        try await held.begin(.azimuth, positive: false, onEnded: { _ in _ = timedOut.swap(true) })
        try await Task.sleep(for: .milliseconds(300))
        try await held.end()
        try await Task.sleep(for: .seconds(1.2)) // past the time limit
        let after = try await client.readStatus()
        await client.disconnect()

        #expect(!timedOut.swap(false))
        #expect(after.slewing == false)
        let moved = try #require(after.horizontal).azimuth - start
        #expect(moved < -0.05 && moved > -0.5)
    }

    @Test func aQuickTapNeverLeavesTheMountMoving() async throws {
        let (server, client) = try await trackingMount()
        defer { server.stop() }
        let held = HeldMove(client: client)

        let start = try #require(try await client.readStatus().horizontal).azimuth
        try await held.begin(.azimuth, positive: true)
        try await held.end()
        try await Task.sleep(for: .milliseconds(500))
        let after = try await client.readStatus()
        await client.disconnect()

        #expect(after.slewing == false)
        #expect(abs(try #require(after.horizontal).azimuth - start) < 0.1)
    }

    @Test func holdingUpMovesOnlyAltitude() async throws {
        let (server, client) = try await trackingMount()
        defer { server.stop() }
        let held = HeldMove(client: client)

        let before = try #require(try await client.readStatus().horizontal)
        try await held.begin(.altitude, positive: true)
        try await Task.sleep(for: .milliseconds(400))
        try await held.end()
        let after = try #require(try await client.readStatus().horizontal)
        await client.disconnect()

        #expect(after.altitude - before.altitude > 0.05 && after.altitude - before.altitude < 1.5)
        #expect(abs(after.azimuth - before.azimuth) < 0.01)
    }

    @Test func aSecondPressIsRefusedWhileOneIsHeld() async throws {
        let (server, client) = try await trackingMount()
        defer { server.stop() }
        let held = HeldMove(client: client)

        try await held.begin(.azimuth, positive: true)
        await #expect(throws: MountError.self) { try await held.begin(.altitude, positive: true) }
        try await held.end()
        await client.disconnect()
    }

    @Test func startingOnABusyPortThrowsInsteadOfHanging() async throws {
        let first = try SimulatorServer(flavor: .handController, port: 0)
        try await first.start()
        defer { first.stop() }

        let second = try SimulatorServer(flavor: .handController, port: try #require(first.port))
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) { try await second.start() }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func stoppingDropsConnectedClients() async throws {
        let server = try SimulatorServer(flavor: .handController, port: 0)
        try await server.start()
        let client = HandControllerClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)))
        try await client.connect()

        server.stop()
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: MountError.self) { try await client.readStatus() }
        await client.disconnect()
    }

    @Test func connectingToNothingFailsQuickly() async throws {
        let client = HandControllerClient(transport: TCPTransport(host: "127.0.0.1", port: 1))
        let start = ContinuousClock.now
        await #expect(throws: MountError.self) { try await client.connect() }
        #expect(ContinuousClock.now - start < .seconds(6))
    }
}
