// swift-tools-version:5.10
import PackageDescription

// Throwaway feasibility spike (see spike-longform report) measuring how WhisperKit handles a
// 40-60 minute French audio file with the owner's already-compiled turbo model. Not a product,
// not run by `swift test`, no MurmureCore dependency (raw WhisperKit transcribe API only).
//
// WhisperKit pinned EXACTLY to 1.1.0 -- the version actually resolved by Murmure.xcodeproj's own
// Package.resolved (verified against project.xcworkspace/xcshareddata/swiftpm/Package.resolved
// and `git describe` on the .build/xcode/SourcePackages/checkouts/WhisperKit checkout, both
// v1.1.0). The spike brief assumed 1.7.0; that is not what this project has resolved.
let package = Package(
    name: "longform",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "longform",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        )
    ]
)
