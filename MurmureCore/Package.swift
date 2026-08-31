// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MurmureCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MurmureCore", targets: ["MurmureCore"])],
    targets: [
        .target(name: "MurmureCore"),
        .testTarget(name: "MurmureCoreTests", dependencies: ["MurmureCore"], resources: [.copy("Fixtures")]),
    ]
)
