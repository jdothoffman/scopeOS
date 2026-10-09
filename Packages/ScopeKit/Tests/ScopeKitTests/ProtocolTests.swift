import Foundation
import Testing
@testable import ScopeKit

@Suite("AUX packets")
struct AuxPacketTests {
    @Test func encodesKnownHandControllerPositionQuery() {
        // Hand controller (0x0D) asking the azimuth motor (0x10) for its position: a commonly logged packet.
        let packet = AuxPacket(source: 0x0D, destination: 0x10, command: 0x01)
        #expect(packet.encoded() == [0x3B, 0x03, 0x0D, 0x10, 0x01, 0xDF])
    }

    @Test func roundTripsWithData() {
        let packet = AuxPacket(source: 0x10, destination: 0x20, command: 0x01, data: [0x12, 0x34, 0x56])
        var buffer = packet.encoded()
        #expect(AuxPacket.extract(from: &buffer) == [packet])
        #expect(buffer.isEmpty)
    }

    @Test func skipsNoiseAndBadChecksumsAndKeepsPartialPackets() {
        let good = AuxPacket(source: 0x11, destination: 0x20, command: 0x13, data: [0xFF]).encoded()
        var corrupt = AuxPacket(source: 0x10, destination: 0x20, command: 0x01, data: [1, 2, 3]).encoded()
        corrupt[corrupt.count - 1] ^= 0xFF
        let partial = Array(good.prefix(3))

        var buffer: [UInt8] = [0x00, 0x99] + corrupt + good + partial
        let packets = AuxPacket.extract(from: &buffer)
        #expect(packets.count == 1)
        #expect(packets.first?.data == [0xFF])
        #expect(buffer == partial)

        buffer += good.dropFirst(3)
        #expect(AuxPacket.extract(from: &buffer).count == 1)
    }
}

@Suite("Read-only guard")
struct ReadOnlyGuardTests {
    @Test func allowsEveryHandControllerQuery() throws {
        for command in HandControllerCommand.allCases {
            try ReadOnlyGuard.checkHandController([command.byte])
        }
    }

    @Test(arguments: ["R", "r", "B", "b", "P", "T", "S", "W", "H", "M", "s"])
    func blocksHandControllerMotionAndSetCommands(_ command: Character) {
        #expect(throws: MountError.self) { try ReadOnlyGuard.checkHandController([command.asciiValue!]) }
    }

    @Test func blocksMultiByteHandControllerPayloads() {
        #expect(throws: MountError.self) { try ReadOnlyGuard.checkHandController([UInt8(ascii: "e"), UInt8(ascii: "R")]) }
    }

    @Test func allowsAuxQueries() throws {
        for query in AuxQuery.allCases {
            try ReadOnlyGuard.checkAux(AuxPacket.query(query, to: query.destinations?.first ?? .azimuthMotor).encoded())
        }
    }

    /// 0x2C reads the focuser's limits but sets the cord-wrap position on the motor controllers.
    @Test func scopesFocuserLimitsQueryToTheFocuser() throws {
        try ReadOnlyGuard.checkAux(AuxPacket.query(.focuserLimits, to: .focuser).encoded())
        for motor in [AuxDevice.azimuthMotor, .altitudeMotor] {
            #expect(throws: MountError.self) { try ReadOnlyGuard.checkAux(AuxPacket.query(.focuserLimits, to: motor).encoded()) }
        }
    }

    @Test(arguments: [UInt8(0x02), 0x04, 0x06, 0x17, 0x24, 0x25])
    func blocksAuxMotionCommands(_ command: UInt8) {
        let packet = AuxPacket(source: 0x20, destination: 0x10, command: command).encoded()
        #expect(throws: MountError.self) { try ReadOnlyGuard.checkAux(packet) }
    }

    @Test func blocksAuxQueryCarryingData() {
        let packet = AuxPacket(source: 0x20, destination: 0x10, command: 0x01, data: [0x00]).encoded()
        #expect(throws: MountError.self) { try ReadOnlyGuard.checkAux(packet) }
    }
}

