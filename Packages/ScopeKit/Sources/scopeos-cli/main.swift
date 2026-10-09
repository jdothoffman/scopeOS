import Foundation
import ScopeKit

// Terminal monitor, handy for first contact with the real mount.
// Usage:
//   swift run scopeos-cli wifi [host] [port]      # SkyPortal WiFi module (default 1.2.3.4 2000)
//   swift run scopeos-cli usb /dev/cu.usbserial-XXXX
//   swift run scopeos-cli net host port           # hand-controller protocol over TCP (simulator: 127.0.0.1 2001)
//   swift run scopeos-cli find                    # search the local network for WiFi modules
//   add --verbose to print every byte sent and received

setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments.dropFirst().filter { $0 != "--verbose" }
let verbose = CommandLine.arguments.contains("--verbose")
let mode = args.first ?? "wifi"
let rest = Array(args.dropFirst())

if mode == "find" {
    print("Searching the local network for telescopes on port \(TelescopeFinder.defaultPort)…")
    let found = await TelescopeFinder.findOnLocalNetwork()
    if found.isEmpty { print("None found. Is the mount on, its WiFi module on this network, and the SkyPortal app closed?") }
    for telescope in found { print("Found: \(telescope.host):\(telescope.port)") }
    exit(0)
}

let settings: ConnectionSettings
switch mode {
case "wifi":
    settings = .wifiModule(host: rest.first ?? "1.2.3.4", port: rest.count > 1 ? UInt16(rest[1]) ?? 2000 : 2000)
case "usb":
    guard let path = rest.first ?? SerialTransport.availablePorts().first(where: { $0.contains("usb") }) else {
        print("No USB serial port found. Available: \(SerialTransport.availablePorts().joined(separator: ", "))")
        exit(1)
    }
    settings = .usbHandController(path: path)
case "net":
    settings = .networkHandController(host: rest.first ?? "127.0.0.1", port: rest.count > 1 ? UInt16(rest[1]) ?? 2001 : 2001)
default:
    print("Unknown mode \"\(mode)\". Use wifi, usb, net or find.")
    exit(1)
}

let client = settings.makeClient(log: { entry in
    switch entry.direction {
    case .note: print("· \(entry.text)")
    case .sent: if verbose { print("→ \(entry.text)") }
    case .received: if verbose { print("← \(entry.text)") }
    }
})

do {
    try await client.connect()
} catch {
    print("✗ \(error.localizedDescription)")
    exit(1)
}

while true {
    do {
        let s = try await client.readStatus()
        var parts: [String] = []
        if let eq = s.equatorial {
            parts.append("RA \(SkyFormat.rightAscension(eq.raHours))  Dec \(SkyFormat.declination(eq.decDegrees))")
            parts.append(String(format: "Sun %.0f° away", Astronomy.separation(eq, Astronomy.sunPosition(at: .now))))
        }
        if let h = s.horizontal {
            parts.append("Az \(SkyFormat.degrees(h.azimuth)) \(SkyFormat.compassPoint(h.azimuth))  Alt \(SkyFormat.degrees(h.altitude))")
        }
        if s.slewing == true { parts.append("SLEWING") }
        if let focus = s.focuserPosition { parts.append("Focus \(focus)") }
        print(parts.joined(separator: "  |  "))
    } catch {
        print("✗ \(error.localizedDescription)")
        await client.disconnect()
        exit(1)
    }
    try await Task.sleep(for: .seconds(1))
}
