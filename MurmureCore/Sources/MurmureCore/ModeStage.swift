import Foundation

/// One model a mode puts the audio through, in the order it runs them.
///
/// The list row draws one badge per stage (design notes §5): one for a transcribe-only mode, two
/// for a refining one. Superwhisper's own badges carry the *provider's avatar* and a padlock when
/// the model is not available on the current tier — the availability half collapses here, since
/// everything is local and everything is available, but the **stage-count half is the part worth
/// keeping**: at a glance, `Voice` and `Prompt` are different kinds of mode without either being
/// opened.
///
/// An enum and not an `Int`, because the badge has to name which stage it is: two identical dots
/// say "two models" and nothing about what the second one does.
public enum ModeStage: String, CaseIterable, Sendable {
    /// Whisper. Every mode has this one; it is what a mode is.
    case transcription
    /// The refiner. Present only when `llm.enabled`.
    case refinement

    /// The glyph on the badge.
    ///
    /// The same two symbols `MainWindowView`'s header already draws for the active mode, and
    /// deliberately: a mode wearing one glyph in the header and another in the list would be two
    /// modes to the eye. Written **without a `default`** so a third stage cannot arrive glyphless.
    public var symbolName: String {
        switch self {
        case .transcription: "mic.fill"
        case .refinement: "sparkles"
        }
    }
}

extension Mode {
    /// The stages this mode runs, in the order it runs them.
    ///
    /// Derived from `llm.enabled` and nothing else. That single boolean is what
    /// `TranscriptRefiner` itself branches on, so a badge count that came from anywhere else —
    /// a non-empty `llm.model`, an `api` value — could say two while the dictation ran one.
    public var stages: [ModeStage] {
        llm.enabled ? [.transcription, .refinement] : [.transcription]
    }

    /// The glyph the mode wears in the list (D14), and the two other surfaces that read this same
    /// computed property: the Modes list row and `MainWindowView`'s header. **`symbol` when the
    /// mode names one, derived from the stage otherwise.**
    ///
    /// **Not the menu-bar mode list.** That list (`MurmureApp.swift`) draws `Toggle(mode.name,
    /// ...)` with no icon at all today -- a file this lot may not touch (a concurrent lot owns
    /// per-mode hotkeys there) -- so it neither reads nor ignores `symbolName`; it is a follow-up
    /// for whoever next edits that file, not a surface this property currently reaches.
    ///
    /// Superwhisper stores an `iconName` per mode file (design notes §6, item 4) and the notes
    /// argued for adopting it; `Mode.symbol` is that field, added once people started asking to
    /// build and tell modes apart by more than "does it refine" (§4 of the modes-editor lot). The
    /// derived half stays exactly what it was: what the glyph has to say when nobody picked one is
    /// the thing the row does not otherwise show — whether this mode sends what is said to a
    /// language model — and `llm.enabled` already knows.
    ///
    /// **Falls back on a `symbol` outside ``ModeSymbol/library`` too, not only on nil.** These
    /// files are hand-edited (`Mode.swift`'s own opening line): `"symbol": "nonsense"` typed or
    /// pasted wrong is not this property's business to refuse the way `Mode.validate()` refuses an
    /// empty name, because a mode is still perfectly usable with a glyph nobody can draw -- it just
    /// must not draw NOTHING (review, lot 3a, item 6). The library is the one place both this
    /// check and the editor's grid read, so the two cannot silently disagree about what counts as
    /// a real choice.
    public var symbolName: String {
        if let symbol, ModeSymbol.library.contains(symbol) { return symbol }
        return llm.enabled ? ModeStage.refinement.symbolName : ModeStage.transcription.symbolName
    }

    /// Which model a stage runs, so a badge can name it rather than being decoration.
    public func model(for stage: ModeStage) -> String {
        switch stage {
        case .transcription: stt.model
        case .refinement: llm.model
        }
    }
}
