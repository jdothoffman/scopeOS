import Foundation
import ScopeKit

/// The record of solar filter confirmations: one line each time someone confirms, before Go to the Sun, that a solar
/// filter covers the front of the telescope. Kept on this device (`Platform.solarLogFile`) and only ever added to.
struct SolarLog {
    static let defaultFile = Platform.solarLogFile

    /// What the person confirmed, word for word as the checklist asks it.
    static let checklist = [
        "A full-aperture solar filter is fitted securely over the front of the telescope (not a filter at the eyepiece or camera).",
        "The filter is undamaged: no scratches, pinholes or tears, checked against a light.",
        "The finder is covered or removed, and nobody will look through the telescope without the filter.",
    ]

    let file: URL

    /// Adds one line: when, what was confirmed, where, and what scopeOS was connected to.
    func record(at date: Date, observer: Observer?, connection: String) throws {
        let place = observer.map { "\(SkyFormat.latitude($0.latitude)), \(SkyFormat.longitude($0.longitude))" } ?? "no location"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let line = "\(Self.timestamp.string(from: date))  Solar filter confirmed by the user: \(Self.checklist.joined(separator: " ")) "
            + "Location \(place). Connected to \(connection). scopeOS \(version).\n"
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            let header = "scopeOS: solar filter confirmations. One line each time someone confirmed a solar filter was on before Go to the Sun.\n\n"
            try Data(header.utf8).write(to: file)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    /// Local time with its offset from UTC, so the record reads the same anywhere.
    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss xxx"
        return formatter
    }()
}
