import ScopeKit
import SwiftUI

/// The app's tabs. The header (clocks, night vision, link status, STOP, Connect) stays visible on all of them.
enum AppTab: String, CaseIterable, Identifiable {
    case telescope, sky, camera, setup

    var id: Self { self }

    /// The camera needs a Mac for now (an iPad can take a USB camera too: #36).
    static var available: [AppTab] {
        #if os(macOS)
        allCases
        #else
        [.telescope, .sky, .setup]
        #endif
    }

    var title: String {
        switch self {
        case .telescope: "Telescope"
        case .sky: "Sky"
        case .camera: "Camera"
        case .setup: "Setup"
        }
    }

    var systemImage: String {
        switch self {
        case .telescope: "scope"
        case .sky: "sparkles"
        case .camera: "camera.aperture"
        case .setup: "gearshape"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .telescope: "1"
        case .sky: "2"
        case .camera: "3"
        case .setup: "4"
        }
    }
}

struct ContentView: View {
    @Environment(MonitorModel.self) private var model
    @AppStorage("selectedTab") private var tab: AppTab = .telescope

    var body: some View {
        ZStack {
            SpaceBackground()
            VStack(spacing: 0) {
                HeaderBar()
                TabBar(tab: $tab)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let error = model.lastError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(Theme.warning)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.warning.opacity(0.35)))
                        }
                        switch tab {
                        case .telescope: TelescopeTab()
                        case .sky: SkyTab()
                        case .camera: CameraTab()
                        case .setup: SetupTab()
                        }
                    }
                    .padding(20)
                }
                FooterBar()
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
        .colorMultiply(Theme.windowFilter)
        #if os(macOS)
        .frame(minWidth: 1080, minHeight: 720)
        #endif
        .onChange(of: tab) {
            // A held arrow vanishes with its tab before it can see the mouse button come up: stop the move now.
            model.releaseArrow()
            model.releaseFocus()
        }
    }
}

/// Moving and monitoring the mount.
private struct TelescopeTab: View {
    @Environment(MonitorModel.self) private var model

    /// Control gets the whole right column, so the arrows, Stop and Go to never need scrolling to.
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
                PointingCard(status: model.status)
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        StatusCard(status: model.status, pollTime: model.pollTime)
                        FocusCard()
                    }
                    SkyDomeCard(status: model.status)
                        .frame(width: 330)
                }
            }
            ControlCard()
                .frame(width: 330)
        }
    }
}

/// Imaging: the camera, with the mount and focus controls beside it for centring and focusing on the preview.
private struct CameraTab: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            CameraCard()
            VStack(spacing: 16) {
                ControlCard()
                FocusCard()
            }
            .frame(width: 330)
        }
    }
}

/// Start-of-session setup and troubleshooting.
private struct SetupTab: View {
    @Environment(MonitorModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
                ConnectionPanel()
                DevicesCard(status: model.status)
                TrafficLogView()
            }
            VStack(spacing: 16) {
                SiteCard()
                RecordingSettingsCard()
                AssistantCard()
            }
            .frame(width: 330)
        }
    }
}

