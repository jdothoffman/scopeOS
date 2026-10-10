import Foundation
import ScopeKit

/// What the simulated telescope sees: where it points (in the real sky), from where, when, and how far the focus motor
/// is from focus.
public struct SimulatedView: Sendable {
    public var pointing: Horizontal
    public var observer: Observer
    public var date: Date
    /// Focus motor steps from best focus.
    public var focusOffset: Int

    public init(pointing: Horizontal, observer: Observer, date: Date, focusOffset: Int) {
        self.pointing = pointing
        self.observer = observer
        self.date = date
        self.focusOffset = focusOffset
    }
}

/// A pretend planetary camera on the simulated telescope, for trying the Camera tab, the focus aid and recording
/// without hardware. It shows what the telescope points at, at the 6SE's focal length: catalog stars, the Moon and
/// the planets, blurred by the simulated focus motor's distance from focus and by seeing, with sensor noise and a
/// bright sky by day. Its exposure and gain behave like a real camera's USB controls.
public final class SimulatedCamera: CameraControlling, @unchecked Sendable {
    public static let id = "scopeOS.simulated-camera"
    public static let camera = CaptureCamera(id: id, name: "Simulated camera", isBuiltIn: false)
    /// The whole field at two resolutions, like a camera that bins rather than crops.
    public static let formats = [
        CaptureFormat(id: "SIM-640x480-30", code: "SIM", width: 640, height: 480, maxFrameRate: 30),
        CaptureFormat(id: "SIM-1280x960-15", code: "SIM", width: 1280, height: 960, maxFrameRate: 15),
    ]

    private static let ranges: [UVCControl: UVCRange] = [
        // UVC's auto-exposure bitmap: 1 manual, 8 aperture priority (auto).
        .autoExposure: UVCRange(minimum: 0, maximum: 0x09, step: 1, defaultValue: 0x08),
        // Units of 100 µs, as UVC: 0.1 ms to 1 s.
        .exposureTime: UVCRange(minimum: 1, maximum: 10_000, step: 1, defaultValue: 100),
        .gain: UVCRange(minimum: 0, maximum: 100, step: 1, defaultValue: 30),
    ]

    private let view: @Sendable () -> SimulatedView?
    private let lock = NSLock()
    private var values: [UVCControl: Int] = ranges.mapValues(\.defaultValue)
    /// Only used from the capture engine's video queue.
    private let renderer = SimulatedSkyRenderer()

    /// `view` is asked for every frame; nil (no location yet) shows an empty, noisy frame.
    public init(view: @escaping @Sendable () -> SimulatedView?) {
        self.view = view
        SimulatedSkyRenderer.prepareMoon()
    }

    public func range(_ control: UVCControl) -> UVCRange? { Self.ranges[control] }

    public func value(_ control: UVCControl) -> Int? {
        lock.withLock { values[control] }
    }

    @discardableResult
    public func set(_ control: UVCControl, _ value: Int) -> Bool {
        guard let range = Self.ranges[control] else { return false }
        lock.withLock { values[control] = control == .autoExposure ? value : min(range.maximum, max(range.minimum, value)) }
        return true
    }

    /// Draws the next frame into a 32-bit BGRA buffer. Called on the capture engine's video queue only.
    func render(into base: UnsafeMutableRawPointer, width: Int, height: Int, rowBytes: Int) {
        let settings = lock.withLock { values }
        let auto = settings[.autoExposure].map { $0 != UVCCamera.manualExposureMode } ?? true
        let exposure = renderer.render(view: view(), into: base, width: width, height: height, rowBytes: rowBytes,
                                       exposureUnits: settings[.exposureTime] ?? 100, gain: settings[.gain] ?? 30, autoExposure: auto)
        // In auto, the camera picks the exposure; reading it back shows what it chose.
        if auto { lock.withLock { values[.exposureTime] = exposure } }
    }
}
