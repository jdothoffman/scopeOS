import Accelerate
@preconcurrency import AVFoundation
import Foundation
import ScopeKit

/// A webcam-style (UVC) camera, as macOS lists it.
public struct CaptureCamera: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isBuiltIn: Bool
}

/// One of a camera's video modes.
public struct CaptureFormat: Identifiable, Hashable, Sendable {
    public let id: String
    /// Pixel format code as macOS names it, e.g. "YUVS" or "420V".
    public let code: String
    public let width: Int
    public let height: Int
    public let maxFrameRate: Double

    public var label: String { String(format: "%@ %d×%d · %.0f fps", code, width, height, maxFrameRate) }
}

public struct CaptureStats: Sendable, Equatable {
    public var framesPerSecond = 0.0
    public var lastFrame: Date?
    public var recording = false
    public var framesRecorded = 0
    public var framesDropped = 0
    public var bytesWritten: Int64 = 0
    public var recordingStarted: Date?
    /// Brightness distribution of the latest frame: 64 bins, scaled so the tallest is 1.
    public var histogram: [Double] = []
    /// Brightness (0–1) that 99.5% of the frame is below: roughly the brightest part of the target.
    public var peakLevel = 0.0
    /// Share of the frame (0–1) with a channel at or near full brightness, i.e. over-exposed.
    public var saturatedFraction = 0.0
    /// Focus aid: edge crispness in the centre of the frame, smoothed over recent frames (higher is sharper;
    /// only comparisons matter). Nil until measured.
    public var sharpness: Double?

    public init() {}
}

public struct RecordingResult: Sendable {
    public let url: URL
    public let frames: Int
    public let dropped: Int
    public let started: Date
    public let ended: Date
    public let width: Int
    public let height: Int
}

