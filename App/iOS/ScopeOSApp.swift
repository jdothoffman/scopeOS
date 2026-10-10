import SwiftUI
import UIKit

@main
struct ScopeOSApp: App {
    @State private var location: LocationModel
    @State private var model: MonitorModel
    @State private var camera: CameraModel
    @State private var assistant = Assistant()
    @State private var tonight = TonightModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let location = LocationModel()
        let model = MonitorModel(location: location)
        _location = State(initialValue: location)
        _model = State(initialValue: model)
        _camera = State(initialValue: CameraModel(monitor: model, location: location))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(location)
                .environment(camera)
                .environment(assistant)
                .environment(tonight)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background: stopAndPause()
                    case .active: model.resume()
                    default: break // inactive: held arrows and focus buttons stop by themselves (`Platform.resignActive`)
                    }
                }
                // The screen mustn't lock while connected: that would suspend the app in the middle of a move.
                .onChange(of: model.isRunning, initial: true) { _, running in
                    UIApplication.shared.isIdleTimerDisabled = running
                }
                #if DEBUG
                // For trying layouts in the iOS Simulator, where nothing can be tapped from a script:
                // `xcrun simctl launch booted com.jdot.ScopeOS -connect YES -startSimulator YES` connects with the
                // saved settings, then starts the simulated mount (the connection retries until it's up).
                .task {
                    if UserDefaults.standard.bool(forKey: "connect") { model.connect() }
                    if UserDefaults.standard.bool(forKey: "startSimulator") { model.startSimulator() }
                }
                #endif
        }
        .commands {
            // An iPad with a keyboard gets the same shortcuts as the Mac.
            CommandGroup(before: .toolbar) {
                Toggle("Night Vision", isOn: Bindable(Appearance.shared).nightVision)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }

    /// iOS suspends the app soon after it leaves the screen. Asks for time to stop everything moving, close the
    /// connection and finish a recording first (`MonitorModel.pause()`, `CameraModel.finishRecording()`); it comes
    /// back on `resume()`. If iOS runs out of patience first, the mount still stops at the end of the current step.
    private func stopAndPause() {
        let background = BackgroundTask(name: "Stop and pause")
        Task {
            async let paused: Void = model.pause()
            async let finished: Void = camera.finishRecording()
            _ = await (paused, finished)
            background.end()
        }
    }
}

/// A `UIApplication` background task, ended exactly once: when the work is done or when time runs out.
@MainActor
private final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
