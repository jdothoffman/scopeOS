@preconcurrency import AVFoundation
import Foundation
import Observation
import ScopeCapture
import ScopeKit

/// The telescope camera: choice of camera and mode, live preview, and SER recordings with a notes file beside each.
@MainActor
@Observable
final class CameraModel {
    static let recordLimits = [0, 30, 60, 90, 120, 180] // seconds; 0 = until stopped
    static let defaultTelescope = "Celestron NexStar 6SE (150 mm, f/10)"
    static let defaultFocalLength = 1500
    static let defaultRecordingFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("scopeOS", isDirectory: true)

    private(set) var cameras: [CaptureCamera] = []
    var selectedCameraID: String? {
        didSet {
            guard selectedCameraID != oldValue else { return }
            defaults.set(selectedCameraID, forKey: "cameraID")
            loadFormats()
            loadControls()
            restartIfRunning()
        }
    }
    private(set) var formats: [CaptureFormat] = []
    var selectedFormatID: String? {
        didSet {
            guard selectedFormatID != oldValue else { return }
            defaults.set(selectedFormatID, forKey: "cameraFormat")
            restartIfRunning()
        }
    }
    var targetName: String { didSet { defaults.set(targetName, forKey: "cameraTarget") } }
    var recordLimit: Int { didSet { defaults.set(recordLimit, forKey: "cameraRecordLimit") } }
    var showCrosshair = true

    /// Equipment and observer, written into each SER file's header and the notes file beside it (Setup › Recordings).
    var telescopeName: String { didSet { defaults.set(telescopeName, forKey: "telescopeName") } }
    /// Effective focal length in mm, after any reducer or Barlow; 0 leaves it out of the notes.
    var focalLength: Int { didSet { defaults.set(focalLength, forKey: "focalLength") } }
    var observerName: String { didSet { defaults.set(observerName, forKey: "observerName") } }
    /// Where recordings go, or nil for `defaultRecordingFolder`.
    var customRecordingFolder: URL? {
        didSet {
            defaults.set(customRecordingFolder?.path, forKey: "recordingFolder")
            refreshFreeSpace()
        }
    }

    private(set) var running = false
    private(set) var starting = false
    private(set) var stats = CaptureStats()
    private(set) var problem: String?
    private(set) var lastRecording: RecordingResult?
    /// Free space on the recording disk, refreshed every few seconds and before each recording.
    private(set) var freeBytes: Int64?

    /// The camera's adjustable controls and their current values (empty if the camera doesn't offer them).
    private(set) var controls: [UVCControl: UVCRange] = [:]
    private(set) var controlValues: [UVCControl: Int] = [:]

    let engine = CaptureEngine()

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let monitor: MonitorModel
    @ObservationIgnored private let location: LocationModel
    @ObservationIgnored private var pendingNotes: String?
    @ObservationIgnored private var frameWatch: Task<Void, Never>?
    @ObservationIgnored private var disconnectObserver: NSObjectProtocol?
    @ObservationIgnored private var uvc: UVCCamera?
    @ObservationIgnored private var pendingControls: [UVCControl: Int] = [:]
    @ObservationIgnored private var applyingControls = false
    @ObservationIgnored private var recordingWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var spaceChecked = Date.distantPast
    @ObservationIgnored private var stoppingForSpace = false

    var recordingFolder: URL { customRecordingFolder ?? Self.defaultRecordingFolder }

    var selectedFormat: CaptureFormat? { formats.first { $0.id == selectedFormatID } }