/// Runs one camera: preview session, frame-rate measurement and SER recording. Session changes happen on
/// `sessionQueue`, frames arrive on `videoQueue`; callbacks are delivered on the main actor.
public final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()

    /// Called a few times a second with the latest numbers.
    public var onStats: (@MainActor @Sendable (CaptureStats) -> Void)?
    /// Called when a recording ends, whether stopped, timed out or failed.
    public var onRecordingFinished: (@MainActor @Sendable (Result<RecordingResult, Error>) -> Void)?

    private let sessionQueue = DispatchQueue(label: "ScopeCapture.session")
    private let videoQueue = DispatchQueue(label: "ScopeCapture.video")
    private let output = AVCaptureVideoDataOutput()

    // Only touched on videoQueue.
    private var stats = CaptureStats()
    private var frameTimes: [CFTimeInterval] = []
    private var lastStatsSent: CFTimeInterval = 0
    private var writer: SERWriter?
    private var recordingLimit: TimeInterval?
    private var rgbBuffer: [UInt8] = []
    private var frameCounter = 0
    private var recentSharpness: [Double] = []

    public static func cameras() -> [CaptureCamera] {
        let types: [AVCaptureDevice.DeviceType] = [.external, .builtInWideAngleCamera]
        // Telescope cameras first; the Mac's own camera and an iPhone (Continuity Camera) last.
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
            .map { CaptureCamera(id: $0.uniqueID, name: $0.localizedName,
                                 isBuiltIn: $0.deviceType == .builtInWideAngleCamera || $0.deviceType == .continuityCamera) }
            .sorted { !$0.isBuiltIn && $1.isBuiltIn }
    }

    public static func formats(for cameraID: String) -> [CaptureFormat] {
        guard let device = AVCaptureDevice(uniqueID: cameraID) else { return [] }
        return device.formats.map(describe)
    }

    static func describe(_ format: AVCaptureDevice.Format) -> CaptureFormat {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let code = String(bytes: [24, 16, 8, 0].map { UInt8((subtype >> $0) & 0xFF) }, encoding: .ascii)?.uppercased() ?? "?"
        let rate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        return CaptureFormat(id: "\(code)-\(dimensions.width)x\(dimensions.height)-\(Int(rate))", code: code,
                             width: Int(dimensions.width), height: Int(dimensions.height), maxFrameRate: rate)
    }

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Starts (or switches) the camera and format.
    public func start(cameraID: String, formatID: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    try configure(cameraID: cameraID, formatID: formatID)
                    if !session.isRunning { session.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop() {
        stopRecording()
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure(cameraID: String, formatID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: cameraID) else { throw CaptureError.cameraMissing }
        guard let format = device.formats.first(where: { Self.describe($0).id == formatID }) else { throw CaptureError.formatMissing }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cameraBusy }
        session.addInput(input)

        if session.outputs.isEmpty {
            // macOS converts whatever the camera sends into full-color BGRA, which is what gets recorded.
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true // dropped frames are counted, not queued up
            output.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(output) else { throw CaptureError.cameraBusy }
            session.addOutput(output)
        }

        try device.lockForConfiguration()
        device.activeFormat = format
        if let range = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
            device.activeVideoMinFrameDuration = range.minFrameDuration
        }
        device.unlockForConfiguration()

        videoQueue.async { [self] in
            // Forget the old mode's frame size: a recording started before the new mode's first frame must wait
            // for it (noFrames), not open a file with the old dimensions.
            lastSize = nil
            frameTimes.removeAll()
            stats.framesPerSecond = 0
        }
    }

    // MARK: Recording

    /// Starts writing frames to a new SER file. `limit` stops the recording automatically.
    public func startRecording(to url: URL, metadata: SERWriter.Metadata, limit: TimeInterval?) throws {
        var failure: Error?
        videoQueue.sync {
            guard writer == nil else { failure = CaptureError.alreadyRecording; return }
            guard let size = currentSize() else { failure = CaptureError.noFrames; return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                writer = try SERWriter(url: url, width: size.width, height: size.height, color: .rgb, metadata: metadata)
                recordingLimit = limit
                stats.recording = true
                stats.framesRecorded = 0
                stats.framesDropped = 0
                stats.bytesWritten = Int64(SERWriter.headerSize)
                stats.recordingStarted = .now
                sendStats(force: true)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    public func stopRecording() {
        videoQueue.async { [self] in finishRecording(error: nil) }
    }

    private var lastSize: (width: Int, height: Int)?
    private func currentSize() -> (width: Int, height: Int)? { lastSize }

    private func finishRecording(error: Error?) {
        guard let writer, let started = stats.recordingStarted else { return }
        self.writer = nil
        let result: Result<RecordingResult, Error>
        do {
            try writer.finish()
            if let error { throw error }
            result = .success(RecordingResult(url: writer.url, frames: writer.frameCount, dropped: stats.framesDropped,
                                              started: started, ended: .now, width: writer.width, height: writer.height))
        } catch {
            result = .failure(error)
        }
        stats.recording = false
        stats.recordingStarted = nil
        sendStats(force: true)
        let callback = onRecordingFinished
        Task { @MainActor in callback?(result) }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate (on videoQueue)

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 2 }
        stats.framesPerSecond = frameTimes.count > 1 ? Double(frameTimes.count - 1) / (now - frameTimes[0]) : 0
        stats.lastFrame = .now

        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSize = (CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels))
        if now - lastStatsSent > 0.25 { measure(pixels) }
        frameCounter += 1
        if frameCounter % 3 == 0 { updateSharpness(pixels) } // about 10 times a second at 30 fps

        if let writer {
            do {
                try append(pixels, to: writer)
                stats.framesRecorded = writer.frameCount
                stats.bytesWritten = writer.bytesWritten
                if let limit = recordingLimit, let started = stats.recordingStarted, Date.now.timeIntervalSince(started) >= limit {
                    finishRecording(error: nil)
                }
            } catch {
                finishRecording(error: error)
            }
        }
        sendStats(force: false)
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if writer != nil { stats.framesDropped += 1 }
    }

    /// Fills in the histogram, peak level and over-exposed share from a grid of sampled pixels.
    private func measure(_ pixels: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let step = max(4, width / 320)
        var bins = [Int](repeating: 0, count: 64)
        var saturated = 0, total = 0
        for y in stride(from: 0, to: height, by: step) {
            let row = base + y * rowBytes
            for x in stride(from: 0, to: width, by: step) {
                let pixel = row + x * 4 // BGRA
                let blue = Int(pixel[0]), green = Int(pixel[1]), red = Int(pixel[2])
                bins[(red * 77 + green * 150 + blue * 29) >> 10] += 1
                if max(red, green, blue) >= 250 { saturated += 1 }
                total += 1
            }
        }
        guard total > 0 else { return }
        let tallest = Double(bins.max() ?? 1)
        stats.histogram = bins.map { Double($0) / tallest }
        stats.saturatedFraction = Double(saturated) / Double(total)
        var running = 0
        let threshold = Int(Double(total) * 0.995)
        let peakBin = bins.indices.first { running += bins[$0]; return running >= threshold } ?? 63
        stats.peakLevel = Double(peakBin + 1) / 64
    }

    private func updateSharpness(_ pixels: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return }
        guard let value = Self.sharpness(bgra: base, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
                                         rowBytes: CVPixelBufferGetBytesPerRow(pixels)) else { return }
        // Median of the last five readings: steady enough to read through the shimmer of the atmosphere.
        recentSharpness.append(value)
        if recentSharpness.count > 5 { recentSharpness.removeFirst() }
        stats.sharpness = recentSharpness.sorted()[recentSharpness.count / 2]
    }

    /// Edge crispness of the central third of a BGRA frame: mean squared brightness gradient, divided by the
    /// square of the region's bright level so that changing the exposure barely moves it. Nil for a dark frame.
    static func sharpness(bgra base: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int) -> Double? {
        let x0 = width / 3, x1 = width * 2 / 3, y0 = height / 3, y1 = height * 2 / 3
        guard x1 - x0 > 4, y1 - y0 > 4 else { return nil }
        let step = max(1, Int((Double((x1 - x0) * (y1 - y0)) / 60_000).squareRoot()))
        @inline(__always) func luminance(_ x: Int, _ y: Int) -> Int {
            let pixel = base + y * rowBytes + x * 4
            return (Int(pixel[2]) * 77 + Int(pixel[1]) * 150 + Int(pixel[0]) * 29) >> 8
        }
        var energy = 0.0, count = 0
        var bins = [Int](repeating: 0, count: 256)
        for y in stride(from: y0 + step, to: y1 - step, by: step) {
            for x in stride(from: x0 + step, to: x1 - step, by: step) {
                let gx = luminance(x + step, y) - luminance(x - step, y)
                let gy = luminance(x, y + step) - luminance(x, y - step)
                energy += Double(gx * gx + gy * gy)
                bins[luminance(x, y)] += 1
                count += 1
            }
        }
        guard count > 0 else { return nil }
        // Bright level: the 99th percentile, so a few hot pixels don't set the scale.
        var running = 0
        let bright = bins.indices.first { running += bins[$0]; return running >= count * 99 / 100 } ?? 255
        guard bright >= 12 else { return nil }
        return energy / Double(count) / Double(bright * bright) * 100
    }

    /// Converts a BGRA frame to tightly packed RGB and appends it.
    private func append(_ pixels: CVPixelBuffer, to writer: SERWriter) throws {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        guard width == writer.width, height == writer.height, let base = CVPixelBufferGetBaseAddress(pixels) else {
            throw CaptureError.formatChangedWhileRecording
        }
        if rgbBuffer.count != writer.frameSize { rgbBuffer = [UInt8](repeating: 0, count: writer.frameSize) }
        try rgbBuffer.withUnsafeMutableBytes { rgb in
            var source = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                       rowBytes: CVPixelBufferGetBytesPerRow(pixels))
            var destination = vImage_Buffer(data: rgb.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                            rowBytes: width * 3)
            vImageConvert_BGRA8888toRGB888(&source, &destination, vImage_Flags(kvImageNoFlags))
            try writer.append(UnsafeRawBufferPointer(rgb))
        }
    }

    private func sendStats(force: Bool) {
        let now = CACurrentMediaTime()
        guard force || now - lastStatsSent > 0.25 else { return }
        lastStatsSent = now
        let snapshot = stats
        let callback = onStats
        Task { @MainActor in callback?(snapshot) }
    }
}

public enum CaptureError: LocalizedError {
    case cameraMissing, formatMissing, cameraBusy, alreadyRecording, noFrames, formatChangedWhileRecording

    public var errorDescription: String? {
        switch self {
        case .cameraMissing: "The camera isn't connected."
        case .formatMissing: "That video mode isn't available on this camera."
        case .cameraBusy: "The camera is in use by another app. Quit AstroDMx, FireCapture or QuickTime and try again."
        case .alreadyRecording: "Already recording."
        case .noFrames: "No picture from the camera yet, so there's nothing to record."
        case .formatChangedWhileRecording: "The video mode changed during the recording, so it was stopped."
        }
    }
}