@Suite("Stop commands")
struct StopCommandTests {
    @Test func stopPacketsAreRateZeroMoveCommandsToEachMotor() throws {
        #expect(StopCommand.aux.map(\.bytes) == [
            [0x3B, 0x04, 0x20, 0x10, 0x24, 0x00, 0xA8],
            [0x3B, 0x04, 0x20, 0x11, 0x24, 0x00, 0xA7],
        ])
        for (_, bytes) in StopCommand.aux { try StopCommand.check(bytes) }
        try StopCommand.check(StopCommand.handController)
    }

    @Test(arguments: [UInt8(1), 2, 5, 9])
    func blocksNonZeroRates(_ rate: UInt8) {
        for device in [AuxDevice.azimuthMotor, .altitudeMotor] {
            let packet = AuxPacket(source: 0x20, destination: device.rawValue, command: StopCommand.auxCommand, data: [rate]).encoded()
            #expect(throws: MountError.self) { try StopCommand.check(packet) }
        }
    }

    @Test func blocksAnythingElse() {
        let attempts: [[UInt8]] = [
            AuxPacket(source: 0x20, destination: 0x10, command: 0x25, data: [9]).encoded(), // move negative
            AuxPacket(source: 0x20, destination: 0x10, command: 0x02, data: [0, 0, 0]).encoded(), // goto
            AuxPacket(source: 0x20, destination: 0x12, command: 0x24, data: [5]).encoded(), // focuser moving, not stopping
            Array("R".utf8), Array("MM".utf8), Array("e".utf8), [],
        ]
        for payload in attempts {
            #expect(throws: MountError.self) { try StopCommand.check(payload) }
        }
    }

    @Test func queryGuardStillRejectsStops() {
        #expect(throws: MountError.self) { try ReadOnlyGuard.checkHandController(StopCommand.handController) }
        for (_, bytes) in StopCommand.aux {
            #expect(throws: MountError.self) { try ReadOnlyGuard.checkAux(bytes) }
        }
    }
}

@Suite("Nudge command")
struct NudgeCommandTests {
    static let oneDegree = 46_603 // round(2^24 / 360)

    static func counts(_ degrees: Double) -> UInt32 {
        UInt32((((degrees / 360 * 16_777_216).rounded()).truncatingRemainder(dividingBy: 16_777_216) + 16_777_216)
            .truncatingRemainder(dividingBy: 16_777_216))
    }

    static func rawPacket(to motor: UInt8, target: UInt32) -> [UInt8] {
        AuxPacket(source: 0x20, destination: motor, command: 0x17,
                  data: [UInt8(target >> 16), UInt8(target >> 8 & 0xFF), UInt8(target & 0xFF)]).encoded()
    }

    @Test func encodesASlowGotoOfTheChosenMotor() throws {
        let az = NudgeCommand.packet(.azimuth, from: 0, by: 1)
        #expect(Array(az.prefix(5)) == [0x3B, 0x06, 0x20, 0x10, 0x17])
        #expect(Int(az[5]) << 16 | Int(az[6]) << 8 | Int(az[7]) == Self.oneDegree)
        try NudgeCommand.check(az, axis: .azimuth, currentPosition: 0)

        let alt = NudgeCommand.packet(.altitude, from: Self.counts(30), by: 0.1)
        #expect(alt[3] == 0x11)
        try NudgeCommand.check(alt, axis: .altitude, currentPosition: Self.counts(30))
    }

    @Test func azimuthWrapsAcrossZeroAndStillCountsAsSmall() throws {
        let bytes = NudgeCommand.packet(.azimuth, from: 100, by: -0.5)
        #expect(bytes[5] == 0xFF) // just below a full turn
        try NudgeCommand.check(bytes, axis: .azimuth, currentPosition: 100)
    }

    @Test(arguments: [(NudgeAxis.azimuth, 5.0, true), (.azimuth, 5.01, false), (.altitude, 0.1, true), (.altitude, 1.5, true), (.altitude, 1.51, false), (.altitude, 3, false)])
    func enforcesEachAxisStepLimit(_ axis: NudgeAxis, _ degrees: Double, _ allowed: Bool) {
        let current = Self.counts(30)
        let steps = UInt32((degrees / 360 * 16_777_216).rounded())
        let bytes = Self.rawPacket(to: axis.motor.rawValue, target: current + steps)
        if allowed {
            #expect(throws: Never.self) { try NudgeCommand.check(bytes, axis: axis, currentPosition: current) }
        } else {
            #expect(throws: MountError.self) { try NudgeCommand.check(bytes, axis: axis, currentPosition: current) }
        }
    }

