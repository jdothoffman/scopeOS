import Foundation
import Testing
@testable import ScopeKit

@Suite("SER writer")
struct SERWriterTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scopeos-\(UUID().uuidString).ser")
    }

    private func int32(_ data: Data, _ offset: Int) -> Int32 {
        data.subdata(in: offset ..< offset + 4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
    }

    private func int64(_ data: Data, _ offset: Int) -> Int64 {
        data.subdata(in: offset ..< offset + 8).withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }.littleEndian
    }

    @Test func writesHeaderFramesAndTimestamps() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = try #require(ISO8601DateFormatter().date(from: "2026-10-07T03:00:00Z"))
        let writer = try SERWriter(url: url, width: 4, height: 2, color: .rgb,
                                   metadata: .init(observer: "J", instrument: "SVBONY SV205", telescope: "Celestron NexStar 6SE"), start: start)
        let frame = [UInt8](0 ..< 24)
        for index in 0 ..< 3 {
            try frame.withUnsafeBytes { try writer.append($0, at: start.addingTimeInterval(Double(index))) }
        }
        try writer.finish()

        let data = try Data(contentsOf: url)
        #expect(data.count == 178 + 3 * 24 + 3 * 8)
        #expect(String(decoding: data.prefix(14), as: UTF8.self) == "LUCAM-RECORDER")
        #expect(int32(data, 18) == 100) // RGB
        #expect(int32(data, 26) == 4)
        #expect(int32(data, 30) == 2)
        #expect(int32(data, 34) == 8)
        #expect(int32(data, 38) == 3) // frame count filled in on finish
        #expect(String(decoding: data[82 ..< 94], as: UTF8.self) == "SVBONY SV205")
        #expect(data[122 ..< 162].contains(0)) // fixed 40-byte, zero-padded fields
        // 2026-10-07T03:00:00Z in .NET ticks.
        #expect(int64(data, 170) == 639_269_388_000_000_000)
        #expect(Array(data[178 ..< 202]) == frame)
        let trailer = 178 + 3 * 24
        #expect(int64(data, trailer + 8) - int64(data, trailer) == 10_000_000) // one second apart
    }

    @Test func keepsTheFrameCountCurrentWhileRecording() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SERWriter(url: url, width: 2, height: 2, color: .mono)
        let frame = [UInt8](repeating: 7, count: 4)
        for _ in 0 ..< 61 { try frame.withUnsafeBytes { try writer.append($0) } }
        // Not finished, as if the app had crashed: the header already counts the first 60 frames.
        let data = try Data(contentsOf: url)
        #expect(int32(data, 38) == 60)
        #expect(data.count == 178 + 61 * 4) // frames stayed in order after the header update
        try writer.finish()
        #expect(int32(try Data(contentsOf: url), 38) == 61)
    }

    @Test func rejectsFramesOfTheWrongSize() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SERWriter(url: url, width: 4, height: 2, color: .mono)
        #expect(throws: (any Error).self) { try [UInt8](repeating: 0, count: 7).withUnsafeBytes { try writer.append($0) } }
        try writer.finish()
        #expect(try Data(contentsOf: url).count == 178)
    }
}
