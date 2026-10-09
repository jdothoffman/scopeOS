// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScopeKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ScopeKit", targets: ["ScopeKit"]),
        .library(name: "NexStarSimulator", targets: ["NexStarSimulator"]),
        .executable(name: "scopesim", targets: ["scopesim"]),
        .executable(name: "scopeos-cli", targets: ["scopeos-cli"]),
        .library(name: "ScopeCapture", targets: ["ScopeCapture"]),
        .executable(name: "scopecap", targets: ["scopecap"]),
    ],
    targets: [
        .target(name: "ScopeKit", resources: [.process("Resources")]),
        .target(name: "NexStarSimulator", dependencies: ["ScopeKit"]),
        .executableTarget(name: "scopesim", dependencies: ["NexStarSimulator"]),
        .executableTarget(name: "scopeos-cli", dependencies: ["ScopeKit"]),
        .target(name: "CUVC", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "ScopeCapture", dependencies: ["ScopeKit", "CUVC"]),
        .executableTarget(name: "scopecap", dependencies: ["ScopeCapture", "ScopeKit"]),
        .testTarget(name: "ScopeKitTests", dependencies: ["ScopeKit", "NexStarSimulator", "ScopeCapture"]),
    ]
)
