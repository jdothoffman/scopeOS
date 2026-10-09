import Foundation
import ScopeKit
import Testing

@MainActor
@Suite("Tonight")
struct TonightTests {
    let observer = Observer(latitude: 38.89, longitude: -77.04)
    /// 2026-10-10 02:00 UT (22:00 in Washington): dark, a week after Saturn's opposition.
    let night = Date(timeIntervalSince1970: 1_791_597_600)
    /// 2026-10-09 16:00 UT: midday.
    let midday = Date(timeIntervalSince1970: 1_791_561_600)

    @Test func theDarkWindowStartsNowAtNightAndAtDuskByDay() throws {
        let tonight = try #require(TonightPlanner.darkWindow(observer: observer, from: night))
        #expect(tonight.lowerBound == night)
        #expect(tonight.upperBound.timeIntervalSince(night) > 6 * 3600, "dark until dawn")

        let later = try #require(TonightPlanner.darkWindow(observer: observer, from: midday))
        #expect(later.lowerBound.timeIntervalSince(midday) > 3 * 3600, "waits for dusk")
        #expect(later.lowerBound < night)
    }

    @Test func candidatesAreReachableWhileDarkAndAwayFromTheSun() throws {
        let candidates = TonightPlanner.candidates(observer: observer, date: night)
        let dark = try #require(TonightPlanner.darkWindow(observer: observer, from: night))
        #expect(candidates.contains { $0.id == "saturn" })
        #expect(candidates.contains { $0.kind == .star })
        #expect(Set(candidates.map(\.id)).count == candidates.count, "ids are unique")
        for candidate in candidates {
            #expect((TonightPlanner.minimumAltitude ... NudgeCommand.altitudeLimits.upperBound).contains(candidate.bestSky.altitude))
            #expect(dark.contains(candidate.best))
            let sun = Astronomy.separation(candidate.target.position(at: candidate.best), Astronomy.sunPosition(at: candidate.best))
            #expect(sun >= SunSafety.keepOutDegrees)
        }
        // The Moon and planets come before the stars.
        let firstStar = try #require(candidates.firstIndex { $0.kind == .star })
        #expect(candidates[firstStar...].allSatisfy { $0.kind == .star })
    }

    @Test func theModelCanOnlyPickListedTargets() {
        let candidates = TonightPlanner.candidates(observer: observer, date: night)
        let picks = [TonightSuggestion(id: "saturn", reason: "Rings."), TonightSuggestion(id: "andromedagalaxy", reason: "Made up."),
                     TonightSuggestion(id: "saturn", reason: "Again.")]
        #expect(Assistant.keep(picks, from: candidates) == [TonightSuggestion(id: "saturn", reason: "Rings.")])
    }

    @Test func thePromptListsEveryCandidateByIdWithoutNumbers() {
        let bodies = TonightPlanner.candidates(observer: observer, date: night).filter { $0.kind != .star }
        let prompt = Assistant.prompt(bodies)
        for candidate in bodies { #expect(prompt.contains("id: \(candidate.id) |")) }
        #expect(!prompt.contains("°"), "no altitudes for the model to parrot")
    }
}

@MainActor
@Suite("Apple Intelligence switches")
struct AssistantSwitchTests {
    private func defaults() -> UserDefaults {
        let suite = "scopeos-tests-assistant-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func theShippedFeatureFileTurnsItOn() {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Features.plist")
        #expect(FeatureFlags(contentsOf: file).onDeviceAI)
        #expect(FeatureFlags(contentsOf: nil).onDeviceAI, "a missing file counts as on")
    }

    @Test func theFeatureFileCanLeaveItOut() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("features-\(UUID().uuidString).plist")
        try PropertyListSerialization.data(fromPropertyList: ["OnDeviceAI": false], format: .xml, options: 0).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let flags = FeatureFlags(contentsOf: file)
        #expect(!flags.onDeviceAI)
        #expect(Assistant(flags: flags, defaults: defaults()).status == .notInBuild)
    }

    @Test func itsOnUntilTheUserTurnsItOffAndStaysOff() {
        let store = defaults()
        let assistant = Assistant(flags: FeatureFlags(), defaults: store)
        #expect(assistant.userEnabled)
        assistant.userEnabled = false
        #expect(assistant.status == .turnedOff)
        #expect(!Assistant(flags: FeatureFlags(), defaults: store).userEnabled, "remembered")
    }
}

/// Asks the real on-device model, for checking its picks by eye. Off unless asked for:
///   TEST_RUNNER_SCOPEOS_LIVE_AI=1 xcodebuild test -scheme ScopeOS -only-testing:ScopeOSTests/LiveAssistantTests
@MainActor
@Suite("Live Apple Intelligence")
struct LiveAssistantTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["SCOPEOS_LIVE_AI"] != nil

    @Test(.enabled(if: enabled))
    func suggestTonight() async throws {
        let observer = Observer(latitude: 38.89, longitude: -77.04)
        let date = Date.now
        let candidates = TonightPlanner.candidates(observer: observer, date: date)
        let assistant = Assistant(flags: FeatureFlags(), defaults: UserDefaults(suiteName: "scopeos-tests-live-\(UUID().uuidString)")!)
        try #require(assistant.status == .ready)
        let picks = try await assistant.suggest(candidates, telescope: "a Celestron NexStar 6SE (150 mm aperture, f/10), at 1500 mm focal length")
        print(Assistant.prompt(candidates.filter { $0.kind != .star }))
        for pick in picks { print("PICK \(pick.id): \(pick.reason)") }
        #expect(!picks.isEmpty)
    }
}
