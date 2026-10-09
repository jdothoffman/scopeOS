import ScopeKit
import SwiftUI

/// Tonight's targets on the Sky tab. Clicking one selects it on the map; Go to is a separate, confirmed step there.
struct TonightList: View {
    @Environment(LocationModel.self) private var location
    @Environment(CameraModel.self) private var camera
    @Environment(Assistant.self) private var assistant
    @Environment(TonightModel.self) private var tonight
    @Binding var selection: SkySelection?

    var body: some View {
        if let observer = location.observer {
            VStack(alignment: .leading, spacing: 10) {
                header
                if tonight.candidates.isEmpty {
                    Text(tonight.dark == nil ? "It doesn't get dark here in the next day." : "Nothing is high enough tonight.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    VStack(spacing: 2) {
                        ForEach(tonight.shown, id: \.candidate.id) { row($0.candidate, reason: $0.reason) }
                    }
                }
                footer
            }
            .task(id: observer) {
                // Again every five minutes while it's on screen, so "in view" stays true through the night.
                while !Task.isCancelled {
                    tonight.refresh(observer: observer)
                    try? await Task.sleep(for: .seconds(300))
                }
            }
        } else {
            Text("Set your location in the Setup tab to see what's up tonight.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let dark = tonight.dark {
                Text("Dark \(time(dark.lowerBound))–\(time(dark.upperBound))")
                    .font(Theme.numeric(12))
                    .foregroundStyle(Theme.textSecondary)
                    .help("Each target's time is when it's highest while dark. Click one to select it on the map, then Go to.")
            }
            Spacer()
            if assistant.status != .notInBuild && assistant.status != .turnedOff {
                if tonight.suggesting {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await tonight.suggest(using: assistant, telescope: telescope) }
                } label: {
                    Label(tonight.suggestions == nil ? "Suggest" : "Again", systemImage: "apple.intelligence")
                }
                .controlSize(.small)
                .disabled(assistant.status != .ready || tonight.suggesting || !tonight.hasBodies)
                .help(helpText)
            }
        }
    }

    private func row(_ candidate: TonightCandidate, reason: String?) -> some View {
        Button {
            selection = candidate.selection
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(candidate.target.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if reason == nil {
                            Text(candidate.note)
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    if let reason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                Text(time(candidate.best))
                    .font(Theme.numeric(14))
                    .foregroundStyle(Theme.accent)
                Text("\(Int(candidate.bestSky.altitude.rounded()))° \(SkyFormat.compassPoint(candidate.bestSky.azimuth))")
                    .font(Theme.numeric(11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 52, alignment: .trailing)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(TonightRowStyle())
        .help("Highest at \(time(candidate.best)) while dark; in view \(time(candidate.window.lowerBound))–\(time(candidate.window.upperBound)). Click to select it on the map.")
    }

    @ViewBuilder private var footer: some View {
        if let problem = tonight.problem {
            Text(problem).font(.caption).foregroundStyle(Theme.warning)
        } else if case .unavailable(let reason) = assistant.status {
            Text(reason).font(.caption).foregroundStyle(Theme.textTertiary)
        } else if tonight.suggestions != nil {
            Label("Picked by Apple Intelligence, on this Mac. Times are the app's own.", systemImage: "apple.intelligence")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var helpText: String {
        if case .unavailable(let reason) = assistant.status { return reason }
        return "Ask Apple Intelligence, on this Mac, to pick the best of tonight's targets for this telescope and say why"
    }

    private var telescope: String {
        let name = camera.telescopeName.isEmpty ? "a Celestron NexStar 6SE (150 mm aperture, f/10)" : camera.telescopeName
        return "\(name), at \(camera.focalLength) mm focal length"
    }

    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

/// A faint highlight under the pointer and while pressed.
private struct TonightRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Theme.accent.opacity(configuration.isPressed ? 0.14 : hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 3))
            .onHover { hovering = $0 }
    }
}

/// Setup: whether scopeOS uses Apple Intelligence. Hidden when the build leaves it out (Features.plist).
struct AssistantCard: View {
    @Environment(Assistant.self) private var assistant
    @Environment(TonightModel.self) private var tonight

    var body: some View {
        @Bindable var assistant = assistant
        if assistant.flags.onDeviceAI {
            Card(title: "AI suggestions", systemImage: "apple.intelligence") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Use Apple Intelligence", isOn: $assistant.userEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: assistant.userEnabled) { _, on in
                            if !on { tonight.clearSuggestions() }
                        }
                    switch assistant.status {
                    case .ready:
                        Label("Ready", systemImage: "checkmark.circle").foregroundStyle(Theme.ok).font(.caption)
                    case .unavailable(let reason):
                        Label(reason, systemImage: "exclamationmark.circle").foregroundStyle(Theme.warning).font(.caption)
                    case .turnedOff, .notInBuild:
                        EmptyView()
                    }
                    Text("Ranks tonight's targets on the Sky tab. Runs on this Mac and sends nothing anywhere. It only picks from the targets scopeOS works out, and never moves the telescope: a pick just selects the target on the Sky map.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
