import Foundation
import Testing
@testable import NexStarSimulator
@testable import ScopeKit

@Suite("Axis calibration")
struct AxisCalibrationTests {
    @Test func convertsMotorAnglesToSkyAngles() {
        let calibration = AxisCalibration(azimuthOffset: 10, altitudeOffset: 23)
        let sky = calibration.sky(fromMotor: Horizontal(azimuth: 5, altitude: 23))
        #expect(abs(sky.azimuth - 355) < 1e-9) // wraps through north
        #expect(abs(sky.altitude) < 1e-9)
    }

    @Test func pointingSetsOnlyTheAxesGiven() {
        let start = AxisCalibration(azimuthOffset: 4, altitudeOffset: 0)
        let level = start.pointing(motor: Horizontal(azimuth: 100, altitude: 23), azimuth: nil, altitude: 0)
        #expect(level == AxisCalibration(azimuthOffset: 4, altitudeOffset: 23))
        let north = level.pointing(motor: Horizontal(azimuth: 350, altitude: 23), azimuth: 0, altitude: nil)
        #expect(abs(north.azimuthOffset - -10) < 1e-9) // smallest offset, not +350
        #expect(north.altitudeOffset == 23)
    }

    @Test func altitudeBandUsesTheCalibratedAltitude() {
        // Motor reads 23° while the tube is level (offset 23): a move to motor 22.9° would be −0.1°, below the horizon.
        let current = NudgeCommandTests.counts(23)
        let down = NudgeCommand.packet(.altitude, from: current, by: -0.1)
        #expect(throws: MountError.self) { try NudgeCommand.check(down, axis: .altitude, currentPosition: current, altitudeOffset: 23) }
        #expect(throws: Never.self) { try NudgeCommand.check(down, axis: .altitude, currentPosition: current, altitudeOffset: 0) }
    }

    @Test func polarisSitsNearTheObserversLatitude() {
        let observer = Observer(latitude: 38.89, longitude: -77.04)
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        let sky = Astronomy.horizontal(SkyTarget.polaris.position(at: date), at: date, observer: observer)
        #expect(abs(sky.altitude - observer.latitude) < 0.7)
    }
}

@Suite("Calibration end to end", .serialized)
struct CalibrationIntegrationTests {
    private func mount() async throws -> (SimulatorServer, AuxClient) {
        let server = try SimulatorServer(flavor: .aux, port: 0, sky: SimulatedSky(trackSeconds: 60, slewSeconds: 5))
        try await server.start()
        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)), motionPolicy: { .darkTestSky })
        try await client.connect()
        return (server, client)
    }

    @Test func calibratingMakesTheReadingsMatch() async throws {
        let (server, client) = try await mount()
        defer { server.stop() }
        let before = try await client.readStatus()
        #expect(before.calibration == nil)

        // Pretend the tube is actually level and pointing due east while the motors read 165°/38°.
        _ = try await client.calibrate(azimuth: 90, altitude: 0)
        let after = try await client.readStatus()
        let sky = try #require(after.horizontal)
        #expect(abs(sky.altitude) < 0.05)
        #expect(abs(sky.azimuth - 90) < 0.05)
        #expect(after.axisAngles.map { abs($0.altitude - 38) < 1 } == true) // raw angles unchanged

        await client.setCalibration(nil)
        #expect(abs(try #require(try await client.readStatus().horizontal).altitude - 38) < 1)
        await client.disconnect()
    }

    @Test func upDownLimitsFollowTheCalibration() async throws {
        let (server, client) = try await mount()
        defer { server.stop() }
        // Say the tube is just above the horizon: moving down 0.1° would cross it, so it's refused.
        _ = try await client.calibrate(azimuth: nil, altitude: 0.05)
        await #expect(throws: MountError.self) { try await client.nudge(.altitude, by: -0.1) }
        try await client.nudge(.altitude, by: 0.1) // up is fine
        await client.disconnect()
    }

    @Test func calibrationIsRefusedWhileMoving() async throws {
        let server = try SimulatorServer(flavor: .aux, port: 0, sky: SimulatedSky(trackSeconds: 0.01, slewSeconds: 30, start: .now.addingTimeInterval(-1)))
        try await server.start()
        defer { server.stop() }
        let client = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(server.port)), motionPolicy: { .darkTestSky })
        try await client.connect()
        await #expect(throws: MountError.self) { try await client.calibrate(azimuth: 0, altitude: 0) }
        await client.disconnect()
    }
}
