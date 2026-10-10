import ScopeKit
import SwiftUI

/// Celestron focus motor: position within its calibrated range, step buttons and press-and-hold.
struct FocusCard: View {
    @Environment(MonitorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Card(title: "Focus", systemImage: "circle.circle") {
            if let status = model.status, model.canNudge, let position = status.focuserPosition {
                if let limits = status.focuserLimits {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Readout(label: "Position", value: "\(position)", tint: Theme.cool)
                            Spacer()
                            if status.focuserMoving == true {
                                StatusPill(label: "Moving", color: Theme.warning)
                            }
                        }
                        RangeBar(position: position, limits: limits)

                        HStack(spacing: 8) {
                            FocusHoldButton(positive: false, systemImage: "backward.fill")
                            Button { model.focus(direction: -1) } label: { Label("−\(model.focusStep)", systemImage: "minus") }
                            Spacer()
                            Button { model.focus(direction: 1) } label: { Label("+\(model.focusStep)", systemImage: "plus") }
                            FocusHoldButton(positive: true, systemImage: "forward.fill")
                        }
                        .disabled(!model.canFocus || model.focusInFlight || status.focuserMoving == true && model.activeFocus == nil)

                        Picker("Step", selection: $model.focusStep) {
                            ForEach(MonitorModel.focusSteps.filter { $0 <= FocusCommand.maxStep(limits) }, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)

                        FocusStatus()

                        Text("The ◀◀ ▶▶ buttons move while held, for up to \(Int(MonitorModel.focusHoldSeconds)) seconds. Every move stays inside the motor's calibrated range (\(limits.lowerBound)–\(limits.upperBound)) and stops on its own at its target.")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Label("The focus motor hasn't reported calibrated limits, so focusing is locked. Calibrate it from the hand controller or the SkyPortal app, then reconnect.",
                          systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(model.phase == .connected && model.status?.protocolKind == .aux ? "No focus motor found on the AUX bus."
                     : "Connect over the WiFi module to use the focus motor.")
                    .foregroundStyle(Theme.textSecondary)
            }
            Divider().overlay(Color.white.opacity(0.06))
            FocusAid()
        }
        .onReceive(NotificationCenter.default.publisher(for: Platform.resignActive)) { _ in
            model.releaseFocus()
        }
    }
}

/// Where the focuser sits between its calibrated ends.
private struct RangeBar: View {
    let position: Int
    let limits: ClosedRange<Int>

    var body: some View {
        let fraction = Double(position - limits.lowerBound) / Double(max(1, limits.upperBound - limits.lowerBound))
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.accent.opacity(0.12))
                    Capsule()
                        .fill(Theme.cool)
                        .frame(width: max(6, geometry.size.width * min(1, max(0, fraction))))
                        .glow(Theme.cool, radius: 4)
                }
            }
            .frame(height: 6)
            HStack {
                Text("\(limits.lowerBound)")
                Spacer()
                Text("\(limits.upperBound)")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// Moves the focuser while the mouse button is held down on it.
private struct FocusHoldButton: View {
    @Environment(MonitorModel.self) private var model
    let positive: Bool
    let systemImage: String
    @State private var pressed = false

    private var isMine: Bool { model.activeFocus?.positive == positive }
    private var enabled: Bool { model.canFocus && !model.focusInFlight && (model.activeFocus == nil ? model.activeMove == nil : isMine) }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 40, height: 26)
            .foregroundStyle(isMine ? Theme.backgroundTop : Theme.accent)
            .background(isMine ? Theme.accent : Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.accent.opacity(isMine ? 0 : 0.35)))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.35)
            .help(positive ? "Hold to move the focuser up (higher positions)" : "Hold to move the focuser down (lower positions)")
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed, enabled else { return }
                        pressed = true
                        model.pressFocus(positive: positive)
                    }
                    .onEnded { _ in
                        guard pressed else { return }
                        pressed = false
                        model.releaseFocus()
                    }
            )
            .onChange(of: enabled) { _, nowEnabled in
                if !nowEnabled && pressed {
                    pressed = false
                    model.releaseFocus()
                }
            }
    }
}

