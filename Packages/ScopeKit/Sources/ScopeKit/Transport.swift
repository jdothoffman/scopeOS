import Foundation

public protocol MountTransport: Sendable {
    var displayName: String { get }
    func open(timeout: Duration) async throws
    func close()
    func write(_ bytes: [UInt8]) async throws
    /// Returns at least one byte, or throws `MountError.timeout` / `.disconnected`.
    func read(maxLength: Int, timeout: Duration) async throws -> [UInt8]
    func discardBuffered()
}

/// Thread-safe byte buffer fed by a background reader. A read timing out does not tear the connection down,
/// so optional devices that never answer (e.g. no focuser on the AUX bus) don't force a reconnect.
final class ByteInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var failure: MountError?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func reset() {
        lock.withLock {
            bytes.removeAll()
            failure = nil
        }
    }

    func append(_ data: [UInt8]) {
        lock.withLock {
            bytes += data
            return drainWaiters()
        }.forEach { $0.resume() }
    }

    func fail(_ error: MountError) {
        lock.withLock {
            if failure == nil { failure = error }
            return drainWaiters()
        }.forEach { $0.resume() }
    }

    func discard() {
        lock.withLock { bytes.removeAll() }
    }

    func take(maxLength: Int, timeout: Duration, context: String) async throws -> [UInt8] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let result: Result<[UInt8], MountError>? = lock.withLock {
                if !bytes.isEmpty {
                    let count = min(maxLength, bytes.count)
                    let out = Array(bytes.prefix(count))
                    bytes.removeFirst(count)
                    return .success(out)
                }
                if let failure { return .failure(failure) }
                return nil
            }
            if let result { return try result.get() }
            if ContinuousClock.now >= deadline { throw MountError.timeout(context) }
            await wait(until: deadline)
        }
    }

    private func wait(until deadline: ContinuousClock.Instant) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock { () -> Bool in
                    if !bytes.isEmpty || failure != nil { return true }
                    waiters[id] = continuation
                    return false
                }
                if ready {
                    continuation.resume()
                    return
                }
                Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    self?.wake(id)
                }
            }
        } onCancel: {
            wake(id)
        }
    }

    private func wake(_ id: UUID) {
        lock.withLock { waiters.removeValue(forKey: id) }?.resume()
    }

    private func drainWaiters() -> [CheckedContinuation<Void, Never>] {
        let pending = Array(waiters.values)
        waiters.removeAll()
        return pending
    }
}

/// First-come, first-served async lock. Client actors are reentrant at every `await`, so this keeps a single
/// request/reply exchange on the wire when a stop arrives in the middle of a status poll.
final class ExchangeLock: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let granted = lock.withLock { () -> Bool in
                if held {
                    waiters.append(continuation)
                    return false
                }
                held = true
                return true
            }
            if granted { continuation.resume() }
        }
    }

    /// Hands the lock straight to the next waiter, if any.
    func release() {
        lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if waiters.isEmpty {
                held = false
                return nil
            }
            return waiters.removeFirst()
        }?.resume()
    }
}

final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) { take()?.resume(returning: value) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
