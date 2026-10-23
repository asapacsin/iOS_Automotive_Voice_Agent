// swift-tools-version: 6.0
// NovaPlatform adapter (specs/ios-architecture.md §3). iOS frameworks; built with xcodebuild, not on Linux.
import PackageDescription

let package = Package(
    name: "NovaPlatform",
    platforms: [.iOS(.v18)],
    products: [.library(name: "NovaPlatform", targets: ["NovaPlatform"])],
    dependencies: [.package(path: "../NovaCore")],
    targets: [
        .target(name: "NovaPlatform", dependencies: [
            .product(name: "NovaKit", package: "NovaCore"),
            .product(name: "NovaPorts", package: "NovaCore"),
        ]),
    ]
)
