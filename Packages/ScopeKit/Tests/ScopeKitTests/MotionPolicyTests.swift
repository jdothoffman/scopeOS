import Foundation
import Testing
@testable import NexStarSimulator
@testable import ScopeKit

/// The Sun rules are enforced by the client itself, so they hold for every caller, not just the app.
@Suite("Sun rules in the client")
struct MotionPolicyTests {
    static let observer = Observer(latitude: 38.89, longitude: -77.04)
    /// Local noon in January: the Sun is about 30° up in the south.
    static let noon = Date(timeIntervalSince1970: 1_768_496_400)
    static let sun = Astronomy.horizontal(Astronomy.sunPosition(at: noon), at: noon, observer: observer)

    /// A mount sitting still at `pointing` (uncalibrated, so motor angles are sky angles).
    private func mount(at pointing: Horizontal, policy: MotionPolicy?) -> (AuxClient, ScriptedTransport) {
        let transport = ScriptedTransport()
        transport.onWrite = { bytes in
            guard let packet = AuxPacket.decodeSingle(bytes) else { return [] }
            let reply: [UInt8]? = switch packet.command {
            case AuxQuery.slewDone.rawValue: [0xFF]
            case AuxQuery.getPosition.rawValue:
                Encode.fraction24(packet.destination == AuxDevice.azimuthMotor.rawValue ? pointing.azimuth : pointing.altitude)
            case NudgeCommand.auxCommand: []
            default: nil
            }
            return reply.map { AuxPacket(source: packet.destination, destination: AuxDevice.app.rawValue, command: packet.command, data: $0).encoded() } ?? []
        }
        let client = policy.map { policy in AuxClient(transport: transport, motionPolicy: { policy }) } ?? AuxClient(transport: transport)
        return (client, transport)
    }

    private func moves(_ transport: ScriptedTransport) -> Int {
        transport.written.compactMap(AuxPacket.decodeSingle).filter { $0.command == NudgeCommand.auxCommand }.count
    }

    private func refusal(_ operation: () async throws -> Void) async -> String? {
        do {
            try await operation()
            return nil
        } catch MountError.refused(let reason) {
            return reason
        } catch {
            return "unexpected \(error)"
        }
    }

    private var nearTheSun: Horizontal { Horizontal(azimuth: Self.sun.azimuth - 10, altitude: Self.sun.altitude) }

    @Test func aNudgeTowardTheSunIsRefusedAndSendsNothing() async {
        let (client, transport) = mount(at: nearTheSun, policy: MotionPolicy(observer: Self.observer, lockWhileSunUp: false, date: Self.noon))
        let reason = await refusal { try await client.nudge(.azimuth, by: 1) }
        #expect(reason?.contains("Sun") == true, "\(String(describing: reason))")
        #expect(moves(transport) == 0)
    }

    @Test func aNudgeAwayFromTheSunGoesThrough() async {
        let (client, transport) = mount(at: nearTheSun, policy: MotionPolicy(observer: Self.observer, lockWhileSunUp: false, date: Self.noon))
        #expect(await refusal { try await client.nudge(.azimuth, by: -1) } == nil)
        #expect(moves(transport) == 1)
    }

    @Test func holdsAreCheckedToo() async {
        let (client, transport) = mount(at: nearTheSun, policy: MotionPolicy(observer: Self.observer, lockWhileSunUp: false, date: Self.noon))
        let held = HeldMove(client: client)
        #expect(await refusal { try await held.begin(.azimuth, positive: true) } != nil)
        #expect(moves(transport) == 0)
    }

    @Test func withoutALocationEveryMoveIsRefused() async {
        let (client, transport) = mount(at: Horizontal(azimuth: 10, altitude: 40), policy: nil)
        let reason = await refusal { try await client.nudge(.azimuth, by: 1) }
        #expect(reason?.contains("location") == true, "\(String(describing: reason))")
        #expect(moves(transport) == 0)
    }

    @Test func theDaylightLockRefusesEveryMoveWhileTheSunIsUp() async {
        let farFromTheSun = Horizontal(azimuth: Self.sun.azimuth + 180, altitude: 40)
        let (client, transport) = mount(at: farFromTheSun, policy: MotionPolicy(observer: Self.observer, lockWhileSunUp: true, date: Self.noon))
        let reason = await refusal { try await client.nudge(.altitude, by: 1) }
        #expect(reason?.contains("Sun is up") == true, "\(String(describing: reason))")
        #expect(moves(transport) == 0)

        let (unlocked, unlockedTransport) = mount(at: farFromTheSun, policy: MotionPolicy(observer: Self.observer, lockWhileSunUp: false, date: Self.noon))
        #expect(await refusal { try await unlocked.nudge(.altitude, by: 1) } == nil)
        #expect(moves(unlockedTransport) == 1)
    }
}
