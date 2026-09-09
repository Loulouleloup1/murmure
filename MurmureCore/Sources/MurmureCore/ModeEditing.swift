import Foundation

/// One input in the mode editor, so a validation error can be drawn under the field that caused it.
///
/// The reason this enum exists rather than a banner at the top of the editor: `ModeStore` reports
/// a broken *file* to someone who will open a text editor, and a sentence naming `"llm.endpoint"`
/// is exactly right for that reader. In the editor the field is already on screen — repeating its
/// JSON path in a banner asks the reader to map one to the other, and it is the same mistake as
/// "invalid mode" one level up.
///
/// Seven cases for ten errors: `key` owns two, `llmEndpoint` two, `instructions` two.
public enum ModeField: String, CaseIterable, Sendable {
    /// The file name. Edited on the advanced screen, not in the basic editor — see ``ModeDraft``.
    case key
    case name
    case sttModel
    case sttLanguage
    /// The advanced screen too: an endpoint is machinery, and it is right for every mode until
    /// Ollama moves.
    case llmEndpoint
    case llmModel
    case instructions
}

/// The two screens of the editor, in the ladder the doc corpus shows: what a mode *is*, then the
/// machinery underneath it.
public enum ModeEditorScreen: String, CaseIterable, Sendable {
    /// The inline expansion of the row.
    case basic
    /// Pushed over the pane, with the sidebar left in place.
    case advanced
}

extension ModeField {
    /// Which screen this input is on.
    ///
    /// In `MurmureCore` and not in the view, because the editor has a rule that depends on it: an
    /// error belongs under its own input, and when that input is on the *other* screen the basic
    /// editor has to say so beside the button that leads there. A screen split written into the
    /// view would leave that rule reading a layout instead of a decision.
    ///
    /// `key` and `llmEndpoint` are the two advanced ones. Both are true machinery and both are
    /// right by default — the key is derived when the mode is created and the endpoint is Ollama's
    /// root for every mode there will ever be — while the five basic ones are the mode itself.
    public var screen: ModeEditorScreen {
        switch self {
        case .key, .llmEndpoint: .advanced
        case .name, .sttModel, .sttLanguage, .llmModel, .instructions: .basic
        }
    }
}

extension ModeValidationError {
    /// The input this error belongs under.
    ///
    /// Written **without a `default`**, the same guarantee `WindowSection` makes: a validation
    /// case added to `Mode` must fail to compile until someone has said where the editor shows it.
    /// A `default` would send it to an arbitrary field, under an input that is not the one to fix.
    public var field: ModeField {
        switch self {
        case .emptyKey, .keyIsNotFilenameSafe: .key
        case .emptyName: .name
        case .emptySTTModel: .sttModel
        case .emptySTTLanguage: .sttLanguage
        case .invalidLLMEndpoint, .llmEndpointIsNotARoot: .llmEndpoint
        case .emptyLLMModel: .llmModel
        case .emptyInstructions, .instructionsAreNotControlFields: .instructions
        // These two are `editorValidationError`'s, not `Mode.validationError`'s -- `ModeDraft`
        // still reads the latter here, so neither is reachable through this property today. The
        // mapping exists only to keep this switch exhaustive per its own rule above. Tasks 5-6 of
        // this lot route `.protectedField` and `.refinerRequired` to their own places in the
        // editor -- the Identity card and the Refiner card respectively -- rather than under a
        // `ModeField`; the mapping here is a placeholder until then, not the real destination.
        case .protectedField: .name
        case .refinerRequired: .instructions
        }
    }
}

/// A mode being edited: the working copy, and what it was before.
///
/// The whole editor is this struct plus a `ModeStore`. It carries two things the mode itself
/// cannot:
///
/// - **`previousKey`** — the key doubles as the file name, so a key that changed is a file that
///   has to move, and one that did not is a file to overwrite in place. A save that only ever
///   wrote `<key>.json` would leave the old file behind on every rename, and `ModeStore.loadAll()`
///   would then read the mode twice.
/// - **`previousModifiedAt`** — the same files are edited by hand while the window is open (the
///   whole point of `ModeStore`'s hand-editable shape). A window holding a mode read ten minutes
///   ago would overwrite an edit made in the meantime, silently, and a prompt someone wrote by
///   hand is the one loss in this pane that cannot be undone.
public struct ModeDraft: Equatable {
    /// The edited mode. Mutable: this is what the fields are bound to.
    public var mode: Mode

    /// The mode as the editor opened it — the file's contents, or the preset's. What "unsaved
    /// changes" is measured against, and the only reason it is kept.
    public let original: Mode

    /// The key the mode was opened under, or nil when it is being created.
    public let previousKey: String?

