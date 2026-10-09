import AppKit
import SwiftUI
import Testing

/// Renders each tab to a PNG, for checking the layout by eye. Off unless asked for:
///   TEST_RUNNER_SCOPEOS_SNAPSHOTS=/some/folder xcodebuild test -scheme ScopeOS
@MainActor
@Suite("Snapshots", .serialized)
struct SnapshotTests {
    nonisolated static let folder = ProcessInfo.processInfo.environment["SCOPEOS_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil))
    func renderEveryTab() async throws {
        let folder = URL(fileURLWithPath: try #require(Self.folder), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rig = try await MonitorModelTests.Rig()
        defer { rig.tearDown() }
        let camera = CameraModel(monitor: rig.model, location: rig.location)
        let assistant = Assistant(defaults: rig.defaults)
        let tonight = TonightModel()
        rig.model.movementEnabled = true
        rig.model.verticalEnabled = true
        _ = try await rig.freshStatus()

        for size in [CGSize(width: 1080, height: 720), CGSize(width: 1440, height: 900)] {
            for tab in AppTab.allCases {
                UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab")
                let view = ContentView()
                    .environment(rig.model)
                    .environment(rig.location)
                    .environment(camera)
                    .environment(assistant)
                    .environment(tonight)
                    .preferredColorScheme(.dark)
                let host = NSHostingView(rootView: view)
                host.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                window.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(800))
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let name = "\(tab.rawValue)-\(Int(size.width))x\(Int(size.height)).png"
                try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
                window.orderOut(nil)
            }
        }
    }
}
