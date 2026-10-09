import Foundation

public struct TrafficEntry: Identifiable, Sendable {
    public enum Direction: Sendable { case sent, received, note }

    public let id = UUID()
    public let date = Date()
    public let direction: Direction
    public let text: String

    public init(_ direction: Direction, _ text: String) {
        self.direction = direction
        self.text = text
    }
}

public typealias TrafficLogger = @Sendable (TrafficEntry) -> Void

/// Each client is driven by a single polling loop. Exchanges are serialized internally, so `stop()` may be
/// called while a status poll is in flight; it goes out as soon as the current request finishes.
public protocol MountClient: Actor {
    func connect() async throws
    func readStatus() async throws -> MountStatus
    /// Stops any slew or GoTo in progress. Never starts motion. Throws if the mount didn't acknowledge.
    func stop() async throws
    /// Turns one motor by a small, bounded step (positive increases the motor angle) and returns once the mount
    /// has acknowledged. Refuses if either axis is already moving, the step exceeds `axis.maxStepDegrees`, or an
    /// altitude nudge would leave `NudgeCommand.altitudeLimits`.
    func nudge(_ axis: NudgeAxis, by degrees: Double) async throws
    /// Starts a press-and-hold move: a bounded slow GoTo the full `axis.maxStepDegrees` in one direction (for
    /// altitude, clipped to `NudgeCommand.altitudeLimits`). The caller stops it early with `stop()`; if nothing
    /// does, the motor still stops by itself at the target. Use `HeldMove` rather than calling this directly.
    /// `onSend` runs just before the move command is written; if this throws without having called it, nothing
    /// that moves the mount went out, so there is nothing to stop. `continuing` is for the next step of a hold that
    /// is already turning this axis: it may go out while this axis is still moving (the other must be still), so the
    /// motor carries straight on. Returns where the step ends, as a motor angle (signed for altitude).
    @discardableResult
    func move(_ axis: NudgeAxis, positive: Bool, continuing: Bool, onSend: @escaping @Sendable () -> Void) async throws -> Double
    /// The motor's angle now, uncalibrated (signed for altitude).
    func motorAngle(_ axis: NudgeAxis) async throws -> Double
    /// One step of a longer move to the sky angle `target` (azimuth, or calibrated altitude): a slow GoTo at most
    /// `axis.maxStepDegrees` along the way, for azimuth going the `positive` way round. Returns true if this step
    /// ends at the target (or the motor is already there, in which case nothing is sent). Refused like `move`.
    /// `onSend` works as for `move`. Use `HeldMove.goTo` rather than calling this directly.
    func move(_ axis: NudgeAxis, toward target: Double, positive: Bool, onSend: @escaping @Sendable () -> Void) async throws -> Bool
    /// Whether `axis`'s motor is still carrying out a move.
    func isMoving(_ axis: NudgeAxis) async throws -> Bool
    /// Moves the focus motor `steps` from where it is (bounded by `FocusCommand`). Refused if it isn't calibrated.
    func focus(by steps: Int) async throws
    /// Moves the focus motor to `position`, read against its position at the moment of sending (so a reading taken
    /// earlier can't throw it off). Refused if that's outside the calibrated range or more than one move away.
    func focus(to position: Int) async throws
    /// Starts a press-and-hold focus move toward one end; it stops by itself after `FocusCommand.holdReach`.
    /// `onSend` works as for `move`.
    func focusMove(positive: Bool, onSend: @escaping @Sendable () -> Void) async throws
    /// Stops the focus motor only.
    func stopFocuser() async throws
    /// Records that the telescope currently points at `azimuth`/`altitude` (nil leaves that axis alone), so later
    /// readings, limits and Sun checks use real sky directions. Refused while the mount is moving.
    func calibrate(azimuth: Double?, altitude: Double?) async throws -> AxisCalibration
    /// Applies a calibration made earlier (e.g. after an automatic reconnect), or clears it with nil.
    func setCalibration(_ calibration: AxisCalibration?)
    func disconnect()
}

enum Angles {
    /// Celestron positions are fractions of a full turn; `bits` is 32 for hand-controller hex, 24 for AUX.
    static func degrees(fraction value: UInt32, bits: Int) -> Double {
        Double(value) / pow(2, Double(bits)) * 360
    }

    static func signed(_ degrees: Double) -> Double {
        degrees > 180 ? degrees - 360 : degrees
    }

    /// Parses the "XXXXXXXX,XXXXXXXX#" reply of the precise position commands.
    static func parsePrecisePair(_ reply: [UInt8]) -> (Double, Double)? {
        guard reply.count == 18, reply[8] == UInt8(ascii: ","), reply[17] == UInt8(ascii: "#") else { return nil }
        let text = String(decoding: reply[0 ..< 17], as: UTF8.self)
        let parts = text.split(separator: ",")
        guard parts.count == 2, let a = UInt32(parts[0], radix: 16), let b = UInt32(parts[1], radix: 16) else { return nil }
        return (degrees(fraction: a, bits: 32), degrees(fraction: b, bits: 32))
    }
}
