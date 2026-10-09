import Foundation

/// The move in progress, built from bounded steps: press-and-hold (`begin`, until `end` or `timeLimit`) and driving
/// to a position (`goTo`, until it arrives or `end`). Each step is a slow GoTo at most `axis.maxStepDegrees` away,
/// so if the app or the connection dies the motor still stops within one step. A hold sends its next step shortly
/// before the current one ends (`lead`), so the motor carries straight on; a drive waits for each step to finish.
///
/// Calls must arrive in the order the user made them (press, then release). Even so, a stop always waits until
/// the step being sent has gone out, so a quick tap can never send the stop first and leave the move running. A
/// move that fails before anything is written (refused because the mount is already slewing, say) is never
/// stopped: the stop would halt whatever else is moving the mount, such as a GoTo from the hand controller.
public actor HeldMove {
    public static let defaultTimeLimit: Duration = .seconds(15)
    public static let defaultFocusTimeLimit: Duration = .seconds(5)
    /// How often a step is checked for having finished.
    static let pollInterval: Duration = .milliseconds(250)

    /// Why a move ended by itself rather than through `end`.
    public enum Ending: Sendable, Equatable {
        /// A hold reached the time limit and was stopped.
        case timeLimit
        /// A `goTo` reached its target.
        case arrived
        /// `mayContinue` declined the next step, or a step was refused or failed. Stopped if a step was under way.
        case stopped(String)
        /// The move ended by itself and was meant to be stopped, but the stop failed: the step under way may still
        /// run to its end. Carries the stop's error.
        case stopFailed(String)
    }

    /// One axis of a `goTo`: drive `axis` to the sky angle `target`, for azimuth going the `positive` way round.
    public struct Leg: Equatable, Sendable {
        public let axis: NudgeAxis
        public let target: Double
        public let positive: Bool

        public init(axis: NudgeAxis, target: Double, positive: Bool) {
            self.axis = axis
            self.target = target
            self.positive = positive
        }
    }

    /// How far before a hold step's end the next one is sent: far enough ahead of the position polling that the
    /// motor never reaches the end and stops.
    static func lead(_ axis: NudgeAxis) -> Double { axis.maxStepDegrees / 3 }

    /// What a step did: whether it completes its leg, and where it ends (motor angle), if known.
    private struct StepResult: Sendable {
        var arrived: Bool
        var end: Double?
    }

    /// Sends one step. `continuing` is true for every step after a move's first.
    private typealias Step = @Sendable (_ continuing: Bool, _ onSend: @escaping @Sendable () -> Void) async throws -> StepResult
    /// Checked before each step after the first: a reason to stop instead, or nil. Gets the axis and direction.
    public typealias MayContinue = @Sendable (_ axis: NudgeAxis, _ positive: Bool) async -> String?

    private struct Part: Sendable {
        /// The motor to wait on before the next step; nil when that can't be told (the focuser), so no step follows.
        let axis: NudgeAxis?
        let positive: Bool
        /// Send the next step this far before this one's end; nil waits for it to finish.
        var lead: Double? = nil
        let step: Step
    }

    private struct Drive {
        let id: UUID
        /// Set once any step has been written.
        let sent: SentFlag
        let stop: @Sendable () async throws -> Void
        /// The step being sent, or the last one sent.
        var step: Task<StepResult, Error>
    }

    private let client: any MountClient
    private let timeLimit: Duration
    private let focusTimeLimit: Duration
    private var current: Drive?

    public init(client: any MountClient, timeLimit: Duration = defaultTimeLimit, focusTimeLimit: Duration = defaultFocusTimeLimit) {
        self.client = client
        self.timeLimit = timeLimit
        self.focusTimeLimit = focusTimeLimit
    }

    /// Starts moving one axis and returns once the mount has accepted the first step. Steps keep coming until
    /// `end`, the time limit, `mayContinue` declining, or a refused step (e.g. at the edge of the altitude band).
    /// `onEnded` runs when the move ends by itself.
    public func begin(_ axis: NudgeAxis, positive: Bool, mayContinue: @escaping MayContinue = { _, _ in nil },
                      onEnded: @escaping @Sendable (Ending) -> Void = { _ in }) async throws {
        let part = Part(axis: axis, positive: positive, lead: Self.lead(axis)) { [client] continuing, onSend in
            let end = try await client.move(axis, positive: positive, continuing: continuing, onSend: onSend)
            return StepResult(arrived: false, end: end) // a hold has no end point of its own
        }
        try await start([part], timeLimit: timeLimit, stop: { [client] in try await client.stop() },
                        mayContinue: mayContinue, onEnded: onEnded)
    }

    /// The same for the focus motor: one bounded step, stopped by `end` or `focusTimeLimit`. Stopping it leaves
    /// the mount alone.
    public func beginFocus(positive: Bool, onEnded: @escaping @Sendable (Ending) -> Void = { _ in }) async throws {
        let part = Part(axis: nil, positive: positive) { [client] _, onSend in
            try await client.focusMove(positive: positive, onSend: onSend)
            return StepResult(arrived: false)
        }
        try await start([part], timeLimit: focusTimeLimit, stop: { [client] in try await client.stopFocuser() },
                        mayContinue: { _, _ in nil }, onEnded: onEnded)
    }

    /// Drives the mount through `legs` in order, one axis at a time, and returns once the first step is accepted.
    /// Ends when the last leg arrives, `mayContinue` declines, a step is refused, or `end` is called. No time limit.
    public func goTo(_ legs: [Leg], mayContinue: @escaping MayContinue = { _, _ in nil },
                     onEnded: @escaping @Sendable (Ending) -> Void = { _ in }) async throws {
        guard !legs.isEmpty else { return }
        let parts = legs.map { leg in
            Part(axis: leg.axis, positive: leg.positive) { [client] _, onSend in
                StepResult(arrived: try await client.move(leg.axis, toward: leg.target, positive: leg.positive, onSend: onSend))
            }
        }
        try await start(parts, timeLimit: nil, stop: { [client] in try await client.stop() },
                        mayContinue: mayContinue, onEnded: onEnded)
    }

    /// Stops the current move, if any.
    public func end() async throws {
        _ = try await finish(nil)
    }

    private func start(_ parts: [Part], timeLimit: Duration?, stop: @escaping @Sendable () async throws -> Void,
                       mayContinue: @escaping MayContinue, onEnded: @escaping @Sendable (Ending) -> Void) async throws {
        guard current == nil else { throw MountError.refused("A move is already in progress.") }
        let id = UUID()
        let sent = SentFlag()
        let first = parts[0]
        let step = Task { try await first.step(false) { sent.set() } }
        current = Drive(id: id, sent: sent, stop: stop, step: step)

        if let timeLimit {
            Task {
                try? await Task.sleep(for: timeLimit)
                do {
                    if try await self.finish(id) { onEnded(.timeLimit) }
                } catch {
                    onEnded(.stopFailed(error.localizedDescription))
                }
            }
        }

        let result: StepResult
        do {
            result = try await step.value
        } catch {
            _ = try? await finish(id)
            throw error
        }
        guard current?.id == id else { return } // already released
        Task {
            await self.keepGoing(id, parts: parts, next: result.arrived ? 1 : 0, after: first, end: result.end,
                                 mayContinue: mayContinue, onEnded: onEnded)
        }
    }

    /// Sends the remaining steps: each once the one before has finished, or for a hold, once the motor is within
    /// `lead` of the current step's end (`end`).
    private func keepGoing(_ id: UUID, parts: [Part], next: Int, after previous: Part, end: Double?,
                           mayContinue: @escaping MayContinue, onEnded: @escaping @Sendable (Ending) -> Void) async {
        var index = next
        var previous = previous
        var end = end
        while let axis = previous.axis {
            do {
                // Wait a moment first, so a step that has only just been sent has had time to show as moving.
                waiting: repeat {
                    try await Task.sleep(for: Self.pollInterval)
                    guard current?.id == id else { return }
                    if let lead = previous.lead, let end {
                        let angle = try await client.motorAngle(axis)
                        let remaining = axis == .azimuth ? abs(Astronomy.shortTurn(from: angle, to: end)) : abs(end - angle)
                        if remaining <= lead { break waiting }
                    }
                } while try await client.isMoving(axis)
            } catch {
                await ended(id, .stopped("Lost track of the move (\(error.localizedDescription)), so it was stopped."), stop: true, onEnded)
                return
            }
            guard current?.id == id else { return }
            guard index < parts.count else {
                await ended(id, .arrived, stop: false, onEnded)
                return
            }
            let part = parts[index]
            if let reason = await mayContinue(part.axis ?? axis, part.positive) {
                // The last step ends by itself (a hold's within `lead`); nothing to stop.
                await ended(id, .stopped(reason), stop: false, onEnded)
                return
            }
            guard var drive = current, drive.id == id else { return } // released while checking
            let sent = drive.sent, stepSent = SentFlag()
            let step = Task { try await part.step(true) { sent.set(); stepSent.set() } }
            drive.step = step
            current = drive
            do {
                let result = try await step.value
                if result.arrived { index += 1 }
                end = result.end
            } catch {
                // A step refused before it was written leaves the last one to end by itself.
                await ended(id, .stopped(error.localizedDescription), stop: stepSent.isSet, onEnded)
                return
            }
            previous = part
        }
    }

    /// Ends the move `id` by itself, if it is still current.
    private func ended(_ id: UUID, _ ending: Ending, stop: Bool, _ onEnded: @Sendable (Ending) -> Void) async {
        guard let drive = current, drive.id == id else { return }
        current = nil
        if stop {
            do {
                try await drive.stop()
            } catch {
                onEnded(.stopFailed(error.localizedDescription))
                return
            }
        }
        onEnded(ending)
    }

    /// Stops the move `id` (or whichever is current, for nil). Returns false if there was nothing to stop.
    private func finish(_ id: UUID?) async throws -> Bool {
        guard let drive = current, id == nil || drive.id == id else { return false }
        current = nil
        // The stop must follow the step being sent, never overtake it. Stop a move that went out even if its
        // acknowledgement didn't come back; one that never went out needs no stop.
        _ = try? await drive.step.value
        guard drive.sent.isSet else { return false }
        try await drive.stop()
        return true
    }
}

/// Set just before a move is written, from the client's actor; read by `HeldMove` once the move has finished.
private final class SentFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
