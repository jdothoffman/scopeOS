import Foundation
import Testing
@testable import NexStarSimulator
@testable import ScopeKit

@Suite("Focus command")
struct FocusCommandTests {
    let limits = 1_000 ... 39_000 // max step 7,600

    @Test func encodesAGotoOfTheFocusMotor() throws {
        let bytes = FocusCommand.packet(to: 20_250)
        #expect(Array(bytes.prefix(5)) == [0x3B, 0x06, 0x20, 0x12, 0x02])
        #expect(Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7]) == 20_250)
        try FocusCommand.check(bytes, current: 20_000, limits: limits)
    }

    @Test func blocksTargetsOutsideTheCalibratedRange() {
        #expect(throws: MountError.self) { try FocusCommand.check(FocusCommand.packet(to: 999), current: 1_500, limits: limits) }
        #expect(throws: MountError.self) { try FocusCommand.check(FocusCommand.packet(to: 39_001), current: 38_500, limits: limits) }
        #expect(throws: Never.self) { try FocusCommand.check(FocusCommand.packet(to: 39_000), current: 38_500, limits: limits) }
    }

    @Test func blocksStepsLargerThanAFifthOfTheRange() {
        #expect(throws: MountError.self) { try FocusCommand.check(FocusCommand.packet(to: 27_601), current: 20_000, limits: limits) }
        #expect(throws: Never.self) { try FocusCommand.check(FocusCommand.packet(to: 27_600), current: 20_000, limits: limits) }
    }

    @Test func blocksOtherMotorsCommandsAndUncalibratedRanges() {
        let wrong: [[UInt8]] = [
            AuxPacket(source: 0x20, destination: 0x10, command: 0x02, data: [0, 0x4F, 0x1A]).encoded(), // azimuth motor
            AuxPacket(source: 0x20, destination: 0x12, command: 0x17, data: [0, 0x4F, 0x1A]).encoded(), // other goto
            AuxPacket(source: 0x20, destination: 0x12, command: 0x02, data: [0x4F, 0x1A]).encoded(),
        ]
        for payload in wrong {
            #expect(throws: MountError.self) { try FocusCommand.check(payload, current: 20_000, limits: limits) }
        }
        #expect(throws: MountError.self) { try FocusCommand.check(FocusCommand.packet(to: 20_000), current: 20_000, limits: 0 ... 0) }
    }

    @Test func parsesCalibratedLimitsAndRejectsUncalibratedOnes() {
        #expect(FocusCommand.limits(fromReply: [0, 0, 0x03, 0xE8, 0, 0, 0x98, 0x58]) == 1_000 ... 39_000)
        #expect(FocusCommand.limits(fromReply: [0, 0, 0, 0, 0, 0, 0, 0]) == nil) // not calibrated
        #expect(FocusCommand.limits(fromReply: [0, 0, 0x98, 0x58, 0, 0, 0x03, 0xE8]) == nil) // backwards
        #expect(FocusCommand.limits(fromReply: [0, 0, 0x03]) == nil)
    }

    @Test func guardsKnowTheFocusPackets() throws {
        try StopCommand.check(StopCommand.focuser)
        try ReadOnlyGuard.checkAux(AuxPacket.query(.focuserLimits, to: .focuser).encoded())
        #expect(throws: MountError.self) { try ReadOnlyGuard.checkAux(FocusCommand.packet(to: 20_000)) }
    }
}

