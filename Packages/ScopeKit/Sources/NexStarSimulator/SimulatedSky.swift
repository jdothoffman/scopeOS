import Foundation
import ScopeKit

/// A pretend mount that tracks a target for a while, slews to the next one, and repeats.
public struct SimulatedSky: Sendable {
    public struct Target: Sendable {
        public let name: String
        public let position: Equatorial
        public let horizontal: Horizontal
    }

    public static let targets: [Target] = [
        Target(name: "Saturn", position: Equatorial(raHours: 23.35, decDegrees: -6.9), horizontal: Horizontal(azimuth: 165, altitude: 38)),
        Target(name: "Moon", position: Equatorial(raHours: 2.1, decDegrees: 12.4), horizontal: Horizontal(azimuth: 108, altitude: 31)),
        Target(name: "Vega", position: Equatorial(raHours: 18.62, decDegrees: 38.78), horizontal: Horizontal(azimuth: 292, altitude: 56)),
        Target(name: "Jupiter", position: Equatorial(raHours: 7.55, decDegrees: 21.8), horizontal: Horizontal(azimuth: 74, altitude: 19)),
    ]

    public let trackSeconds: Double
    public let slewSeconds: Double
    private let start: Date

    public init(trackSeconds: Double = 15, slewSeconds: Double = 5, start: Date = .now) {
        self.trackSeconds = trackSeconds
        self.slewSeconds = slewSeconds
        self.start = start
    }

    public struct State: Sendable {
        public let equatorial: Equatorial
        public let horizontal: Horizontal
        public let slewing: Bool
        public let targetName: String
    }

    public func state(at date: Date = .now) -> State {
        let cycle = trackSeconds + slewSeconds
        let elapsed = max(0, date.timeIntervalSince(start))
        let index = Int(elapsed / cycle) % Self.targets.count
        let phase = elapsed.truncatingRemainder(dividingBy: cycle)
        let current = Self.targets[index]
        let next = Self.targets[(index + 1) % Self.targets.count]

        if phase < trackSeconds {
            // Tracking: equatorial position holds; azimuth/altitude drift slowly as the sky turns.
            let drift = phase * 0.004
            return State(
                equatorial: current.position,
                horizontal: Horizontal(azimuth: current.horizontal.azimuth + drift, altitude: current.horizontal.altitude + drift / 2),
                slewing: false,
                targetName: current.name
            )
        }

        let t = (phase - trackSeconds) / slewSeconds
        let eased = t * t * (3 - 2 * t)
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * eased }
        func lerpAngle(_ a: Double, _ b: Double, period: Double) -> Double {
            var delta = (b - a).truncatingRemainder(dividingBy: period)
            if delta > period / 2 { delta -= period }
            if delta < -period / 2 { delta += period }
            let value = (a + delta * eased).truncatingRemainder(dividingBy: period)
            return value < 0 ? value + period : value
        }
        return State(
            equatorial: Equatorial(
                raHours: lerpAngle(current.position.raHours, next.position.raHours, period: 24),
                decDegrees: lerp(current.position.decDegrees, next.position.decDegrees)
            ),
            horizontal: Horizontal(
                azimuth: lerpAngle(current.horizontal.azimuth, next.horizontal.azimuth, period: 360),
                altitude: lerp(current.horizontal.altitude, next.horizontal.altitude)
            ),
            slewing: true,
            targetName: "→ \(next.name)"
        )
    }
}

enum Encode {
    static func fraction32(_ degrees: Double) -> UInt32 {
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return UInt32(min(4_294_967_295, (normalized / 360 * 4_294_967_296).rounded()))
    }

    static func fraction24(_ degrees: Double) -> [UInt8] {
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let value = UInt32(min(16_777_215, (normalized / 360 * 16_777_216).rounded()))
        return [UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}