    /// Leaving the band, or going further out once outside it (200° raw is −160°, far below), is blocked.
    @Test(arguments: [(0.05, -0.1), (74.95, 0.1), (-3.0, -0.1), (200.0, -0.1), (76.0, 0.1)])
    func blocksAltitudeTargetsOutsideTheSafeBand(_ from: Double, _ step: Double) {
        let bytes = Self.rawPacket(to: 0x11, target: Self.counts(from + step))
        #expect(throws: MountError.self) { try NudgeCommand.check(bytes, axis: .altitude, currentPosition: Self.counts(from)) }
    }

    /// Outside the band, a step back toward it is allowed, so the scope can always be brought back.
    @Test(arguments: [(-3.0, 0.1), (200.0, 0.1), (76.0, -0.1)])
    func allowsAltitudeStepsBackTowardTheBand(_ from: Double, _ step: Double) throws {
        let bytes = Self.rawPacket(to: 0x11, target: Self.counts(from + step))
        try NudgeCommand.check(bytes, axis: .altitude, currentPosition: Self.counts(from))
    }

    @Test func allowsAltitudeTargetsJustInsideTheBand() throws {
        try NudgeCommand.check(Self.rawPacket(to: 0x11, target: Self.counts(0.05)), axis: .altitude, currentPosition: Self.counts(0))
        try NudgeCommand.check(Self.rawPacket(to: 0x11, target: Self.counts(74.95)), axis: .altitude, currentPosition: Self.counts(74.9))
    }

    @Test func blocksAStepComputedFromAStalePosition() {
        let bytes = NudgeCommand.packet(.azimuth, from: 0, by: 0.5)
        #expect(throws: MountError.self) { try NudgeCommand.check(bytes, axis: .azimuth, currentPosition: UInt32(Self.oneDegree * 10)) }
    }

    /// Outside the altitude band, a step back toward it is allowed (so the scope can always be brought back), one
    /// further out is not.
    @Test func outsideTheAltitudeBandOnlyStepsBackTowardItAreAllowed() {
        #expect(NudgeCommand.altitudeMoveAllowed(from: -1.8, to: -0.3), "below: up, still below")
        #expect(NudgeCommand.altitudeMoveAllowed(from: -1.8, to: 0.5), "below: up, into the band")
        #expect(!NudgeCommand.altitudeMoveAllowed(from: -1.8, to: -2.5), "below: further down")
        #expect(NudgeCommand.altitudeMoveAllowed(from: 76, to: 75.5))
        #expect(!NudgeCommand.altitudeMoveAllowed(from: 76, to: 77))
        #expect(!NudgeCommand.altitudeMoveAllowed(from: 0.5, to: -0.5), "inside: may not leave")

        // The same rule on the bytes: from 1.8° below the horizon (offset 0), a 1.5° step up passes, a step down doesn't.
        let turn = Double(1 << 24)
        let below = UInt32(turn - turn * 1.8 / 360)
        #expect(throws: Never.self) { try NudgeCommand.check(NudgeCommand.packet(.altitude, from: below, by: 1.5), axis: .altitude, currentPosition: below) }
        #expect(throws: MountError.self) { try NudgeCommand.check(NudgeCommand.packet(.altitude, from: below, by: -0.5), axis: .altitude, currentPosition: below) }
    }

    @Test func blocksWrongMotorsCommandsAndShapes() {
        let small: [UInt8] = [0, 0, 1]
        let attempts: [(NudgeAxis, [UInt8])] = [
            (.azimuth, AuxPacket(source: 0x20, destination: 0x11, command: 0x17, data: small).encoded()), // altitude packet as azimuth
            (.altitude, AuxPacket(source: 0x20, destination: 0x10, command: 0x17, data: small).encoded()), // azimuth packet as altitude
            (.azimuth, AuxPacket(source: 0x20, destination: 0x10, command: 0x02, data: small).encoded()), // fast goto
            (.azimuth, AuxPacket(source: 0x0D, destination: 0x10, command: 0x17, data: small).encoded()), // not from the app
            (.azimuth, AuxPacket(source: 0x20, destination: 0x10, command: 0x17, data: [0, 1]).encoded()),
            (.azimuth, AuxPacket(source: 0x20, destination: 0x10, command: 0x17, data: [0, 0, 1, 0]).encoded()),
            (.azimuth, NudgeCommand.packet(.azimuth, from: 0, by: 0.5) + [0x3B]),
        ]
        for (axis, payload) in attempts {
            #expect(throws: MountError.self) { try NudgeCommand.check(payload, axis: axis, currentPosition: 0) }
        }
    }

