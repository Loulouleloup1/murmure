// swift-tools-version:5.10
import PackageDescription

// A one-shot network-verification harness for lot "Add a model" -- not a product, and not run by
// `swift test`. It links WhisperKit so `WhisperKit.download(variant:downloadBase:from:)` can be
// exercised against a real temporary directory (never `models/`), and MurmureCore so the pull and
// delete requests it sends are the same `OllamaPull`/`OllamaDelete` types the app itself builds.
// Gated by `MURMURE_NETWORK_TESTS=1` -- see `Sources/modelnettest/main.swift`.
//
// WhisperKit pinned EXACTLY to 1.1.0, the same reasoning `benchmark/vocabprobe/Package.swift`
// gives for its own pin: this has to be the same build the app resolves, or a download here says
// nothing about the download the app actually performs.
let package = Package(
    name: "modelnettest",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
        .package(path: "../../MurmureCore"),
    ],
    targets: [
        .executableTarget(
            name: "modelnettest",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MurmureCore", package: "MurmureCore"),
            ]
        )
    ]
)
