import Foundation
import Testing
@testable import NexStarSimulator
@testable import ScopeKit

/// Go to and Return to home slew the long part of each leg at the mount's normal speed, keeping to what the mount
/// taught us: never across a motor's zero, one slew per stretch from rest, and the final approach in slow steps.
@Suite("Slewing", .serialized)
struct SlewTests {
    private func raw(_ degrees: Double) -> UInt32 { UInt32((degrees / 360 * 16_777_216).rounded()) }

    @Test func aSlewStopsShortOfTheMotorsZero() {
        #expect(SlewCommand.plan(.azimuth, degrees: 30, fromRaw: 350) == 9, "up to 359°, not across zero")
        #expect(SlewCommand.plan(.azimuth, degrees: -30, fromRaw: 10) == -9, "down to 1°")
        #expect(SlewCommand.plan(.azimuth, degrees: 30, fromRaw: 0.5) == nil, "starting too near zero: slow steps first")
        #expect(SlewCommand.plan(.azimuth, degrees: 5, fromRaw: 357) == nil, "too little left before zero to be worth it")
        #expect(SlewCommand.plan(.azimuth, degrees: 250, fromRaw: 100) == 180, "at most half a turn")
        #expect(SlewCommand.plan(.altitude, degrees: 2, fromRaw: 20) == nil, "short moves go in slow steps")
    }

    @Test func theCheckRefusesASlewAcrossZeroTooFarOrOutOfTheBand() throws {
        let across = AuxPacket(source: AuxDevice.app.rawValue, destination: AuxDevice.azimuthMotor.rawValue,
                               command: SlewCommand.auxCommand, data: [0x00, 0x2E, 0x8C]).encoded() // about 1° from 359.5°
        #expect(throws: MountError.self) { try SlewCommand.check(across, axis: .azimuth, currentPosition: self.raw(359.5)) }

        let tooFar = SlewCommand.packet(.azimuth, from: raw(10), by: 200)
        #expect(throws: MountError.self) { try SlewCommand.check(tooFar, axis: .azimuth, currentPosition: self.raw(10)) }

        let pastTheBand = SlewCommand.packet(.altitude, from: raw(40), by: 45)
        #expect(throws: MountError.self) { try SlewCommand.check(pastTheBand, axis: .altitude, currentPosition: self.raw(40)) }

        let fine = SlewCommand.packet(.azimuth, from: raw(10), by: 170)
        try SlewCommand.check(fine, axis: .azimuth, currentPosition: raw(10))
    }

    /// A parked simulated mount at `start`, with slews six times faster than slow steps (like the real one), whose
    /// fast GoTo goes the long way round if asked to cross zero.
    private func mount(at start: Horizontal) async throws -> (SimulatorServer, AuxClient, Box<[String]>) {
        let server = try SimulatorServer(flavor: .aux, port: 0, mount: SimulatedMount(sky: .parked(at: start), secondsPerDegree: 0.03))
        try await server.start()
        let sent = Box<[String]>([])
        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)), log: { entry in
            if entry.direction == .sent { _ = sent.swap(sent.swap([]) + [entry.text]) }
        }, motionPolicy: { .darkTestSky })
        try await client.connect()
        return (server, client, sent)
    }

    private func drive(_ client: AuxClient, _ legs: [HeldMove.Leg]) async throws -> HeldMove.Ending? {
        let ending = Box<HeldMove.Ending?>(nil)
        try await HeldMove(client: client).goTo(legs, onEnded: { _ = ending.swap($0) })
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if let value = ending.swap(nil) { return value }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    @Test func aLongGoToSlewsOnceThenFinishesInSlowSteps() async throws {
        let (server, client, sent) = try await mount(at: Horizontal(azimuth: 100, altitude: 20))
        defer { server.stop() }
        #expect(try await drive(client, [.init(axis: .azimuth, target: 190, positive: true)]) == .arrived)
        let after = try #require(try await client.readStatus().horizontal)
        await client.disconnect()

        #expect(abs(after.azimuth - 190) < 0.05, "azimuth \(after.azimuth)°")
        let log = sent.swap([])
        #expect(log.filter { $0.contains("(slew ") }.count == 1, "one slew for the stretch: \(log.filter { $0.contains("slew") })")
        #expect(log.contains { $0.contains("(move ") }, "the final approach is a slow step")
    }

    @Test func aGoToAcrossTheAzimuthZeroGetsThereTheShortWay() async throws {
        // 340° → 30° going up: a slew to 359°, slow steps across zero, then a slew on. Across zero in one slew, the
        // mount (like the real one) would go the long way round instead.
        let (server, client, sent) = try await mount(at: Horizontal(azimuth: 340, altitude: 20))
        defer { server.stop() }
        #expect(try await drive(client, [.init(axis: .azimuth, target: 30, positive: true)]) == .arrived)
        let after = try #require(try await client.readStatus().horizontal)
        await client.disconnect()

        #expect(abs(Astronomy.shortTurn(from: after.azimuth, to: 30)) < 0.05, "azimuth \(after.azimuth)°")
        #expect(sent.swap([]).filter { $0.contains("(slew ") }.count == 2)
    }

    @Test func aGoToUpFromJustBelowTheAltitudeZeroDoesntRunAway() async throws {
        // What went wrong on the mount: from −1.17°, a fast GoTo upward drove it down. Now the slow steps cross zero.
        let (server, client, _) = try await mount(at: Horizontal(azimuth: 100, altitude: -1.17))
        defer { server.stop() }
        #expect(try await drive(client, [.init(axis: .altitude, target: 30, positive: true)]) == .arrived)
        let after = try #require(try await client.readStatus().horizontal)
        await client.disconnect()
        #expect(abs(after.altitude - 30) < 0.05, "altitude \(after.altitude)°")
    }

    @Test func aSlewIsCheckedAgainstTheSunAlongTheWholeWay() async throws {
        // At noon, 60° west of the Sun at its altitude: a slew to 60° east of it would pass straight through it.
        let observer = Observer(latitude: 38.89, longitude: -77.03)
        let noon = Date(timeIntervalSince1970: 1_791_651_600)
        let sun = Astronomy.horizontal(Astronomy.sunPosition(at: noon), at: noon, observer: observer)
        let server = try SimulatorServer(flavor: .aux, port: 0, mount: SimulatedMount(
            sky: .parked(at: Horizontal(azimuth: Astronomy.normalize(sun.azimuth - 60), altitude: sun.altitude)), secondsPerDegree: 0.03))
        try await server.start()
        defer { server.stop() }
        let sent = Box<[String]>([])
        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)), log: { entry in
            if entry.direction == .sent { _ = sent.swap(sent.swap([]) + [entry.text]) }
        }, motionPolicy: { MotionPolicy(observer: observer, lockWhileSunUp: false, date: noon) })
        try await client.connect()

        do {
            try await HeldMove(client: client).goTo([.init(axis: .azimuth, target: Astronomy.normalize(sun.azimuth + 60), positive: true)])
            Issue.record("the slew should have been refused")
        } catch MountError.refused(let reason) {
            #expect(reason.contains("Sun"), "\(reason)")
        }
        await client.disconnect()
        #expect(!sent.swap([]).contains { $0.contains("(slew ") || $0.contains("(move ") }, "nothing moved")
    }
}
