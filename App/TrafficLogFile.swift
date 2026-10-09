import Foundation
import ScopeKit

/// Mirrors the traffic log to `~/Library/Logs/scopeOS/`, one file per launch, so a session's traffic can be sent
/// afterwards even if the app has quit. Keeps the newest `keep` files.
final class TrafficLogFile {
    static let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/scopeOS", isDirectory: true)
    private static let keep = 20

    private let folder: URL
    private var handle: FileHandle?
    private(set) var url: URL?

    init(folder: URL = TrafficLogFile.folder) {
        self.folder = folder
    }

    /// One line of the log as text, the same in the file, Copy and Save.
    static func line(_ entry: TrafficEntry) -> String {
        let symbol = switch entry.direction {
        case .sent: "→"
        case .received: "←"
        case .note: "·"
        }
        return "\(timeFormatter.string(from: entry.date)) \(symbol) \(entry.text)"
    }

    func write(_ entry: TrafficEntry) {
        if handle == nil { open() }
        guard let handle, let data = (Self.line(entry) + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    private func open() {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        prune(manager)
        let url = folder.appendingPathComponent("scopeOS \(Self.fileFormatter.string(from: .now)).log")
        guard manager.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else { return }
        self.handle = handle
        self.url = url
    }

    private func prune(_ manager: FileManager) {
        let logs = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]))?
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? [] // names start with the date, so this is newest first
        for old in logs.dropFirst(Self.keep - 1) { try? manager.removeItem(at: old) }
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}
