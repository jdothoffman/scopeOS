import Foundation

public enum MountError: Error, LocalizedError, Equatable, Sendable {
    case blockedCommand(String)
    case timeout(String)
    case disconnected
    case connectionFailed(String)
    case unexpectedReply(command: String, bytes: [UInt8])
    case invalidConfiguration(String)
    /// A movement request that was declined before anything was sent.
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .blockedCommand(let detail):
            "Blocked a command that is not on the read-only list: \(detail)"
        case .timeout(let what):
            "No reply from the mount (\(what))."
        case .disconnected:
            "The connection to the mount closed."
        case .connectionFailed(let reason):
            "Could not connect: \(reason)"
        case .unexpectedReply(let command, let bytes):
            "Unexpected reply to \(command): \(Hex.string(bytes))"
        case .invalidConfiguration(let reason), .refused(let reason):
            reason
        }
    }
}

public enum Hex {
    public static func string(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