/// Tabs on the left; what scopeOS is connected to on the right.
private struct TabBar: View {
    @Environment(MonitorModel.self) private var model
    @Binding var tab: AppTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.available) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                        Text(item.title.uppercased())
                            .font(Theme.display(15))
                            .tracking(2)
                            .padding(.top, 3)
                    }
                    .foregroundStyle(tab == item ? Theme.accent : Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(tab == item ? Theme.accent : Color.clear).frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(item.shortcut, modifiers: .command)
                .help("\(item.title) (⌘\(String(item.shortcut.character)))")
            }
            Spacer()
            Text(connectionSummary)
                .font(Theme.numeric(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .background(Color.black.opacity(0.25))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var connectionSummary: String {
        let target = switch model.kind {
        case .wifiModule: "WiFi module · \(model.wifiHost):\(model.wifiPort)"
        case .usbHandController: "USB · \(model.serialPath.isEmpty ? "no port" : model.serialPath)"
        case .networkHandController: "Network · \(model.networkHost):\(model.networkPort)"
        }
        return model.isRunning ? target : "Not connected · \(target) · Setup (⌘3) to change"
    }
}

/// Brand, mission clocks, link status and the primary actions. Sits under the (hidden) title bar.
struct HeaderBar: View {
    @Environment(MonitorModel.self) private var model
    @Environment(LocationModel.self) private var location

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1)
                    Circle().strokeBorder(Theme.hairline, lineWidth: 1).padding(6)
                    Image(systemName: "scope")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 38, height: 38)
                // With the subtitle when it fits, else the name alone.
                ViewThatFits(in: .horizontal) {
                    brand("scopeOS", subtitle: true)
                    brand("scopeOS", subtitle: false)
                }
            }

            Spacer()

            TimelineView(.periodic(from: .now, by: 1)) { context in
                // UTC goes first when the window is narrow; local time and LST matter more at the eyepiece.
                ViewThatFits(in: .horizontal) {
                    clocks(at: context.date, utc: true)
                    clocks(at: context.date, utc: false)
                }
            }

            Spacer()

            Button {
                Appearance.shared.nightVision.toggle()
            } label: {
                Image(systemName: Appearance.shared.nightVision ? "moon.fill" : "moon")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.accent.opacity(Appearance.shared.nightVision ? 0.2 : 0.06), in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.accent.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .help("Night vision: dim red display that keeps your eyes dark-adapted (⇧⌘N)")

            TimelineView(.periodic(from: .now, by: 1)) { context in
                StatusPill(label: phaseLabel(at: context.date), color: phaseColor(at: context.date),
                           pulsing: model.phase == .connected && !model.isLinkStale(at: context.date))
                    .help(linkHelp(at: context.date))
                    .fixedSize()
            }
            if model.phase == .connected {
                Button {
                    model.stopTelescope()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("STOP")
                            .font(Theme.display(17))
                            .tracking(2.4)
                            .padding(.top, 3)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Theme.danger, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.25)).padding(2))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Stops any slew, GoTo or move in progress (shortcut: Esc).")
            }
            Button(model.isRunning ? "Disconnect" : "Connect") {
                model.isRunning ? model.disconnect() : model.connect()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .fixedSize()
        }
        .padding(.leading, 84) // clear of the window's traffic-light buttons
        .padding(.trailing, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
            Color.black.opacity(0.45)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                .ignoresSafeArea()
        )
    }

    private func brand(_ name: String, subtitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(name)
                    .font(Theme.display(26))
                    .tracking(1.2)
                    .padding(.top, 4)
                if BuildMode.isDebug && !subtitle { debugBadge }
            }
            if subtitle {
                HStack(spacing: 6) {
                    Text("CONTROL & CAPTURE FOR CELESTRON NEXSTAR")
                        .font(Theme.display(11))
                        .tracking(2.4)
                        .foregroundStyle(Theme.textSecondary)
                    if BuildMode.isDebug { debugBadge }
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var debugBadge: some View {
        Text("DEBUG")
            .font(Theme.display(10))
            .tracking(1.2)
            .foregroundStyle(Theme.warning)
            .padding(.horizontal, 5)
            .padding(.top, 2)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.warning.opacity(0.6)))
    }

    private func clocks(at date: Date, utc: Bool) -> some View {
        HStack(spacing: 22) {
            if utc { Clock(label: "UTC", value: Self.time(date, zone: TimeZone(identifier: "UTC")!)) }
            Clock(label: "Local", value: Self.time(date, zone: .current))
            Clock(label: "LST", value: location.observer.map {
                SkyFormat.hoursMinutesSeconds(Astronomy.localSiderealHours(at: date, longitude: $0.longitude))
            } ?? "--:--:--")
        }
        .fixedSize()
    }

    private func phaseLabel(at date: Date) -> String {
        switch model.phase {
        case .idle: "Offline"
        case .connecting: model.retryAttempt > 0 ? "Connecting (attempt \(model.retryAttempt + 1))" : "Connecting"
        case .connected:
            if model.isLinkStale(at: date), let age = model.readingAge(at: date) { "No data for \(Int(age)) s" } else { "Link active" }
        case .waitingToRetry:
            if let retryAt = model.retryAt { "Retrying in \(max(0, Int(retryAt.timeIntervalSince(date).rounded(.up)))) s" } else { "Retrying" }
        }
    }

    private func phaseColor(at date: Date) -> Color {
        switch model.phase {
        case .idle: Theme.textTertiary
        case .connecting: Theme.warning
        case .connected: model.isLinkStale(at: date) ? Theme.warning : Theme.ok
        case .waitingToRetry: Theme.warning
        }
    }

    private func linkHelp(at date: Date) -> String {
        guard let age = model.readingAge(at: date) else { return "Connection to the mount" }
        let last = String(format: "Last reading %.0f s ago.", age)
        return model.isLinkStale(at: date)
            ? "\(last) Readings normally arrive every second or two, so the connection may be failing. Keep Stop at hand."
            : last
    }

    private static func time(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}

