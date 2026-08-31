import Foundation

public enum Storage {
    /// Application Support/Murmure/<subfolder>, created on demand.
    public static func appSupportDirectory(subfolder: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Murmure").appendingPathComponent(subfolder)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
