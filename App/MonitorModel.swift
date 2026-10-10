import Foundation
import NexStarSimulator
import Observation
import ScopeKit

@MainActor
@Observable
final class MonitorModel {
    enum Kind: String, CaseIterable, Identifiable {
        case wifiModule, usbHandController, networkHandController

        var id: Self { self }

        /// The connections this device can make: iOS has no serial ports, so no USB hand controller.
        static var available: [Kind] {
            #if os(macOS)
            allCases
            #else
            [.wifiModule, .networkHandController]
            #endif
        }

        var title: String {
            switch self {
            case .wifiModule: "WiFi module"
            case .usbHandController: "USB hand controller"
            case .networkHandController: BuildMode.isDebug ? "Network / simulator" : "Network adapter"
            }
        }

        var help: String {
            switch self {
            case .wifiModule:
                "Close the SkyPortal app first: the module accepts one connection at a time. On the module's own network (Celestron-XX) the address is 1.2.3.4; on your home or Starlink network, click Find. Shows motor angles; full sky coordinates need \(Kind.available.contains(.usbHandController) ? "the USB option" : "the hand controller's USB connection, from a Mac")."
            case .usbHandController:
                "Plug a USB cable into the hand controller. Shows full sky coordinates (RA/Dec) plus azimuth and altitude."
            case .networkHandController:
                BuildMode.isDebug
                    ? "Hand-controller protocol over the network, e.g. a SkyFi adapter. To try scopeOS without the telescope, click Start Simulator."
                    : "Hand-controller protocol over the network, e.g. a SkyFi adapter plugged into the hand controller."
            }
        }
    }

    enum Phase: Equatable {
        case idle, connecting, connected, waitingToRetry
    }

    enum SimulatorState: Equatable {
        case off, starting, running
    }

    static let azimuthSteps = [0.1, 0.5, 1.0, 1.5, 2.0, 5.0]
    static let altitudeSteps = [0.1, 0.5, 1.0, 1.5]

    static let simulatorAuxPort: UInt16 = 2000
    static let simulatorHandControllerPort: UInt16 = 2001

    private let defaults: UserDefaults
    private let location: LocationModel

    var kind: Kind { didSet { defaults.set(kind.rawValue, forKey: "kind") } }
    var wifiHost: String { didSet { defaults.set(wifiHost, forKey: "wifiHost") } }
    var wifiPort: String { didSet { defaults.set(wifiPort, forKey: "wifiPort") } }
    var networkHost: String { didSet { defaults.set(networkHost, forKey: "networkHost") } }
    var networkPort: String { didSet { defaults.set(networkPort, forKey: "networkPort") } }
    var serialPath: String { didSet { defaults.set(serialPath, forKey: "serialPath") } }

    private(set) var phase: Phase = .idle
    private(set) var status: MountStatus?
    private(set) var lastError: String?
    private(set) var log: [TrafficEntry] = []
    private(set) var pollTime: Duration?
    private(set) var availablePorts: [String] = []
    private(set) var simulatorState: SimulatorState = .off

    /// Network search for WiFi modules (the Find button).
    private(set) var finding = false
    /// When the current search started, for the elapsed time.
    private(set) var findStarted: Date?
    private var findTask: Task<Void, Never>?
    private(set) var foundTelescopes: [TelescopeFinder.Found] = []
    private(set) var findMessage: String?

    /// Deliberately not saved. Debug builds start with movement off and turn it off on disconnect; release builds
    /// hide the switches and turn movement on whenever a connection is made.
    var movementEnabled = false {
        didSet {
            if !movementEnabled {
                verticalEnabled = false
                releaseArrow()
            }
        }
    }
    /// A second switch just for altitude, which only works while `movementEnabled` is on. Turning it on always
    /// starts back at the smallest step.
    var verticalEnabled = false {
        didSet {
            if verticalEnabled && !movementEnabled { verticalEnabled = false }
            guard verticalEnabled != oldValue else { return } // release builds set it on every reconnect
            altitudeStep = Self.altitudeSteps[0]
            if !verticalEnabled, activeMove?.axis == .altitude { releaseArrow() }
        }
    }
    var azimuthStep = 0.5
    var altitudeStep = altitudeSteps[0]
    private(set) var nudgeInFlight = false

    /// The arrow being held, if any.
    private(set) var activeMove: (id: UUID, axis: NudgeAxis, positive: Bool, started: Date)?
    /// The focus button being held, if any.
    private(set) var activeFocus: (id: UUID, positive: Bool, started: Date)?
    private(set) var focusInFlight = false
    var focusStep = 50
    static let focusSteps = [10, 50, 250, 1000]
    /// Why the last hold ended, when it wasn't the user letting go.
    private(set) var controlNotice: String?
    static let holdSeconds = HeldMove.defaultTimeLimit.components.seconds
    static let focusHoldSeconds = HeldMove.defaultFocusTimeLimit.components.seconds

