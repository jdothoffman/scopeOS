import Foundation
import NexStarSimulator
import ScopeKit

// Usage: swift run scopesim [--aux-port 2000] [--hc-port 2001] [--lan] [--tour] [--location <lat> <lon>]
//   --lan       listen on all interfaces instead of 127.0.0.1 only.
//   --tour      the mount tours Saturn, the Moon, Vega and Jupiter by itself instead of staying where it's moved.
//   --location  where the mount is (decimal degrees, east positive), for the RA/Dec the hand controller reports.

setvbuf(stdout, nil, _IOLBF, 0)

func option(_ name: String, default value: UInt16) -> UInt16 {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let port = UInt16(args[i + 1]) else { return value }
    return port
}

let loopbackOnly = !CommandLine.arguments.contains("--lan")
let touring = CommandLine.arguments.contains("--tour")
let mount = SimulatedMount(sky: touring ? SimulatedSky() : .parked(), focuser: true)
if let i = CommandLine.arguments.firstIndex(of: "--location"), i + 2 < CommandLine.arguments.count,
   let latitude = Double(CommandLine.arguments[i + 1]), let longitude = Double(CommandLine.arguments[i + 2]) {
    mount.setObserver(Observer(latitude: latitude, longitude: longitude))
}
let log: @Sendable (String) -> Void = { message in
    let time = Date().formatted(date: .omitted, time: .standard)
    print("[\(time)] \(message)")
}

// Both protocols describe the same mount: a move over one shows in the other.
let aux = try SimulatorServer(flavor: .aux, port: option("--aux-port", default: 2000), mount: mount, loopbackOnly: loopbackOnly)
let hc = try SimulatorServer(flavor: .handController, port: option("--hc-port", default: 2001), mount: mount, loopbackOnly: loopbackOnly)
aux.onEvent = log
hc.onEvent = log
try await aux.start()
try await hc.start()

let host = loopbackOnly ? "127.0.0.1" : "<this Mac's IP>"
print("""
Simulated Celestron mount running. Press Ctrl+C to stop.
  WiFi module (AUX protocol):       \(host):\(aux.port ?? 0)
  Hand controller (NexStar protocol): \(host):\(hc.port ?? 0)
\(touring ? "It cycles through Saturn, the Moon, Vega and Jupiter, slewing between them every \(Int(mount.sky.trackSeconds + mount.sky.slewSeconds)) s."
          : "It was switched on at its home position (level, pointing north) and stays put until moved.")
""")

while true {
    try await Task.sleep(for: .seconds(3600))
}
