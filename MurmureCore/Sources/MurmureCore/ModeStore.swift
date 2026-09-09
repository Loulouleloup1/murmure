import Foundation

/// A mode file that could not be used, and why. Reported one by one so the user can be told which
/// file to fix; the mode itself is skipped.
public enum ModeLoadProblem: Equatable, CustomStringConvertible {
    case directoryUnreadable(message: String)
    case unreadableFile(name: String, message: String)
    case malformedJSON(name: String, message: String)
    case invalidField(name: String, error: ModeValidationError)
    case keyDoesNotMatchFilename(name: String, key: String)
    /// `stt.model` is neither a full `SpeechModelReference` nor a bare variant name the migration
    /// can complete on its own (``ModeStore/STTModelMigration/unresolvable(_:)``) -- most often a
    /// two-component `"owner/name"` with no variant. The mode still loads; this is a warning, not
    /// a rejection, and dictation for it falls back to `SpeechModelReference.shippedDefault` until
    /// the field is corrected by hand.
    case sttModelNotAReference(name: String, stored: String)
    /// A mode's `stt.model` was migrated in memory but the write to disk failed -- a read-only
    /// modes folder, most often. The mode still loads and dictates correctly on the migrated value
    /// for this launch; only the file stays stale, and the next launch that can write tries again.
    case sttModelMigrationNotSaved(name: String, message: String)

    public var description: String {
        switch self {
        case .directoryUnreadable(let message): "modes folder unreadable: \(message)"
        case .unreadableFile(let name, let message): "\(name): unreadable -- \(message)"
        case .malformedJSON(let name, let message): "\(name): not valid mode JSON -- \(message)"
        case .invalidField(let name, let error): "\(name): \(error)"
        case .keyDoesNotMatchFilename(let name, let key):
            "\(name): declares key \(key.debugDescription); rename the file or the key so they match"
        case .sttModelNotAReference(let name, let stored):
            """
            \(name): "stt.model" \(stored.debugDescription) is not a speech model reference \
            (owner/name/variant); the mode keeps it, dictation falls back to the shipped model.
            """
        case .sttModelMigrationNotSaved(let name, let message):
            "\(name): \"stt.model\" was migrated in memory but the file could not be updated -- \(message)"
        }
    }
}

/// Why an edited mode was not written. Distinct from `ModeValidationError`, which is about the
/// mode; these two are about the folder, and neither is fixable by changing a field.
public enum ModeWriteProblem: Error, Equatable, CustomStringConvertible {
    case fileChangedOnDisk(key: String)
    case keyAlreadyInUse(key: String)
    /// A built-in mode's file was asked to be deleted -- see `Mode.isProtected`.
    case protectedMode(key: String)