    /// Calibration of the WiFi module's motor angles, kept across automatic reconnects (the motors keep counting
    /// unless the mount is switched off) and cleared by Disconnect.
    private(set) var calibration: AxisCalibration?
    /// A calibration saved for when the mount is switched on at its home marks (the elevation index on the fork
    /// arm, plus a mark between the arm and the base), so it can be reused without calibrating again. Kept between
    /// launches, and only applied once the user confirms the mount was switched on there.
    private(set) var home: AxisCalibration?
    /// True while asking whether the mount was switched on at its home marks.
    var offerHome = false
    /// Whether this connection has already asked, so declining isn't asked again on an automatic reconnect.
    private var homeAsked = false
    private var heldMove: HeldMove?
    /// Presses and releases run strictly in the order they happened.
    private var controlChain: Task<Void, Never>?

    func isEnabled(_ axis: NudgeAxis) -> Bool {
        axis == .azimuth ? movementEnabled : movementEnabled && verticalEnabled
    }

    /// True when connected over the WiFi module, the only connection nudging supports.
    var canNudge: Bool { phase == .connected && status?.protocolKind == .aux }

    /// Refuse every move while the Sun is up. Deliberately not saved: back on at every launch.
    var sunLockWhileUp = true

    private var task: Task<Void, Never>?
    private var activeSettings: ConnectionSettings?
    private var connectedClient: (any MountClient)?
    private var simulators: [SimulatorServer] = []
    /// About six minutes of WiFi polling; the file in `TrafficLogFile.folder` keeps everything.
    private static let maxLogEntries = 5_000
    private let logFile: TrafficLogFile

    var isRunning: Bool { task != nil }

    /// A connection with no reading for longer than this shows as stale in the header: something is failing, even
    /// if it hasn't errored out yet. Normally a reading arrives every second or two.
    static let staleAfter: TimeInterval = 5

    /// Seconds since the last reading, while connected.
    func readingAge(at date: Date = .now) -> TimeInterval? {
        guard phase == .connected, let updated = status?.updated else { return nil }
        return max(0, date.timeIntervalSince(updated))
    }

    func isLinkStale(at date: Date = .now) -> Bool {
        (readingAge(at: date) ?? 0) > Self.staleAfter
    }

    /// Failed connection attempts in a row, and when the next one is due while waiting to retry.
    private(set) var retryAttempt = 0
    private(set) var retryAt: Date?


    /// `defaults` and `logFolder` are where settings and the traffic log are kept (tests use their own).
    init(location: LocationModel, defaults: UserDefaults = .standard, logFolder: URL = TrafficLogFile.folder) {
        self.location = location
        self.defaults = defaults
        logFile = TrafficLogFile(folder: logFolder)
        kind = Kind(rawValue: defaults.string(forKey: "kind") ?? "").flatMap { Kind.available.contains($0) ? $0 : nil } ?? .wifiModule
        wifiHost = defaults.string(forKey: "wifiHost") ?? "1.2.3.4"
        wifiPort = defaults.string(forKey: "wifiPort") ?? "2000"
        networkHost = defaults.string(forKey: "networkHost") ?? "127.0.0.1"
        networkPort = defaults.string(forKey: "networkPort") ?? "2001"
        serialPath = defaults.string(forKey: "serialPath") ?? ""
        if let saved = defaults.dictionary(forKey: "homeCalibration"),
           let azimuth = saved["azimuthOffset"] as? Double, let altitude = saved["altitudeOffset"] as? Double {
            home = AxisCalibration(azimuthOffset: azimuth, altitudeOffset: altitude)
        }
        refreshPorts()
    }

    func refreshPorts() {
        availablePorts = SerialTransport.availablePorts()
        if serialPath.isEmpty || !availablePorts.contains(serialPath) {
            serialPath = availablePorts.first(where: { $0.contains("usb") }) ?? availablePorts.first ?? ""
        }
    }

    func connect() {
        guard task == nil else { return }
        let settings: ConnectionSettings
        do {
            settings = try makeSettings()
        } catch {
            lastError = error.localizedDescription
            return
        }
        lastError = nil
        status = nil
        retryAttempt = 0
        retryAt = nil
        homeAsked = false
        pausedSettings = nil
        activeSettings = settings
        task = Task { await run(settings) }
    }

    func disconnect() {
        // Queued while the client is still connected; the connection task waits for them before closing it.
        releaseArrow()
        releaseFocus()
        cancelDrive()
        task?.cancel()
        task = nil
        connectedClient = nil
        calibration = nil // the mount may be switched off or moved before the next connection
        offerHome = false
        offerReturnHome = false
        checkReturnHome = false
        pendingGoTo = nil
        driving = nil
        planAfter = nil
        arrivedAt = nil
        azimuthTrack = nil
        activeSettings = nil
        pausedSettings = nil
        movementEnabled = false
        heldMove = nil
        activeMove = nil
        activeFocus = nil
        phase = .idle
        append(TrafficEntry(.note, "Disconnected."))
    }

    // MARK: Leaving the screen (iOS)

    /// The connection `pause()` closed, to reopen on `resume()`.
    private var pausedSettings: ConnectionSettings?
    /// Between `pause()` and `resume()`: coming back while the stops are still going out keeps the connection.
    private var leaving = false

