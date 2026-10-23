// swift-tools-version: 6.0
// NovaServices adapter (specs/ios-architecture.md §3). Foundation only, testable on macOS and Linux.
import PackageDescription

let package = Package(
    name: "NovaServices",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "NovaServices", targets: ["NovaServices"])],
    dependencies: [.package(path: "../NovaCore")],
    targets: [
        .target(name: "NovaServices", dependencies: [
            .product(name: "NovaKit", package: "NovaCore"),
            .product(name: "NovaPorts", package: "NovaCore"),
        ]),
        .testTarget(name: "NovaServicesTests", dependencies: [
            "NovaServices",
            .product(name: "NovaAgent", package: "NovaCore"),
        ]),
    ]
)
