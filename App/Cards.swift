import ScopeKit
import SwiftUI

struct Card<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text(title.uppercased())
                    .font(Theme.display(15))
                    .tracking(2.4)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 3) // DIN Condensed sits high in its line box
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

struct Readout: View {
    let label: String
    let value: String
    var detail: String?
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Theme.label(label)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(Theme.numeric(32))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7) // a little smaller rather than wrapping, on a phone
                if let detail {
                    Text(detail)
                        .font(Theme.display(17))
                        .tracking(1)
                        .foregroundStyle(tint)
                }
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var color: Color = Theme.textPrimary

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(Theme.numeric(15))
                .foregroundStyle(color)
        }
        .font(.callout)
    }
}

struct PointingCard: View {
    @Environment(MonitorModel.self) private var model
    @Environment(\.layoutWidth) private var width
    let status: MountStatus?

    var body: some View {
        @Bindable var model = model
        Card(title: "Pointing", systemImage: "scope") {
            if let eq = status?.equatorial {
                HStack(spacing: width == .narrow ? 20 : 40) {
                    Readout(label: "Right ascension", value: SkyFormat.rightAscension(eq.raHours))
                    Readout(label: "Declination", value: SkyFormat.declination(eq.decDegrees))
                }
            } else if status?.protocolKind == .aux {
                Text(MonitorModel.Kind.available.contains(.usbHandController)
                     ? "Motor angles over WiFi. RA/Dec needs the USB connection to the hand controller."
                     : "Motor angles over WiFi. RA/Dec needs the hand controller's USB connection, from a Mac.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(width == .wide ? 1 : 2)
                    .minimumScaleFactor(0.85)
            }

            if let h = status?.horizontal {
                let isAux = status?.protocolKind == .aux
                let moving = status?.slewing == true
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Readout(label: "Azimuth", value: SkyFormat.degrees(h.azimuth),
                                detail: SkyFormat.compassPoint(h.azimuth), tint: Theme.accent)
                        AzimuthTape(azimuth: h.azimuth, moving: moving)
                            .frame(height: 42)
                    }
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    HStack(alignment: .top, spacing: 16) {
                        Readout(label: "Altitude", value: SkyFormat.degrees(h.altitude), tint: Theme.accent)
                            .fixedSize()
                        AltitudeTape(altitude: h.altitude, moving: moving)
                            .animation(.linear(duration: 0.9), value: h.altitude)
                            .frame(width: 56, height: 118)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if isAux {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let calibration = status?.calibration {
                            Label(String(format: "Calibrated (motor offsets %.1f° az, %.1f° alt)", calibration.azimuthOffset, calibration.altitudeOffset),
                                  systemImage: "checkmark.seal")
                                .foregroundStyle(Theme.ok)
                        } else {
                            Label("Uncalibrated: assumes the scope was switched on level and pointing north.", systemImage: "exclamationmark.circle")
                                .foregroundStyle(Theme.warning)
                        }
                        Spacer()
                        Menu("Calibrate") {
                            Button("Tube is level now") { model.calibrateLevel() }
                            Button("Pointing true north now") { model.calibrateNorth() }
                            Button("Centred on Polaris") { model.calibratePolaris() }
                            Divider()
                            Button("Use home position") { model.useHome() }
                                .disabled(model.home == nil)
                            Button("Save as home position") { model.saveHome() }
                                .disabled(!model.isCalibrated)
                            Button("Forget home position") { model.forgetHome() }
                                .disabled(model.home == nil)
                            Divider()
                            Button("Clear calibration") { model.clearCalibration() }
                                .disabled(!model.isCalibrated)
                        }
                        .fixedSize()
                        .help("Level: check with a spirit level or the iPhone's Measure app. North: use true north (iPhone Compass › Settings › Use True North), with the phone away from the metal tube. Polaris: centre it first; sets both axes. Home: save a calibration made after switching on at the home marks, then reuse it whenever you switch on there.")
                    }
                    .font(.caption)
                }
            }

            if status == nil {
                VStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Theme.accent.opacity(0.7))
                    Text("Awaiting telemetry. Connect to see where the telescope is pointing.")
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
            }
        }
        .alert("Was the mount switched on at its home marks?", isPresented: $model.offerHome) {
            Button("Yes, use the home position") { model.useHome() }
            Button("No", role: .cancel) {}
        } message: {
            Text("The tube at the elevation index and the arm lined up with the base mark. If it wasn't, choose No: the readings, the Sun lock and the up/down limits would all be off.")
        }
    }
}