    /// For when iOS is about to suspend the app: stops everything moving (a held arrow or focus button, Return to
    /// home, Go to), waits for those stops to go out, then closes the connection, so no move is left half-done while
    /// the app can't run, and the WiFi module is free for other apps. Like an automatic reconnect, it keeps the
    /// calibration (the motors keep counting while the mount stays on) and doesn't ask about the home position again.
    func pause() async {
        leaving = true
        await releaseControls()
        guard leaving, let running = task, let settings = activeSettings else { return }
        pausedSettings = settings
        running.cancel()
        task = nil
        connectedClient = nil
        movementEnabled = false
        heldMove = nil
        activeMove = nil
        activeFocus = nil
        driving = nil
        planAfter = nil
        arrivedAt = nil
        pendingGoTo = nil // a move needs asking for afresh once back
        append(TrafficEntry(.note, "Paused: scopeOS left the screen."))
        await running.value // closes the connection
        if task == nil { phase = .idle } // unless `resume()` has already started a new one
    }

    /// Reopens the connection `pause()` closed.
    func resume() {
        leaving = false
        guard let settings = pausedSettings else { return }
        pausedSettings = nil
        guard task == nil else { return }
        lastError = nil
        retryAttempt = 0
        retryAt = nil
        activeSettings = settings
        append(TrafficEntry(.note, "Back on screen: reconnecting."))
        task = Task { await run(settings) }
    }

    /// Searches the local network for WiFi modules and fills in the first one found.
    func findTelescope() {
        guard !finding, !isRunning else { return }
        finding = true
        findStarted = .now
        findMessage = "Searching this network…"
        foundTelescopes = []
        findTask = Task {
            let found = await TelescopeFinder.findOnLocalNetwork()
            finding = false
            findTask = nil
            foundTelescopes = found
            if Task.isCancelled, found.isEmpty {
                findMessage = "Search cancelled."
            } else if let first = found.first {
                useFoundTelescope(first)
                findMessage = found.count == 1 ? "Found the telescope at \(first.host)." : "Found \(found.count) telescopes; using \(first.host)."
            } else {
                findMessage = "No telescope found on this network. Check the mount is on, its WiFi module has joined this network (light flashing slowly), and the SkyPortal app is closed."
            }
            append(TrafficEntry(.note, findMessage ?? ""))
        }
    }

    /// Stops a search; it ends within a second, keeping anything already found.
    func cancelFind() {
        findTask?.cancel()
    }

    func useFoundTelescope(_ telescope: TelescopeFinder.Found) {
        wifiHost = telescope.host
        wifiPort = String(telescope.port)
    }

    func clearLog() {
        log.removeAll()
    }

    /// Asks the mount to stop any slew or GoTo. This is the only command scopeOS sends that acts on the mount,
    /// and it can only stop motion, never start it.
    func stopTelescope() {
        guard let client = connectedClient else { return }
        releaseArrow()
        releaseFocus()
        cancelDrive()
        append(TrafficEntry(.note, "Stop requested."))
        Task {
            do {
                try await client.stop()
                append(TrafficEntry(.note, "Stop acknowledged by the mount."))
            } catch {
                lastError = "Stop may not have reached the mount: \(error.localizedDescription)"
            }
        }
    }

    /// Runs a simulated mount inside the app on 127.0.0.1 and, unless already connected elsewhere, connects to it.
    func startSimulator() {
        guard simulatorState == .off else { return }
        simulatorState = .starting
        Task { await launchSimulator() }
    }

    func stopSimulator() {
        if let activeSettings, Self.pointsAtSimulator(activeSettings) { disconnect() }
        simulators.forEach { $0.stop() }
        simulators = []
        simulatorState = .off
        append(TrafficEntry(.note, "Simulator stopped."))
    }

    /// Nudges one axis in the given direction (+1 or −1) by that axis's chosen step.
    /// The client refuses if the mount is moving; the per-step caps and altitude band are enforced again on the
    /// bytes that go out.
    func nudge(_ axis: NudgeAxis, direction: Double) {
        guard isEnabled(axis), canNudge, !nudgeInFlight, activeMove == nil, activeFocus == nil, driving == nil,
              let client = connectedClient else { return }
        let step = direction * (axis == .azimuth ? azimuthStep : altitudeStep)
        arrivedAt = nil
        if let problem = sunProblem(axis, by: step) {
            lastError = problem
            return
        }
        nudgeInFlight = true
        controlNotice = nil
        Task {
            defer { nudgeInFlight = false }
            do {
                try await client.nudge(axis, by: step)
                lastError = nil
            } catch {
                lastError = "Nudge not sent: \(error.localizedDescription)"
            }
        }
    }

    /// Moves while an arrow is held, in bounded steps (see `HeldMove`), until it's released, the next step would
    /// come near the Sun or leave the altitude band, or `holdSeconds` pass.
    func pressArrow(_ axis: NudgeAxis, positive: Bool) {
        guard isEnabled(axis), canNudge, !nudgeInFlight, activeMove == nil, activeFocus == nil, driving == nil,
              let heldMove else { return }
        // Checked against the first step's full reach, since where it actually stops depends on when it's released.
        let reach = (positive ? 1 : -1) * axis.maxStepDegrees
        if let problem = sunProblem(axis, by: reach) {
            lastError = problem
            return
        }
        let id = UUID()
        activeMove = (id, axis, positive, .now)
        arrivedAt = nil
        controlNotice = nil
        enqueue {
            do {
                try await heldMove.begin(axis, positive: positive, mayContinue: { [weak self] axis, positive in
                    await self?.holdStepProblem(id, axis, positive)
                }, onEnded: { [weak self] ending in
                    Task { @MainActor in self?.holdEnded(id, ending) }
                })
            } catch {
                guard self.activeMove?.id == id else { return }
                self.activeMove = nil
                self.lastError = "Move not started: \(error.localizedDescription)"
            }
        }
    }