    /// The modification date of the file when it was opened, or nil when there was no file.
    public let previousModifiedAt: Date?

    /// Opens an existing mode for editing. `modifiedAt` comes from
    /// ``ModeStore/modificationDate(forKey:)``, read at the same moment the mode was.
    public init(editing mode: Mode, modifiedAt: Date?) {
        self.mode = mode
        original = mode
        previousKey = mode.key
        previousModifiedAt = modifiedAt
    }

    /// Opens a new mode, which has no file yet and therefore nothing to move or to clash with.
    public init(creating mode: Mode) {
        self.mode = mode
        original = mode
        previousKey = nil
        previousModifiedAt = nil
    }

    /// Whether closing this editor would lose something.
    ///
    /// A whole-object comparison, so a field typed and typed back reads as unchanged — which is
    /// what stops the guard below from asking about work nobody did.
    public var hasUnsavedChanges: Bool { mode != original }

    /// The dialog for a loss the *app* is about to cause, as opposed to the one
    /// ``ModeStore/save(_:)`` refuses because the disk moved.
    ///
    /// Shown only for an **implicit** close — opening another row, pressing `+`. An explicit
    /// Cancel is not asked about: it already says discard, and a dialog confirming a button whose
    /// whole meaning is "throw this away" is the kind that teaches someone to click through the
    /// next one.
    public var discardConfirmation: ConfirmationPrompt {
        ConfirmationPrompt(
            title: previousKey == nil
                ? "Discard the new mode?"
                : "Discard the changes to \u{201C}\(original.name)\u{201D}?",
            message: previousKey == nil
                ? "Nothing has been written to the modes folder yet, so what is in the editor is "
                    + "all there is of this mode."
                : "modes/\(original.key).json is untouched on disk; the edits made here have not "
                    + "reached it.",
            confirmTitle: "Discard",
            cancelTitle: "Keep Editing")
    }

    /// The first field that is wrong, or nil — `Mode`'s own rule, reused rather than restated.
    ///
    /// **The first**, not all of them, and that is `Mode.validationError`'s shape rather than a
    /// choice made here. It matters for one case: the editor shows one message at a time, so an
    /// empty `key` on the advanced screen hides an empty `name` in the basic one until it is
    /// fixed. Accepted, because the alternative is validating seven variants of the mode to
    /// collect errors the reader will meet one at a time anyway, and because `key` and `endpoint`
    /// — the two fields that are not in front of the reader — are the two the editor never leaves
    /// invalid on its own: it derives the key and inherits the endpoint.
    public var validationError: ModeValidationError? { mode.validationError }

    /// The message to draw under `field`, or nil.
    ///
    /// The error's own `description` verbatim. It names the JSON path (`"llm.endpoint"`) even
    /// though the field is on screen, and that is deliberate: the sentence after the path is the
    /// part that explains — what a root is, why an `s1` mode cannot take prose — and it is the
    /// same sentence the menu shows for the same broken file. Two wordings for one rule is two
    /// wordings to keep true.
    public func message(for field: ModeField) -> String? {
        guard let error = validationError, error.field == field else { return nil }
        return error.description
    }

    /// Whether this draft can be written at all. What the Save button is enabled by.
    ///
    /// The point of the whole editor for an `api: .s1` mode: prose in `instructions` is refused
    /// **here**, while it is being typed, rather than at dictation time. `Mode.validate()` already
    /// refuses it — but by then the mode is unusable, the raw transcript is inserted instead, and
    /// the measured version of that failure is Superwhisper's own words appearing inside Louis's
    /// text (`Mode.validationError`, the `s1` branch).
    public var canSave: Bool { validationError == nil }

    /// Whether saving moves the file. True only when an existing mode's key changed — renaming a
    /// mode's *name* is a field like any other and leaves `<key>.json` exactly where it was.
    public var movesItsFile: Bool {
        guard let previousKey else { return false }
        return previousKey != mode.key
    }

    /// The message to draw beside the way *out* of `screen`, when what is wrong is on the other
    /// one. Nil the rest of the time, including when the error is on `screen` itself — that
    /// message belongs under its own input, and saying it twice would make the reader look for
    /// two problems.
    public func messageElsewhere(from screen: ModeEditorScreen) -> String? {
        guard let error = validationError, error.field.screen != screen else { return nil }
        return error.description
    }
}

