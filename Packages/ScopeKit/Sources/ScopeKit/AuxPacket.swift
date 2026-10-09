/// A packet on Celestron's AUX bus: `3B <len> <src> <dst> <cmd> <data…> <checksum>`,
/// where `len` counts src, dst, cmd and data, and the checksum makes the sum of len…data equal 0 mod 256.
public struct AuxPacket: Equatable, Sendable {
    public static let preamble: UInt8 = 0x3B

    public var source: UInt8
    public var destination: UInt8
    public var command: UInt8
    public var data: [UInt8]

    public init(source: UInt8, destination: UInt8, command: UInt8, data: [UInt8] = []) {
        self.source = source
        self.destination = destination
        self.command = command
        self.data = data
    }

    public static func query(_ query: AuxQuery, to device: AuxDevice) -> AuxPacket {
        AuxPacket(source: AuxDevice.app.rawValue, destination: device.rawValue, command: query.rawValue)
    }

    public func encoded() -> [UInt8] {
        let body = [UInt8(3 + data.count), source, destination, command] + data
        return [Self.preamble] + body + [Self.checksum(body)]
    }

    static func checksum(_ body: [UInt8]) -> UInt8 {
        let sum = body.reduce(0) { $0 &+ Int($1) }
        return UInt8((0x100 - (sum & 0xFF)) & 0xFF)
    }

    /// Pulls every complete, valid packet off the front of `buffer`, skipping noise and bad checksums.
    /// Incomplete trailing bytes are left in the buffer for the next call.
    public static func extract(from buffer: inout [UInt8]) -> [AuxPacket] {
        var packets: [AuxPacket] = []
        while true {
            guard let start = buffer.firstIndex(of: preamble) else {
                buffer.removeAll()
                return packets
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 2 else { return packets }

            let length = Int(buffer[1])
            let total = length + 3
            guard length >= 3 else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= total else { return packets }

            let body = Array(buffer[1 ..< total - 1])
            if checksum(body) == buffer[total - 1] {
                packets.append(AuxPacket(source: body[1], destination: body[2], command: body[3], data: Array(body[4...])))
                buffer.removeFirst(total)
            } else {
                buffer.removeFirst()
            }
        }
    }

    static func decodeSingle(_ bytes: [UInt8]) -> AuxPacket? {
        var buffer = bytes
        let packets = extract(from: &buffer)
        return packets.count == 1 && buffer.isEmpty ? packets[0] : nil
    }
}
