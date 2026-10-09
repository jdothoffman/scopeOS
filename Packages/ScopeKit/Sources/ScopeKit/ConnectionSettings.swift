public enum ConnectionSettings: Sendable, Equatable {
    /// SkyPortal WiFi module plugged into the mount's AUX port.
    case wifiModule(host: String, port: UInt16)
    /// USB cable to the hand controller.
    case usbHandController(path: String)
    /// Hand-controller protocol over the network: SkyFi-style bridges, or the ScopeKit simulator.
    case networkHandController(host: String, port: UInt16)

    /// `motionPolicy` gives the Sun rules each move must pass (WiFi module only; the hand controller can't move).
    public func makeClient(log: TrafficLogger? = nil,
                           motionPolicy: @escaping @Sendable () async -> MotionPolicy = { .refuseAll }) -> any MountClient {
        switch self {
        case .wifiModule(let host, let port):
            AuxClient(transport: TCPTransport(host: host, port: port), log: log, motionPolicy: motionPolicy)
        case .usbHandController(let path):
            HandControllerClient(transport: SerialTransport(path: path), log: log)
        case .networkHandController(let host, let port):
            HandControllerClient(transport: TCPTransport(host: host, port: port), log: log)
        }
    }
}

extension ConnectionSettings {
    /// How long to wait before reconnection attempt `attempt + 1` (the first retry is attempt 1): doubling from
    /// 3 s up to 30 s.
    public static func retryDelay(attempt: Int) -> Duration {
        .seconds(min(30, 3 * (1 << max(0, min(attempt - 1, 4)))))
    }

    /// A clearer reason for a failed or lost connection than the network layer gives.
    public func problem(_ error: Error, wasConnected: Bool) -> String {
        let detail = error.localizedDescription
        if wasConnected { return "Lost the connection: \(detail)" }
        switch (self, error as? MountError) {
        case (.wifiModule(let host, let port), .connectionFailed?), (.wifiModule(let host, let port), .timeout?),
             (.wifiModule(let host, let port), .disconnected?):
            return "Nothing answered at \(host):\(port). Is the SkyPortal app, or another copy of scopeOS, connected to the WiFi module? It takes one connection at a time. Otherwise check the mount is on and the address is right. (\(detail))"
        case (.usbHandController(let path), .connectionFailed?):
            return "Couldn't open \(path): is the hand controller plugged in and switched on, and no other app using the port? (\(detail))"
        default:
            return detail
        }
    }

    /// Whether retrying can't help (settings that can't work).
    public static func isPermanent(_ error: Error) -> Bool {
        if case .invalidConfiguration? = error as? MountError { return true }
        return false
    }
}