struct StatusCard: View {
    @Environment(LocationModel.self) private var location
    let status: MountStatus?
    let pollTime: Duration?

    var body: some View {
        Card(title: "Status", systemImage: "waveform.path.ecg") {
            VStack(spacing: 10) {
                InfoRow(label: "Motion", value: motion, color: status?.slewing == true ? Theme.warning : Theme.textPrimary)
                if let aligned = status?.aligned {
                    InfoRow(label: "Aligned", value: aligned ? "Yes" : "No", color: aligned ? Theme.ok : Theme.warning)
                }
                if let tracking = status?.tracking {
                    InfoRow(label: "Tracking", value: tracking.label)
                }
                sunRow
                if let pollTime {
                    InfoRow(label: "Poll round-trip", value: pollTime.formatted(.units(allowed: [.milliseconds], width: .abbreviated)))
                }
            }
        }
    }

    private var motion: String {
        switch status?.slewing {
        case .some(true): "Slewing"
        case .some(false): "Stationary / tracking"
        case .none: "—"
        }
    }

    /// The Sun where it is now, against the latest pointing reading; redrawn every 30 s, so it keeps up while
    /// disconnected too.
    private var sunRow: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            sunDistance(at: context.date)
        }
    }

    @ViewBuilder private func sunDistance(at date: Date) -> some View {
        if let (distance, approximate) = SunSituation.distance(status: status, observer: location.observer, date: date) {
            let tooClose = distance < SunSafety.keepOutDegrees
            let color: Color = tooClose ? Theme.danger : distance < SunSafety.cautionDegrees ? Theme.warning : Theme.ok
            InfoRow(label: approximate ? "Distance from Sun (approx.)" : "Distance from Sun",
                    value: String(format: "%@%.0f°%@", approximate ? "≈" : "", distance, tooClose ? "  TOO CLOSE" : ""),
                    color: color)
        } else if status != nil {
            InfoRow(label: "Distance from Sun", value: "Set location", color: Theme.textTertiary)
        }
    }
}

struct SiteCard: View {
    @Environment(LocationModel.self) private var location
    @State private var showManual = false

    var body: some View {
        @Bindable var location = location
        Card(title: "Site", systemImage: "location.north.circle") {
            VStack(alignment: .leading, spacing: 10) {
                if let observer = location.observer {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let sun = SunSituation(observer: observer, date: context.date)
                        VStack(spacing: 10) {
                            InfoRow(label: "Sky", value: sun.darkness.label, color: darknessColor(sun.darkness))
                            InfoRow(label: "Sun altitude", value: SkyFormat.degrees(sun.position.altitude, decimals: 1),
                                    color: sun.position.altitude > 0 ? Theme.warning : Theme.textPrimary)
                            InfoRow(label: "Sidereal time", value: SkyFormat.hoursMinutesSeconds(sun.siderealHours))
                        }
                    }
                    Divider().overlay(Color.white.opacity(0.06))
                    InfoRow(label: "Latitude", value: SkyFormat.latitude(observer.latitude))
                    InfoRow(label: "Longitude", value: SkyFormat.longitude(observer.longitude))
                    if let source = location.source, let date = location.fixDate {
                        Text("\(source.label), \(date.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                } else {
                    Text("Set your location to see the Sun's position, sky darkness and sidereal time, and to get the Sun warning over WiFi.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button {
                        location.locate()
                    } label: {
                        Label(location.locating ? "Locating…" : "Use My Location", systemImage: "location.fill")
                    }
                    .disabled(location.locating)
                    if location.locating { ProgressView().controlSize(.small) }
                }

                DisclosureGroup("Enter manually", isExpanded: $showManual) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Latitude (N +)", text: $location.manualLatitude)
                            TextField("Longitude (E +, W −)", text: $location.manualLongitude)
                        }
                        .textFieldStyle(.roundedBorder)
                        Button("Apply") { location.applyManual() }
                    }
                    .padding(.top, 6)
                }
                .foregroundStyle(Theme.textSecondary)

                if let problem = location.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func darknessColor(_ darkness: SkyDarkness) -> Color {
        switch darkness {
        case .day: Theme.warning
        case .civilTwilight, .nauticalTwilight: Theme.cool
        case .astronomicalTwilight: Theme.accent
        case .night: Theme.ok
        }
    }
}

struct DevicesCard: View {
    let status: MountStatus?

