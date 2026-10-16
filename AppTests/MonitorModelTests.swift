import Foundation
import NexStarSimulator
import ScopeCapture
import ScopeKit
import Testing

/// `MonitorModel` driving the simulated mount, with its own settings and log folder, from a place where it's
/// local midnight now, so the Sun is out of the way whenever the tests run.
@MainActor
@Suite("MonitorModel against the simulator", .serialized)
struct MonitorModelTests {
    /// Longitude (east positive) where the Sun is on the meridian below the pole now (hour angle 0) or 180° from it.
    static func longitude(sunHourAngle: Double) -> Double {
        let now = Date.now
        let sun = Astronomy.sunPosition(at: now)
        let greenwichSidereal = Astronomy.localSiderealHours(at: now, longitude: 0) * 15
        var longitude = Astronomy.normalize(sun.raHours * 15 + sunHourAngle - greenwichSidereal)
        if longitude > 180 { longitude -= 360 }
        return longitude
    }

    final class Rig {
        let model: MonitorModel
        let location: LocationModel
        let server: SimulatorServer
        let defaults: UserDefaults
        let suite: String
        let logFolder: URL

        @MainActor
        init(home: AxisCalibration? = nil, sunHourAngle: Double = 180) async throws {
            suite = "ScopeOSTests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            if let home {
                defaults.set(["azimuthOffset": home.azimuthOffset, "altitudeOffset": home.altitudeOffset], forKey: "homeCalibration")
            }
            logFolder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            location = LocationModel(defaults: defaults)
            location.manualLatitude = "38.89"
            location.manualLongitude = String(MonitorModelTests.longitude(sunHourAngle: sunHourAngle))
            location.applyManual()
            model = MonitorModel(location: location, defaults: defaults, logFolder: logFolder,
                                 solarLogFile: logFolder.appendingPathComponent("Solar filter confirmations.txt"))

            server = try SimulatorServer(flavor: .aux, port: 0, sky: SimulatedSky(trackSeconds: 600, slewSeconds: 5), secondsPerDegree: 0.02)
            try await server.start()
            model.kind = .wifiModule
            model.wifiHost = "127.0.0.1"
            model.wifiPort = String(try #require(server.port))
            model.connect()
            // Long enough for one automatic retry, should the first attempt fail.
            try await waitUntil(timeout: .seconds(30)) {
                model.phase == .connected && model.status?.horizontal != nil
            } failure: { [model] in "not connected: phase \(model.phase), error \(model.lastError ?? "none"), log \(model.log.suffix(6).map(\.text))" }
        }

        @MainActor
        func tearDown() {
            model.disconnect()
            server.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: logFolder)
        }

