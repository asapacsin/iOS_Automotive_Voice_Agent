// swift-tools-version: 6.0
// NovaWakeIflytek adapter (specs/ios-architecture.md §3). iOS frameworks; built with xcodebuild, not on Linux.
import PackageDescription

let package = Package(
    name: "NovaWakeIflytek",
    platforms: [.iOS(.v18)],
    products: [.library(name: "NovaWakeIflytek", targets: ["NovaWakeIflytek"])],
    dependencies: [.package(path: "../NovaCore")],
    targets: [
        .target(name: "NovaWakeIflytek", dependencies: [
            .product(name: "NovaKit", package: "NovaCore"),
            .product(name: "NovaPorts", package: "NovaCore"),
            .product(name: "NovaVoice", package: "NovaCore"),
        ]),
    ]
)