    init(monitor: MonitorModel, location: LocationModel) {
        self.monitor = monitor
        self.location = location
        targetName = defaults.string(forKey: "cameraTarget") ?? "Jupiter"
        recordLimit = defaults.object(forKey: "cameraRecordLimit") as? Int ?? 90
        telescopeName = defaults.string(forKey: "telescopeName") ?? Self.defaultTelescope
        focalLength = defaults.object(forKey: "focalLength") as? Int ?? Self.defaultFocalLength
        observerName = defaults.string(forKey: "observerName") ?? ""
        customRecordingFolder = defaults.string(forKey: "recordingFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }

        engine.onStats = { [weak self] stats in
            self?.stats = stats
            self?.recordSharpness(stats)
            self?.watchSpace(stats)
        }
        engine.onRecordingFinished = { [weak self] result in self?.recordingFinished(result) }
        disconnectObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.object as? AVCaptureDevice)?.uniqueID
            MainActor.assumeIsolated { self?.cameraDisconnected(id) }
        }
        refreshCameras() // choosing the camera loads its controls
        refreshFreeSpace()
    }

    func refreshCameras() {
        cameras = CaptureEngine.cameras()
        let saved = defaults.string(forKey: "cameraID")
        if selectedCameraID == nil || !cameras.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = cameras.first(where: { $0.id == saved })?.id ?? cameras.first(where: { !$0.isBuiltIn })?.id ?? cameras.first?.id
        }
        loadFormats()
    }

    private func loadFormats() {
        formats = selectedCameraID.map(CaptureEngine.formats) ?? []
        if !formats.contains(where: { $0.id == selectedFormatID }) {
            let saved = defaults.string(forKey: "cameraFormat")
            // Full-color YUVS at 640×480 suits planets and fits within USB 2.
            selectedFormatID = formats.first(where: { $0.id == saved })?.id
                ?? formats.first(where: { $0.code == "YUVS" && $0.width == 640 })?.id
                ?? formats.first?.id
        }
    }

    func startPreview() {
        guard !running, !starting else { return }
        resetFocusAid()
        starting = true
        problem = nil
        Task {
            defer { starting = false }
            guard await CaptureEngine.requestAccess() else {
                problem = "scopeOS isn't allowed to use the camera. Turn it on in System Settings › Privacy & Security › Camera."
                return
            }
            guard let camera = selectedCameraID, let format = selectedFormatID else {
                problem = "No camera found. Connect it (through a USB 2 hub) and click Refresh."
                return
            }
            do {
                try await engine.start(cameraID: camera, formatID: format)
                running = true
                watchForFrames()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    func stopPreview() {
        frameWatch?.cancel()
        engine.stop()
        running = false
        stats = CaptureStats()
    }

    private func restartIfRunning() {
        guard running, !stats.recording else { return }
        running = false
        startPreview()
    }

    /// Webcam-style cameras on Apple Silicon Macs often stream nothing over USB 3; say so instead of showing black.
    private func watchForFrames() {
        frameWatch?.cancel()
        frameWatch = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, running else { return }
            if stats.lastFrame.map({ Date.now.timeIntervalSince($0) > 3 }) ?? true {
                problem = "No picture from the camera. On Apple Silicon Macs, webcam-style cameras like the SV205 need a USB 2 connection: plug the camera in through a USB 2 hub."
            }
        }
    }

    // MARK: Focus aid

    struct SharpnessSample: Sendable {
        let date: Date
        let value: Double
        /// Where the focus motor was at the time, if there is one.
        let focuserPosition: Int?
    }

    /// The last 30 seconds of sharpness readings, and the best since the last reset.
    private(set) var sharpnessHistory: [SharpnessSample] = []
    private(set) var bestSharpness: SharpnessSample?
    nonisolated static let sharpnessWindow: TimeInterval = 30

    func resetFocusAid() {
        sharpnessHistory = []
        bestSharpness = nil
    }

    private func recordSharpness(_ stats: CaptureStats) {
        guard running, let value = stats.sharpness else { return }
        let sample = SharpnessSample(date: .now, value: value, focuserPosition: monitor.status?.focuserPosition)
        sharpnessHistory.append(sample)
        sharpnessHistory.removeAll { sample.date.timeIntervalSince($0.date) > Self.sharpnessWindow }
        if bestSharpness.map({ value > $0.value }) ?? true { bestSharpness = sample }
    }

    // MARK: Camera controls (USB Video Class)

    var autoExposure: Bool { controlValues[.autoExposure].map { $0 != UVCCamera.manualExposureMode } ?? false }
    var autoWhiteBalance: Bool { (controlValues[.autoWhiteBalance] ?? 0) != 0 }

    /// Opens the selected camera's controls over USB and reads their ranges. Runs off the main thread.
    func loadControls() {
        controls = [:]
        controlValues = [:]
        guard let id = selectedCameraID else {
            uvc = nil
            return
        }
        Task {
            let (camera, ranges, values) = await Task.detached { () -> (UVCCamera?, [UVCControl: UVCRange], [UVCControl: Int]) in
                guard let camera = UVCCamera(captureDeviceID: id) else { return (nil, [:], [:]) }
                var ranges: [UVCControl: UVCRange] = [:], values: [UVCControl: Int] = [:]
                for control in UVCControl.allCases {
                    if let range = camera.range(control), let value = camera.value(control) {
                        ranges[control] = range
                        values[control] = value
                    }
                }
                return (camera, ranges, values)
            }.value
            guard id == selectedCameraID else { return }
            uvc = camera
            controls = ranges
            controlValues = values
        }
    }

    /// Updates the slider at once; the camera is told in the background, keeping only the latest value per control.
    func setControl(_ control: UVCControl, _ value: Int) {
        guard let range = controls[control] else { return }
        let clamped = control == .autoExposure ? value : min(range.maximum, max(range.minimum, value))
        controlValues[control] = clamped
        pendingControls[control] = clamped
        applyPendingControls()
    }

    func setAutoExposure(_ on: Bool) {
        let supported = controls[.autoExposure]?.maximum ?? 0x09
        setControl(.autoExposure, on ? UVCCamera.autoExposureMode(supported: supported) : UVCCamera.manualExposureMode)
        refreshControlValues(after: .milliseconds(400)) // the camera picks its own exposure in auto
    }

    func setAutoWhiteBalance(_ on: Bool) {
        setControl(.autoWhiteBalance, on ? 1 : 0)
        refreshControlValues(after: .milliseconds(400))
    }

    /// Puts every control back to the camera's own default (exposure and white balance back on auto).
    func resetControls() {
        for (control, range) in controls { setControl(control, range.defaultValue) }
        refreshControlValues(after: .milliseconds(500))
    }

    private func applyPendingControls() {
        guard !applyingControls, let uvc, let (control, value) = pendingControls.first else { return }
        pendingControls[control] = nil
        applyingControls = true
        Task {
            let ok = await Task.detached { uvc.set(control, value) }.value
            if !ok { problem = "The camera didn't accept the \(control.label.lowercased()) setting." }
            applyingControls = false
            applyPendingControls()
        }
    }

    private func refreshControlValues(after delay: Duration) {
        guard let uvc else { return }
        let wanted = Array(controls.keys)
        Task {
            try? await Task.sleep(for: delay)
            let values = await Task.detached { () -> [UVCControl: Int] in
                var values: [UVCControl: Int] = [:]
                for control in wanted { values[control] = uvc.value(control) }
                return values
            }.value
            for (control, value) in values where pendingControls[control] == nil { controlValues[control] = value }
        }
    }

    // MARK: Recording

    func toggleRecording() {
        stats.recording ? engine.stopRecording() : startRecording()
    }

    /// Ends the recording in progress, if any, and returns once its SER file is finished and its notes are written.
    func finishRecording() async {
        guard stats.recording else { return }
        await withCheckedContinuation { continuation in
            recordingWaiters.append(continuation)
            engine.stopRecording()
        }
    }

    // MARK: Disk space

    /// Space recordings leave free: they refuse to start, and stop, rather than use it.
    static let spaceMargin: Int64 = 2_000_000_000

    /// Bytes a second of recording takes in the chosen mode at its full frame rate: frames are stored as 8-bit
    /// RGB, plus an 8-byte timestamp each.
    var bytesPerSecond: Double? {
        guard let format = selectedFormat, format.maxFrameRate > 0 else { return nil }
        return Double(format.width * format.height * 3 + 8) * format.maxFrameRate
    }

    /// Roughly how many minutes of recording fit in the chosen mode, leaving `spaceMargin` free.
    var minutesOfSpace: Double? {
        guard let freeBytes, let bytesPerSecond else { return nil }
        return max(0, Double(freeBytes - Self.spaceMargin)) / bytesPerSecond / 60
    }

    func refreshFreeSpace() {
        spaceChecked = .now
        var url = recordingFolder
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        freeBytes = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// Why a recording of the chosen length won't fit, or nil. "Until stopped" needs room for at least a minute.
    private func spaceProblem() -> String? {
        refreshFreeSpace()
        guard let freeBytes, let bytesPerSecond else { return nil }
        let seconds = recordLimit > 0 ? recordLimit : 60
        let needed = Int64(bytesPerSecond * Double(seconds))
        guard freeBytes - Self.spaceMargin < needed else { return nil }
        let size = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return "Not enough disk space: \(recordLimit > 0 ? "this recording" : "a minute of recording") needs about \(size(needed)) in this mode, and \(size(Self.spaceMargin)) is kept free, but only \(size(freeBytes)) is free. Choose a shorter length or a smaller mode, or free some space."
    }

    /// While recording, checks free space every few seconds and stops cleanly before the disk fills.
    private func watchSpace(_ stats: CaptureStats) {
        guard Date.now.timeIntervalSince(spaceChecked) > (stats.recording ? 3 : 30) else { return }
        refreshFreeSpace()
        guard stats.recording, !stoppingForSpace, let freeBytes, freeBytes < Self.spaceMargin else { return }
        stoppingForSpace = true
        engine.stopRecording()
        problem = "Recording stopped: the disk is nearly full (less than \(ByteCountFormatter.string(fromByteCount: Self.spaceMargin, countStyle: .file)) free)."
    }

    private func startRecording() {
        guard running, let camera = cameras.first(where: { $0.id == selectedCameraID }) else { return }
        if let spaceProblem = spaceProblem() {
            problem = spaceProblem
            return
        }
        stoppingForSpace = false
        let now = Date.now
        let folder = recordingFolder.appendingPathComponent(Self.dayFormatter.string(from: now), isDirectory: true)
        let url = folder.appendingPathComponent("\(Self.safeName(targetName))_\(Self.fileTimeFormatter.string(from: now))UTC.ser")
        do {
            try engine.startRecording(to: url,
                                      metadata: .init(observer: observerName, instrument: camera.name, telescope: telescopeName),
                                      limit: recordLimit > 0 ? TimeInterval(recordLimit) : nil)
            pendingNotes = notes(camera: camera, start: now)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func recordingFinished(_ result: Result<RecordingResult, Error>) {
        switch result {
        case .success(let recording):
            lastRecording = recording
            let duration = recording.ended.timeIntervalSince(recording.started)
            let summary = String(format: """
                Ended (UTC):    %@
                Duration:       %.1f s
                Frames:         %d (%.1f fps average), %d dropped
                """, Self.isoFormatter.string(from: recording.ended), duration, recording.frames,
                Double(recording.frames) / max(duration, 0.001), recording.dropped)
            let text = (pendingNotes ?? "") + summary + "\n"
            try? text.write(to: recording.url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        case .failure(let error):
            problem = "Recording stopped: \(error.localizedDescription)"
        }
        pendingNotes = nil
        recordingWaiters.forEach { $0.resume() }
        recordingWaiters.removeAll()
    }

    private func notes(camera: CaptureCamera, start: Date) -> String {
        var lines = [
            "scopeOS capture",
            "Target:         \(targetName)",
            "Started (UTC):  \(Self.isoFormatter.string(from: start))",
            "Camera:         \(camera.name), \(selectedFormat?.label ?? "?")",
            "Telescope:      \(telescopeName)",
        ]
        if focalLength > 0 { lines.append("Focal length:   \(focalLength) mm") }
        if !observerName.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("Observer:       \(observerName)") }
        if let observer = location.observer {
            lines.append("Location:       \(SkyFormat.latitude(observer.latitude)), \(SkyFormat.longitude(observer.longitude))")
        }
        if let equatorial = monitor.status?.equatorial {
            lines.append("Pointing:       RA \(SkyFormat.rightAscension(equatorial.raHours)), Dec \(SkyFormat.declination(equatorial.decDegrees))")
        }
        if let horizontal = monitor.status?.horizontal {
            let kind = monitor.status?.protocolKind == .aux ? " (motor angles)" : ""
            lines.append(String(format: "Az/Alt:         %.2f° / %.2f°%@", horizontal.azimuth, horizontal.altitude, kind))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func cameraDisconnected(_ id: String?) {
        guard id == selectedCameraID else { return }
        if stats.recording { engine.stopRecording() }
        stopPreview()
        problem = "The camera was disconnected."
        refreshCameras()
    }

    private static func safeName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let cleaned = String(text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "Capture" : cleaned
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let fileTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()

    private static let isoFormatter = ISO8601DateFormatter()
}
