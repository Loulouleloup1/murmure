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

/// Why an edited mode was not written. Distinct from `ModeValidationError`, which is about the
/// mode; these two are about the folder, and neither is fixable by changing a field.
public enum ModeWriteProblem: Error, Equatable, CustomStringConvertible {
    case fileChangedOnDisk(key: String)
    case keyAlreadyInUse(key: String)

    public var description: String {
        switch self {
        case .fileChangedOnDisk(let key):
            """
            \(key).json was edited outside Murmure while this mode was open. Nothing was written. \
            Close the editor and open it again to see the file as it is now.
            """
        case .keyAlreadyInUse(let key):
            "another mode already uses the file name \(key).json. Pick a different key."
        }
    }
}

/// Reads and writes `modes/*.json` (spec §7).
public struct ModeStore {
    private let directory: URL
    private let report: (ModeLoadProblem) -> Void

    /// `directory` is injected rather than resolved here so tests never reach the real
    /// `Application Support/Murmure/modes`; the app passes
    /// `Storage.directory(subfolder: "modes")`.
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

    // MARK: - Editing

    /// When a mode's file was last written, or nil if there is none.
    ///
    /// Read at the moment the editor opens a mode and handed back on save (``ModeDraft``). The
    /// pane re-reads the folder every time it appears, the way `DictationController.refreshModes()`
    /// already does, but "appears" is not "is on screen": the window can sit open on this pane for
    /// an hour while the same file is edited in a text editor.
    public func modificationDate(forKey key: String) -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: fileURL(for: key).path)[.modificationDate] as? Date
    }

    /// Writes an edited mode, moving its file if its key changed.
    ///
    /// Three refusals, in the order they can be told apart:
    ///
    /// 1. the mode is invalid — `Mode.validate()`, naming the field;
    /// 2. the file changed under the editor since it was opened;
    /// 3. the destination file belongs to another mode.
    ///
    /// Only then is anything written. The new file is written **before** the old one is removed:
    /// a failure between the two leaves two files, which `loadAll()` shows as two modes and which
    /// is repairable; the other order loses the mode outright.
    public func save(_ draft: ModeDraft) throws {
        try draft.mode.validate()

        // A file that is *gone* is not a conflict. The guard is here to keep an edit made in a
        // text editor from being overwritten, and a deleted file has no edit to lose -- while
        // refusing would strand whatever is in the editor with nowhere left to put it. A file that
        // appeared where there was none still counts, which is the case that matters: `loadAll()`
        // stands the built-in `Voice` in when `voice.json` is missing, so that mode can be opened
        // with no file behind it and someone else may write one meanwhile.
        if let previousKey = draft.previousKey,
           let onDisk = modificationDate(forKey: previousKey),
           onDisk != draft.previousModifiedAt {
            throw ModeWriteProblem.fileChangedOnDisk(key: previousKey)
        }

        let destination = fileURL(for: draft.mode.key)
        // Also what refuses a rename that only changes the key's case. The volume is very likely
        // case-insensitive, so `Voice.json` and `voice.json` are one file: allowing it would write
        // the mode and then delete it under its old name, which is the same file. Refusing costs
        // a rename nobody needs; the alternative loses the mode.
        if draft.mode.key != draft.previousKey,
           FileManager.default.fileExists(atPath: destination.path) {
            throw ModeWriteProblem.keyAlreadyInUse(key: draft.mode.key)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(draft.mode).write(to: destination, options: .atomic)

        if draft.movesItsFile, let previousKey = draft.previousKey {
            try FileManager.default.removeItem(at: fileURL(for: previousKey))
        }
    }

    /// Removes a mode's file.
    ///
    /// Takes the **draft**, not a key, so it carries the same modification date `save(_ draft:)`
    /// checks — and refuses on the same `fileChangedOnDisk`. The asymmetry that would otherwise
    /// exist is the wrong way round: the reversible path would be guarded and the irreversible one
    /// not, so opening the editor, correcting `prompt.json` by hand, coming back and pressing
    /// Delete would destroy that correction without a word, where pressing Save would have been
    /// refused.
    ///
    /// A file that is **already gone** is not an error: the outcome asked for is the outcome that
    /// holds, and reporting a failure for it would make the pane complain about having nothing
    /// left to do. What that leaves is `removeItem` throwing only for a real refusal, which is
    /// then shown.
    public func delete(_ draft: ModeDraft) throws {
        guard let key = draft.previousKey else { return }

        let url = fileURL(for: key)
        guard let onDisk = modificationDate(forKey: key) else { return }
        if onDisk != draft.previousModifiedAt {
            throw ModeWriteProblem.fileChangedOnDisk(key: key)
        }
        try FileManager.default.removeItem(at: url)
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
