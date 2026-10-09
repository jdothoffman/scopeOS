import Foundation

/// Writes SER video files (format v3), the standard container for planetary imaging that stacking software
/// (AutoStakkert, Siril, Planetary System Stacker, PIPP) reads. Layout: a 178-byte little-endian header,
/// raw frames back to back, then one UTC timestamp per frame.
public final class SERWriter {
    public enum ColorID: Int32, Sendable {
        case mono = 0
        case rgb = 100
        case bgr = 101

        var planes: Int { self == .mono ? 1 : 3 }
    }

    public struct Metadata: Sendable {
        public var observer: String
        public var instrument: String
        public var telescope: String

        public init(observer: String = "", instrument: String = "", telescope: String = "") {
            self.observer = observer
            self.instrument = instrument
            self.telescope = telescope
        }
    }

    public static let headerSize = 178

    public let url: URL
    public let width: Int
    public let height: Int
    public let color: ColorID
    public private(set) var frameCount = 0
    public var frameSize: Int { width * height * color.planes }
    public var bytesWritten: Int64 { Int64(Self.headerSize) + Int64(frameCount) * Int64(frameSize) }

    private let handle: FileHandle
    private var timestamps: [Int64] = []
    private var finished = false

    /// Creates the file (replacing any existing one) and writes the header. Frames are 8 bits per plane.
    public init(url: URL, width: Int, height: Int, color: ColorID, metadata: Metadata = Metadata(), start: Date = .now) throws {
        guard width > 0, height > 0 else { throw CocoaError(.fileWriteInvalidFileName) }
        self.url = url
        self.width = width
        self.height = height
        self.color = color
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(width: width, height: height, color: color, frameCount: 0, metadata: metadata, start: start))
    }

    deinit {
        try? finish()
    }

    /// Appends one frame of exactly `frameSize` bytes.
    public func append(_ frame: UnsafeRawBufferPointer, at date: Date = .now) throws {
        precondition(!finished, "SERWriter used after finish()")
        guard frame.count == frameSize else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Frame is \(frame.count) bytes; expected \(frameSize)."])
        }
        try handle.write(contentsOf: Data(bytes: frame.baseAddress!, count: frame.count))
        timestamps.append(Self.ticks(date))
        frameCount += 1
        // Keep the header's frame count roughly current, so a crash mid-recording still leaves a readable file.
        if frameCount % 30 == 0 {
            try writeFrameCount()
            try handle.seekToEnd()
        }
    }

    /// Writes the timestamp trailer, fills in the frame count and closes the file. Safe to call twice.
    public func finish() throws {
        guard !finished else { return }
        finished = true
        var trailer = Data(capacity: timestamps.count * 8)
        for stamp in timestamps { trailer.appendLittleEndian(stamp) }
        try handle.write(contentsOf: trailer)
        try writeFrameCount()
        try handle.close()
    }

    private func writeFrameCount() throws {
        try handle.seek(toOffset: 38) // FrameCount field
        var count = Data()
        count.appendLittleEndian(Int32(frameCount))
        try handle.write(contentsOf: count)
    }

    static func header(width: Int, height: Int, color: ColorID, frameCount: Int, metadata: Metadata, start: Date) -> Data {
        var data = Data(capacity: headerSize)
        data.append(contentsOf: Array("LUCAM-RECORDER".utf8))
        data.appendLittleEndian(Int32(0)) // LuID
        data.appendLittleEndian(color.rawValue)
        data.appendLittleEndian(Int32(0)) // byte order of 16-bit data; frames here are 8-bit
        data.appendLittleEndian(Int32(width))
        data.appendLittleEndian(Int32(height))
        data.appendLittleEndian(Int32(8)) // bits per plane
        data.appendLittleEndian(Int32(frameCount))
        for text in [metadata.observer, metadata.instrument, metadata.telescope] {
            var field = Array(text.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "?") }.prefix(40))
            field += Array(repeating: 0, count: 40 - field.count)
            data.append(contentsOf: field)
        }
        let utc = ticks(start)
        data.appendLittleEndian(utc + Int64(TimeZone.current.secondsFromGMT(for: start)) * 10_000_000)
        data.appendLittleEndian(utc)
        return data
    }

    /// .NET-style ticks: 100 ns intervals since 0001-01-01 UTC, as SER timestamps use.
    static func ticks(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 62_135_596_800) * 10_000_000)
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
