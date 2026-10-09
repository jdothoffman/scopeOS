/// Keeps telescope moves away from the Sun. A move is checked along its whole path, not just where it ends.
public enum SunSafety {
    /// No move may pass closer to the Sun than this. Also the "too close" warning and the zone on the sky chart.
    public static let keepOutDegrees = 30.0
    /// Shown as a caution (amber) between the keep-out and this distance.
    public static let cautionDegrees = keepOutDegrees * 1.5

    /// Returns why a move of `axis` by `degrees` from `pointing` isn't allowed, or nil if it is.
    /// Moves that stay outside the keep-out zone are allowed. Inside it, only moves that steadily increase the
    /// distance from the Sun are allowed, so the telescope can always be backed away.
    public static func check(_ axis: NudgeAxis, by degrees: Double, from pointing: Horizontal, sun: Horizontal,
                             keepOut: Double = keepOutDegrees) -> String? {
        let samples = max(2, Int((abs(degrees) / 0.25).rounded(.up)) + 1)
        let distances = (0 ..< samples).map { index -> Double in
            let fraction = Double(index) / Double(samples - 1)
            var point = pointing
            switch axis {
            case .azimuth: point.azimuth = Astronomy.normalize(pointing.azimuth + degrees * fraction)
            case .altitude: point.altitude = pointing.altitude + degrees * fraction
            }
            return Astronomy.separation(point, sun)
        }
        guard let start = distances.first, let end = distances.last else { return nil }

        if distances.allSatisfy({ $0 >= keepOut }) { return nil }
        let steadilyAway = zip(distances, distances.dropFirst()).allSatisfy { $1 >= $0 - 1e-9 } && end > start
        if start < keepOut, steadilyAway { return nil }
        return String(format: "That move would bring the telescope within %.0f° of the Sun (it is %.0f° away now).", keepOut, start)
    }
}
