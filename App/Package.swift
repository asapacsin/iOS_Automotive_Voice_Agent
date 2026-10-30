// swift-tools-version: 6.0
// xtool build of the device app on Windows/WSL (owner rule 2026-10-27: no macOS CI). Same sources and
// packages as project.yml; the AIKit wake SDK is a plain .framework SwiftPM cannot link, so this build has
// no wake word (`#if canImport(AIKIT)` is false). Build: `xtool dev build` in App/.
import PackageDescription

let package = Package(
    name: "NovaDrive",
    platforms: [.iOS(.v18)],
    products: [.library(name: "NovaDrive", targets: ["NovaDrive"])],
    dependencies: [
        .package(path: "../Packages/NovaCore"),
        .package(path: "../Packages/NovaServices"),
        .package(path: "../Packages/NovaAudio"),
        .package(path: "../Packages/NovaRealtime"),
        .package(path: "../Packages/NovaPlatform"),
        .package(path: "../Packages/NovaAsrSherpa"),
    ],
    targets: [
        .target(
            name: "NovaDrive",
            dependencies: [
                .product(name: "NovaKit", package: "NovaCore"),
                .product(name: "NovaPorts", package: "NovaCore"),
                .product(name: "NovaTools", package: "NovaCore"),
                .product(name: "NovaVoice", package: "NovaCore"),
                .product(name: "NovaNav", package: "NovaCore"),
                .product(name: "NovaAgent", package: "NovaCore"),
                .product(name: "NovaServices", package: "NovaServices"),
                .product(name: "NovaAudio", package: "NovaAudio"),
                .product(name: "NovaRealtime", package: "NovaRealtime"),
                .product(name: "NovaPlatform", package: "NovaPlatform"),
                .product(name: "NovaAsrSherpa", package: "NovaAsrSherpa"),
            ],
            path: "NovaDrive",
            // Bundled by project.yml as a folder resource; this xtool build does not carry the models yet
            // (no SherpaModels in Bundle.main, so the app falls back as §5 S3 / F-08 §14 item 8).
            exclude: ["SherpaModels"]
        ),
    ]
)