/// What removing a mode's file actually does — which is not the same thing for a built-in.
///
/// **A built-in cannot be deleted, and a button that claimed otherwise would lie.**
/// `createBuiltInsIfMissing()` runs at every launch, not only the first
/// (`DictationController.swift`), so `voice.json` and `prompt.json` are written again from the
/// built-in whatever happens to them; `Voice` does not even wait that long, since `loadAll()`
/// stands it in the moment no `voice` entry loads. Removing the file of a built-in therefore
/// destroys the *edits* and returns the mode to what shipped.
///
/// The alternative was to refuse the removal of a built-in outright, with a reason. Rejected:
/// resetting a mode Louis has edited into a corner is a genuinely useful thing to be able to do —
/// it is how `voice.json` repairs itself, and the store's own comment already says so — and the
/// only problem with the button was its word. Saying "Reset" costs one string and keeps the
/// action; refusing costs the action and keeps nothing.
public enum ModeRemoval: Equatable, Sendable {
    /// A mode somebody wrote. The file goes, the mode goes with it.
    case deletion
    /// A mode Murmure ships. The file goes, the mode comes back, the edits do not.
    case reset

    /// The button in the editor.
    ///
    /// Both carry the ellipsis, because both stop to ask — the rule `HistoryClearing.buttonTitle`
    /// sets, where macOS spells a trailing `…` as "this opens something before it acts". There is
    /// no unconfirmed case here the way there is for recordings: that one is confirmed by the fact
    /// that the app already does it on its own every three days, and nothing does either of these
    /// on its own.
    public var buttonTitle: String {
        switch self {
        case .deletion: "Delete…"
        case .reset: "Reset…"
        }
    }
}

extension Mode {
    /// Whether this mode is one of the two Murmure writes at launch.
    ///
    /// By key, because the key is the file name and the file is what gets written back. A mode
    /// renamed to `voice` **is** the one that comes back, whatever it now contains, which is the
    /// behaviour rather than an approximation of it.
    public var isBuiltIn: Bool {
        Mode.builtIns.contains { $0.key == key }
    }

    public var removal: ModeRemoval {
        isBuiltIn ? .reset : .deletion
    }

    /// The dialog. A removal is irreversible, so it always asks — and the message is the whole
    /// point of asking: "Are you sure?" tells the reader nothing they did not know from having
    /// clicked, and the only useful sentence names what will not be there afterwards
    /// (``ConfirmationPrompt``).
    public var removalConfirmation: ConfirmationPrompt {
        switch removal {
        case .deletion:
            ConfirmationPrompt(
                title: "Delete \u{201C}\(name)\u{201D}?",
                message:
                    "This deletes modes/\(key).json. The mode stops being offered and nothing "
                    + "brings it back. Dictations already made with it keep their text.",
                confirmTitle: "Delete Mode",
                cancelTitle: "Cancel")
        case .reset:
            ConfirmationPrompt(
                title: "Reset \u{201C}\(name)\u{201D} to what Murmure ships?",
                message:
                    "\(name) is one of the modes Murmure writes at launch, so modes/\(key).json "
                    + "comes back \(returnsImmediately ? "straight away" : "at the next launch") "
                    + "with its original settings. What is lost is every change made to it, and "
                    + "nothing brings those back.",
                confirmTitle: "Reset Mode",
                cancelTitle: "Cancel")
        }
    }

    /// Whether the mode is back the instant its file is gone, or only once the app is relaunched.
    ///
    /// The difference is visible and worth a word in the dialog: reset `Prompt` and it is missing
    /// from the list until Murmure is started again, where `Voice` never leaves it. Derived from
    /// `loadAll()`'s own stand-in rule rather than restated, so the sentence cannot outlive it.
    private var returnsImmediately: Bool {
        key == Mode.voice.key
    }
}

/// What the `+` button offers: a mode to start from.
///
/// **The non-protected built-ins plus Custom, and no Meeting.** The plan's own line says
/// "Murmure's four built-ins plus Custom" — there are two built-ins, since `Message` and `Email`
/// were removed for pointing at a model `scripts/bootstrap.sh` does not pull (`Mode.builtIns`),
/// and of those two only `Prompt` offers a preset: a copy of `Voice` is a mode with the refiner
/// off, which `docs/specs/2026-09-09-modes-editor-v2-design.md` §3 forbids for anything that is
/// not `Voice` itself -- and `Voice` exists exactly once, protected, never as a duplicate. Derived
/// from `Mode.builtIns` (filtered to the non-protected ones) rather than typed out, so this cannot
/// drift from what actually ships: a third, non-protected built-in appears in the picker the day
/// it appears in the app.
public struct ModePreset: Equatable, Identifiable {
    public var id: String { name }
    /// The name the new mode starts with, and what the key is derived from.
    public let name: String
    /// One line under the name in the picker. What this mode *does*, not what it is called.
    public let summary: String
    /// The mode this preset copies. Its `key` is replaced at creation time.
    public let template: Mode

    public init(name: String, summary: String, template: Mode) {
        self.name = name
        self.summary = summary
        self.template = template
    }

