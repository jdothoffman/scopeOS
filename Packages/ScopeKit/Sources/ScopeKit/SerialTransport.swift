import Darwin
import Foundation

/// USB serial connection to a NexStar / StarSense hand controller (9600 baud, 8N1).
public final class SerialTransport: MountTransport, @unchecked Sendable {
    public let path: String
    public var displayName: String { path }

    private let inbox = ByteInbox()
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var generation = 0

    public init(path: String) {
        self.path = path
    }

    /// Serial devices that look like USB adapters, newest naming conventions first.
    public static func availablePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth") && !$0.contains("debug-console") }
            .sorted()
            .map { "/dev/\($0)" }
    }

    public func open(timeout: Duration) async throws {
        guard !path.isEmpty else { throw MountError.invalidConfiguration("Choose a serial port.") }
        close()
        inbox.reset()

        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw MountError.connectionFailed("\(path): \(String(cString: strerror(errno)))")
        }

        var settings = termios()
        tcgetattr(descriptor, &settings)
        cfmakeraw(&settings)
        cfsetspeed(&settings, speed_t(B9600))
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
        settings.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CCTS_OFLOW | CRTS_IFLOW)
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw MountError.connectionFailed("\(path): \(reason)")
        }
        tcflush(descriptor, TCIOFLUSH)

        let myGeneration = lock.withLock {
            fd = descriptor
            generation += 1
            return generation
        }
        startReader(descriptor: descriptor, generation: myGeneration)
    }

    private func startReader(descriptor: Int32, generation myGeneration: Int) {
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 512)
            while let self, self.lock.withLock({ self.generation == myGeneration }) {
                var pollfd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pollfd, 1, 200)
                if ready < 0 && errno != EINTR {
                    self.inbox.fail(.disconnected)
                    break
                }
                guard ready > 0 else { continue }
                if pollfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    self.inbox.fail(.disconnected)
                    break
                }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    self.inbox.append(Array(buffer[0 ..< count]))
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    self.inbox.fail(.disconnected)
                    break
                }
            }
            Darwin.close(descriptor)
        }
        thread.name = "ScopeKit.SerialReader"
        thread.start()
    }

    public func close() {
        lock.withLock {
            generation += 1
            fd = -1
        }
        inbox.fail(.disconnected)
    }

    public func write(_ bytes: [UInt8]) async throws {
        let descriptor = lock.withLock { fd }
        guard descriptor >= 0 else { throw MountError.disconnected }
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if errno == EAGAIN || errno == EINTR {
                try await Task.sleep(for: .milliseconds(5))
            } else {
                throw MountError.connectionFailed(String(cString: strerror(errno)))
            }
        }
    }

    public func read(maxLength: Int, timeout: Duration) async throws -> [UInt8] {
        try await inbox.take(maxLength: maxLength, timeout: timeout, context: path)
    }

    public func discardBuffered() {
        inbox.discard()
    }
}
