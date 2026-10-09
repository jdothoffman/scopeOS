import Foundation
import Network

public final class TCPTransport: MountTransport, @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public var displayName: String { "\(host):\(port)" }

    private let queue = DispatchQueue(label: "ScopeKit.TCPTransport")
    private let inbox = ByteInbox()
    private let lock = NSLock()
    private var connection: NWConnection?

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public func open(timeout: Duration) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port), !host.isEmpty else {
            throw MountError.invalidConfiguration("Enter a host and port.")
        }
        close()
        inbox.reset()

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        lock.withLock { self.connection = connection }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { [inbox] state in
                switch state {
                case .ready:
                    once.resume(returning: ())
                case .waiting(let error), .failed(let error):
                    once.resume(throwing: MountError.connectionFailed(error.localizedDescription))
                    inbox.fail(.disconnected)
                    connection.cancel()
                case .cancelled:
                    once.resume(throwing: MountError.disconnected)
                    inbox.fail(.disconnected)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout.seconds) { [displayName] in
                if connection.state != .ready {
                    once.resume(throwing: MountError.timeout("connecting to \(displayName)"))
                    connection.cancel()
                }
            }
        }
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { inbox.append([UInt8](data)) }
            if let error {
                inbox.fail(.connectionFailed(error.localizedDescription))
            } else if isComplete {
                inbox.fail(.disconnected)
            } else {
                receiveLoop(connection)
            }
        }
    }

    public func close() {
        let connection = lock.withLock {
            defer { self.connection = nil }
            return self.connection
        }
        connection?.cancel()
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard let connection = lock.withLock({ self.connection }) else { throw MountError.disconnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MountError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func read(maxLength: Int, timeout: Duration) async throws -> [UInt8] {
        try await inbox.take(maxLength: maxLength, timeout: timeout, context: displayName)
    }

    public func discardBuffered() {
        inbox.discard()
    }
}
