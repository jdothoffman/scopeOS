import Foundation
import Testing
@testable import ScopeKit

@Suite("Planning drives")
struct DriveRouteTests {
    /// The Sun well below the horizon, out of the way.
    let night = Horizontal(azimuth: 0, altitude: -50)

    @Test func altitudeGoesFirstWhenTheSunAllows() throws {
        let legs = try DriveRoute.legs(from: Horizontal(azimuth: 100, altitude: 20), to: Horizontal(azimuth: 130, altitude: 40), turn: 30, sun: night).get()
        #expect(legs.map(\.axis) == [.altitude, .azimuth])
        #expect(legs.map(\.positive) == [true, true])
        #expect(legs.map(\.target) == [40, 130])
    }

    @Test func azimuthGoesFirstWhenRaisingFirstWouldPassTheSun() throws {
        // Sun at 180°, 40° up. Raising first from 150°/10° to 40° comes within 30° of it while turning away;
        // turning away first, then raising, stays clear.
        let sun = Horizontal(azimuth: 180, altitude: 40)
        let legs = try DriveRoute.legs(from: Horizontal(azimuth: 150, altitude: 10), to: Horizontal(azimuth: 90, altitude: 40), turn: -60, sun: sun).get()
        #expect(legs.map(\.axis) == [.azimuth, .altitude])
    }

    @Test func aRouteThatCantAvoidTheSunIsRefused() {
        let sun = Horizontal(azimuth: 180, altitude: 40)
        let result = DriveRoute.legs(from: Horizontal(azimuth: 160, altitude: 40), to: Horizontal(azimuth: 200, altitude: 40), turn: 40, sun: sun)
        guard case .failure(.nearSun) = result else { Issue.record("expected nearSun, got \(result)"); return }
    }

    @Test func targetsOutsideTheAltitudeBandAreRefused() {
        let from = Horizontal(azimuth: 10, altitude: 30)
        #expect(DriveRoute.legs(from: from, to: Horizontal(azimuth: 10, altitude: -5), turn: 0, sun: night) == .failure(.belowBand(altitude: -5)))
        #expect(DriveRoute.legs(from: from, to: Horizontal(azimuth: 10, altitude: 80), turn: 0, sun: night) == .failure(.aboveBand(altitude: 80)))
    }

    @Test func anAxisAlreadyThereIsLeftOut() throws {
        let legs = try DriveRoute.legs(from: Horizontal(azimuth: 10, altitude: 30), to: Horizontal(azimuth: 10.005, altitude: 35), turn: 0.005, sun: night).get()
        #expect(legs.map(\.axis) == [.altitude])
    }

    @Test func theCableTrackCountsWholeTurns() {
        var track = CableTrack(motorAzimuth: 350)
        for azimuth in stride(from: 0.0, through: 350, by: 50) { track.update(motorAzimuth: azimuth) } // on round through 0°
        track.update(motorAzimuth: 20)
        #expect(abs(track.turned - 390) < 1e-9)
    }

    @Test func goingHomeUnwindsTheWayItCame() {
        // Switched on at home (motor 0°), then turned 300° to the right: home is 60° further right the short way,
        // but going home turns back 300° to the left.
        var track = CableTrack(motorAzimuth: 0)
        for azimuth in stride(from: 50.0, through: 300, by: 50) { track.update(motorAzimuth: azimuth) }
        #expect(abs(track.turnHome(homeMotor: 0) - -300) < 1e-9)
        #expect(abs(track.turnHome(homeMotor: 360) - -300) < 1e-9, "the same home, a turn on")
    }

    @Test func goToTakesTheShortWayUnlessTheCableWouldWindTooFar() {
        var track = CableTrack(motorAzimuth: 0)
        #expect(track.turn(from: 0, to: 30) == 30)
        for azimuth in stride(from: 50.0, through: 250, by: 50) { track.update(motorAzimuth: azimuth) } // 250° right
        // 10° more right leaves 260° wound: fine. 50° more would leave 300°, so it goes 310° left instead (−60°).
        #expect(abs(track.turn(from: 250, to: 260) - 10) < 1e-9)
        #expect(abs(track.turn(from: 250, to: 300) - -310) < 1e-9)
    }

    @Test func retriesBackOffToThirtySeconds() {
        #expect((1 ... 7).map { ConnectionSettings.retryDelay(attempt: $0) } == [3, 6, 12, 24, 30, 30, 30].map { Duration.seconds($0) })
    }

    @Test func aSilentWiFiModuleGetsAClearReason() {
        let settings = ConnectionSettings.wifiModule(host: "1.2.3.4", port: 2000)
        #expect(settings.problem(MountError.timeout("version from Azimuth motor"), wasConnected: false).contains("SkyPortal"))
        #expect(settings.problem(MountError.connectionFailed("Connection refused"), wasConnected: false).hasPrefix("Nothing answered at 1.2.3.4:2000"))
        #expect(settings.problem(MountError.disconnected, wasConnected: true).hasPrefix("Lost the connection"))
        #expect(ConnectionSettings.isPermanent(MountError.invalidConfiguration("Enter a host and port.")))
        #expect(!ConnectionSettings.isPermanent(MountError.timeout("x")))
    }
}
