import Foundation

/// The Sun rules every mount move must pass. `AuxClient` checks them immediately before writing each move, so they
/// hold for every caller (the app, the CLI, tests, future features), not only for the app's controls. The step
/// cap and the altitude band are enforced separately, on the bytes (`NudgeCommand`).
public struct MotionPolicy: Equatable, Sendable {
    /// Where the telescope is. Without it the Sun's position isn't known, so every move is refused.
    public var observer: Observer?
    /// Refuse every move while the Sun is up.
    public var lockWhileSunUp: Bool
    /// A fixed time to check against (tests); nil means the current time.
    public var date: Date?

    public init(observer: Observer?, lockWhileSunUp: Bool = true, date: Date? = nil) {
        self.observer = observer
        self.lockWhileSunUp = lockWhileSunUp
        self.date = date
    }

    /// Refuses every move: what a client uses until it's given a policy with a location.
    public static let refuseAll = MotionPolicy(observer: nil)

    /// Why moving `axis` by `degrees` from `pointing` (sky angles) isn't allowed, or nil if it is.
    public func problem(_ axis: NudgeAxis, by degrees: Double, from pointing: Horizontal) -> String? {
        guard let observer else { return "No location is set, so moves can't be kept away from the Sun." }
        let now = date ?? .now
        let sun = Astronomy.horizontal(Astronomy.sunPosition(at: now), at: now, observer: observer)
        if lockWhileSunUp, SkyDarkness(sunAltitude: sun.altitude) == .day {
            return "The Sun is up, so movement is locked."
        }
        return SunSafety.check(axis, by: degrees, from: pointing, sun: sun)
    }
}
