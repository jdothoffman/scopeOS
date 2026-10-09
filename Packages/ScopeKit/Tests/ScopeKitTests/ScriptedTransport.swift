import Foundation
@testable import ScopeKit

/// Replays scripted bytes: lets a test hand the client replies in any order it likes, for protocol edge cases the
/// simulator can't produce.
final class ScriptedTransport: MountTransport, @unchecked Sendable {
    let displayName = "scripted"
    private let lock = NSLock()
    private var inbox: [UInt8] = []
    private var sent: [[UInt8]] = []
    /// Called after each write; return bytes to queue as the "reply".
    var onWrite: @Sendable ([UInt8]) -> [UInt8] = { _ in [] }

    var written: [[UInt8]] { lock.withLock { sent } }

    func open(timeout: Duration) async throws {}
    func close() {}
    func write(_ bytes: [UInt8]) async throws {
        let reply = onWrite(bytes)
        lock.withLock { sent.append(bytes); inbox += reply }
    }
    func read(maxLength: Int, timeout: Duration) async throws -> [UInt8] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let out: [UInt8] = lock.withLock {
                let n = min(maxLength, inbox.count); let o = Array(inbox.prefix(n)); inbox.removeFirst(n); return o
            }
            if !out.isEmpty { return out }
            if ContinuousClock.now >= deadline { throw MountError.timeout("scripted") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func discardBuffered() {}
}

extension MotionPolicy {
    /// Washington, DC, at local midnight in January: the Sun is far below the horizon, so the Sun rules allow
    /// any move the tests make, whenever they run.
    static let darkTestSky = MotionPolicy(observer: Observer(latitude: 38.89, longitude: -77.04), lockWhileSunUp: true,
                                          date: Date(timeIntervalSince1970: 1_768_453_200))
}