private struct FocusStatus: View {
    @Environment(MonitorModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            Group {
                if let hold = model.activeFocus {
                    let remaining = max(0, Double(MonitorModel.focusHoldSeconds) - context.date.timeIntervalSince(hold.started))
                    Text(String(format: "Focusing %@ · stops in %.1f s", hold.positive ? "up" : "down", remaining))
                        .foregroundStyle(Theme.accent)
                } else if let notice = model.controlNotice, notice.hasPrefix("Focus") {
                    Text(notice).foregroundStyle(Theme.warning)
                } else {
                    Text("Tip: watch the camera preview and step until the planet's edge is crisp.")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Live sharpness from the camera: peaks at best focus. Works with the focus motor or a hand on the focus knob.
private struct FocusAid: View {
    @Environment(CameraModel.self) private var camera
    @Environment(MonitorModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Theme.label("Focus aid")
                Spacer()
                if camera.bestSharpness != nil {
                    Button("Reset") { camera.resetFocusAid() }
                        .controlSize(.small)
                        .help("Forget the best reading and start over")
                }
            }
            if camera.running, let current = camera.stats.sharpness {
                let best = camera.bestSharpness
                let ratio = best.map { current / max($0.value, 1e-9) } ?? 1
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(format: "%.2f", current))
                        .font(.system(size: 26, weight: .light, design: .monospaced))
                        .glow(Theme.accent, radius: 8)
                        .contentTransition(.numericText())
                    Text(String(format: "%.0f%% of best", ratio * 100))
                        .font(.callout)
                        .foregroundStyle(ratio >= 0.95 ? Theme.ok : Theme.textSecondary)
                }
                SharpnessTrend(samples: camera.sharpnessHistory, best: best?.value)
                    .frame(height: 44)
                if let best {
                    HStack {
                        Text(best.focuserPosition.map { String(format: "Best %.2f at position %d", best.value, $0) }
                             ?? String(format: "Best %.2f", best.value))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        if let position = best.focuserPosition, model.canFocus {
                            Button("Go to best") { model.focus(toPosition: position) }
                                .controlSize(.small)
                                .disabled(model.focusInFlight || model.activeFocus != nil || model.status?.focuserPosition == position)
                                .help("Move the focuser back to where the sharpest reading was (approximate: the position is read once a second)")
                        }
                    }
                }
                Text("Keep the target on the crosshair and step the focus: the reading peaks at best focus. The air makes it flicker, so watch the trend.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(camera.running ? "No reading yet: aim at something bright and put it on the crosshair."
                     : "Start the camera preview (Camera tab) to see a live sharpness reading.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The last 30 seconds of sharpness, with the best reading as a dashed line.
private struct SharpnessTrend: View {
    let samples: [CameraModel.SharpnessSample]
    let best: Double?

    var body: some View {
        Canvas { context, size in
            guard let last = samples.last else { return }
            let top = max(best ?? 0, samples.map(\.value).max() ?? 0) * 1.1
            guard top > 0 else { return }
            func point(_ sample: CameraModel.SharpnessSample) -> CGPoint {
                let age = last.date.timeIntervalSince(sample.date)
                return CGPoint(x: size.width * (1 - age / CameraModel.sharpnessWindow), y: size.height * (1 - sample.value / top))
            }
            if let best {
                var line = Path()
                let y = size.height * (1 - best / top)
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(Theme.ok.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            var trend = Path()
            for (index, sample) in samples.enumerated() {
                index == 0 ? trend.move(to: point(sample)) : trend.addLine(to: point(sample))
            }
            context.stroke(trend, with: .color(Theme.accent), lineWidth: 1.5)
        }
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
