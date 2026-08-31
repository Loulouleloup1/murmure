import Foundation

/// A mode file that could not be used, and why. Reported one by one so the user can be told which
/// file to fix; the mode itself is skipped.
public enum ModeLoadProblem: Equatable, CustomStringConvertible {
    case directoryUnreadable(message: String)
    case unreadableFile(name: String, message: String)
    case malformedJSON(name: String, message: String)
    case invalidField(name: String, error: ModeValidationError)
    case keyDoesNotMatchFilename(name: String, key: String)

    public var description: String {
        switch self {
        case .directoryUnreadable(let message): "modes folder unreadable: \(message)"
        case .unreadableFile(let name, let message): "\(name): unreadable -- \(message)"
        case .malformedJSON(let name, let message): "\(name): not valid mode JSON -- \(message)"
        case .invalidField(let name, let error): "\(name): \(error)"
        case .keyDoesNotMatchFilename(let name, let key):
            "\(name): declares key \(key.debugDescription); rename the file or the key so they match"
        }
    }
}

/// Reads and writes `modes/*.json` (spec §7).
public struct ModeStore {
    private let directory: URL
    private let report: (ModeLoadProblem) -> Void

    /// `directory` is injected rather than resolved here so tests never reach the real
    /// `Application Support/Murmure/modes`; the app passes
    /// `Storage.appSupportDirectory(subfolder: "modes")`.
    ///
    /// `report` is not optional on purpose. `loadAll()` cannot throw -- one broken file may not
    /// stop the other modes from loading -- so the only way a skipped mode reaches anyone is this
    /// closure, and a store built without one would drop modes in silence.
    public init(directory: URL, report: @escaping (ModeLoadProblem) -> Void) {
        self.directory = directory
        self.report = report
    }

    /// Writes the built-in modes that are not on disk yet. Run at every launch, not only the
    /// first: a built-in deleted by hand comes back, which is how `voice.json` repairs itself.
    public func createBuiltInsIfMissing() throws {
        for mode in Mode.builtIns
        where !FileManager.default.fileExists(atPath: fileURL(for: mode.key).path) {
            try save(mode)
        }
    }

    /// Every usable mode on disk, ordered by key. Does not throw: one file Louis mistyped may not
    /// cost him the other three modes, so a bad file is reported through `report` and skipped.
    public func loadAll() -> [Mode] {
        var modes = fileNames().filter { $0.hasSuffix(".json") }.sorted().compactMap(load)

        // Spec §5 makes `Voice` the default mode. A typo in `voice.json` costs its edits, never
        // the ability to dictate -- so the built-in stands in until the file is fixed.
        if !modes.contains(where: { $0.key == Mode.voice.key }) {
            modes.append(Mode.voice)
            modes.sort { $0.key < $1.key }
        }
        return modes
    }

    /// Validates before writing: an invalid mode is never persisted, and the caller is told which
    /// field stopped it.
    public func save(_ mode: Mode) throws {
        try mode.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(mode).write(to: fileURL(for: mode.key), options: .atomic)
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    private func fileNames() -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            report(.directoryUnreadable(message: error.localizedDescription))
            return []
        }
    }

    private func load(_ name: String) -> Mode? {
        let data: Data
        do {
            data = try Data(contentsOf: directory.appendingPathComponent(name))
        } catch {
            report(.unreadableFile(name: name, message: error.localizedDescription))
            return nil
        }

        let mode: Mode
        do {
            mode = try JSONDecoder().decode(Mode.self, from: data)
        } catch {
            report(.malformedJSON(name: name, message: error.localizedDescription))
            return nil
        }

        // The file name is the key (spec §5). Copying a mode file without changing the key inside
        // gives two files claiming one mode, and whichever loads last wins in silence.
        guard name == "\(mode.key).json" else {
            report(.keyDoesNotMatchFilename(name: name, key: mode.key))
            return nil
        }
        if let error = mode.validationError {
            report(.invalidField(name: name, error: error))
            return nil
        }
        return mode
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // The file is meant to be opened in a text editor: indented, and with `/` left alone so
        // an endpoint reads `http://localhost:11434` and not `http:\/\/localhost:11434`.
        // `.sortedKeys` for a file that is diffed and re-read: without it Foundation writes the
        // keys in hash order, so re-saving an unchanged mode reshuffles the whole file.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