    /// The picker's entries, in order.
    public static let all: [ModePreset] =
        Mode.builtIns.filter { !$0.isProtected }.map(preset(for:)) + [.custom]

    /// An empty mode to fill in.
    ///
    /// Ships with the refiner **on** — `docs/specs/2026-09-09-modes-editor-v2-design.md` §3 makes
    /// a refiner mandatory outside Voice ("a mode without a refiner IS Voice"), which supersedes
    /// this preset's earlier rationale (built on `Voice` with the refiner off, so a blank mode
    /// that arrived pointing at an unpulled model would not silently refine nothing — the failure
    /// that cost `Message` and `Email` their place in `builtIns`). Still built on `Voice` for
    /// everything else (language, context, `autoActivate`); only `llm` and `instructions` differ.
    public static let custom = ModePreset(
        name: "New mode",
        summary: "Transcribes, then cleans the text up with \(Mode.rewriteModel.modelTag).",
        template: {
            var mode = Mode.voice
            mode.llm = .init(
                enabled: true, endpoint: mode.llm.endpoint, model: Mode.rewriteModel, api: .chat)
            mode.instructions = Mode.prompt.instructions
            return mode
        }())

    /// The one-liner for a built-in, keyed off what the mode does rather than off its name, so a
    /// built-in renamed keeps its description.
    private static func preset(for mode: Mode) -> ModePreset {
        ModePreset(
            name: mode.name,
            summary: mode.llm.enabled
                ? "Transcribes, then cleans the text up with \(mode.llm.model.modelTag)."
                : "Transcribes and inserts. Nothing is sent to a language model.",
            template: mode)
    }

    /// A new mode from this preset, with a key that is free.
    ///
    /// `takenKeys` is passed rather than read from a store: creating the second `Voice` must not
    /// overwrite the first, and the caller is the one holding the loaded list.
    public func mode(avoiding takenKeys: some Collection<String>) -> Mode {
        var mode = template
        mode.name = name
        mode.key = Mode.availableKey(basedOn: name, avoiding: takenKeys)
        return mode
    }
}

extension Mode {
    /// A key derived from a display name: lower-cased, everything outside
    /// ``filenameSafeCharacters`` folded to a single `-`, and a numeric suffix until it is free.
    ///
    /// The key is the file name, which is why this exists at all — a user typing a name with a
    /// slash or an accent in it would otherwise produce a mode that cannot be written. Derived
    /// **once, at creation**: after that the key is a field of its own on the advanced screen, and
    /// renaming a mode does not rename its file. That is the difference the editor has to keep
    /// visible, because a mode file is also a thing people refer to by path.
    public static func availableKey(
        basedOn name: String, avoiding takenKeys: some Collection<String>
    ) -> String {
        let folded = String(name.lowercased().map {
            $0.unicodeScalars.allSatisfy(filenameSafeCharacters.contains) ? $0 : "-"
        })
        var slug = folded.split(separator: "-", omittingEmptySubsequences: true).joined(
            separator: "-")
        // A name made entirely of characters a file name cannot hold — an emoji, punctuation —
        // still has to produce a key, and an empty one is refused by `validationError`.
        if slug.isEmpty { slug = "mode" }

        let taken = Set(takenKeys)
        guard taken.contains(slug) else { return slug }
        // From 2, so the second `Voice` is `voice-2`: `voice-1` implies a `voice-0` that is not
        // there, and the first one is simply `voice`.
        var suffix = 2
        while taken.contains("\(slug)-\(suffix)") { suffix += 1 }
        return "\(slug)-\(suffix)"
    }
}

extension Mode {
    /// `autoActivate` as the one field the advanced screen draws, and back.
    ///
    /// One line of comma-separated bundle ids rather than a list with an add button: they are
    /// pasted, usually several at a time, out of `osascript -e 'id of app "…"'` or a colleague's
    /// message, and a row-at-a-time editor turns a paste into six operations.
    ///
    /// Empty entries are dropped rather than written: a trailing comma is the normal way to leave
    /// this field, and `""` in the file is a claim on no application that a reader of the JSON has
    /// to work out is inert. Duplicates and case are left exactly as typed — `ModeSelection`
    /// compares without case, and rewriting what someone entered is how a field stops being
    /// theirs.
    public static func autoActivateText(_ bundleIDs: [String]) -> String {
        bundleIDs.joined(separator: ", ")
    }

    public static func autoActivateList(from text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension String {
    /// The readable tail of an Ollama model id: `hf.co/superwhisper/s1-mini-GGUF:Q4_K_M` is a
    /// registry path, and the only part of it a sentence in a picker can use is the last
    /// component. Not `ModelDisplayName`, which names *Whisper* models from a directory listing.
    fileprivate var modelTag: String {
        split(separator: "/").last.map(String.init) ?? self
    }
}
