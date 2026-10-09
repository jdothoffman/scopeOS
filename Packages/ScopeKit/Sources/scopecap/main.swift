import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import ScopeCapture
import ScopeKit

// Camera test tool.
// Usage:
//   swift run scopecap list
//   swift run scopecap record [seconds] [format-id] [out.ser]   (also writes out.png from the first frame)
//   swift run scopecap controls                                 (reads the camera's exposure, gain... and tests a write)

setvbuf(stdout, nil, _IOLBF, 0)

let args = Array(CommandLine.arguments.dropFirst())
let cameras = CaptureEngine.cameras()
guard let camera = cameras.first(where: { !$0.isBuiltIn }) ?? cameras.first else {
    print("No camera found.")
    exit(1)
}

switch args.first ?? "list" {
case "list":
    for item in cameras {
        print("\(item.name)\(item.isBuiltIn ? " (built in)" : "")")
        for format in CaptureEngine.formats(for: item.id) { print("  \(format.id)   \(format.label)") }
    }

case "record":
    let seconds = args.count > 1 ? Double(args[1]) ?? 3 : 3
    let formats = CaptureEngine.formats(for: camera.id)
    guard let format = args.count > 2 ? formats.first(where: { $0.id == args[2] }) : formats.first(where: { $0.code == "YUVS" && $0.width == 640 }) ?? formats.first else {
        print("Unknown format. Run `scopecap list`.")
        exit(1)
    }
    let out = URL(fileURLWithPath: args.count > 3 ? args[3] : "capture.ser")
    if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
        print("Asking macOS for camera access. From a terminal the permission prompt may not appear; if nothing happens, allow your terminal app in System Settings › Privacy & Security › Camera, then run this again.")
    }
    switch await cameraAccess(timeout: .seconds(15)) {
    case true?:
        break
    case false?:
        print("Camera access was denied. Allow your terminal app in System Settings › Privacy & Security › Camera.")
        exit(1)
    case nil:
        print("No answer to the camera permission request after 15 s. Allow your terminal app in System Settings › Privacy & Security › Camera (or grant scopeOS.app access and record from the app), then run this again.")
        exit(1)
    }

    let engine = CaptureEngine()
    let done = AsyncStream<Result<RecordingResult, Error>>.makeStream()
    engine.onStats = { stats in
        if stats.recording {
            print(String(format: "  %.1f fps, %d frames, %d dropped", stats.framesPerSecond, stats.framesRecorded, stats.framesDropped))
        }
    }
    engine.onRecordingFinished = { done.continuation.yield($0) }

    print("Starting \(camera.name) at \(format.label)…")
    try await engine.start(cameraID: camera.id, formatID: format.id)
    var waited = 0.0
    while (try? engine.startRecording(to: out, metadata: .init(instrument: camera.name, telescope: "scopecap test"), limit: seconds)) == nil {
        try await Task.sleep(for: .milliseconds(100))
        waited += 0.1
        if waited > 5 {
            print("No frames after 5 s. On Apple Silicon Macs, connect webcam-style cameras through a USB 2 hub.")
            exit(1)
        }
    }
    print("Recording \(seconds) s to \(out.path)…")
    for await result in done.stream {
        engine.stop()
        switch result {
        case .failure(let error):
            print("✗ \(error.localizedDescription)")
            exit(1)
        case .success(let recording):
            print("✓ \(recording.frames) frames, \(recording.dropped) dropped, \(recording.width)×\(recording.height)")
            let data = try Data(contentsOf: recording.url)
            let frameSize = recording.width * recording.height * 3
            let png = out.deletingPathExtension().appendingPathExtension("png")
            let provider = CGDataProvider(data: data.subdata(in: 178 ..< 178 + frameSize) as CFData)!
            let image = CGImage(width: recording.width, height: recording.height, bitsPerComponent: 8, bitsPerPixel: 24,
                                bytesPerRow: recording.width * 3, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            print("First frame saved to \(png.path)")
        }
        break
    }

case "controls":
    guard let uvc = UVCCamera(captureDeviceID: camera.id) else {
        print("Couldn't open \(camera.name)'s USB video controls.")
        exit(1)
    }
    print("\(camera.name) controls:")
    for control in UVCControl.allCases {
        if let range = uvc.range(control) {
            print("  \(control.label): \(uvc.value(control).map(String.init) ?? "?")  [min \(range.minimum), max \(range.maximum), step \(range.step), default \(range.defaultValue)]")
        } else {
            print("  \(control.label): not supported")
        }
    }
    // Round-trip write test on the first adjustable control: set a different value, read back, restore.
    if let control = [UVCControl.gain, .gamma, .contrast].first(where: { uvc.range($0) != nil }),
       let range = uvc.range(control), let original = uvc.value(control) {
        let test = original == range.minimum ? min(range.maximum, original + range.step * 4) : range.minimum
        let ok = uvc.set(control, test)
        let readBack = uvc.value(control)
        uvc.set(control, original)
        print("\(control.label) write test: set \(test) → \(ok ? "ok" : "failed"), read back \(readBack.map(String.init) ?? "?"), restored \(uvc.value(control).map(String.init) ?? "?")")
    }

default:
    print("Use `list`, `record` or `controls`.")
}

/// Asks for camera access, giving up after `timeout` (nil): a command-line tool has no app bundle of its own, so
/// macOS may never show the prompt, and the request would otherwise wait forever.
func cameraAccess(timeout: Duration) async -> Bool? {
    let answered = AnswerOnce()
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
        Task {
            let granted = await CaptureEngine.requestAccess()
            if answered.claim() { continuation.resume(returning: granted) }
        }
        Task {
            try? await Task.sleep(for: timeout)
            if answered.claim() { continuation.resume(returning: nil) }
        }
    }
}

/// True for the first caller only.
final class AnswerOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
