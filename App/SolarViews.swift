import ScopeKit
import SwiftUI

/// Before every Go to the Sun: the solar filter checklist. Every item must be ticked; confirming records it with the
/// date and time (`SolarLog`) and turns Solar mode on.
struct SolarConfirmationSheet: View {
    @Environment(MonitorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var ticked = Array(repeating: false, count: SolarLog.checklist.count)

    var body: some View {
        #if os(macOS)
        checklist.frame(width: 520)
        #else
        ScrollView { checklist } // all of it reachable on a small phone
            .background(Theme.backgroundTop)
        #endif
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Go to the Sun", systemImage: "sun.max.trianglebadge.exclamationmark")
                .font(Theme.display(24))
                .foregroundStyle(Theme.warning)
            Text("Never point a telescope at the Sun without a solar filter covering the front of the telescope. Looking through it, even for an instant, causes permanent eye damage, and the Sun's focused light can destroy a camera.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SolarLog.checklist.indices, id: \.self) { index in
                    Toggle(isOn: $ticked[index]) {
                        Text(SolarLog.checklist[index]).fixedSize(horizontal: false, vertical: true)
                    }
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
                }
            }
            .padding(12)
            .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(model.goToSummary(.sun))
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Confirming saves the date and time on this \(Platform.deviceName) (\(SolarLog.defaultFile.lastPathComponent)), and turns on Solar mode: the 30° Sun keep-out and the daylight lock are lifted until you end it, disconnect or quit. scopeOS asks again before every Go to the Sun.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Confirm and Go to the Sun") {
                    model.confirmSolarGoTo()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.warning)
                .disabled(ticked.contains(false))
            }
        }
        .padding(24)
        .foregroundStyle(Theme.textPrimary)
        .background(Theme.backgroundTop)
        .preferredColorScheme(.dark)
    }
}

/// On every tab while Solar mode is on, with the way out.
struct SolarModeBanner: View {
    @Environment(MonitorModel.self) private var model

    var body: some View {
        if let confirmed = model.solarMode {
            HStack(spacing: 12) {
                Image(systemName: "sun.max.fill")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SOLAR MODE")
                        .font(Theme.display(16))
                        .tracking(2)
                    Text("The 30° Sun keep-out and the daylight lock are off. Solar filter confirmed at \(confirmed.formatted(date: .omitted, time: .shortened)).")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("End Solar Mode") { model.endSolarMode() }
                    .controlSize(.small)
            }
            .foregroundStyle(Theme.warning)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.warning.opacity(0.6)))
        }
    }
}
