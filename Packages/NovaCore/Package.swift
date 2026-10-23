// swift-tools-version: 6.0
// NovaCore: pure product logic. Foundation and Synchronization only (specs/ios-architecture.md §3).
import PackageDescription

let package = Package(
    name: "NovaCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "NovaKit", targets: ["NovaKit"]),
        .library(name: "NovaPorts", targets: ["NovaPorts"]),
        .library(name: "NovaVoice", targets: ["NovaVoice"]),
        .library(name: "NovaTools", targets: ["NovaTools"]),
        .library(name: "NovaNav", targets: ["NovaNav"]),
        .library(name: "NovaAgent", targets: ["NovaAgent"]),
    ],
    targets: [
        .target(name: "NovaKit"),
        .target(name: "NovaPorts", dependencies: ["NovaKit"]),
        .target(name: "NovaVoice", dependencies: ["NovaKit", "NovaPorts"]),
        .target(name: "NovaTools", dependencies: ["NovaKit", "NovaPorts"]),
        .target(name: "NovaNav", dependencies: ["NovaKit", "NovaPorts"]),
        .target(name: "NovaAgent", dependencies: ["NovaKit", "NovaPorts", "NovaVoice", "NovaTools", "NovaNav"]),
        .testTarget(name: "NovaKitTests", dependencies: ["NovaKit"]),
        .testTarget(name: "NovaPortsTests", dependencies: ["NovaKit", "NovaPorts"]),
        .testTarget(name: "NovaToolsTests", dependencies: ["NovaKit", "NovaPorts", "NovaTools"]),
        .testTarget(name: "NovaVoiceTests", dependencies: ["NovaKit", "NovaPorts", "NovaVoice"]),
    ]
)
