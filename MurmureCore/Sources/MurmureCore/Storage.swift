import Foundation

/// Where Murmure keeps what it owns: `Application Support/Murmure/<subfolder>`.
///
/// Computing a path and creating a folder are two functions on purpose, and the next store added
/// here has to pick one. `url(subfolder:)` is pure: it can be called to compare, display or assert
/// a path, and it cannot reach the disk. `directory(subfolder:)` is the only thing in this file
/// that creates, so a caller that is about to write has to say so in the name it calls.
///
/// The split is not hygiene, it is a bug that was live: a single function that created on every
/// call meant a test merely ASKING for a path was building folders inside the one holding Louis's
/// real recordings -- and it stops being harmless the instant a test written in the same shape
/// opens a database there.
///
/// `base` is injectable for the same reason. A test that must prove creation creates under
/// `NSTemporaryDirectory()`; without the parameter, `directory(subfolder:)` could only ever be
/// exercised against the real folder, which is exactly what may not happen.
public enum Storage {
    /// The path, computed. Creates nothing, and must stay that way.
    ///
    /// `isDirectory: true` is not decoration. The one-argument `appendingPathComponent` STATS the
    /// path to decide whether to write a trailing slash, so without it this function reads the
    /// disk and answers `.../history` before the folder exists and `.../history/` after -- two
    /// unequal URLs for one location, which is measured: it is what the equality test caught.
    public static func url(subfolder: String, in base: URL = applicationSupport) -> URL {
        base.appendingPathComponent("Murmure", isDirectory: true)
            .appendingPathComponent(subfolder, isDirectory: true)
    }

    /// The same path, with the folder and its parents created. For callers that are about to write.
    public static func directory(
        subfolder: String,
        in base: URL = applicationSupport
    ) throws -> URL {
        let directory = url(subfolder: subfolder, in: base)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `~/Library/Application Support`, resolved without touching the disk.
    ///
    /// `FileManager.url(for:in:appropriateFor:create:)` is deliberately not used: it is the
    /// throwing, creating API -- the old code passed it `create: true`, which is how asking for a
    /// path came to build folders. The fallback is not a recovery path; it is what makes this
    /// total, so `url(subfolder:)` can stay non-throwing.
    public static let applicationSupport: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
}
