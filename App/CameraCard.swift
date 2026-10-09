@preconcurrency import AVFoundation
import AppKit
import CoreImage
import ScopeCapture
import ScopeKit
import SwiftUI

struct CameraCard: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        @Bindable var camera = camera
        Card(title: "Camera", systemImage: "camera.aperture") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Picker("Camera", selection: $camera.selectedCameraID) {
                        if camera.cameras.isEmpty { Text("No camera found").tag(String?.none) }
                        ForEach(camera.cameras) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    Picker("Mode", selection: $camera.selectedFormatID) {
                        ForEach(camera.formats) { Text($0.label).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    Button("Refresh", systemImage: "arrow.clockwise") { camera.refreshCameras() }
                        .labelStyle(.iconOnly)
                        .help("Look for cameras again")
                    Spacer()
                    Button(camera.running ? "Stop Preview" : camera.starting ? "Starting…" : "Start Preview",
                           systemImage: camera.running ? "video.slash" : "video") {
                        camera.running ? camera.stopPreview() : camera.startPreview()
                    }
                    .disabled(camera.starting)
                }
                .disabled(camera.stats.recording)

                // Recording right under the camera choice, so Record never needs scrolling to.
                HStack(spacing: 10) {
                    TextField("Target", text: $camera.targetName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .disabled(camera.stats.recording)
                    Picker("Length", selection: $camera.recordLimit) {
                        ForEach(CameraModel.recordLimits, id: \.self) { seconds in
                            Text(seconds == 0 ? "Until stopped" : seconds < 120 ? "\(seconds) s" : "\(seconds / 60) min").tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .disabled(camera.stats.recording)
                    if let minutes = camera.minutesOfSpace {
                        let short = camera.recordLimit > 0 ? minutes * 60 < Double(camera.recordLimit) : minutes < 1
                        Text(minutes < 1 ? "No space left" : minutes < 100 ? String(format: "Space for %.0f min", minutes) : "Space for over 99 min")
                            .font(.caption)
                            .foregroundStyle(short ? Theme.warning : Theme.textTertiary)
                            .help("At this mode's full frame rate, keeping 2 GB free. Recordings that won't fit don't start, and a recording stops if free space drops under 2 GB.")
                    }
                    Toggle("Crosshair", isOn: $camera.showCrosshair)
                        .toggleStyle(.checkbox)
                    Spacer()
                    RecordButton()
                }

                CaptureStatusLine()

                if let problem = camera.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let recording = camera.lastRecording, !camera.stats.recording {
                    HStack {
                        Text("Saved \(recording.url.lastPathComponent): \(recording.frames) frames, \(recording.dropped) dropped")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([recording.url])
                        }
                        .controlSize(.small)
                    }
                }

                preview

                if camera.running || !camera.controls.isEmpty {
                    HStack(alignment: .top, spacing: 18) {
                        ExposureMeter()
                            .frame(width: 230)
                        CameraControls()
                    }
                }

            }
        }
    }

    private var aspectRatio: CGFloat {
        guard let format = camera.selectedFormat, format.height > 0 else { return 4 / 3 }
        return CGFloat(format.width) / CGFloat(format.height)
    }

    private var preview: some View {
        ZStack {
            CameraPreview(session: camera.engine.session, nightVision: Appearance.shared.nightVision)
            if !camera.running {
                VStack(spacing: 8) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Theme.accent.opacity(0.7))
                    Text("Preview off. Start the preview to see the camera.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if camera.showCrosshair {
                Crosshair().allowsHitTesting(false)
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 420)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.25)))
    }
}

