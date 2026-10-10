import Foundation
import Testing
@testable import NexStarSimulator
@testable import ScopeKit

@Suite("Simulated mount", .serialized)
struct SimulatedMountTests {
    @Test func aParkedMountStaysAtHomeUntilMoved() async throws {
        let mount = SimulatedMount(sky: .parked(), secondsPerDegree: 0.02)
        let now = Date.now
        #expect(mount.state(at: now).horizontal == Horizontal(azimuth: 0, altitude: 0), "switched on level and pointing north")
        #expect(mount.state(at: now.addingTimeInterval(600)).horizontal == Horizontal(azimuth: 0, altitude: 0), "and stays there")
        #expect(!mount.state(at: now).slewing)

        _ = mount.move(.azimuthMotor, to: 10, at: now)
        _ = mount.move(.altitudeMotor, to: 5, at: now)
        #expect(mount.state(at: now.addingTimeInterval(0.1)).slewing)
        let after = mount.state(at: now.addingTimeInterval(1))
        #expect(!after.slewing)
        #expect(abs(after.horizontal.azimuth - 10) < 1e-9)
        #expect(abs(after.horizontal.altitude - 5) < 1e-9)
    }

    @Test func bothProtocolsDescribeOneMount() async throws {
        let observer = Observer(latitude: 38.89, longitude: -77.03)
        let mount = SimulatedMount(sky: .parked(), focuser: true, secondsPerDegree: 0.02)
        mount.setObserver(observer)
        let aux = try SimulatorServer(flavor: .aux, port: 0, mount: mount)
        let handController = try SimulatorServer(flavor: .handController, port: 0, mount: mount)
        try await aux.start()
        try await handController.start()
        defer {
            aux.stop()
            handController.stop()
        }

        // Moved over the WiFi module's protocol…
        let wifi = AuxClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(aux.port)), motionPolicy: { .darkTestSky })
        try await wifi.connect()
        try await wifi.nudge(.altitude, by: 1.0)
        try await Task.sleep(for: .milliseconds(300))
        let viaWifi = try #require(try await wifi.readStatus().horizontal)
        await wifi.disconnect()
        #expect(abs(viaWifi.altitude - 1) < 0.01)

        // …and seen over the hand controller's, with RA/Dec worked out for where the mount is.
        let usb = HandControllerClient(transport: TCPTransport(host: "127.0.0.1", port: try #require(handController.port)))
        try await usb.connect()
        let status = try await usb.readStatus()
        await usb.disconnect()
        let horizontal = try #require(status.horizontal)
        #expect(abs(horizontal.altitude - 1) < 0.01)
        let expected = Astronomy.equatorial(from: horizontal, at: .now, observer: observer)
        let equatorial = try #require(status.equatorial)
        #expect(Astronomy.separation(equatorial, expected) < 0.05)
    }
}