    public var description: String {
        switch self {
        case .fileChangedOnDisk(let key):
            """
            \(key).json was edited outside Murmure while this mode was open. Nothing was written. \
            Close the editor and open it again to see the file as it is now.
            """
        case .keyAlreadyInUse(let key):
            "another mode already uses the file name \(key).json. Pick a different key."
        case .protectedMode(let key):
            "\"\(key)\" is built in and cannot be deleted"
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

    /// Voice is repaired at every launch. Prompt is an example: seeded once, into a directory that
    /// has never held any mode, and never again -- deleting it must stick. The marker records that
    /// seeding happened; a directory that already has modes but no marker is an install from
    /// before this rule and is marked without seeding.
    public func createBuiltInsIfMissing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hadModes = !fileNames().filter { $0.hasSuffix(".json") }.isEmpty
        if !FileManager.default.fileExists(atPath: seededMarkerURL.path) {
            if !hadModes { try save(Mode.prompt) }
            try Data().write(to: seededMarkerURL, options: .atomic)
        }
        if !FileManager.default.fileExists(atPath: fileURL(for: Mode.voice.key).path) {
            try save(Mode.voice)
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
    /// 1. the mode is invalid — `Mode.editorValidationError(original:)`, naming the field;
    /// 2. the file changed under the editor since it was opened;
    /// 3. the destination file belongs to another mode.
    ///
    /// Only then is anything written. The new file is written **before** the old one is removed:
    /// a failure between the two leaves two files, which `loadAll()` shows as two modes and which
    /// is repairable; the other order loses the mode outright.
    public func save(_ draft: ModeDraft) throws {
        if let error = draft.mode.editorValidationError(original: draft.original) { throw error }

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
        // The ORIGINAL, not the edited copy: `key` is one of the fields Voice must keep, so
        // editing it away and then deleting would un-flag `isProtected` on `draft.mode` while
        // `draft.previousKey` still points at `voice.json` -- the same laundering
        // `editorValidationError` refuses on save, but for the file this removes.
        if draft.original.isProtected {
            throw ModeWriteProblem.protectedMode(key: draft.original.key)
        }
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

    /// Records that `createBuiltInsIfMissing` has already decided whether to seed Prompt -- so a
    /// second launch never reseeds it after it was deleted on purpose.
    private var seededMarkerURL: URL {
        directory.appendingPathComponent(".seeded")
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

        var mode: Mode
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

        // Before `validationError`, deliberately: a blank `stt.model` is one of the shapes this
        // rewrites, and `Mode.validate()` refuses a blank field outright (`.emptySTTModel`). Left
        // until after, a hand-cleared field would be reported as broken instead of repaired.
        //
        // Only the IN-MEMORY value is touched here. The write, when there is one, happens below
        // -- after `validationError`, not before -- so a mode that fails validation on some other
        // field (an invalid `llm.endpoint`, say) and is about to be reported and skipped never has
        // its file rewritten first. A rewritten-then-discarded mode would leave the migrated
        // `stt.model` on disk for a mode `loadAll()` is telling the caller does not exist.
        let migration = Self.classifySTTModel(mode.stt.model)
        switch migration {
        case .noChange:
            break
        case .migrate(let migrated):
            mode.stt.model = migrated
        case .unresolvable(let stored):
            // Neither a full reference nor a bare variant this migration knows how to complete
            // (`classifySTTModel`'s own doc comment has the shapes) -- left exactly as written,
            // never guessed at, and reported so it does not fail silently. The mode still loads:
            // this is not `Mode.validate()`'s business, and `stt.model` being unresolvable does not
            // make the rest of the mode unusable.
            report(.sttModelNotAReference(name: name, stored: stored))
        }

        if let error = mode.validationError {
            report(.invalidField(name: name, error: error))
            return nil
        }

        if case .migrate = migration {
            writeMigratedSTTModel(mode, fileName: name)
        }
        return mode
    }

    /// Writes a mode whose `stt.model` ``load(_:)`` just migrated in memory. Called only after
    /// `validationError` has already passed, so this never rewrites a file for a mode that is
    /// about to be reported invalid and skipped.
    ///
    /// **Best-effort.** The migrated value already stands in `mode`, in memory, regardless of
    /// whether this write succeeds -- so a read-only modes folder still dictates correctly for
    /// this launch, on the resolved model rather than the stale alias. It is only the on-disk copy
    /// that stays stale, and the next launch that CAN write tries again. This mirrors
    /// ``SpeechModelResolution``'s own stance: resolving what a file means must never depend on
    /// being able to write it back. A failure here is not swallowed, though -- unlike the earlier
    /// `try?` version of this method, it is reported through the same `report` channel every other
    /// load problem goes through, once per load, so a modes folder that has gone read-only says so
    /// instead of silently never catching up.
    ///
    /// **One more consequence of writing through `Self.encoder`, worth stating rather than
    /// discovering later.** This is the same encoder `save(_ draft:)` uses, and it always encodes
    /// every field `Mode`/`LLM` currently declare -- so the FIRST migrating write to a file also
    /// normalises it to the encoder's current shape: a `voice.json` written before `api` existed on
    /// `LLM` (`LLM.init(from:)`'s own doc comment) gains an explicit `"api" : "chat"` it did not
    /// carry before, the same way any `save()` from the editor already would. Not a migration
    /// side effect -- the same thing happens whenever ANY field on an old file is edited and saved.
    private func writeMigratedSTTModel(_ mode: Mode, fileName: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(mode).write(to: directory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            report(.sttModelMigrationNotSaved(name: fileName, message: error.localizedDescription))
        }
    }

    /// What a stored `stt.model` needs, decided once and used both to change `mode` in memory and
    /// to decide whether `writeMigratedSTTModel` runs at all.
    enum STTModelMigration: Equatable {
        /// Already a full reference (``SpeechModelReference/init(parsing:)`` parsed it) -- nothing
        /// to do.
        case noChange
        /// Rewrite `stt.model` to this string, in memory and (once validation passes) on disk.
        case migrate(String)
        /// Neither a full reference nor a single bare variant name -- most often a two-component
        /// `"owner/name"` with no variant, which this migration must not complete by guessing a
        /// third segment: that would silently turn a hand-typed value nobody asked to change into
        /// a *different* model reference. Left untouched; `stored` is what gets reported.
        case unresolvable(String)
    }

    /// Classifies a stored `stt.model` into what ``load(_:)`` should do with it, by reading
    /// ``StoredSTTModelShape`` -- the SAME classification `SpeechModelResolution.reference` reads,
    /// so this migration and the engine's own fallback cannot silently disagree about which shape
    /// a stored string is (that type's own doc comment has the defect this shared reading fixes).
    ///
    /// What each shape becomes:
    /// 1. Blank, or the legacy alias -- becomes ``SpeechModelReference/shippedDefault``.
    /// 2. A full reference already -- `.noChange`.
    /// 3. A bare variant folder with no repository at all (`openai_whisper-tiny`, something typed
    ///    by hand before this migration existed) -- assumed to live in the shipped default's own
    ///    repository, `argmaxinc/whisperkit-coreml`. That assumption is the one every mode file in
    ///    the wild already makes implicitly: every variant a mode has ever named by hand has come
    ///    from that one repository, because installing from another one is a later lot's feature.
    /// 4. Unresolvable (in practice, a two-component `"owner/name"` with no variant) -- `stored` is
    ///    left exactly as written and reported, never guessed at.
    static func classifySTTModel(_ stored: String) -> STTModelMigration {
        switch StoredSTTModelShape.classify(stored) {
        case .blankOrLegacyAlias:
            return .migrate(SpeechModelReference.shippedDefault.string)
        case .reference:
            return .noChange
        case .bareVariant(let variant):
            return .migrate(SpeechModelReference(
                repository: SpeechModelReference.shippedDefault.repository, variant: variant
            ).string)
        case .unresolvable(let stored):
            return .unresolvable(stored)
        }
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