/// Brightness histogram with the planetary target band, plus a plain-language verdict.
private struct ExposureMeter: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        let stats = camera.stats
        VStack(alignment: .leading, spacing: 6) {
            Theme.label("Histogram")
            Canvas { context, size in
                // Target band for the brightest part of a planet: 60–75%.
                let band = CGRect(x: size.width * 0.6, y: 0, width: size.width * 0.15, height: size.height)
                context.fill(Path(band), with: .color(Theme.ok.opacity(0.12)))
                context.fill(Path(CGRect(x: size.width * 0.97, y: 0, width: size.width * 0.03, height: size.height)),
                             with: .color(Theme.danger.opacity(0.25)))
                let bins = stats.histogram
                guard !bins.isEmpty else { return }
                let width = size.width / CGFloat(bins.count)
                for (index, value) in bins.enumerated() {
                    // Square root keeps a small bright planet visible next to a large dark sky.
                    let height = size.height * CGFloat(value.squareRoot())
                    let bar = CGRect(x: CGFloat(index) * width, y: size.height - height, width: max(1, width - 1), height: height)
                    context.fill(Path(bar), with: .color(index >= 62 ? Theme.danger : Theme.accent.opacity(0.8)))
                }
            }
            .frame(height: 64)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            if camera.running, !stats.histogram.isEmpty {
                HStack {
                    Text(String(format: "Peak %.0f%%", stats.peakLevel * 100))
                    Spacer()
                    Text(String(format: "%.1f%% over", stats.saturatedFraction * 100))
                        .foregroundStyle(stats.saturatedFraction > 0.005 ? Theme.danger : Theme.textSecondary)
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                let (advice, color) = verdict(stats)
                Text(advice)
                    .font(.caption)
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Start the preview to see the brightness spread.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func verdict(_ stats: CaptureStats) -> (String, Color) {
        if stats.saturatedFraction > 0.005 { return ("Over-exposed: shorten the exposure until the red bars disappear.", Theme.danger) }
        if stats.peakLevel < 0.35 { return ("Dim: lengthen the exposure or raise gamma.", Theme.warning) }
        if stats.peakLevel > 0.85 { return ("Close to over-exposing: shorten the exposure a little.", Theme.warning) }
        if (0.55 ... 0.8).contains(stats.peakLevel) { return ("Good level for planets.", Theme.ok) }
        return ("Usable. Planets look best with the peak around 60–75%.", Theme.textSecondary)
    }
}

/// Exposure, gain, gamma, white balance and friends, read from and written to the camera over USB.
private struct CameraControls: View {
    @Environment(CameraModel.self) private var camera
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if camera.controls.isEmpty {
                Text("This camera doesn't offer manual controls over USB.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                HStack {
                    Theme.label("Camera controls")
                    Spacer()
                    Button("Defaults") { camera.resetControls() }
                        .controlSize(.small)
                        .help("Put every control back to the camera's own defaults")
                }
                if camera.controls[.autoExposure] != nil {
                    Toggle("Auto exposure", isOn: Binding(get: { camera.autoExposure }, set: { camera.setAutoExposure($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if let range = camera.controls[.exposureTime] {
                    // Exposure spans four orders of magnitude, so the slider is logarithmic.
                    let low = Double(max(1, range.minimum)), high = Double(max(range.maximum, range.minimum + 1))
                    let value = Double(camera.controlValues[.exposureTime] ?? range.defaultValue)
                    ControlSlider(title: "Exposure",
                                  position: log(max(value, low) / low) / log(high / low),
                                  display: Self.exposureText(Int(value)),
                                  enabled: !camera.autoExposure) { position in
                        camera.setControl(.exposureTime, Int((low * pow(high / low, position)).rounded()))
                    }
                }
                ForEach([UVCControl.gain, .gamma, .brightness], id: \.self) { control in
                    linearSlider(control)
                }
                if camera.controls[.autoWhiteBalance] != nil {
                    Toggle("Auto white balance", isOn: Binding(get: { camera.autoWhiteBalance }, set: { camera.setAutoWhiteBalance($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                linearSlider(.whiteBalance, suffix: " K", enabled: !camera.autoWhiteBalance)
                DisclosureGroup("More", isExpanded: $showMore) {
                    VStack(spacing: 8) {
                        linearSlider(.contrast)
                        linearSlider(.saturation)
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func linearSlider(_ control: UVCControl, suffix: String = "", enabled: Bool = true) -> some View {
        if let range = camera.controls[control], range.maximum > range.minimum {
            let value = camera.controlValues[control] ?? range.defaultValue
            ControlSlider(title: control.label,
                          position: Double(value - range.minimum) / Double(range.maximum - range.minimum),
                          display: "\(value)\(suffix)",
                          enabled: enabled) { position in
                let raw = Double(range.minimum) + position * Double(range.maximum - range.minimum)
                let stepped = Int((raw / Double(range.step)).rounded()) * range.step
                camera.setControl(control, stepped)
            }
        }
    }

    /// UVC exposure is in units of 100 µs.
    static func exposureText(_ units: Int) -> String {
        let milliseconds = Double(units) / 10
        return milliseconds < 10 ? String(format: "%.1f ms", milliseconds) : milliseconds < 1000
            ? String(format: "%.0f ms", milliseconds) : String(format: "%.2f s", milliseconds / 1000)
    }
}

private struct ControlSlider: View {
    let title: String
    /// Where the camera's current value sits, 0–1.
    let position: Double
    let display: String
    let enabled: Bool
    let onChange: (Double) -> Void

    @State private var value = 0.0
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 92, alignment: .leading)
            Slider(value: $value, in: 0 ... 1) { editing in
                dragging = editing
                // Settle on the camera's own (stepped) value once the drag ends.
                if !editing { value = min(1, max(0, position)) }
            }
                .controlSize(.small)
                .onChange(of: value) { _, newValue in
                    if abs(newValue - position) > 0.0005 { onChange(newValue) }
                }
            Text(display)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 64, alignment: .trailing)
        }
        .disabled(!enabled)
        .onAppear { value = min(1, max(0, position)) }
        .onChange(of: position) { _, newPosition in
            // Follow the camera (auto modes, Defaults, rounding to its step) without echoing it back, but not
            // mid-drag: on a coarse control the camera's rounding would pull the thumb back under the pointer.
            if !dragging, abs(newPosition - value) > 0.0005 { value = min(1, max(0, newPosition)) }
        }
    }
}

/// Equipment, observer and folder for recordings: written into each SER header and its notes file.
struct RecordingSettingsCard: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        @Bindable var camera = camera
        Card(title: "Recordings", systemImage: "film") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Telescope") {
                    TextField("Telescope", text: $camera.telescopeName)
                }
                LabeledContent("Focal length") {
                    HStack(spacing: 4) {
                        TextField("mm", value: $camera.focalLength, format: .number)
                            .frame(width: 70)
                        Text("mm").foregroundStyle(Theme.textTertiary)
                        Spacer()
                    }
                }
                .help("Effective focal length, after any reducer or Barlow (1500 mm for a 6SE on its own, about 945 mm with an f/6.3 reducer)")
                LabeledContent("Observer") {
                    TextField("Your name", text: $camera.observerName)
                }
                LabeledContent("Folder") {
                    HStack(spacing: 6) {
                        Text(camera.recordingFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .help(camera.recordingFolder.path)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                        if camera.customRecordingFolder != nil {
                            Button("Default") { camera.customRecordingFolder = nil }
                        }
                    }
                    .controlSize(.small)
                }
                Text("Written into each recording's SER header and the notes file beside it.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .disabled(camera.stats.recording)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = camera.recordingFolder
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        camera.customRecordingFolder = url
    }
}

private struct RecordButton: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        let recording = camera.stats.recording
        Button {
            camera.toggleRecording()
        } label: {
            Label(recording ? "Stop" : "Record", systemImage: recording ? "stop.fill" : "record.circle")
                .font(.system(size: 12, weight: .bold))
                .tracking(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Theme.danger.opacity(camera.running ? 1 : 0.35), in: Capsule())
                .glow(Theme.danger, radius: recording ? 10 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!camera.running)
        .help("Records an uncompressed SER video to \(camera.recordingFolder.path) (⌘R starts and stops it from any tab)")
    }
}

private struct CaptureStatusLine: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        let stats = camera.stats
        HStack(spacing: 14) {
            if camera.running {
                Text(String(format: "%.1f fps", stats.framesPerSecond))
            }
            if stats.recording, let started = stats.recordingStarted {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let elapsed = Int(context.date.timeIntervalSince(started))
                    HStack(spacing: 14) {
                        Label(String(format: "REC %02d:%02d", elapsed / 60, elapsed % 60), systemImage: "circle.fill")
                            .foregroundStyle(Theme.danger)
                        if camera.recordLimit > 0 { Text("of \(camera.recordLimit) s").foregroundStyle(Theme.textTertiary) }
                    }
                }
                Text("\(stats.framesRecorded) frames")
                Text("\(stats.framesDropped) dropped").foregroundStyle(stats.framesDropped > 0 ? Theme.warning : Theme.textSecondary)
                Text(ByteCountFormatter.string(fromByteCount: stats.bytesWritten, countStyle: .file))
            }
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(Theme.textSecondary)
    }
}

/// Thin centre crosshair with a small ring, for putting a planet in the middle of the frame.
private struct Crosshair: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var lines = Path()
            for (dx, dy) in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1)] {
                lines.move(to: CGPoint(x: center.x + dx * 18, y: center.y + dy * 18))
                lines.addLine(to: CGPoint(x: center.x + dx * size.width, y: center.y + dy * size.height))
            }
            context.stroke(lines, with: .color(Theme.accent.opacity(0.45)), lineWidth: 1)
            let ring = Path(ellipseIn: CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24))
            context.stroke(ring, with: .color(Theme.accent.opacity(0.7)), lineWidth: 1)
        }
    }
}

/// The camera's live picture, drawn by AVFoundation. Night vision runs it through a red filter.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let nightVision: Bool

    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.nightVision = nightVision
    }

    final class PreviewView: NSView {
        private let previewLayer: AVCaptureVideoPreviewLayer

        var nightVision = false {
            didSet {
                guard nightVision != oldValue else { return }
                previewLayer.filters = nightVision ? [Self.redFilter()] : nil
            }
        }

        init(session: AVCaptureSession) {
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            layerUsesCoreImageFilters = true
            layer?.backgroundColor = NSColor.black.cgColor
            previewLayer.videoGravity = .resizeAspect
            layer?.addSublayer(previewLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }

        /// Brightness into the red channel only, slightly dimmed. Kept even though the window's night filter is
        /// multiplied over everything: that isn't guaranteed to reach this AppKit layer, and where it does it leaves
        /// red-only content unchanged (see `Theme.nightFilter`).
        static func redFilter() -> CIFilter {
            let filter = CIFilter(name: "CIColorMatrix")!
            filter.setValue(CIVector(x: 0.24, y: 0.47, z: 0.09, w: 0), forKey: "inputRVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            return filter
        }
    }
}
