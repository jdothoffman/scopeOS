import AppKit
import SwiftUI

@main
struct ScopeOSApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var location: LocationModel
    @State private var model: MonitorModel
    @State private var camera: CameraModel
    @State private var assistant = Assistant()
    @State private var tonight = TonightModel()

    init() {
        let location = LocationModel()
        let model = MonitorModel(location: location)
        _location = State(initialValue: location)
        _model = State(initialValue: model)
        _camera = State(initialValue: CameraModel(monitor: model, location: location))
    }

    var body: some Scene {
        Window("scopeOS", id: "main") {
            ContentView()
                .environment(model)
                .environment(location)
                .environment(camera)
                .environment(assistant)
                .environment(tonight)
                .preferredColorScheme(.dark)
                .onAppear { appDelegate.attach(monitor: model, camera: camera) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(before: .toolbar) {
                Toggle("Night Vision", isOn: Bindable(Appearance.shared).nightVision)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Camera") {
                // A menu command, so ⌘R works from any tab.
                Button(camera.stats.recording ? "Stop Recording" : "Start Recording") { camera.toggleRecording() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!camera.running)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The longest quitting waits for a held move's stop to go out and a recording to be finished.
    static let quitTimeLimit: Duration = .seconds(2)

    private weak var monitor: MonitorModel?
    private weak var camera: CameraModel?

    func attach(monitor: MonitorModel, camera: CameraModel) {
        self.monitor = monitor
        self.camera = camera
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting (⌘Q or closing the window) stops a held arrow or focus button, as letting go would, and finishes a
    /// recording so its SER file gets its timestamp trailer and the notes file is written.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let monitor, let camera else { return .terminateNow }
        Task {
            await Self.wait(atMost: Self.quitTimeLimit) {
                async let released: Void = monitor.releaseControls()
                async let finished: Void = camera.finishRecording()
                _ = await (released, finished)
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Runs `operation`, returning when it finishes or after `limit`, whichever comes first.
    private static func wait(atMost limit: Duration, for operation: @escaping @MainActor () async -> Void) async {
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await operation()
                once.run { continuation.resume() }
            }
            Task {
                try? await Task.sleep(for: limit)
                once.run { continuation.resume() }
            }
        }
    }
}

@MainActor
private final class Once {
    private var done = false

    func run(_ action: () -> Void) {
        guard !done else { return }
        done = true
        action()
    }
}
