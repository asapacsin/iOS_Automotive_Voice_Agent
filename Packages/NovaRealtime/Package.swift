// swift-tools-version: 6.0
// NovaRealtime adapter (specs/ios-architecture.md §3). Foundation only, testable on macOS and Linux.
import PackageDescription

let package = Package(
    name: "NovaRealtime",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "NovaRealtime", targets: ["NovaRealtime"])],
    dependencies: [.package(path: "../NovaCore")],
    targets: [
        .target(name: "NovaRealtime", dependencies: [
            .product(name: "NovaKit", package: "NovaCore"),
            .product(name: "NovaPorts", package: "NovaCore"),
        ]),
        .testTarget(name: "NovaRealtimeTests", dependencies: ["NovaRealtime"], exclude: []),
    ]
)
