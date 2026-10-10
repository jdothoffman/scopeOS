import Foundation
import ScopeKit

/// The pretend telescope's moving parts: the two motors (the sky's schedule plus any moves), the focus motor and a
/// stop's hold. Shared by the AUX and hand-controller servers, so both report the same mount, and read by the
/// simulated camera to know where the telescope points and how far out of focus it is. Safe to use from any thread.
public final class SimulatedMount: @unchecked Sendable {
    public let sky: SimulatedSky
    /// Whether a Celestron focus motor is fitted, and its calibrated range.
    public let hasFocuser: Bool
    public static let focuserLimits = 1_000 ... 39_000
    /// Where the simulated optics are in focus. The focuser starts a little away from it, so there's focusing to do.
    public static let bestFocus = 21_500
    /// How long a move takes per degree (tests speed it up).
    public let secondsPerDegree: Double

    private let lock = NSLock()
    private var location: Observer?
    /// Set when a client stops a slew: the mount stays where it stopped for one cycle.
    private var hold: (state: SimulatedSky.State, until: Date)?
    /// Angles added by moves, animated so the mount reports slewing while a motor turns.
    private var azimuthMove = MotorMotion()
    private var altitudeMove = MotorMotion()
    private var focuser = FocuserMotion(position: 20_000)

    public init(sky: SimulatedSky = SimulatedSky(), focuser: Bool = false, secondsPerDegree: Double = 1.5) {
        self.sky = sky
        hasFocuser = focuser
        self.secondsPerDegree = secondsPerDegree
    }

    /// The observer's location, for the RA/Dec a parked mount reports (the hand controller works it out from the
    /// alignment on the real mount). Without one, RA/Dec read 0.
    public func setObserver(_ observer: Observer?) {
        lock.withLock { location = observer }
    }

    /// Where the mount is, if known.
    public var observer: Observer? { lock.withLock { location } }

    /// Where the mount points now, whether it's turning, and what it's pointed at.
    public func state(at now: Date = .now) -> SimulatedSky.State {
        lock.withLock { currentState(at: now) }
    }

    /// The focus motor's position.
    public func focuserPosition(at now: Date = .now) -> Int {
        lock.withLock { focuser.position(at: now) }
    }

    private func currentState(at now: Date) -> SimulatedSky.State {
        let base = scheduledState(at: now)
        let az = azimuthMove.offset(at: now), alt = altitudeMove.offset(at: now)
        let horizontal = Horizontal(azimuth: Astronomy.normalize(base.horizontal.azimuth + az.degrees),
                                    altitude: base.horizontal.altitude + alt.degrees)
        var equatorial = base.equatorial
        if sky.parkedAt != nil, let location {
            equatorial = Astronomy.equatorial(from: horizontal, at: now, observer: location)
        }
        return SimulatedSky.State(equatorial: equatorial, horizontal: horizontal, slewing: base.slewing || az.moving || alt.moving,
                                  targetName: base.targetName)
    }

    /// The sky's schedule, or the position a stop froze it at.
    private func scheduledState(at now: Date) -> SimulatedSky.State {
        if let hold, now < hold.until { return hold.state }
        hold = nil
        return sky.state(at: now)
    }

    /// Whether one motor is turning: a slew moves both, a move only its own. Each motor answers for itself, as on
    /// the real mount.
    func isTurning(_ motor: AuxDevice, at now: Date = .now) -> Bool {
        lock.withLock {
            let move = motor == .azimuthMotor ? azimuthMove : altitudeMove
            return scheduledState(at: now).slewing || move.offset(at: now).moving
        }
    }

    /// Stops both motors where they are. Returns whether anything was moving.
    @discardableResult
    func stop(at now: Date = .now) -> Bool {
        lock.withLock {
            let moving = azimuthMove.offset(at: now).moving || altitudeMove.offset(at: now).moving
            azimuthMove.freeze(at: now)
            altitudeMove.freeze(at: now)
            let base = scheduledState(at: now)
            if base.slewing {
                let stopped = SimulatedSky.State(equatorial: base.equatorial, horizontal: base.horizontal, slewing: false, targetName: "Stopped")
                hold = (stopped, now.addingTimeInterval(sky.trackSeconds + sky.slewSeconds))
            }
            return moving || base.slewing
        }
    }

    /// Turns one motor the short way to `degrees`. Returns the turn.
    func move(_ motor: AuxDevice, to degrees: Double, at now: Date = .now) -> Double {
        lock.withLock {
            let state = currentState(at: now)
            var delta = (degrees - (motor == .azimuthMotor ? state.horizontal.azimuth : state.horizontal.altitude))
                .truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            if motor == .azimuthMotor {
                azimuthMove.start(by: delta, at: now, secondsPerDegree: secondsPerDegree)
            } else {
                altitudeMove.start(by: delta, at: now, secondsPerDegree: secondsPerDegree)
            }
            return delta
        }
    }

    func focuserMoving(at now: Date = .now) -> Bool {
        lock.withLock { focuser.moving(at: now) }
    }

    /// Starts the focus motor toward `target`, kept inside the calibrated range.
    func moveFocuser(to target: Int, at now: Date = .now) {
        let clamped = min(Self.focuserLimits.upperBound, max(Self.focuserLimits.lowerBound, target))
        lock.withLock { focuser.start(to: clamped, at: now) }
    }

    func stopFocuser(at now: Date = .now) {
        lock.withLock { focuser.freeze(at: now) }
    }
}

/// A move in progress (or finished) on one simulated motor.
struct MotorMotion {
    private var from = 0.0, to = 0.0, startTime = Date.distantPast, duration = 0.0

    func offset(at now: Date) -> (degrees: Double, moving: Bool) {
        let elapsed = now.timeIntervalSince(startTime)
        guard elapsed < duration else { return (to, false) }
        return (from + (to - from) * elapsed / duration, true)
    }

    mutating func start(by delta: Double, at now: Date, secondsPerDegree: Double) {
        let current = offset(at: now).degrees
        (from, to, startTime, duration) = (current, current + delta, now, max(0.3, abs(delta) * secondsPerDegree))
    }

    mutating func freeze(at now: Date) {
        let current = offset(at: now).degrees
        (from, to, duration) = (current, current, 0)
    }
}

/// The simulated focus motor's position, moving at 2,000 steps per second during a GoTo.
struct FocuserMotion {
    private var from: Int, to: Int, startTime = Date.distantPast, duration = 0.0

    init(position: Int) {
        from = position
        to = position
    }

    func position(at now: Date) -> Int {
        let elapsed = now.timeIntervalSince(startTime)
        guard elapsed < duration else { return to }
        return from + Int(Double(to - from) * elapsed / duration)
    }

    func moving(at now: Date) -> Bool { now.timeIntervalSince(startTime) < duration }

    mutating func start(to target: Int, at now: Date) {
        let current = position(at: now)
        (from, to, startTime, duration) = (current, target, now, max(0.2, Double(abs(target - current)) / 2_000))
    }

    mutating func freeze(at now: Date) {
        let current = position(at: now)
        (from, to, duration) = (current, current, 0)
    }
}