    var body: some View {
        Card(title: "Devices", systemImage: "cpu") {
            if let status {
                VStack(spacing: 10) {
                    InfoRow(label: "Protocol", value: status.protocolKind == .aux ? "AUX bus" : "Hand controller")
                    if let model = status.model { InfoRow(label: "Mount", value: model) }
                    ForEach(status.devices, id: \.name) { InfoRow(label: $0.name, value: $0.version) }
                    if let focus = status.focuserPosition { InfoRow(label: "Focuser position", value: "\(focus)") }
                }
            } else {
                Text("—").foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

struct ControlCard: View {
    @Environment(MonitorModel.self) private var model
    @State private var showFineSteps = false
    @State private var showMoveRules = false

    var body: some View {
        @Bindable var model = model
        Card(title: "Control", systemImage: "dpad") {
            if model.canNudge {
                VStack(alignment: .leading, spacing: 12) {
                    if BuildMode.isDebug { // release builds keep movement on and hide these
                        HStack(spacing: 14) {
                            Toggle("Movement", isOn: $model.movementEnabled)
                                .help("Enable movement")
                            Toggle("Up/down", isOn: $model.verticalEnabled)
                                .disabled(!model.movementEnabled)
                                .help("Enable up/down (needs movement on)")
                        }
                        .toggleStyle(.switch)
                        .lineLimit(1) // iOS switches are wider; the labels mustn't break mid-word
                    }
                    Toggle("Lock while the Sun is up", isOn: $model.sunLockWhileUp)
                        .toggleStyle(.switch)
                        .help("On at every launch. Turn off only for daytime testing with the telescope pointed well away from the Sun.")

                    ArrowPad()
                        .frame(maxWidth: .infinity)
                    HoldStatus()
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        GoToMenu()
                        ReturnHomeButton()
                    }

                    DisclosureGroup("Fine steps", isExpanded: $showFineSteps) {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Left/right", selection: $model.azimuthStep) {
                                ForEach(MonitorModel.azimuthSteps, id: \.self) { Text(String(format: "%g°", $0)).tag($0) }
                            }
                            .disabled(!model.movementEnabled)
                            NudgeButtons(axis: .azimuth, negative: ("Left", "arrow.left"), positive: ("Right", "arrow.right"))
                            Picker("Up/down", selection: $model.altitudeStep) {
                                ForEach(MonitorModel.altitudeSteps, id: \.self) { Text(String(format: "%g°", $0)).tag($0) }
                            }
                            .disabled(!model.verticalEnabled)
                            NudgeButtons(axis: .altitude, negative: ("Down", "arrow.down"), positive: ("Up", "arrow.up"))
                        }
                        .pickerStyle(.segmented)
                        .padding(.top, 6)
                    }

                    // The rules in one line, the full explanation a click away.
                    HStack(spacing: 6) {
                        Text(String(format: "Hold to move, up to %d s · %.0f°–%.0f° up · %.0f° from the Sun",
                                    Int(MonitorModel.holdSeconds), NudgeCommand.altitudeLimits.lowerBound,
                                    NudgeCommand.altitudeLimits.upperBound, SunSafety.keepOutDegrees))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Button {
                            showMoveRules.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                        .help("How moves are kept safe")
                        .popover(isPresented: $showMoveRules, arrowEdge: .bottom) {
                            Text(String(format: "Hold an arrow to move; release to stop (holds stop by themselves after %d seconds). Moves go in steps of at most %g° left/right or %g° up/down, each sent before the last ends and each ending at a fixed point the mount stops at on its own, so it stops within a step even if the connection drops. Up/down stays between %.0f° and %.0f° altitude. No move may pass within %.0f° of the Sun.",
                                        Int(MonitorModel.holdSeconds), NudgeAxis.azimuth.maxStepDegrees, NudgeAxis.altitude.maxStepDegrees,
                                        NudgeCommand.altitudeLimits.lowerBound, NudgeCommand.altitudeLimits.upperBound, SunSafety.keepOutDegrees))
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 320)
                                .padding(14)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                }
                .onReceive(NotificationCenter.default.publisher(for: Platform.resignActive)) { _ in
                    model.releaseArrow()
                }
            } else {
                Text(model.phase == .connected ? "Available over the WiFi module." : "Connect to control the telescope.")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .alert("The scope isn't at its home position", isPresented: $model.offerReturnHome) {
            Button("Return to home") { model.returnHome() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Drive it back now? It moves one axis at a time, in the same small steps as holding an arrow, and Stop cancels it.")
        }
    }
}

/// Points the scope at Polaris or a bright star, after confirming.
private struct GoToMenu: View {
    @Environment(MonitorModel.self) private var model

    var body: some View {
        Menu("Go to") {
            ForEach(SkyTarget.brightStars) { star in
                Button(label(star)) { model.requestGoTo(star) }
            }
        }
        .fixedSize()
        .disabled(model.driveProblem != nil)
        .help(model.driveProblem ?? "Point at a bright star, worked out from your location and the time.")
        .alert("Go to \(model.pendingGoTo?.name ?? "")?", isPresented: Binding(get: { model.pendingGoTo != nil }, set: { if !$0 { model.pendingGoTo = nil } }),
               presenting: model.pendingGoTo) { star in
            Button("Go") { model.goTo(star) }
            Button("Cancel", role: .cancel) {}
        } message: { star in
            Text(model.goToSummary(star))
        }
    }

    private func label(_ star: SkyTarget) -> String {
        guard let sky = model.pointing(of: .star(star)) else { return star.name }
        if sky.altitude < 0 { return "\(star.name): below the horizon" }
        return String(format: "%@: %.0f° up, %@", star.name, sky.altitude, SkyFormat.compassPoint(sky.azimuth))
    }
}

/// Drives back to the home position, or cancels that while it's under way.
private struct ReturnHomeButton: View {
    @Environment(MonitorModel.self) private var model

    var body: some View {
        if model.home != nil {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if model.isReturningHome {
                    Button("Cancel return") { model.cancelDrive() }
                } else {
                    Button("Return to home") { model.returnHome() }
                        .disabled(model.returnHomeProblem != nil)
                }
                if model.driving == nil, !model.isAtHome, let problem = model.returnHomeProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ArrowPad: View {
    @Environment(MonitorModel.self) private var model

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                HoldArrow(axis: .altitude, positive: true, systemImage: "arrow.up")
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
            GridRow {
                HoldArrow(axis: .azimuth, positive: false, systemImage: "arrow.left")
                Button { model.stopTelescope() } label: {
                    StopKnob()
                        .frame(width: 60, height: 52)
                }
                .buttonStyle(.plain)
                .help("Stop Telescope")
                HoldArrow(axis: .azimuth, positive: true, systemImage: "arrow.right")
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                HoldArrow(axis: .altitude, positive: false, systemImage: "arrow.down")
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline))
        .overlay(CornerBrackets(length: 8).stroke(Theme.scale.opacity(0.5), lineWidth: 1))
    }
}

/// The emergency-stop control: a red knob in a dark collar, like the one on a machine.
struct StopKnob: View {
    var label = "STOP"

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.5))
            Circle().strokeBorder(Theme.danger.opacity(0.5), lineWidth: 1)
            Circle()
                .fill(RadialGradient(colors: [Theme.danger, Theme.danger.opacity(0.75)], center: UnitPoint(x: 0.4, y: 0.35),
                                     startRadius: 0, endRadius: 26))
                .padding(5)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1).padding(5))
            Text(label)
                .font(Theme.display(13))
                .tracking(1.2)
                .foregroundStyle(.white)
                .padding(.top, 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Moves while the mouse button is held down on it, and stops on release (or when the model's time limit hits).
private struct HoldArrow: View {
    @Environment(MonitorModel.self) private var model
    let axis: NudgeAxis
    let positive: Bool
    let systemImage: String
    @State private var pressed = false
    @GestureState private var touching = false

    private var isMine: Bool { model.activeMove.map { $0.axis == axis && $0.positive == positive } ?? false }

    private var enabled: Bool {
        guard model.isEnabled(axis), model.canNudge, !model.nudgeInFlight, model.driving == nil else { return false }
        // Arrows whose full reach would come near the Sun are off; a hold in progress stops if that changes.
        guard model.sunProblem(axis, by: (positive ? 1 : -1) * axis.maxStepDegrees) == nil else { return false }
        // While this arrow is held the mount reports slewing; that mustn't disable the arrow and cut the hold short.
        return model.activeMove == nil ? model.status?.slewing != true : isMine
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(.title2.weight(.medium))
            .frame(width: 60, height: 52)
            .foregroundStyle(isMine ? Theme.backgroundTop : Theme.accent)
            .background(isMine ? Theme.accent : Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(isMine ? Color.clear : Theme.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 2))
            .opacity(enabled ? 1 : 0.35)
            // `touching` is reset when the gesture ends and also when the system cancels it (Control Center, an alert, a
            // second gesture taking over), which never calls `onEnded`: the move must stop either way.
            .gesture(DragGesture(minimumDistance: 0).updating($touching) { _, touching, _ in touching = true })
            .onChange(of: touching) { _, nowTouching in
                if nowTouching {
                    guard !pressed, enabled else { return }
                    pressed = true
                    model.pressArrow(axis, positive: positive)
                } else if pressed {
                    pressed = false
                    model.releaseArrow()
                }
            }
            .onChange(of: enabled) { _, nowEnabled in
                if !nowEnabled && pressed {
                    pressed = false
                    model.releaseArrow()
                }
            }
    }
}

private struct HoldStatus: View {
    @Environment(MonitorModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            Group {
                if let move = model.activeMove {
                    let remaining = max(0, Double(MonitorModel.holdSeconds) - context.date.timeIntervalSince(move.started))
                    Text(String(format: "Moving %@ · stops in %.0f s", direction(move.axis, move.positive), remaining))
                        .foregroundStyle(Theme.accent)
                } else if let drive = model.driving {
                    Text(drive.destination == .home ? "Returning to the home position… Stop cancels it." : "Going to \(drive.destination.name)… Stop cancels it.")
                        .foregroundStyle(Theme.accent)
                } else if let notice = model.controlNotice {
                    Text(notice).foregroundStyle(Theme.warning)
                } else if model.movementEnabled, let lock = model.movementLock(at: context.date) {
                    Label(lock, systemImage: "sun.max.trianglebadge.exclamationmark")
                        .foregroundStyle(Theme.warning)
                } else if model.movementEnabled, towardSun(at: context.date) {
                    Label("Arrows toward the Sun are disabled (\(Int(SunSafety.keepOutDegrees))° keep-out).", systemImage: "sun.max")
                        .foregroundStyle(Theme.warning)
                } else if model.isAtHome {
                    Label("At the home position.", systemImage: "house")
                        .foregroundStyle(Theme.ok)
                } else if let star = model.arrivedAt {
                    Label("Pointing at \(star).", systemImage: "star")
                        .foregroundStyle(Theme.ok)
                }
            }
            .font(.callout)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func towardSun(at date: Date) -> Bool {
        [(NudgeAxis.azimuth, true), (.azimuth, false), (.altitude, true), (.altitude, false)].contains { axis, positive in
            model.isEnabled(axis) && model.sunProblem(axis, by: (positive ? 1 : -1) * axis.maxStepDegrees, at: date) != nil
        }
    }

    private func direction(_ axis: NudgeAxis, _ positive: Bool) -> String {
        switch (axis, positive) {
        case (.azimuth, true): "right"
        case (.azimuth, false): "left"
        case (.altitude, true): "up"
        case (.altitude, false): "down"
        }
    }
}

private struct NudgeButtons: View {
    @Environment(MonitorModel.self) private var model
    let axis: NudgeAxis
    let negative: (title: String, icon: String)
    let positive: (title: String, icon: String)

    var body: some View {
        HStack {
            Button(negative.title, systemImage: negative.icon) { model.nudge(axis, direction: -1) }
                .disabled(blocked(-1))
            Spacer()
            Button(positive.title, systemImage: positive.icon) { model.nudge(axis, direction: 1) }
                .disabled(blocked(1))
        }
        .disabled(!model.isEnabled(axis) || model.nudgeInFlight || model.activeMove != nil || model.status?.slewing == true)
    }

    private func blocked(_ direction: Double) -> Bool {
        model.sunProblem(axis, by: direction * (axis == .azimuth ? model.azimuthStep : model.altitudeStep)) != nil
    }
}

struct SkyDomeCard: View {
    @Environment(LocationModel.self) private var location
    let status: MountStatus?

    /// Keep-out radius drawn around the Sun: the same one moves are held to.
    private static let sunWarningDegrees = SunSafety.keepOutDegrees

    var body: some View {
        Card(title: "Sky", systemImage: "circle.dashed") {
            TimelineView(.periodic(from: .now, by: 10)) { context in
                // The Sun where it is now, even when the last pointing reading is old (e.g. after disconnecting).
                let sun = location.observer.map { SunSituation(observer: $0, date: context.date) }
                VStack(spacing: 8) {
                    Canvas { canvas, size in draw(in: &canvas, size: size, sun: sun) }
                        .frame(height: 260)
                    legend(sun: sun)
                }
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, sun: SunSituation?) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 20
        let dome = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))

        context.fill(dome, with: .radialGradient(Gradient(colors: [Color.white.opacity(0.035), Color.black.opacity(0.3)]),
                                                center: center, startRadius: 0, endRadius: radius))

        // Altitude rings and azimuth spokes.
        for altitude in [30.0, 60] {
            let r = radius * (90 - altitude) / 90
            let ring = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            context.stroke(ring, with: .color(Theme.accent.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            context.draw(Text("\(Int(altitude))°").font(Theme.numeric(9)).foregroundStyle(Theme.textTertiary),
                         at: CGPoint(x: center.x + 3, y: center.y - r - 7), anchor: .leading)
        }
        for azimuth in stride(from: 0.0, to: 360, by: 30) {
            var spoke = Path()
            spoke.move(to: center)
            spoke.addLine(to: position(azimuth: azimuth, altitude: 0, center: center, radius: radius))
            context.stroke(spoke, with: .color(Theme.accent.opacity(0.08)), lineWidth: 1)
        }
        for azimuth in stride(from: 0.0, to: 360, by: 10) {
            var tick = Path()
            tick.move(to: position(azimuth: azimuth, altitude: 0, center: center, radius: radius))
            tick.addLine(to: position(azimuth: azimuth, altitude: azimuth.truncatingRemainder(dividingBy: 30) == 0 ? 6 : 3, center: center, radius: radius))
            context.stroke(tick, with: .color(Theme.accent.opacity(0.5)), lineWidth: 1)
        }
        context.stroke(dome, with: .color(Theme.accent.opacity(0.55)), lineWidth: 1.5)

        // Looking up at the sky: north at the top, east on the left.
        for (label, azimuth) in [("N", 0.0), ("E", 90), ("S", 180), ("W", 270)] {
            let point = position(azimuth: azimuth, altitude: -11, center: center, radius: radius)
            context.draw(Text(label).font(Theme.display(15))
                .foregroundStyle(label == "N" ? Theme.accent : Theme.textSecondary), at: point)
        }

        if let sun, sun.position.altitude > -Self.sunWarningDegrees {
            let point = position(azimuth: sun.position.azimuth, altitude: max(sun.position.altitude, 0), center: center, radius: radius)
            let zone = radius * Self.sunWarningDegrees / 90
            var clipped = context
            clipped.clip(to: dome)
            let keepOut = Path(ellipseIn: CGRect(x: point.x - zone, y: point.y - zone, width: 2 * zone, height: 2 * zone))
            clipped.fill(keepOut, with: .color(Theme.danger.opacity(0.10)))
            clipped.stroke(keepOut, with: .color(Theme.danger.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if sun.position.altitude > 0 {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: Theme.warning, radius: 8))
                    layer.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)), with: .color(Theme.warning))
                }
            }
        }

        if let h = status?.horizontal {
            let point = position(azimuth: h.azimuth, altitude: max(h.altitude, 0), center: center, radius: radius)
            let color = h.altitude < 0 ? Theme.textTertiary : status?.slewing == true ? Theme.warning : Theme.accent
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: color, radius: 6))
                layer.stroke(Path(ellipseIn: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)), with: .color(color), lineWidth: 1.5)
                var cross = Path()
                for (dx, dy) in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1)] {
                    cross.move(to: CGPoint(x: point.x + dx * 6, y: point.y + dy * 6))
                    cross.addLine(to: CGPoint(x: point.x + dx * 15, y: point.y + dy * 15))
                }
                layer.stroke(cross, with: .color(color), lineWidth: 1.5)
                layer.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(color))
            }
        }
    }

    @ViewBuilder private func legend(sun: SunSituation?) -> some View {
        HStack(spacing: 14) {
            Label("Telescope", systemImage: "scope").foregroundStyle(Theme.accent)
            if let sun {
                Label(sun.position.altitude > 0 ? "Sun · \(Int(Self.sunWarningDegrees))° keep-out" : "Sun below horizon",
                      systemImage: sun.position.altitude > 0 ? "sun.max.fill" : "moon.stars")
                    .foregroundStyle(sun.position.altitude > 0 ? Theme.warning : Theme.textSecondary)
            } else {
                Label("Set location to show the Sun", systemImage: "location.slash").foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }

    private func position(azimuth: Double, altitude: Double, center: CGPoint, radius: Double) -> CGPoint {
        let r = radius * (90 - altitude) / 90
        let angle = azimuth * .pi / 180
        return CGPoint(x: center.x - r * sin(angle), y: center.y - r * cos(angle))
    }
}

struct TrafficLogView: View {
    @Environment(MonitorModel.self) private var model
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Image(systemName: "terminal")
                            .foregroundStyle(Theme.accent)
                        Text("TRAFFIC LOG")
                            .tracking(2)
                        Text("\(model.log.count)")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if expanded {
                    HStack(spacing: 6) {
                        Button("Copy") { copyLog() }
                            .help("Copy the whole log as text")
                        #if os(macOS)
                        Button("Save…") { saveLog() }
                            .help("Save the whole log as a text file")
                        if let file = model.logFileURL {
                            Button {
                                Platform.revealInFinder(file)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .help("Everything since launch is also kept in \(file.path)")
                        }
                        #else
                        // Everything since launch, from the file (also in the Files app, scopeOS › Logs).
                        if let file = model.logFileURL {
                            ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                        }
                        #endif
                        Button("Clear") { model.clearLog() }
                    }
                    .controlSize(.small)
                    .disabled(model.log.isEmpty && model.logFileURL == nil)
                }
            }
            if expanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(model.log.reversed()) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Text(entry.date.formatted(date: .omitted, time: .standard))
                                    .foregroundStyle(Theme.textTertiary)
                                Text(symbol(entry.direction)).foregroundStyle(color(entry.direction))
                                Text(entry.text)
                                    .foregroundStyle(entry.direction == .note ? Theme.textSecondary : Theme.textPrimary)
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 11, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(height: 200)
                .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(14)
        .panel()
    }

    private func symbol(_ direction: TrafficEntry.Direction) -> String {
        switch direction {
        case .sent: "→"
        case .received: "←"
        case .note: "·"
        }
    }

    private func copyLog() {
        Platform.copy(model.logText)
    }

    #if os(macOS)
    private func saveLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "scopeOS log \(TrafficLogFile.fileFormatter.string(from: .now)).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.logText.write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

    private func color(_ direction: TrafficEntry.Direction) -> Color {
        switch direction {
        case .sent: Theme.accent
        case .received: Theme.ok
        case .note: Theme.textTertiary
        }
    }
}