        /// The next position reading taken after now.
        @MainActor
        func freshStatus() async throws -> MountStatus {
            let asked = Date.now
            try await waitUntil { (model.status?.updated ?? .distantPast) > asked.addingTimeInterval(0.05) }
            return try #require(model.status)
        }
    }

    static func waitUntil(timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool,
                          failure: @MainActor () -> String = { "timed out waiting" }) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record(Comment(rawValue: failure()))
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func holdsNeedTheDebugSwitches() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        let model = rig.model
        #expect(BuildMode.isDebug)

        model.pressArrow(.azimuth, positive: true)
        #expect(model.activeMove == nil, "movement is off until switched on")

        model.movementEnabled = true
        model.pressArrow(.altitude, positive: true)
        #expect(model.activeMove == nil, "up/down has its own switch")

        model.pressArrow(.azimuth, positive: true)
        #expect(model.activeMove != nil)
        model.releaseArrow()
        await model.releaseControls()
    }

    @Test func theLinkShowsAsStaleWhenReadingsStop() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        let model = rig.model
        _ = try await rig.freshStatus()
        #expect(!model.isLinkStale(), "readings arrive every second or two")
        #expect(model.isLinkStale(at: .now.addingTimeInterval(MonitorModel.staleAfter + 1)))
        model.disconnect()
        #expect(model.readingAge() == nil, "no age while not connected")
    }

    @Test func holdingAnArrowMovesUntilReleased() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        let model = rig.model
        model.movementEnabled = true
        let start = try #require(try await rig.freshStatus().horizontal).azimuth

        model.pressArrow(.azimuth, positive: true)
        try await Task.sleep(for: .seconds(2))
        model.releaseArrow()
        await model.releaseControls()
        try await Task.sleep(for: .milliseconds(300))
        let after = try await rig.freshStatus()

        #expect(model.activeMove == nil)
        #expect(after.slewing == false)
        let moved = Astronomy.shortTurn(from: start, to: try #require(after.horizontal).azimuth)
        #expect(moved > NudgeAxis.azimuth.maxStepDegrees + 1, "moved \(moved)°: a hold keeps sending steps")
    }

    @Test func aQuickTapLeavesTheMountStill() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        let model = rig.model
        model.movementEnabled = true
        let start = try #require(try await rig.freshStatus().horizontal).azimuth

        model.pressArrow(.azimuth, positive: false)
        model.releaseArrow()
        await model.releaseControls()
        try await Task.sleep(for: .milliseconds(500))
        let after = try await rig.freshStatus()

        #expect(after.slewing == false)
        #expect(abs(Astronomy.shortTurn(from: start, to: try #require(after.horizontal).azimuth)) < 1)
    }

    @Test func theDaylightLockStopsMovesFromStarting() async throws {
        let rig = try await Rig(sunHourAngle: 0) // local noon
        defer { rig.tearDown() }
        let model = rig.model
        model.movementEnabled = true
        #expect(model.sunLockWhileUp)

        model.pressArrow(.azimuth, positive: true)
        #expect(model.activeMove == nil)
        #expect(model.lastError?.contains("Sun is up") == true, "\(String(describing: model.lastError))")
        // The client refuses too, whatever the app's checks say.
        #expect(model.motionPolicy.lockWhileSunUp)
    }

    @Test func returnToHomeDrivesBackToTheHomePosition() async throws {
        // Home is 3° right of and 2° above where the scope will be calibrated as pointing north and level.
        let rig = try await Rig(home: AxisCalibration(azimuthOffset: -3, altitudeOffset: -2))
        defer { rig.tearDown() }
        let model = rig.model
        model.movementEnabled = true
        model.verticalEnabled = true
        #expect(model.offerHome, "asks about the home position on connecting")
        model.offerHome = false
        #expect(model.returnHomeProblem != nil, "needs a calibration first")

        model.calibrateLevel()
        try await Rig.waitUntil { model.calibration != nil }
        model.calibrateNorth()
        try await Rig.waitUntil { model.calibration?.azimuthOffset != 0 }
        _ = try await rig.freshStatus()
        #expect(!model.isAtHome)
        #expect(model.returnHomeProblem == nil, "\(String(describing: model.returnHomeProblem))")

        model.returnHome()
        #expect(model.isReturningHome)
        try await Rig.waitUntil(timeout: .seconds(20)) { model.driving == nil }
        _ = try await rig.freshStatus()

        #expect(model.lastError == nil, "\(String(describing: model.lastError))")
        #expect(model.isAtHome, "pointing \(String(describing: model.status?.horizontal)), home \(String(describing: model.homePointing))")
        #expect(model.log.contains { $0.text == "Back at the home position." })
    }

    /// The home position keeps how each axis was calibrated (level, true north, Polaris) and shows it after a relaunch.
    @Test func theHomePositionRemembersHowItWasCalibrated() async throws {
        let rig = try await Rig(home: AxisCalibration(azimuthOffset: -3, altitudeOffset: -2))
        defer { rig.tearDown() }
        let model = rig.model
        model.offerHome = false
        #expect(model.homeBasis == .unrecorded, "saved before scopeOS kept track")
        #expect(model.homeSaved == nil)
        #expect(model.calibrationBasis == nil)

        model.calibrateLevel()
        try await Rig.waitUntil { model.calibration != nil }
        #expect(model.calibrationBasis == CalibrationBasis(azimuth: .switchedOn, altitude: .level))
        model.calibrateNorth()
        try await Rig.waitUntil { model.calibrationBasis?.azimuth == .trueNorth }
        #expect(model.calibrationBasis == CalibrationBasis(azimuth: .trueNorth, altitude: .level))
        model.saveHome()

        let relaunched = MonitorModel(location: rig.location, defaults: rig.defaults, logFolder: rig.logFolder,
                                      solarLogFile: rig.logFolder.appendingPathComponent("Solar filter confirmations.txt"))
        #expect(relaunched.homeBasis == CalibrationBasis(azimuth: .trueNorth, altitude: .level))
        #expect(relaunched.homeSaved != nil)
        let summary = try #require(relaunched.homeSummary)
        #expect(summary.contains("azimuth from true north, altitude from a level tube"), "\(summary)")

        model.calibratePolaris()
        try await Rig.waitUntil { model.calibrationBasis?.azimuth == .polaris }
        #expect(model.calibrationBasis?.summary == "both axes from Polaris")
        model.clearCalibration()
        #expect(model.calibrationBasis == nil)
        model.useHome()
        #expect(model.calibrationBasis == CalibrationBasis(azimuth: .trueNorth, altitude: .level), "the home position's own")
    }

    /// Calibrated, with Return to home set going toward a home 40° away, and its route planned (so steps are going out).
    private func driveHomeUnderWay() async throws -> Rig {
        let rig = try await Rig(home: AxisCalibration(azimuthOffset: -40, altitudeOffset: 0))
        let model = rig.model
        model.movementEnabled = true
        model.verticalEnabled = true
        model.offerHome = false
        model.calibrateLevel()
        try await Rig.waitUntil { model.calibration != nil }
        model.calibrateNorth()
        try await Rig.waitUntil { model.calibration?.azimuthOffset != 0 }
        _ = try await rig.freshStatus()
        model.returnHome()
        try await rig.waitUntil { model.driving?.target != nil } failure: { [model] in "not planned: \(model.lastError ?? "no error")" }
        return rig
    }

    private func stopWasSent(_ model: MonitorModel) -> Bool {
        model.log.contains { $0.direction == .sent && $0.text.contains("stop →") }
    }

    @Test func disconnectingStopsAReturnToHome() async throws {
        let rig = try await driveHomeUnderWay()
        defer { rig.tearDown() }
        let model = rig.model

        model.disconnect()
        try await rig.waitUntil(timeout: .seconds(5)) { stopWasSent(model) } failure: { "no stop sent" }
        #expect(model.driving == nil)
    }

    @Test func quittingStopsAReturnToHome() async throws {
        let rig = try await driveHomeUnderWay()
        defer { rig.tearDown() }
        let model = rig.model

        await model.releaseControls()
        try await rig.waitUntil(timeout: .seconds(5)) { stopWasSent(model) } failure: { "no stop sent" }
        #expect(model.driving == nil)
    }

    /// iOS: leaving the screen stops a drive and closes the connection; coming back reconnects with the same
    /// calibration, and the drive doesn't pick up again by itself.
    @Test func goingToTheBackgroundStopsADriveAndComingBackReconnects() async throws {
        let rig = try await driveHomeUnderWay()
        defer { rig.tearDown() }
        let model = rig.model
        let calibration = try #require(model.calibration)

        await model.pause()
        #expect(stopWasSent(model))
        #expect(model.driving == nil)
        #expect(!model.isRunning)
        #expect(model.phase == .idle)
        #expect(model.calibration == calibration, "kept while paused")

        model.resume()
        try await rig.waitUntil { model.phase == .connected }
        _ = try await rig.freshStatus()
        #expect(model.calibration == calibration)
        #expect(model.driving == nil, "a drive needs asking for again")
        #expect(!model.movementEnabled, "debug builds need the switch again, as after any reconnect")
    }

    /// iOS: declining the home position isn't asked again after a trip to the background.
    @Test func comingBackDoesNotAskAboutTheHomePositionAgain() async throws {
        let rig = try await Rig(home: AxisCalibration(azimuthOffset: -3, altitudeOffset: -2))
        defer { rig.tearDown() }
        let model = rig.model
        #expect(model.offerHome)
        model.offerHome = false

        await model.pause()
        model.resume()
        try await rig.waitUntil { model.phase == .connected }
        _ = try await rig.freshStatus()
        #expect(!model.offerHome)
    }

    /// iOS: coming back while the stops are still going out keeps the connection open.
    @Test func comingBackQuicklyKeepsTheConnection() async throws {
        let rig = try await driveHomeUnderWay()
        defer { rig.tearDown() }
        let model = rig.model

        let pausing = Task { await model.pause() }
        await Task.yield() // `pause()` runs until it waits for the stop to go out
        #expect(model.driving == nil)
        model.resume()
        await pausing.value
        #expect(stopWasSent(model))
        #expect(model.driving == nil)
        #expect(model.isRunning)
        #expect(model.phase == .connected)
    }

    /// Start Simulator gives a mount that can be moved (the WiFi module's protocol) and a camera, without touching the
    /// saved WiFi address.
    @Test func theBuiltInSimulatorCanBeMovedAndHasACamera() async throws {
        let suite = "ScopeOSTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let logFolder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: logFolder)
        }
        let location = LocationModel(defaults: defaults)
        location.manualLatitude = "38.89"
        location.manualLongitude = String(Self.longitude(sunHourAngle: 180))
        location.applyManual()
        // Free ports, so a copy of scopeOS or scopesim already running doesn't get in the way.
        let model = MonitorModel(location: location, defaults: defaults, logFolder: logFolder, simulatorPorts: (0, 0))
        let camera = CameraModel(monitor: model, location: location)
        model.wifiHost = "192.168.1.50"
        model.startSimulator()
        defer { model.stopSimulator() }
        try await Self.waitUntil(timeout: .seconds(30)) { model.phase == .connected && model.status?.horizontal != nil } failure: {
            "not connected: \(model.simulatorState), phase \(model.phase), error \(model.lastError ?? "none"), log \(model.log.suffix(6).map(\.text))"
        }

        #expect(model.isSimulated)
        #expect(model.status?.protocolKind == .aux)
        #expect(model.canNudge)
        #expect(model.wifiHost == "192.168.1.50", "the saved address is left alone")
        let start = try #require(model.status?.horizontal)
        #expect(abs(start.azimuth) < 0.01 && abs(start.altitude) < 0.01, "switched on at home, level and pointing north")

        model.movementEnabled = true
        model.pressArrow(.azimuth, positive: true)
        try await Task.sleep(for: .seconds(2))
        model.releaseArrow()
        await model.releaseControls()
        try await Task.sleep(for: .seconds(1.5))
        let moved = Astronomy.shortTurn(from: start.azimuth, to: try #require(model.status?.horizontal).azimuth)
        #expect(moved > 0.5, "moved \(moved)°")

        // The simulator's camera: chosen when it starts, and its frames keep coming (a frame takes about 1 ms to draw
        // even in a debug build; a busy CI machine still manages only about 10 a second).
        camera.simulatorChanged()
        #expect(camera.isSimulated)
        camera.startPreview()
        try await Self.waitUntil(timeout: .seconds(10)) { camera.previewImage != nil && camera.stats.framesPerSecond > 0 }
        try await Task.sleep(for: .seconds(2))
        #expect(camera.stats.framesPerSecond > 5, "\(camera.stats.framesPerSecond) fps")
        #expect(!camera.controls.isEmpty, "exposure and gain")
        camera.stopPreview()

        model.stopSimulator()
        camera.simulatorChanged()
        #expect(model.phase == .idle)
        #expect(!camera.cameras.contains { $0.id == SimulatedCamera.id })
    }

    /// Go to the Sun asks for the solar filter checklist every time, records each confirmation with the date and time,
    /// and only then lifts the Sun rules (Solar mode), until it's ended or the connection goes.
    @Test func goToTheSunNeedsTheFilterConfirmedEveryTimeAndRecordsIt() async throws {
        // At local noon, with a home calibration that makes the simulated mount read 3° west of the Sun.
        let observer = Observer(latitude: 38.89, longitude: Self.longitude(sunHourAngle: 0))
        let sun = Astronomy.horizontal(Astronomy.sunPosition(at: .now), at: .now, observer: observer)
        let home = AxisCalibration(azimuthOffset: 165 - (sun.azimuth - 3), altitudeOffset: 38 - sun.altitude)
        let rig = try await Rig(home: home, sunHourAngle: 0)
        defer { rig.tearDown() }
        let model = rig.model
        let record = rig.logFolder.appendingPathComponent("Solar filter confirmations.txt")
        model.offerHome = false
        model.useHome()
        try await rig.waitUntil { model.status?.calibration == home }
        model.movementEnabled = true
        model.verticalEnabled = true
        #expect(model.sunProblem(.azimuth, by: 1) != nil, "the Sun rules apply until the filter is confirmed")

        model.requestGoTo(.sun)
        #expect(model.pendingSolarGoTo, "asks for the checklist")
        #expect(model.driving == nil && model.solarMode == nil, "nothing moves or unlocks before confirming")
        #expect(!FileManager.default.fileExists(atPath: record.path))

        model.confirmSolarGoTo()
        #expect(model.solarMode != nil)
        #expect(model.motionPolicy.solarMode)
        let text = try String(contentsOf: record, encoding: .utf8)
        #expect(text.contains("Solar filter confirmed by the user"), "\(text)")
        let today = DateFormatter()
        today.dateFormat = "yyyy-MM-dd" // local, as the record is
        #expect(text.contains(today.string(from: .now)), "dated: \(text)")
        try await rig.waitUntil(timeout: .seconds(20)) { model.driving == nil } failure: { "still driving: \(model.lastError ?? "")" }
        #expect(model.lastError == nil, "\(String(describing: model.lastError))")
        #expect(model.arrivedAt == "Sun")

        // Asked again next time, even in Solar mode; each confirmation is another line.
        model.requestGoTo(.sun)
        #expect(model.pendingSolarGoTo)
        model.confirmSolarGoTo()
        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").filter { $0.contains("Solar filter confirmed by the user") }
        #expect(lines.count == 2)

        model.endSolarMode()
        #expect(model.solarMode == nil && !model.motionPolicy.solarMode)
        #expect(model.driving == nil, "a Go to the Sun stops with Solar mode")
        model.requestGoTo(.sun)
        model.confirmSolarGoTo()
        #expect(model.solarMode != nil)
        model.disconnect()
        #expect(model.solarMode == nil, "Disconnect ends Solar mode")
    }

    /// An abandoned connection attempt that only gives up after a new connection is made mustn't tear the new one
    /// down (that left Stop doing nothing).
    @Test func aConnectAttemptAbandonedByDisconnectLeavesTheNextConnectionAlone() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        let model = rig.model
        let simulatorPort = model.wifiPort

        model.disconnect()
        model.wifiHost = "192.0.2.1" // TEST-NET-1: never answers, so connecting hangs until its 5 s timeout
        model.connect()
        try await Task.sleep(for: .milliseconds(300))
        model.disconnect()
        model.wifiHost = "127.0.0.1"
        model.wifiPort = simulatorPort
        model.connect()
        try await rig.waitUntil { model.phase == .connected }
        model.movementEnabled = true

        try await Task.sleep(for: .seconds(6)) // past the abandoned attempt's timeout
        #expect(model.movementEnabled)
        model.stopTelescope()
        try await rig.waitUntil(timeout: .seconds(5)) {
            model.log.contains { $0.text == "Stop acknowledged by the mount." }
        } failure: { "Stop didn't reach the mount" }
    }

    @Test func goToRefusesAStarBelowTheHorizon() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        let model = rig.model
        model.movementEnabled = true
        model.verticalEnabled = true
        model.calibrateLevel()
        try await Rig.waitUntil { model.calibration != nil }

        let set = try #require(SkyTarget.brightStars.first { (model.pointing(of: .star($0))?.altitude ?? 90) < -5 })
        model.requestGoTo(set)
        #expect(model.pendingGoTo == nil, "no confirmation for a star that can't be reached")
        #expect(model.lastError?.contains("below the horizon") == true, "\(String(describing: model.lastError))")
    }
}

extension MonitorModelTests.Rig {
    static func waitUntil(timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool) async throws {
        try await MonitorModelTests.waitUntil(timeout: timeout, condition)
    }

    @MainActor
    func waitUntil(timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool,
                   failure: @MainActor () -> String = { "timed out waiting" }) async throws {
        try await MonitorModelTests.waitUntil(timeout: timeout, condition, failure: failure)
    }
}
