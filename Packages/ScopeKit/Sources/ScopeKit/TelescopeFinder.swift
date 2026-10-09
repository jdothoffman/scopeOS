import Darwin
import Foundation

/// Finds Celestron WiFi modules on the local network: tries the AUX port on every address in the Mac's subnet,
/// then confirms each answer with a read-only version query to the azimuth motor.
public enum TelescopeFinder {
    public struct Found: Hashable, Sendable {
        public let host: String
        public let port: UInt16
    }

    public static let defaultPort: UInt16 = 2000

    /// Searches the subnets of the Mac's active network interfaces.
    public static func findOnLocalNetwork(port: UInt16 = defaultPort) async -> [Found] {
        await find(hosts: localSubnetHosts(), port: port)
    }

    /// Checks `hosts` (at most `concurrency` at a time) and returns the ones that answer like an AUX bus, in order.
    /// Cancelling stops it within one probe's timeout and returns what was found so far.
    public static func find(hosts: [String], port: UInt16 = defaultPort, concurrency: Int = 48,
                            connectTimeout: Duration = .milliseconds(600)) async -> [Found] {
        var found: [Found] = []
        await withTaskGroup(of: Found?.self) { group in
            var remaining = hosts.makeIterator()
            func addNext() -> Bool {
                guard !Task.isCancelled, let host = remaining.next() else { return false }
                group.addTask { await probe(host: host, port: port, timeout: connectTimeout) ? Found(host: host, port: port) : nil }
                return true
            }
            for _ in 0 ..< concurrency where !addNext() { break }
            for await result in group {
                if let result { found.append(result) }
                _ = addNext()
            }
        }
        return found.sorted { hostOrder($0.host) < hostOrder($1.host) }
    }

    /// True if something at `host` accepts a connection and answers a version query the way an AUX bus does.
    static func probe(host: String, port: UInt16, timeout: Duration) async -> Bool {
        let transport = TCPTransport(host: host, port: port)
        defer { transport.close() }
        do {
            try await transport.open(timeout: timeout)
            return try await AuxClient(transport: transport).identify()
        } catch {
            return false
        }
    }

    /// Every host address in the subnets of the active Wi-Fi and Ethernet interfaces (each capped to the /24 around
    /// the Mac), excluding the Mac itself. VPNs, virtual machine bridges and the like are skipped (see
    /// `isScannable`): the telescope is never behind them, and scanning them only adds time and VPN traffic.
    public static func localSubnetHosts() -> [String] {
        var result: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  isScannable(interface: String(cString: entry.ifa_name)),
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), let mask = entry.ifa_netmask
            else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            result += hosts(address: ip, mask: netmask).filter { $0 != dotted(ip) && !result.contains($0) }
        }
        return result
    }

    /// Wi-Fi and Ethernet (including USB and Thunderbolt adapters) are all `en…` on macOS. Everything else is a VPN
    /// (`utun`, `ipsec`, `ppp`), a virtual machine or container network (`bridge`, `vmnet`, `vnic`), or Apple's
    /// peer-to-peer links (`awdl`, `llw`, `anpi`), none of which leads to the telescope.
    static func isScannable(interface name: String) -> Bool {
        name.hasPrefix("en")
    }

    /// Host addresses of a subnet, as dotted strings. Masks wider than /24 are narrowed to the /24 around `address`,
    /// which keeps a scan to at most 254 addresses per interface.
    static func hosts(address: UInt32, mask: UInt32) -> [String] {
        let narrowed = mask | 0xFFFF_FF00
        let network = address & narrowed
        let broadcast = network | ~narrowed
        guard broadcast > network + 1 else { return [] }
        return (network + 1 ..< broadcast).map(dotted)
    }

    static func dotted(_ value: UInt32) -> String {
        "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    /// Numeric value of a dotted IPv4 address, for sorting.
    private static func hostOrder(_ host: String) -> UInt32 {
        host.split(separator: ".").reduce(0) { $0 << 8 | (UInt32($1) ?? 0) }
    }
}
