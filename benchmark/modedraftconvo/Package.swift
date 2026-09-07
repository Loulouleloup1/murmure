// swift-tools-version:5.10
import PackageDescription

// A one-shot network-verification harness for the mode-drafting lot -- not a product, and not run
// by `swift test`. Links only MurmureCore (no WhisperKit: this lot never touches a speech model),
// so the system prompt built and the reply read back are the SAME `ModeDraftSystemPrompt` /
// `ModeDraftExtraction` the app itself uses. Gated by `MURMURE_NETWORK_TESTS=1` -- see
// `Sources/modedraftconvo/main.swift`.
let package = Package(
    name: "modedraftconvo",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../MurmureCore"),
    ],
    targets: [
        .executableTarget(
            name: "modedraftconvo",
            dependencies: [
                .product(name: "MurmureCore", package: "MurmureCore"),
            ]
        )
    ]
)
