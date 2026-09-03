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

    /// The glyph the mode wears in the list (D14): **derived, never stored.**
    ///
    /// Superwhisper stores an `iconName` per mode file (design notes §6, item 4) and the notes
    /// argue for adopting it. Not here, and not yet: an icon field is a field to pick a value for
    /// in the editor, to validate, and to explain in a hand-edited file, and it would buy one
    /// picture. What the glyph has to say is the thing the row does not otherwise show — whether
    /// this mode sends what is said to a language model — and `llm.enabled` already knows.
    public var symbolName: String {
        llm.enabled ? ModeStage.refinement.symbolName : ModeStage.transcription.symbolName
    }

    /// Which model a stage runs, so a badge can name it rather than being decoration.
    public func model(for stage: ModeStage) -> String {
        switch stage {
        case .transcription: stt.model
        case .refinement: llm.model
        }
    }
}
