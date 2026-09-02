// swift-tools-version:5.10
import PackageDescription

// A measurement harness, not a product. It links WhisperKit so that
// `DecodingOptions.promptTokens` can be driven directly on Louis's own recordings,
// and MurmureCore so the audio reaching the model is the audio the app would have
// sent -- `SpeechGate`'s silence removal included. Nothing here is imported by
// Murmure; the dependency points one way.
//
// WhisperKit is pinned EXACTLY to the version the app resolves (1.1.0, verified with
// `git describe` on the app's own checkout). It has to be the same build: the
// measurement is only about Murmure if the decoder is Murmure's, and CoreML's
// compiled-artefact cache is keyed on the configuration that compiled it -- a
// different variant, `downloadBase` or `WhisperKit.init` would recompile the model
// for the ANE, which costs about seven minutes of pinned CPU on this machine.
let package = Package(
    name: "vocabprobe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
        .package(path: "../../MurmureCore"),
    ],
    targets: [
        // Reads the tokenizer only -- no decoding. Separate from `vocabprobe` so that
        // building it cannot relink a binary that may be mid-run.
        .executableTarget(
            name: "tokencount",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]
        ),
        .executableTarget(
            name: "vocabprobe",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MurmureCore", package: "MurmureCore"),
            ]
        )
    ]
)
