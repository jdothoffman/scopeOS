import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Switches built into the app, from Features.plist. A missing file or key counts as on.
struct FeatureFlags: Equatable {
    /// Apple Intelligence's on-device model may be used at all (the user can still turn it off).
    var onDeviceAI = true

    init(onDeviceAI: Bool = true) {
        self.onDeviceAI = onDeviceAI
    }

    init(contentsOf url: URL?) {
        guard let url, let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        onDeviceAI = values["OnDeviceAI"] as? Bool ?? true
    }

    static let shipped = FeatureFlags(contentsOf: Bundle.main.url(forResource: "Features", withExtension: "plist"))
}

/// One of tonight's targets as the on-device model picked it, with its reason.
struct TonightSuggestion: Equatable {
    let id: String
    let reason: String
}

/// Apple Intelligence's on-device model, used only to rank and describe tonight's targets. It runs on the device and sends
/// nothing anywhere. It never moves the telescope: it can only name targets the app already worked out, and picking one
/// just selects it on the map, so Go to's own checks and confirmation still apply.
@MainActor
@Observable
final class Assistant {
    enum Status: Equatable {
        /// Left out of this build (Features.plist).
        case notInBuild
        /// Turned off in the Setup tab.
        case turnedOff
        case unavailable(String)
        case ready
    }

    let flags: FeatureFlags
    var userEnabled: Bool { didSet { defaults.set(userEnabled, forKey: Self.enabledKey) } }
    @ObservationIgnored private let defaults: UserDefaults
    static let enabledKey = "useOnDeviceAI"

    init(flags: FeatureFlags = .shipped, defaults: UserDefaults = .standard) {
        self.flags = flags
        self.defaults = defaults
        userEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    var status: Status {
        guard flags.onDeviceAI else { return .notInBuild }
        guard userEnabled else { return .turnedOff }
        return Self.modelStatus
    }

    private static var modelStatus: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .ready
            case .unavailable(.appleIntelligenceNotEnabled): return .unavailable("Apple Intelligence is off in System Settings.")
            case .unavailable(.deviceNotEligible): return .unavailable("This \(Platform.deviceName) can't run Apple Intelligence.")
            case .unavailable(.modelNotReady): return .unavailable("Apple Intelligence is still downloading its model. Try again later.")
            case .unavailable: return .unavailable("Apple Intelligence isn't available right now.")
            }
        }
        #endif
        return .unavailable("Needs macOS 26 or later.")
    }

    /// The Moon and planets among `candidates`, best first, each with a one-line reason. Stars aren't offered (the app
    /// lists them itself, for focusing). Anything the model names that wasn't offered is dropped, so it can't put a
    /// made-up target on the list.
    func suggest(_ candidates: [TonightCandidate], telescope: String) async throws -> [TonightSuggestion] {
        let offered = candidates.filter { $0.kind != .star }
        guard status == .ready, !offered.isEmpty else { return [] }
        var picks: [TonightSuggestion] = []
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: Self.instructions(telescope: telescope))
            let plan = try await session.respond(to: Self.prompt(offered), generating: TonightPlan.self).content
            picks = plan.picks.map { TonightSuggestion(id: $0.id.lowercased().filter(\.isLetter), reason: $0.reason) }
        }
        #endif
        return Self.keep(picks, from: offered)
    }

    /// Only picks that name a candidate, each once, in the model's order.
    static func keep(_ picks: [TonightSuggestion], from candidates: [TonightCandidate]) -> [TonightSuggestion] {
        let known = Set(candidates.map(\.id))
        var seen = Set<String>()
        return picks.filter { known.contains($0.id) && seen.insert($0.id).inserted }
    }

    static func instructions(telescope: String) -> String {
        """
        You help plan a night at the telescope: \(telescope), recording short videos with a small planetary camera to \
        stack into still images. Rank the targets you're given, best first for this telescope tonight, and copy each id \
        exactly. Bright, high targets with detail to record come first; faint, tiny or low ones last.
        For each, write one short sentence in your own words: what it will show, and whether to look in the evening, \
        around midnight or before dawn. Use only the facts given, and never mention clock times, degrees or directions.
        """
    }

    /// Words, not numbers, for when and how high: a small model copies numbers back instead of saying anything.
    static func prompt(_ candidates: [TonightCandidate]) -> String {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let lines = candidates.map { c in
            let hour = calendar.component(.hour, from: c.best)
            let when = (12 ..< 22).contains(hour) ? "best in the evening" : (hour >= 22 || hour < 2) ? "best around midnight" : "best before dawn"
            let altitude = c.bestSky.altitude
            let height = altitude >= 50 ? "high in the sky" : altitude >= 30 ? "well up" : "low in the sky"
            return "- id: \(c.id) | \(c.target.name) | \(facts(c)) | \(when), \(height)"
        }
        return "Targets tonight:\n" + lines.joined(separator: "\n")
    }

    /// What each shows in a 150 mm telescope with a planetary camera, so the model needn't recall (or invent) it.
    private static func facts(_ candidate: TonightCandidate) -> String {
        switch candidate.target.kind {
        case .moon: "\(candidate.note); craters and mountains, sharpest along the line between light and dark"
        case .planet(let planet):
            switch planet {
            case .mercury: "planet; small, shows a phase like a tiny Moon"
            case .venus: "planet; very bright, shows a phase but no surface detail"
            case .mars: "planet; small disk, a polar cap and dark markings when near Earth"
            case .jupiter: "planet; cloud belts, sometimes the Great Red Spot, and four bright moons that move night to night"
            case .saturn: "planet; its rings, and the moon Titan nearby"
            case .uranus: "planet; a tiny pale blue-green disk"
            case .neptune: "planet; a tiny blue dot, hard to tell from a star"
            }
        default: candidate.note
        }
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
private struct TonightPlan {
    @Guide(description: "Up to five picks, best first", .maximumCount(5))
    var picks: [Pick]

    @Generable
    struct Pick {
        @Guide(description: "The id of a candidate, copied exactly from the list")
        var id: String
        @Guide(description: "One short sentence in your own words: what it shows, and when in the night to look")
        var reason: String
    }
}
#endif
