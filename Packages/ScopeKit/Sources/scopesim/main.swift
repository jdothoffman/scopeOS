import Foundation
import NexStarSimulator

// Usage: swift run scopesim [--aux-port 2000] [--hc-port 2001] [--lan]
//   --lan  listen on all interfaces instead of 127.0.0.1 only.

setvbuf(stdout, nil, _IOLBF, 0)

func option(_ name: String, default value: UInt16) -> UInt16 {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let port = UInt16(args[i + 1]) else { return value }
    return port
}

let loopbackOnly = !CommandLine.arguments.contains("--lan")
let sky = SimulatedSky()
let log: @Sendable (String) -> Void = { message in
    let time = Date().formatted(date: .omitted, time: .standard)
    print("[\(time)] \(message)")
}

let aux = try SimulatorServer(flavor: .aux, port: option("--aux-port", default: 2000), sky: sky, loopbackOnly: loopbackOnly, focuser: true)
let hc = try SimulatorServer(flavor: .handController, port: option("--hc-port", default: 2001), sky: sky, loopbackOnly: loopbackOnly)
aux.onEvent = log
hc.onEvent = log
try await aux.start()
try await hc.start()

let host = loopbackOnly ? "127.0.0.1" : "<this Mac's IP>"
print("""
Simulated Celestron mount running. Press Ctrl+C to stop.
  WiFi module (AUX protocol):       \(host):\(aux.port ?? 0)
  Hand controller (NexStar protocol): \(host):\(hc.port ?? 0)
It cycles through Saturn, the Moon, Vega and Jupiter, slewing between them every \(Int(sky.trackSeconds + sky.slewSeconds)) s.
""")

while true {
    try await Task.sleep(for: .seconds(3600))
}
