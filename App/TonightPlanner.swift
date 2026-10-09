import Foundation
import Observation
import ScopeKit

/// Something worth pointing at tonight, worked out from the location and the time: when it's dark, when the target is
/// high enough to see well and low enough for the up/down limit, and when it's highest within that.
struct TonightCandidate: Identifiable, Equatable {
    enum Kind: Equatable { case moon, planet, star }

    /// Short and stable, for the on-device model to refer to it by.
    let id: String
    let target: SkyTarget
    let selection: SkySelection
    let kind: Kind
    /// What it is, in a few words: "64% lit", "planet", "star, magnitude 0.0".
    let note: String
    /// When it's highest while dark and inside the altitude band.
    let best: Date
    let bestSky: Horizontal
    /// First and last time tonight it's dark and the target is inside the band.
    let window: ClosedRange<Date>

    /// How well it shows in a 150 mm telescope with a planetary camera, best first.
    var rank: Int {
        switch target.kind {
        case .moon: 0
        case .planet(let planet): [.jupiter: 1, .saturn: 2, .mars: 3, .venus: 4, .mercury: 5, .uranus: 6, .neptune: 7][planet] ?? 8
        default: 9
        }
    }
}

/// Tonight's targets, without any AI: the Moon, the planets and the brightest named stars.
@MainActor
enum TonightPlanner {
    /// Below this the view through the atmosphere is too poor to bother.
    static let minimumAltitude = 15.0
    /// The darkest the Sun's altitude must be: the end of civil twilight, when planets and bright stars are out.
    static let darkSunAltitude = -6.0
    /// Stars no fainter than this are listed (they're for focusing and checking alignment, not imaging).
    static let starMagnitudeLimit = 1.0
    private static let step: TimeInterval = 10 * 60

    /// From `date` (or dusk, if it's light) until dawn; nil if there's no darkness in the next day.
    static func darkWindow(observer: Observer, from date: Date) -> ClosedRange<Date>? {
        func dark(_ time: Date) -> Bool {
            Astronomy.horizontal(Astronomy.sunPosition(at: time), at: time, observer: observer).altitude < darkSunAltitude
        }
        var time = date
        let limit = date.addingTimeInterval(24 * 3600)
        while !dark(time) {
            time += step
            if time > limit { return nil }
        }
        let start = time
        while dark(time + step), time < start.addingTimeInterval(24 * 3600) { time += step }
        return start ... time
    }

    /// Everything that's up and reachable at some point tonight, Moon and planets first, then the brightest stars.
    static func candidates(observer: Observer, date: Date) -> [TonightCandidate] {
        guard let dark = darkWindow(observer: observer, from: date) else { return [] }
        let times = Array(stride(from: dark.lowerBound, through: dark.upperBound, by: step))
        let band = minimumAltitude ... NudgeCommand.altitudeLimits.upperBound

        func candidate(_ target: SkyTarget, selection: SkySelection, kind: TonightCandidate.Kind, note: String) -> TonightCandidate? {
            let inBand = times.compactMap { time -> (Date, Horizontal)? in
                let sky = target.horizontal(at: time, observer: observer)
                return band.contains(sky.altitude) ? (time, sky) : nil
            }
            guard let first = inBand.first, let last = inBand.last,
                  let best = inBand.max(by: { $0.1.altitude < $1.1.altitude }) else { return nil }
            // The Sun is down, but Mercury and Venus can still sit inside the keep-out zone at dusk.
            let sun = Astronomy.separation(target.position(at: best.0), Astronomy.sunPosition(at: best.0))
            guard sun >= SunSafety.keepOutDegrees else { return nil }
            let id = target.name.lowercased().filter(\.isLetter)
            return TonightCandidate(id: id, target: target, selection: selection, kind: kind, note: note,
                                    best: best.0, bestSky: best.1, window: first.0 ... last.0)
        }

        var list: [TonightCandidate] = []
        let moonTime = dark.lowerBound
        let elongation = Astronomy.separation(SkyTarget.moon.position(at: moonTime), Astronomy.sunPosition(at: moonTime))
        let lit = Int(((1 - cos(elongation * .pi / 180)) / 2 * 100).rounded())
        if let moon = candidate(.moon, selection: .body(.moon), kind: .moon, note: "Moon, \(lit)% lit") { list.append(moon) }
        list += Planet.allCases.compactMap { planet in
            let target = SkyTarget.planet(planet)
            return candidate(target, selection: .body(target), kind: .planet, note: "planet")
        }
        // Without the on-device model, rank by what shows best in a small telescope, then by how high it gets.
        list.sort { ($0.rank, -$0.bestSky.altitude) < ($1.rank, -$1.bestSky.altitude) }

        let stars = SkyMapData.stars
            .filter { !$0.star.name.isEmpty && $0.star.magnitude <= starMagnitudeLimit }
            .compactMap { entry in
                candidate(entry.star.target, selection: .star(hr: entry.star.hr), kind: .star,
                          note: String(format: "star, magnitude %.1f", entry.star.magnitude))
            }
            .sorted { $0.bestSky.altitude > $1.bestSky.altitude }
        return list + stars
    }
}

/// Tonight's list and, once asked for, the on-device model's picks from it. Kept app-wide so switching tabs keeps them.
@MainActor
@Observable
final class TonightModel {
    private(set) var candidates: [TonightCandidate] = []
    private(set) var dark: ClosedRange<Date>?
    private(set) var suggestions: [TonightSuggestion]?
    private(set) var suggesting = false
    private(set) var problem: String?
    @ObservationIgnored private var worked: (observer: Observer, date: Date)?

    /// Works the list out again if the place changed or it's more than five minutes old.
    func refresh(observer: Observer, date: Date = .now) {
        if let worked, worked.observer == observer, date.timeIntervalSince(worked.date) < 300 { return }
        worked = (observer, date)
        dark = TonightPlanner.darkWindow(observer: observer, from: date)
        candidates = TonightPlanner.candidates(observer: observer, date: date)
        // Picks of targets that have dropped off the list (set, or no longer reachable) go with them.
        suggestions = suggestions?.filter { suggestion in candidates.contains { $0.id == suggestion.id } }
    }

    func suggest(using assistant: Assistant, telescope: String) async {
        guard !suggesting else { return }
        suggesting = true
        problem = nil
        defer { suggesting = false }
        do {
            let picks = try await assistant.suggest(candidates, telescope: telescope)
            suggestions = picks.isEmpty ? nil : picks
            if picks.isEmpty { problem = "Apple Intelligence didn't pick anything. Try again." }
        } catch {
            problem = "Apple Intelligence couldn't make suggestions: \(error.localizedDescription)"
        }
    }

    func clearSuggestions() {
        suggestions = nil
        problem = nil
    }

    /// The Moon and planets (the model's picks in its order, once asked), then a couple of bright stars for focusing.
    var shown: [(candidate: TonightCandidate, reason: String?)] {
        let bodies: [(TonightCandidate, String?)] = if let suggestions {
            suggestions.compactMap { suggestion in candidates.first { $0.id == suggestion.id }.map { ($0, suggestion.reason) } }
        } else {
            candidates.filter { $0.kind != .star }.prefix(5).map { ($0, nil) }
        }
        let stars = candidates.filter { $0.kind == .star }.prefix(1).map { ($0, Optional("Bright star, for focusing")) }
        return bodies + stars
    }

    /// Whether there's anything to ask the model about (it isn't offered stars).
    var hasBodies: Bool { candidates.contains { $0.kind != .star } }
}