    @Test(arguments: [(NudgeAxis.azimuth, 0.0), (.azimuth, 5.01), (.azimuth, -45), (.azimuth, .nan), (.azimuth, .infinity),
                      (.altitude, 1.6), (.altitude, -2), (.altitude, .nan)])
    func clientRefusesOutOfRangeStepsBeforeSendingAnything(_ axis: NudgeAxis, _ degrees: Double) async {
        // Port 1 has nothing listening: the refusal has to come before any connection attempt.
        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: 1))
        await #expect(throws: MountError.self) { try await client.nudge(axis, by: degrees) }
    }

    @Test func handControllerRefusesNudges() async {
        let client = HandControllerClient(transport: TCPTransport(host: "127.0.0.1", port: 1))
        await #expect(throws: MountError.self) { try await client.nudge(.azimuth, by: 0.5) }
        await #expect(throws: MountError.self) { try await client.move(.azimuth, positive: true, continuing: false, onSend: {}) }
    }
}

@Suite("Sun safety")
struct SunSafetyTests {
    let sun = Horizontal(azimuth: 180, altitude: 40)

    @Test func allowsMovesFarFromTheSun() {
        #expect(SunSafety.check(.azimuth, by: 5, from: Horizontal(azimuth: 0, altitude: 40), sun: sun) == nil)
        #expect(SunSafety.check(.altitude, by: -1.5, from: Horizontal(azimuth: 90, altitude: 20), sun: sun) == nil)
    }

    @Test func blocksMovesThatEndInsideTheKeepOutZone() {
        // 31° east of the Sun along the horizon circle at 40° altitude is about 24° away; start just outside.
        let start = Horizontal(azimuth: 180 - 41, altitude: 40)
        #expect(SunSafety.check(.azimuth, by: 5, from: start, sun: sun) != nil)
    }

    @Test func blocksAMoveThatSweepsPastTheSunEvenIfItEndsOutside() {
        // Azimuth sweep at the Sun's altitude: starts and ends outside a 2° zone but passes right over the Sun.
        let start = Horizontal(azimuth: 177.5, altitude: 40)
        #expect(SunSafety.check(.azimuth, by: 5, from: start, sun: sun, keepOut: 2) != nil)
    }

    @Test func allowsBackingAwayFromInsideTheZone() {
        let start = Horizontal(azimuth: 190, altitude: 40)
        #expect(SunSafety.check(.azimuth, by: 5, from: start, sun: sun) == nil) // further from 180°
        #expect(SunSafety.check(.azimuth, by: -5, from: start, sun: sun) != nil) // back toward it
        // Level with the Sun, the shortest line to it bows upward: going up first gets closer, going down doesn't.
        #expect(SunSafety.check(.altitude, by: 1.5, from: start, sun: sun) != nil)
        #expect(SunSafety.check(.altitude, by: -1.5, from: start, sun: sun) == nil)
    }

    @Test func handlesAzimuthWrapAroundNorth() {
        let northSun = Horizontal(azimuth: 2, altitude: 10)
        #expect(SunSafety.check(.azimuth, by: 5, from: Horizontal(azimuth: 330, altitude: 10), sun: northSun) != nil)
        #expect(SunSafety.check(.azimuth, by: -5, from: Horizontal(azimuth: 330, altitude: 10), sun: northSun) == nil)
    }
}

@Suite("Parsing and formatting")
struct ParsingTests {
    @Test func parsesPrecisePositionReply() throws {
        // 0x40000000 is a quarter turn (90°); 0xC0000000 is three quarters (270° → −90° when signed).
        let reply = Array("40000000,C0000000#".utf8)
        let (a, b) = try #require(Angles.parsePrecisePair(reply))
        #expect(abs(a - 90) < 1e-9)
        #expect(abs(Angles.signed(b) + 90) < 1e-9)
    }

    @Test func rejectsMalformedPositionReply() {
        #expect(Angles.parsePrecisePair(Array("40000000;C0000000#".utf8)) == nil)
        #expect(Angles.parsePrecisePair(Array("4000".utf8)) == nil)
    }

