import SwiftUI

@main
struct ScopeOSApp: App {
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
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(location)
                .environment(camera)
                .environment(assistant)
                .environment(tonight)
                .preferredColorScheme(.dark)
        }
        .commands {
            // An iPad with a keyboard gets the same shortcuts as the Mac.
            CommandGroup(before: .toolbar) {
                Toggle("Night Vision", isOn: Bindable(Appearance.shared).nightVision)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}
