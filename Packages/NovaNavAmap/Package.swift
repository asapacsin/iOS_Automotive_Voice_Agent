// swift-tools-version: 6.0
// NovaNavAmap adapter (specs/ios-architecture.md §3). iOS frameworks; built with xcodebuild, not on Linux.
import PackageDescription

let package = Package(
    name: "NovaNavAmap",
    platforms: [.iOS(.v18)],
    products: [.library(name: "NovaNavAmap", targets: ["NovaNavAmap"])],
    dependencies: [.package(path: "../NovaCore")],
    targets: [
        .target(name: "NovaNavAmap", dependencies: [
            .product(name: "NovaKit", package: "NovaCore"),
            .product(name: "NovaPorts", package: "NovaCore"),
        ]),
    ]
)