    @Test func formatsCoordinates() {
        #expect(SkyFormat.rightAscension(5.5) == "05h 30m 00.0s")
        #expect(SkyFormat.rightAscension(23.999999) == "00h 00m 00.0s")
        #expect(SkyFormat.declination(-6.9) == "−06° 54′ 00″")
        #expect(SkyFormat.declination(38.7836) == "+38° 47′ 01″")
        #expect(SkyFormat.compassPoint(0) == "N")
        #expect(SkyFormat.compassPoint(165) == "SSE")
        #expect(SkyFormat.compassPoint(359) == "N")
    }

    @Test func sunIsNearZeroZeroAtMarchEquinox2026() throws {
        // March equinox 2026: 20 March, 14:46 UTC.
        let date = try #require(ISO8601DateFormatter().date(from: "2026-03-20T14:46:00Z"))
        let sun = Astronomy.sunPosition(at: date)
        let raDegrees = sun.raHours * 15
        #expect(min(raDegrees, 360 - raDegrees) < 0.1)
        #expect(abs(sun.decDegrees) < 0.1)
    }

    @Test func siderealTimeAtJ2000() throws {
        // Greenwich mean sidereal time at 2000-01-01 12:00 UT is 18.697 h.
        let date = try #require(ISO8601DateFormatter().date(from: "2000-01-01T12:00:00Z"))
        #expect(abs(Astronomy.localSiderealHours(at: date, longitude: 0) - 18.697_374_6) < 0.001)
        #expect(abs(Astronomy.localSiderealHours(at: date, longitude: -77.04) - (18.697_374_6 - 77.04 / 15)) < 0.001)
    }

    @Test func polarisSitsAtTheObserversLatitude() {
        let washington = Observer(latitude: 38.89, longitude: -77.04)
        let polaris = Equatorial(raHours: 3.0, decDegrees: 89.36)
        for hour in stride(from: 0.0, to: 24, by: 3) {
            let sky = Astronomy.horizontal(polaris, at: Date(timeIntervalSince1970: 1_790_000_000 + hour * 3600), observer: washington)
            #expect(abs(sky.altitude - washington.latitude) < 0.7)
            #expect(min(sky.azimuth, 360 - sky.azimuth) < 1.2) // always within about a degree of due north
        }
    }

    @Test func objectOnTheMeridianIsDueSouth() {
        let observer = Observer(latitude: 38.89, longitude: -77.04)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let star = Equatorial(raHours: Astronomy.localSiderealHours(at: date, longitude: observer.longitude), decDegrees: 0)
        let sky = Astronomy.horizontal(star, at: date, observer: observer)
        #expect(abs(sky.azimuth - 180) < 0.01)
        #expect(abs(sky.altitude - (90 - 38.89)) < 0.01)
    }

    @Test func sunIsHighAtNoonAndBelowTheHorizonAtMidnightInSummer() throws {
        // Washington, DC on the June solstice 2026: local noon is about 17:10 UTC.
        let observer = Observer(latitude: 38.89, longitude: -77.04)
        let noon = try #require(ISO8601DateFormatter().date(from: "2026-06-21T17:10:00Z"))
        let high = Astronomy.horizontal(Astronomy.sunPosition(at: noon), at: noon, observer: observer)
        #expect(abs(high.altitude - (90 - 38.89 + 23.44)) < 0.5)
        let midnight = noon.addingTimeInterval(12 * 3600)
        #expect(Astronomy.horizontal(Astronomy.sunPosition(at: midnight), at: midnight, observer: observer).altitude < -20)
    }

    @Test func darknessBoundaries() {
        #expect(SkyDarkness(sunAltitude: 10) == .day)
        #expect(SkyDarkness(sunAltitude: -3) == .civilTwilight)
        #expect(SkyDarkness(sunAltitude: -9) == .nauticalTwilight)
        #expect(SkyDarkness(sunAltitude: -15) == .astronomicalTwilight)
        #expect(SkyDarkness(sunAltitude: -25) == .night)
    }

    @Test func separationBasics() {
        let a = Equatorial(raHours: 0, decDegrees: 0)
        #expect(abs(Astronomy.separation(a, Equatorial(raHours: 6, decDegrees: 0)) - 90) < 1e-9)
        #expect(abs(Astronomy.separation(a, Equatorial(raHours: 0, decDegrees: 90)) - 90) < 1e-9)
        #expect(Astronomy.separation(a, a) < 1e-9)
    }
}
