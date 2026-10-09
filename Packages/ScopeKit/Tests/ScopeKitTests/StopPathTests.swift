import Foundation
import Testing
@testable import NexStarSimulator
@testable import ScopeKit

@Suite("Stop path regressions", .serialized)
struct StopPathTests {
    /// Both stops go out back to back and each motor answers at its own pace, so the altitude acknowledgement
    /// may arrive first. It must not be thrown away while waiting for the azimuth one.
    @Test func stopSucceedsWhenAltitudeAnswersBeforeAzimuth() async throws {
        let transport = ScriptedTransport()
        let app = AuxDevice.app.rawValue
        transport.onWrite = { bytes in
            guard bytes[3] == AuxDevice.altitudeMotor.rawValue else { return [] }
            let altAck = AuxPacket(source: AuxDevice.altitudeMotor.rawValue, destination: app, command: StopCommand.auxCommand).encoded()
            let azAck = AuxPacket(source: AuxDevice.azimuthMotor.rawValue, destination: app, command: StopCommand.auxCommand).encoded()
            return altAck + azAck
        }
        let client = AuxClient(transport: transport, motionPolicy: { .darkTestSky })
        try await client.stop()
        #expect(transport.written.count == 2)
    }

    /// A reply kept over from one exchange (here an unasked-for "azimuth done") must not answer the next request.
    @Test func leftoverReplyIsNotTakenForTheNextRequest() async throws {
        let transport = ScriptedTransport()
        let app = AuxDevice.app.rawValue
        let slewDone = AuxQuery.slewDone.rawValue
        transport.onWrite = { bytes in
            switch bytes[3] {
            case AuxDevice.altitudeMotor.rawValue:
                AuxPacket(source: AuxDevice.azimuthMotor.rawValue, destination: app, command: slewDone, data: [0xFF]).encoded()
                    + AuxPacket(source: AuxDevice.altitudeMotor.rawValue, destination: app, command: slewDone, data: [0xFF]).encoded()
            default:
                AuxPacket(source: AuxDevice.azimuthMotor.rawValue, destination: app, command: slewDone, data: [0x00]).encoded()
            }
        }
        let client = AuxClient(transport: transport, motionPolicy: { .darkTestSky })
        #expect(try await client.request(.slewDone, to: .altitudeMotor) == [0xFF])
        #expect(try await client.request(.slewDone, to: .azimuthMotor) == [0x00], "got the leftover reply from the previous exchange")
    }

    /// A hold that is refused because the mount is already moving must not send anything, and must not halt the
    /// slew that was in progress (e.g. a GoTo started from the hand controller).
    @Test func refusedHoldSendsNothing() async throws {
        let sky = SimulatedSky(trackSeconds: 0.01, slewSeconds: 30, start: .now.addingTimeInterval(-1))
        let server = try SimulatorServer(flavor: .aux, port: 0, sky: sky)
        try await server.start()
        defer { server.stop() }

        let sent = Box<[String]>([])
        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)), log: { entry in
            if entry.direction == .sent { _ = sent.swap(sent.swap([]) + [entry.text]) }
        }, motionPolicy: { .darkTestSky })
        try await client.connect()
        #expect(try await client.readStatus().slewing == true)

        let held = HeldMove(client: client)
        await #expect(throws: MountError.self) { try await held.begin(.azimuth, positive: true) }
        try await Task.sleep(for: .milliseconds(300))
        let after = try await client.readStatus()
        await client.disconnect()

        let stops = sent.swap([]).filter { $0.contains("stop →") }
        #expect(stops.isEmpty, "a refused move must not emit any command; sent \(stops.count) stops")
        #expect(after.slewing == true, "the slew in progress was halted by the refused hold")
    }
}