private struct Clock: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Theme.label(label)
            Text(value)
                .font(Theme.numeric(19))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

struct ConnectionPanel: View {
    @Environment(MonitorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Connection", selection: $model.kind) {
                    ForEach(MonitorModel.Kind.available) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
                .disabled(model.isRunning)

                Group {
                    switch model.kind {
                    case .wifiModule:
                        TextField("Host", text: $model.wifiHost).frame(width: 150)
                        TextField("Port", text: $model.wifiPort).frame(width: 64)
                        if model.finding {
                            Button("Cancel") { model.cancelFind() }
                                .help("Stop searching")
                            ProgressView().controlSize(.small)
                            if let started = model.findStarted {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text("\(Int(context.date.timeIntervalSince(started))) s")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                        } else {
                            Button {
                                model.findTelescope()
                            } label: {
                                Label("Find", systemImage: "magnifyingglass")
                            }
                            .help("Search this network (Wi-Fi and Ethernet) for the telescope's WiFi module")
                        }
                        if model.foundTelescopes.count > 1 {
                            Menu("\(model.foundTelescopes.count) found") {
                                ForEach(model.foundTelescopes, id: \.self) { telescope in
                                    Button(telescope.host) { model.useFoundTelescope(telescope) }
                                }
                            }
                            .fixedSize()
                        }
                    case .networkHandController:
                        TextField("Host", text: $model.networkHost).frame(width: 150)
                        TextField("Port", text: $model.networkPort).frame(width: 64)
                    case .usbHandController:
                        Picker("Port", selection: $model.serialPath) {
                            if model.availablePorts.isEmpty { Text("No serial ports found").tag("") }
                            ForEach(model.availablePorts, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                        Button("Refresh", systemImage: "arrow.clockwise") { model.refreshPorts() }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(model.isRunning)

                Spacer()
                if BuildMode.isDebug {
                Button(model.simulatorState == .off ? "Start Simulator" : "Stop Simulator",
                       systemImage: model.simulatorState == .off ? "play.circle" : "stop.circle") {
                    model.simulatorState == .off ? model.startSimulator() : model.stopSimulator()
                }
                .disabled(model.simulatorState == .starting)
                .help("Runs a pretend mount inside scopeOS on 127.0.0.1 (AUX port \(MonitorModel.simulatorAuxPort), hand controller port \(MonitorModel.simulatorHandControllerPort)).")
                }
            }

            Text(model.kind.help)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if model.kind == .wifiModule, let message = model.findMessage {
                Label(message, systemImage: model.foundTelescopes.isEmpty && !model.finding ? "exclamationmark.circle" : "scope")
                    .font(.caption)
                    .foregroundStyle(model.foundTelescopes.isEmpty && !model.finding ? Theme.warning : Theme.ok)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .panel()
    }
}

struct FooterBar: View {
    @Environment(MonitorModel.self) private var model

    var body: some View {
        HStack {
            Label("Moves only in short steps that end on their own, checked against the Sun. Stop is always available.", systemImage: "lock.shield")
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            if let updated = model.status?.updated {
                Text("Last telemetry \(updated.formatted(date: .omitted, time: .standard))")
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.35))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
