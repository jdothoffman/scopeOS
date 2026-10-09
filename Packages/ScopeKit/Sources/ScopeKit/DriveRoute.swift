import Foundation

/// Plans a drive (Return to home, Go to): which axis moves first, and whether the route stays clear of the Sun.
/// The client checks every step again as it goes; this decides whether to start at all, and in which order.
public enum DriveRoute {
    public enum Problem: Error, Equatable {
        /// The target is below the altitude band moves keep to.
        case belowBand(altitude: Double)
        /// The target is above the altitude band.
        case aboveBand(altitude: Double)
        /// Both orders pass too close to the Sun; the reason for the first one.
        case nearSun(String)
    }

    /// Legs from `pointing` to `target` (sky angles), one axis after the other: altitude first, unless that passes
    /// too close to the Sun and azimuth first doesn't. `turn` is how far to turn the azimuth, signed, and may be the
    /// long way round (see `CableTrack`). Axes already within 0.01° are left out.
    public static func legs(from pointing: Horizontal, to target: Horizontal, turn: Double, sun: Horizontal) -> Result<[HeldMove.Leg], Problem> {
        let band = NudgeCommand.altitudeLimits
        if target.altitude < band.lowerBound { return .failure(.belowBand(altitude: target.altitude)) }
        if target.altitude > band.upperBound { return .failure(.aboveBand(altitude: target.altitude)) }

        let rise = target.altitude - pointing.altitude
        let altitudeLeg = (leg: HeldMove.Leg(axis: .altitude, target: target.altitude, positive: rise > 0), degrees: rise)
        let azimuthLeg = (leg: HeldMove.Leg(axis: .azimuth, target: target.azimuth, positive: turn > 0), degrees: turn)

        var firstProblem: String?
        for order in [[altitudeLeg, azimuthLeg], [azimuthLeg, altitudeLeg]] {
            var at = pointing
            var problem: String?
            for (leg, degrees) in order where abs(degrees) >= 0.01 {
                problem = problem ?? SunSafety.check(leg.axis, by: degrees, from: at, sun: sun)
                if leg.axis == .azimuth { at.azimuth = target.azimuth } else { at.altitude = target.altitude }
            }
            guard let problem else { return .success(order.filter { abs($0.degrees) >= 0.01 }.map(\.leg)) }
            firstProblem = firstProblem ?? problem
        }
        return .failure(.nearSun(firstProblem ?? ""))
    }
}

/// How far the azimuth motor has turned since connecting, counting whole turns, so drives can keep the camera
/// cable from winding up. Fed one motor reading at a time; readings must come often enough that the motor turns
/// less than half a turn between them (it can't turn that fast).
public struct CableTrack: Equatable, Sendable {
    /// The azimuth motor angle at the first reading.
    public private(set) var first: Double
    /// The latest reading.
    public private(set) var last: Double
    /// Turned since the first reading, signed, counting whole turns.
    public private(set) var turned = 0.0

    public init(motorAzimuth: Double) {
        first = motorAzimuth
        last = motorAzimuth
    }

    public mutating func update(motorAzimuth: Double) {
        turned += Astronomy.shortTurn(from: last, to: motorAzimuth)
        last = motorAzimuth
    }

    /// How far to turn to get home, whose azimuth in motor angles is `homeMotor`: back the way the scope has turned,
    /// so the cable unwinds. Home is taken to be the copy (in whole turns) nearest where the motor was at the first
    /// reading.
    public func turnHome(homeMotor: Double) -> Double {
        let nearestHome = homeMotor + 360 * ((first - homeMotor) / 360).rounded()
        return nearestHome - (first + turned)
    }

    /// How far to turn from `pointing` to `target`: the short way, unless that would leave the cable wound more
    /// than three-quarters of a turn from the first reading and the long way wouldn't.
    public func turn(from pointing: Double, to target: Double) -> Double {
        let short = Astronomy.shortTurn(from: pointing, to: target)
        guard abs(turned + short) > 270 else { return short }
        let long = short > 0 ? short - 360 : short + 360
        return abs(turned + long) < abs(turned + short) ? long : short
    }
}

extension Astronomy {
    /// The turn from azimuth `a` to `b` the short way round, in degrees (−180° to 180°).
    public static func shortTurn(from a: Double, to b: Double) -> Double {
        var delta = (b - a).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta <= -180 { delta += 360 }
        return delta
    }
}
