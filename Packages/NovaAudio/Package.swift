// swift-tools-version: 6.0
// NovaAudio adapter (specs/ios-architecture.md §3). iOS frameworks; built with xcodebuild, not on Linux.
import PackageDescription

let package = Package(
    name: "NovaAudio",
    platforms: [.iOS(.v18)],
    products: [.library(name: "NovaAudio", targets: ["NovaAudio"])],
    dependencies: [.package(path: "../NovaCore")],
    targets: [
        .target(name: "NovaAudio", dependencies: [
            .product(name: "NovaKit", package: "NovaCore"),
            .product(name: "NovaPorts", package: "NovaCore"),
        ]),
    ]
)