@Suite("Focus motor end to end", .serialized)
struct FocusIntegrationTests {
    private func focuserMount() async throws -> (SimulatorServer, AuxClient) {
        let server = try SimulatorServer(flavor: .aux, port: 0, sky: SimulatedSky(trackSeconds: 60, slewSeconds: 5), focuser: true)
        try await server.start()
        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)))
        try await client.connect()
        return (server, client)
    }

    @Test func readsPositionAndCalibratedLimits() async throws {
        let (server, client) = try await focuserMount()
        defer { server.stop() }
        let status = try await client.readStatus()
        await client.disconnect()
        #expect(status.focuserPosition == 20_000)
        #expect(status.focuserLimits == SimulatorServer.focuserLimits)
        #expect(status.focuserMoving == false)
        #expect(status.devices.map(\.name).contains("Focus motor"))
    }

    @Test func focusStepsMoveByTheStepAndStopAtTheLimits() async throws {
        let (server, client) = try await focuserMount()
        defer { server.stop() }

        try await client.focus(by: 250)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await client.readStatus().focuserPosition == 20_250)

        try await client.focus(by: -7_600) // the largest allowed step
        try await Task.sleep(for: .seconds(4.2))
        #expect(try await client.readStatus().focuserPosition == 12_650)

        await #expect(throws: MountError.self) { try await client.focus(by: 7_601) } // over a fifth of the range
        try await client.focus(by: -7_600)
        try await Task.sleep(for: .seconds(4.2))
        await #expect(throws: MountError.self) { try await client.focus(by: -7_600) } // would pass the lower limit
        await client.disconnect()
    }

    /// "Go to best" sends an absolute position, so a reading from before the focuser last moved can't throw it off.
    @Test func focusingToAPositionLandsExactlyEvenFromAStaleReading() async throws {
        let (server, client) = try await focuserMount()
        defer { server.stop() }
        let stale = try #require(try await client.readStatus().focuserPosition)
        try await client.focus(by: 1_000)
        try await Task.sleep(for: .seconds(1))

        try await client.focus(to: stale + 500)
        try await Task.sleep(for: .seconds(1))
        #expect(try await client.readStatus().focuserPosition == stale + 500)
        try await client.focus(to: stale + 500) // already there: nothing to do

        await #expect(throws: MountError.self) { try await client.focus(to: stale + 500 + 7_601) } // over one move
        await #expect(throws: MountError.self) { try await client.focus(to: 1_000_000) } // outside the calibrated range
        await client.disconnect()
    }

    @Test func holdingFocusStopsAtTheTimeLimitWithoutTouchingTheMount() async throws {
        let (server, client) = try await focuserMount()
        defer { server.stop() }
        let mountBefore = try #require(try await client.readStatus().horizontal)
        let held = HeldMove(client: client, focusTimeLimit: .milliseconds(500))

        try await held.beginFocus(positive: true)
        try await Task.sleep(for: .seconds(1))
        let after = try await client.readStatus()
        await client.disconnect()

        let moved = try #require(after.focuserPosition) - 20_000
        #expect(moved > 500 && moved < 1_600) // about half a second at 2,000 steps/s, short of the 3,800-step reach
        #expect(after.focuserMoving == false)
        #expect(after.slewing == false)
        #expect(abs(try #require(after.horizontal).azimuth - mountBefore.azimuth) < 0.02)
    }

    @Test func stopTelescopeAlsoStopsTheFocuser() async throws {
        let (server, client) = try await focuserMount()
        defer { server.stop() }
        try await client.focus(by: 7_000)
        try await Task.sleep(for: .milliseconds(300))
        try await client.stop()
        let stopped = try #require(try await client.readStatus().focuserPosition)
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await client.readStatus().focuserPosition == stopped)
        await client.disconnect()
    }

    @Test func focusingIsRefusedWithoutAFocusMotor() async throws {
        let server = try SimulatorServer(flavor: .aux, port: 0)
        try await server.start()
        defer { server.stop() }
        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)))
        try await client.connect()
        await #expect(throws: MountError.self) { try await client.focus(by: 10) }
        await client.disconnect()
    }
}

@Suite("Focuser readings")
struct FocuserReadingTests {
    /// A mount with a focus motor whose position replies can be switched off, to imitate slow replies.
    private func mount(silent: Box<Bool>) -> AuxClient {
        let transport = ScriptedTransport()
        transport.onWrite = { bytes in
            guard let packet = AuxPacket.decodeSingle(bytes) else { return [] }
            let device = AuxDevice(rawValue: packet.destination)
            let reply: [UInt8]? = switch (device, packet.command) {
            case (.azimuthMotor?, AuxQuery.getVersion.rawValue), (.altitudeMotor?, AuxQuery.getVersion.rawValue), (.focuser?, AuxQuery.getVersion.rawValue): [7, 11]
            case (.azimuthMotor?, AuxQuery.getPosition.rawValue), (.altitudeMotor?, AuxQuery.getPosition.rawValue): [0, 0, 0]
            case (_, AuxQuery.slewDone.rawValue): [0xFF]
            case (.focuser?, AuxQuery.focuserLimits.rawValue): [0, 0, 0x09, 0x75, 0, 0, 0xB3, 0xA6] // 2,421–45,990
            case (.focuser?, AuxQuery.getPosition.rawValue): Self.peek(silent) ? nil : [0, 0x4E, 0x20] // 20,000
            default: nil
            }
            return reply.map { AuxPacket(source: packet.destination, destination: AuxDevice.app.rawValue, command: packet.command, data: $0).encoded() } ?? []
        }
        return AuxClient(transport: transport)
    }

    /// Reads a `Box` without changing it.
    private static func peek(_ box: Box<Bool>) -> Bool {
        let value = box.swap(false)
        _ = box.swap(value)
        return value
    }

    @Test func aMissedReadingOrTwoKeepsTheLastPositionAndTheLimits() async throws {
        let silent = Box(false)
        let client = mount(silent: silent)
        try await client.connect()
        #expect(try await client.readStatus().focuserPosition == 20_000)

        _ = silent.swap(true)
        for _ in 0 ..< AuxClient.focuserMissesAllowed {
            let status = try await client.readStatus()
            #expect(status.focuserPosition == 20_000, "a missed reading keeps the last position")
            #expect(status.focuserLimits == 2_421 ... 45_990, "the limits never go missing")
        }
        let gone = try await client.readStatus()
        #expect(gone.focuserPosition == nil, "after several misses the position is unknown")
        #expect(gone.focuserLimits == 2_421 ... 45_990)

        _ = silent.swap(false)
        #expect(try await client.readStatus().focuserPosition == 20_000)
    }
}
