// swift-tools-version: 6.0
// NovaAsrSherpa adapter (specs/ios-architecture.md §3.2; F-05a §12, F-08 §14): sherpa-onnx streaming ASR and keyword
// spotting. iOS binaries; built with xcodebuild, not on Linux. Run scripts/fetch_sherpa_libs.sh first: it fetches and
// checksums the xcframeworks into Frameworks/ (gitignored), which is why the binary targets use local paths.
import PackageDescription

let package = Package(
    name: "NovaAsrSherpa",
    platforms: [.iOS(.v18)],
    products: [.library(name: "NovaAsrSherpa", targets: ["NovaAsrSherpa"])],
    dependencies: [.package(path: "../NovaCore")],
    targets: [
        .binaryTarget(name: "SherpaOnnxBinary", path: "Frameworks/sherpa-onnx.xcframework"),
        .binaryTarget(name: "OnnxRuntimeBinary", path: "Frameworks/onnxruntime.xcframework"),
        // c-api.h of the pinned release (the xcframework ships no module map); the fetch script checks it matches.
        .target(name: "CSherpaOnnx"),
        .target(
            name: "NovaAsrSherpa",
            dependencies: [
                "CSherpaOnnx", "SherpaOnnxBinary", "OnnxRuntimeBinary",
                .product(name: "NovaKit", package: "NovaCore"),
                .product(name: "NovaPorts", package: "NovaCore"),
                .product(name: "NovaVoice", package: "NovaCore"),
            ],
            linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Foundation"), .linkedFramework("CoreML")]
        ),
        .testTarget(name: "NovaAsrSherpaTests", dependencies: [
            "NovaAsrSherpa",
            .product(name: "NovaKit", package: "NovaCore"),
            .product(name: "NovaPorts", package: "NovaCore"),
            .product(name: "NovaVoice", package: "NovaCore"),
        ]),
    ]
)
