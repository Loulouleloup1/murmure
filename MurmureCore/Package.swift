// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MurmureCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MurmureCore", targets: ["MurmureCore"])],
    dependencies: [
        // MurmureCore's first dependency (lot 4 D5), and pinned EXACTLY for the reason
        // `project.yml` already gives DynamicNotchKit. History is a schema, a migrator and an FTS5
        // index whose behaviour IS the feature: a minor bump that changed how a migration is
        // recorded, or what `synchronize(withTable:)` writes into the external-content triggers,
        // would move Louis's archive without a line of Murmure changing. 7.11.1 is the current
        // stable tag (7.11.x line; the 7.0.0-beta series is behind it) -- picked because it is the
        // newest release with no pre-release qualifier, and because 7.x is where
        // `FTS5.Diacritics.remove` (`remove_diacritics 2`, §5.2) is available.
        // MIT.
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "MurmureCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        // The test target links GRDB directly so `HistoryStoreTests` can open the same file on a
        // second connection and read `sqlite_master`, the raw `startedAt` text and the FTS index
        // itself. Asserting the schema through a hole cut in `HistoryStore` would mean shipping
        // three introspection methods nothing but a test ever calls.
        .testTarget(
            name: "MurmureCoreTests",
            dependencies: ["MurmureCore", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