    func releaseArrow() {
        guard activeMove != nil, let heldMove else {
            activeMove = nil
            return
        }
        activeMove = nil
        enqueue {
            do {
                try await heldMove.end()
            } catch {
                self.lastError = "Stop may not have reached the mount: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Focus motor

    /// True when connected over WiFi to a focus motor that has reported its calibrated range.
    var canFocus: Bool {
        canNudge && status?.focuserPosition != nil && status?.focuserLimits != nil
    }

    /// Moves the focus motor by `focusStep` (clipped to the largest allowed step) in the given direction.
    func focus(direction: Int) {
        guard let limits = status?.focuserLimits else { return }
        focus(steps: direction * min(focusStep, FocusCommand.maxStep(limits)))
    }

    /// Moves the focuser to `position` (the focus aid's best reading), if that's one allowed move away.
    /// The client works the move out from the focuser's position when it sends it, not from the last reading.
    func focus(toPosition position: Int) {
        guard let current = status?.focuserPosition, position != current else { return }
        sendFocus { try await $0.focus(to: position) }
    }

    private func focus(steps: Int) {
        sendFocus { try await $0.focus(by: steps) }
    }

    private func sendFocus(_ move: @escaping (any MountClient) async throws -> Void) {
        guard canFocus, !focusInFlight, activeFocus == nil, activeMove == nil, let client = connectedClient else { return }
        focusInFlight = true
        controlNotice = nil
        Task {
            defer { focusInFlight = false }
            do {
                try await move(client)
                lastError = nil
            } catch {
                lastError = "Focus move not sent: \(error.localizedDescription)"
            }
        }
    }

    func pressFocus(positive: Bool) {
        guard canFocus, !focusInFlight, activeFocus == nil, activeMove == nil, let heldMove else { return }
        let id = UUID()
        activeFocus = (id, positive, .now)
        controlNotice = nil
        enqueue {
            do {
                try await heldMove.beginFocus(positive: positive) { [weak self] ending in
                    Task { @MainActor in self?.focusEnded(id, ending) }
                }
            } catch {
                guard self.activeFocus?.id == id else { return }
                self.activeFocus = nil
                self.lastError = "Focus move not started: \(error.localizedDescription)"
            }
        }
    }

    func releaseFocus() {
        guard activeFocus != nil, let heldMove else {
            activeFocus = nil
            return
        }
        activeFocus = nil
        enqueue {
            do {
                try await heldMove.end()
            } catch {
                self.lastError = "Focus stop may not have reached the motor: \(error.localizedDescription)"
            }
        }
    }

    /// Lets go of any held arrow or focus button, cancels a Go to or Return to home, and returns once every queued
    /// press and release has gone out, so quitting can't leave a move running or skip a stop the user already asked for.
    func releaseControls() async {
        releaseArrow()
        releaseFocus()
        cancelDrive()
        await controlChain?.value
    }

    private func focusEnded(_ id: UUID, _ ending: HeldMove.Ending) {
        guard activeFocus?.id == id else { return }
        activeFocus = nil
        switch ending {
        case .timeLimit: controlNotice = "Focus stopped after \(Self.focusHoldSeconds) seconds. Release and press again to keep going."
        case .stopped(let reason): controlNotice = "Focus stopped: \(reason)"
        case .stopFailed(let error): lastError = "Focus stop may not have reached the motor: \(error)"
        case .arrived: break
        }
    }

    private func holdEnded(_ id: UUID, _ ending: HeldMove.Ending) {
        guard activeMove?.id == id else { return }
        activeMove = nil
        switch ending {
        case .timeLimit: controlNotice = "Stopped after \(Self.holdSeconds) seconds. Release and press again to keep moving."
        case .stopped(let reason): controlNotice = "Stopped: \(reason)"
        case .stopFailed(let error): lastError = "Stop may not have reached the mount: \(error)"
        case .arrived: break
        }
    }

    /// Checked before each further step of a hold. Positions are read once a second, so it looks two steps ahead.
    private func holdStepProblem(_ id: UUID, _ axis: NudgeAxis, _ positive: Bool) -> String? {
        guard activeMove?.id == id else { return "The arrow was released." }
        return sunProblem(axis, by: (positive ? 2 : -2) * axis.maxStepDegrees)
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = controlChain
        controlChain = Task {
            await previous?.value
            await operation()
        }
    }

    /// The Sun rules the client enforces on every move. The checks here (`movementLock`, `sunProblem`) run first,
    /// to grey out controls and explain refusals; the client's are the guarantee.
    var motionPolicy: MotionPolicy { MotionPolicy(observer: location.observer, lockWhileSunUp: sunLockWhileUp) }

    /// Why no move is possible right now regardless of direction, or nil.
    func movementLock(at date: Date = .now) -> String? {
        guard let observer = location.observer else {
            return "Set your location in the Site panel first, so moves can be kept away from the Sun."
        }
        if sunLockWhileUp, SunSituation(observer: observer, date: date).darkness == .day {
            return "The Sun is up, so movement is locked. Turn off \"Lock while the Sun is up\" to override."
        }
        guard status?.horizontal != nil else { return "Waiting for a position reading." }
        return nil
    }

    /// Why a move of `axis` by `degrees` isn't allowed because of the Sun, or nil. Checked along the whole path.
    func sunProblem(_ axis: NudgeAxis, by degrees: Double, at date: Date = .now) -> String? {
        if let lock = movementLock(at: date) { return lock }
        guard let observer = location.observer, let pointing = status?.horizontal else { return nil }
        let sun = SunSituation(observer: observer, date: date).position
        return SunSafety.check(axis, by: degrees, from: pointing, sun: sun)
    }

    // MARK: Calibration (WiFi module)

    var isCalibrated: Bool { calibration != nil }

    /// The tube is level now (checked with a spirit level or the iPhone's Measure app).
    func calibrateLevel() { calibrate(azimuth: nil, altitude: 0, what: "Altitude calibrated: the tube is level.") }

    /// The tube points to true north now.
    func calibrateNorth() { calibrate(azimuth: 0, altitude: nil, what: "Azimuth calibrated: the tube points north.") }

    /// Polaris is centred in the eyepiece or camera: sets both axes from where Polaris is right now.
    func calibratePolaris() {
        guard let observer = location.observer else {
            lastError = "Set your location in the Site panel first, so scopeOS knows where Polaris is."
            return
        }
        let now = Date.now
        let polaris = Astronomy.horizontal(SkyTarget.polaris.position(at: now), at: now, observer: observer)
        calibrate(azimuth: polaris.azimuth, altitude: polaris.altitude, what: "Calibrated on Polaris.")
    }

    /// Applies the saved home calibration: the mount was switched on at its home marks.
    func useHome() {
        offerHome = false
        guard let home, let client = connectedClient else { return }
        calibration = home
        checkReturnHome = true
        Task {
            await client.setCalibration(home)
            append(TrafficEntry(.note, String(format: "Using the home calibration (motor offsets %.2f° az, %.2f° alt).",
                                              home.azimuthOffset, home.altitudeOffset)))
        }
    }

    /// Saves the current calibration as the home one. Only right if this session's mount was switched on at the
    /// home marks, since the offsets count from wherever the motors were at power-on.
    func saveHome() {
        guard let calibration else { return }
        home = calibration
        defaults.set(["azimuthOffset": calibration.azimuthOffset, "altitudeOffset": calibration.altitudeOffset], forKey: "homeCalibration")
        append(TrafficEntry(.note, "Saved this calibration as the home position."))
    }

    func forgetHome() {
        home = nil
        offerHome = false
        defaults.removeObject(forKey: "homeCalibration")
        append(TrafficEntry(.note, "Forgot the home position."))
    }

    /// Asks once per connection, over the WiFi module, whether to use the saved home calibration.
    private func offerHomeIfNeeded(_ status: MountStatus) {
        guard !homeAsked, status.protocolKind == .aux, calibration == nil, home != nil else { return }
        homeAsked = true
        offerHome = true
    }

    // MARK: Driving to a position (Return to home, Go to)

    /// Somewhere scopeOS can drive the scope.
    enum Destination: Equatable {
        case home
        case star(SkyTarget)

        var name: String {
            switch self {
            case .home: "the home position"
            case .star(let star): star.name
            }
        }
    }

    /// The drive under way: where to, the sky position its route was planned for (nil while waiting to plan it),
    /// and how many correcting moves have followed it (a star moves on while the scope travels).
    private(set) var driving: (id: UUID, destination: Destination, target: Horizontal?, pass: Int)?
    /// A drive is planned only from a position read after this, so a reading from before the scope stopped moving
    /// can't send it the wrong way round.
    private var planAfter: Date?
    /// The star the last Go to reached, until something moves the scope again.
    private(set) var arrivedAt: String?
    /// True while asking whether to drive back to the home position.
    var offerReturnHome = false
    /// A Go to waiting for confirmation.
    var pendingGoTo: SkyTarget?
    /// Set by confirming the home position on connect: once the readings use it, ask if the scope isn't there.
    private var checkReturnHome = false
    /// The azimuth motor angle at this connection's first reading, the latest one, and how far it has turned in
    /// between (counting whole turns), so drives can keep the camera cable from winding up.
    private var azimuthTrack: CableTrack?
    /// Correcting moves after arriving at a star.
    static let maxCorrections = 2

    var isReturningHome: Bool { driving?.destination == .home }

    /// The home position in sky angles: where the motors read zero under the home calibration.
    var homePointing: Horizontal? { home?.sky(fromMotor: Horizontal(azimuth: 0, altitude: 0)) }

    /// Whether the scope points at the home position, to within 0.1°.
    var isAtHome: Bool {
        guard let target = homePointing, let pointing = status?.horizontal else { return false }
        return abs(Astronomy.shortTurn(from: pointing.azimuth, to: target.azimuth)) < 0.1 && abs(pointing.altitude - target.altitude) < 0.1
    }

    /// Where `destination` is in the sky at `date`, or nil if that isn't known yet.
    func pointing(of destination: Destination, at date: Date = .now) -> Horizontal? {
        switch destination {
        case .home: homePointing
        case .star(let star): location.observer.map { star.horizontal(at: date, observer: $0) }
        }
    }

    /// Why no drive can start right now, or nil.
    var driveProblem: String? {
        guard calibration != nil else { return "Calibrate first, so scopeOS knows where the scope points." }
        guard canNudge else { return "Only available over the WiFi module." }
        guard isEnabled(.azimuth), isEnabled(.altitude) else { return "Turn on Enable movement and Enable up/down first." }
        guard activeMove == nil, activeFocus == nil, driving == nil, !nudgeInFlight else { return "Wait for the current move to finish." }
        return nil
    }

    /// Why Return to home can't start right now, or nil.
    var returnHomeProblem: String? {
        guard home != nil else { return "Save a home position first (Calibrate › Save as home position)." }
        if let problem = driveProblem { return problem }
        guard !isAtHome else { return "Already at the home position." }
        return nil
    }

    /// Why Go to `star` isn't possible right now, or nil.
    func goToProblem(_ star: SkyTarget) -> String? {
        if let problem = driveProblem ?? movementLock() { return problem }
        if case .failure(let problem) = route(to: .star(star)) { return problem.reason }
        return nil
    }

    /// Drives the scope back to the home position, one axis at a time, in the same bounded steps as a hold.
    func returnHome() {
        offerReturnHome = false
        if let problem = returnHomeProblem ?? movementLock() {
            lastError = "Not returning to home: \(problem)"
            return
        }
        drive(to: .home, pass: 0)
    }

    /// Asks for confirmation before a Go to, or says why it isn't possible.
    func requestGoTo(_ star: SkyTarget) {
        if let problem = goToProblem(star) {
            lastError = "Can't go to \(star.name): \(problem)"
            return
        }
        pendingGoTo = star
    }

    /// Points the scope at `star`, worked out from the location and the time, like Return to home.
    func goTo(_ star: SkyTarget) {
        pendingGoTo = nil
        if let problem = goToProblem(star) {
            lastError = "Not going to \(star.name): \(problem)"
            return
        }
        drive(to: .star(star), pass: 0)
    }

    /// What the Go to confirmation says about `star`.
    func goToSummary(_ star: SkyTarget) -> String {
        guard let sky = pointing(of: .star(star)) else { return "" }
        return String(format: "It is %.0f° up in the %@ (azimuth %.0f°). scopeOS moves one axis at a time in small steps, checks the Sun on the way, and corrects for the sky's turning when it gets there. Stop cancels it. How close it lands depends on your calibration.",
                      sky.altitude, SkyFormat.compassPoint(sky.azimuth), sky.azimuth)
    }

    /// Starts a drive; its route is planned at the next position reading.
    private func drive(to destination: Destination, pass: Int) {
        driving = (UUID(), destination, nil, pass)
        planAfter = .now
        arrivedAt = nil
        controlNotice = nil
        append(TrafficEntry(.note, pass == 0 ? "Going to \(destination.name)." : "\(destination.name) has moved on with the sky: correcting."))
    }

    /// Plans the waiting drive from a fresh position reading and sets it going.
    private func startPlannedDrive() {
        guard let waiting = driving, waiting.target == nil else { return }
        guard let heldMove else {
            driving = nil
            return
        }
        let destination = waiting.destination, id = waiting.id
        let planned: (legs: [HeldMove.Leg], target: Horizontal)
        switch route(to: destination) {
        case .success(let route): planned = route
        case .failure(let problem):
            driving = nil
            lastError = "Not going to \(destination.name): \(problem.reason)"
            return
        }
        driving?.target = planned.target
        enqueue {
            do {
                try await heldMove.goTo(planned.legs, mayContinue: { [weak self] axis, positive in
                    await self?.driveStepProblem(id, axis, positive)
                }, onEnded: { [weak self] ending in
                    Task { @MainActor in self?.driveEnded(id, ending) }
                })
            } catch {
                guard self.driving?.id == id else { return }
                self.driving = nil
                self.lastError = "Not going to \(destination.name): \(error.localizedDescription)"
            }
        }
    }

    /// Cancels Return to home or Go to.
    func cancelDrive() {
        planAfter = nil
        guard driving?.target != nil, let heldMove else {
            driving = nil
            return
        }
        driving = nil
        enqueue {
            do {
                try await heldMove.end()
            } catch {
                self.lastError = "Stop may not have reached the mount: \(error.localizedDescription)"
            }
        }
    }

    private func driveEnded(_ id: UUID, _ ending: HeldMove.Ending) {
        guard let drive = driving, drive.id == id else { return }
        driving = nil
        switch ending {
        case .arrived:
            guard case .star(let star) = drive.destination else {
                append(TrafficEntry(.note, "Back at the home position."))
                return
            }
            // The sky turned while the scope moved: if the star has gone on more than a little, follow it.
            if drive.pass < Self.maxCorrections, let now = pointing(of: drive.destination), let planned = drive.target,
               Astronomy.separation(now, planned) > 0.02 {
                self.drive(to: drive.destination, pass: drive.pass + 1)
            } else {
                arrivedAt = star.name
                append(TrafficEntry(.note, "At \(star.name)."))
            }
        case .stopped(let reason):
            controlNotice = "\(drive.destination == .home ? "Return to home" : "Go to \(drive.destination.name)") stopped: \(reason)"
        case .stopFailed(let error):
            lastError = "Stop may not have reached the mount: \(error)"
        case .timeLimit:
            break
        }
    }

    struct RouteProblem: Error { let reason: String }

    /// The way to `destination` from where the scope points now (see `DriveRoute`). Azimuth turns back the way it
    /// came to get home, and otherwise the short way unless that winds the camera cable too far (see `CableTrack`).
    private func route(to destination: Destination) -> Result<(legs: [HeldMove.Leg], target: Horizontal), RouteProblem> {
        guard let pointing = status?.horizontal else { return .failure(RouteProblem(reason: "waiting for a position reading.")) }
        guard let observer = location.observer, let target = self.pointing(of: destination) else {
            return .failure(RouteProblem(reason: "set your location first."))
        }
        let turn: Double
        switch (destination, azimuthTrack, calibration) {
        case (.home, let track?, let calibration?): turn = track.turnHome(homeMotor: target.azimuth + calibration.azimuthOffset) // motor = sky + offset
        case (_, let track?, _): turn = track.turn(from: pointing.azimuth, to: target.azimuth)
        default: turn = Astronomy.shortTurn(from: pointing.azimuth, to: target.azimuth)
        }
        let sun = SunSituation(observer: observer, date: .now).position
        let band = NudgeCommand.altitudeLimits
        let what = destination == .home ? "home" : destination.name
        switch DriveRoute.legs(from: pointing, to: target, turn: turn, sun: sun) {
        case .success(let legs):
            return .success((legs, target))
        case .failure(.belowBand(let altitude)):
            return .failure(RouteProblem(reason: destination == .home
                ? String(format: "home is at %.1f° altitude, below the %.0f° limit. Use the hand controller.", altitude, band.lowerBound)
                : "\(what) is below the horizon."))
        case .failure(.aboveBand(let altitude)):
            return .failure(RouteProblem(reason: String(format: "%@ is at %.0f° altitude, above the %.0f° limit.", what, altitude, band.upperBound)))
        case .failure(.nearSun(let reason)):
            return .failure(RouteProblem(reason: "the way there passes too close to the Sun. " + reason))
        }
    }

    /// Checked before each step of a drive: the next stretch must stay clear of the Sun. Positions are read once
    /// a second, so it looks up to two steps ahead (no further than the target).
    private func driveStepProblem(_ id: UUID, _ axis: NudgeAxis, _ positive: Bool) -> String? {
        guard let drive = driving, drive.id == id, let target = drive.target else { return "It was cancelled." }
        guard let pointing = status?.horizontal else { return "Lost the position reading." }
        let remaining = axis == .azimuth
            ? Astronomy.normalize(positive ? target.azimuth - pointing.azimuth : pointing.azimuth - target.azimuth)
            : abs(target.altitude - pointing.altitude)
        let reach = min(2 * axis.maxStepDegrees, max(remaining, 0.25))
        return sunProblem(axis, by: (positive ? 1 : -1) * reach)
    }

    private func trackAzimuth(_ status: MountStatus) {
        guard let motor = status.axisAngles?.azimuth else { return }
        if azimuthTrack == nil {
            azimuthTrack = CableTrack(motorAzimuth: motor)
        } else {
            azimuthTrack?.update(motorAzimuth: motor)
        }
    }

    func clearCalibration() {
        calibration = nil
        guard let client = connectedClient else { return }
        Task {
            await client.setCalibration(nil)
            append(TrafficEntry(.note, "Calibration cleared: readings assume the scope was switched on level and pointing north."))
        }
    }

    private func calibrate(azimuth: Double?, altitude: Double?, what: String) {
        guard canNudge, let client = connectedClient else { return }
        releaseArrow()
        Task {
            do {
                calibration = try await client.calibrate(azimuth: azimuth, altitude: altitude)
                lastError = nil
                append(TrafficEntry(.note, what))
            } catch {
                lastError = "Not calibrated: \(error.localizedDescription)"
            }
        }
    }

    private func launchSimulator() async {
        let sky = SimulatedSky()
        var started: [SimulatorServer] = []
        do {
            for (flavor, port) in [(SimulatorServer.Flavor.aux, Self.simulatorAuxPort), (.handController, Self.simulatorHandControllerPort)] {
                let server = try SimulatorServer(flavor: flavor, port: port, sky: sky, focuser: flavor == .aux)
                server.onEvent = { [weak self] message in
                    Task { @MainActor in self?.append(TrafficEntry(.note, "Simulator: \(message)")) }
                }
                try await server.start()
                started.append(server)
            }
        } catch {
            started.forEach { $0.stop() }
            simulatorState = .off
            lastError = "Could not start the simulator: \(error.localizedDescription). If scopesim is running in a terminal, stop it first."
            return
        }

        simulators = started
        simulatorState = .running
        append(TrafficEntry(.note, "Simulator running on 127.0.0.1: AUX port \(Self.simulatorAuxPort), hand controller port \(Self.simulatorHandControllerPort)."))

        guard !isRunning else { return }
        kind = .networkHandController
        networkHost = "127.0.0.1"
        networkPort = String(Self.simulatorHandControllerPort)
        connect()
    }

    private static func pointsAtSimulator(_ settings: ConnectionSettings) -> Bool {
        let loopback = ["127.0.0.1", "localhost", "::1"]
        switch settings {
        case .wifiModule(let host, let port): return loopback.contains(host) && port == simulatorAuxPort
        case .networkHandController(let host, let port): return loopback.contains(host) && port == simulatorHandControllerPort
        case .usbHandController: return false
        }
    }

    private func makeSettings() throws -> ConnectionSettings {
        func port(_ text: String) throws -> UInt16 {
            guard let value = UInt16(text.trimmingCharacters(in: .whitespaces)), value > 0 else {
                throw MountError.invalidConfiguration("\"\(text)\" is not a valid port number.")
            }
            return value
        }
        switch kind {
        case .wifiModule:
            return .wifiModule(host: wifiHost.trimmingCharacters(in: .whitespaces), port: try port(wifiPort))
        case .usbHandController:
            guard !serialPath.isEmpty else { throw MountError.invalidConfiguration("No serial port selected. Plug in the hand controller and click Refresh.") }
            return .usbHandController(path: serialPath)
        case .networkHandController:
            return .networkHandController(host: networkHost.trimmingCharacters(in: .whitespaces), port: try port(networkPort))
        }
    }

    private func run(_ settings: ConnectionSettings) async {
        let logger: TrafficLogger = { [weak self] entry in
            Task { @MainActor in self?.append(entry) }
        }

        var giveUp = false
        while !Task.isCancelled {
            // The client checks the Sun rules itself before every move, asking for the current ones each time.
            let client = settings.makeClient(log: logger, motionPolicy: { [weak self] in await self?.motionPolicy ?? .refuseAll })
            phase = .connecting
            do {
                try await client.connect()
                await client.setCalibration(calibration)
                // Connecting doesn't notice cancellation; a Disconnect (and maybe a new Connect) may have come since.
                try Task.checkCancellation()
                connectedClient = client
                heldMove = HeldMove(client: client)
                phase = .connected
                lastError = nil
                retryAttempt = 0
                if BuildMode.isRelease {
                    movementEnabled = true
                    verticalEnabled = true
                }
                while !Task.isCancelled {
                    let start = ContinuousClock.now
                    let readStarted = Date.now
                    let latest = try await client.readStatus()
                    guard !Task.isCancelled else { break }
                    status = latest
                    trackAzimuth(latest)
                    offerHomeIfNeeded(latest)
                    if checkReturnHome, latest.calibration != nil, latest.calibration == home {
                        checkReturnHome = false
                        offerReturnHome = !isAtHome
                    }
                    if let after = planAfter, readStarted > after {
                        planAfter = nil
                        startPlannedDrive()
                    }
                    pollTime = ContinuousClock.now - start
                    try await Task.sleep(for: .seconds(1))
                }
            } catch is CancellationError {
                // Disconnect requested.
            } catch {
                if !Task.isCancelled {
                    lastError = settings.problem(error, wasConnected: connectedClient != nil)
                    append(TrafficEntry(.note, "Error: \(lastError ?? error.localizedDescription)"))
                    // Settings that can't work won't start working by retrying.
                    if ConnectionSettings.isPermanent(error) { giveUp = true }
                }
            }
            // After a Disconnect, `disconnect()` has already reset all this, and it may belong to a newer connection.
            if !Task.isCancelled {
                connectedClient = nil
                movementEnabled = false
                heldMove = nil
                activeMove = nil
                activeFocus = nil
                driving = nil
                planAfter = nil
                arrivedAt = nil
            }
            // Let queued releases and stops reach the mount before the connection closes.
            await controlChain?.value
            await client.disconnect()
            guard !Task.isCancelled else { break }
            if giveUp {
                append(TrafficEntry(.note, "Not retrying: fix the connection settings, then click Connect."))
                task = nil
                activeSettings = nil
                phase = .idle
                break
            }
            retryAttempt += 1
            let delay = ConnectionSettings.retryDelay(attempt: retryAttempt)
            let seconds = delay.components.seconds
            retryAt = .now.addingTimeInterval(TimeInterval(seconds))
            append(TrafficEntry(.note, "Retrying in \(seconds) s (attempt \(retryAttempt + 1))…"))
            phase = .waitingToRetry
            try? await Task.sleep(for: delay)
            retryAt = nil
        }
    }

    private func append(_ entry: TrafficEntry) {
        log.append(entry)
        if log.count > Self.maxLogEntries { log.removeFirst(log.count - Self.maxLogEntries) }
        logFile.write(entry)
    }

    /// The log as text, oldest first, as Copy and Save give it.
    var logText: String { log.map(TrafficLogFile.line).joined(separator: "\n") + "\n" }

    /// This launch's log file, with everything since launch (the on-screen log keeps the latest 5,000 lines).
    var logFileURL: URL? { logFile.url }
}
