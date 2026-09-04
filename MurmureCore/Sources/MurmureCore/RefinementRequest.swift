import Foundation

/// A mode's instructions plus whatever context this dictation captured, assembled into the one
/// string a `.chat` mode sends as its system turn
/// (``OllamaChat/requestBody(model:instructions:transcript:)``).
///
/// Pure by construction: every input is a `Mode` or a ``CapturedContext``, both plain values, so
/// nothing here reads a file, the network, the pasteboard or the accessibility API. That is what
/// makes the assembly testable in `MurmureCore` -- the reading of the three sources this feeds on
/// is the part that needs AppKit and lives behind ``ContextCapturing`` instead.
///
/// This exists because ``Mode/Context`` was three toggles read by nobody: `selectedText`,
/// `clipboard` and `appContext` were stored and drawn in the editor, and nothing downstream ever
/// looked at them. This type, and `DictationSession`'s use of it, are the wiring that closes that
/// gap -- see the tests below that fail the moment a toggle stops reaching ``systemTurn``.
public struct RefinementRequest {
    public let mode: Mode
    public let captured: CapturedContext

    public init(mode: Mode, captured: CapturedContext) {
        self.mode = mode
        self.captured = captured
    }

    /// Cap on a single captured field before it enters the system turn, in characters.
    ///
    /// Derived from ``OllamaChat/numContext`` rather than picked round, because a clipboard can
    /// hold megabytes while the model reads at most 8192 tokens in total. `numPredict` (2048) is
    /// reserved for the answer, which leaves 6144 tokens for everything that goes IN --
    /// instructions, transcript and context together. A single context field is capped at HALF of
    /// that remaining budget, 3072 tokens, so a full clipboard can never outweigh the instructions
    /// and the transcript it is supposed to sit beside -- the thing it is context FOR must always
    /// have the majority of the room. Converted to characters at four characters per token: no
    /// tokenizer runs in this package, and that ratio is the usual order-of-magnitude estimate for
    /// Latin-script text -- generous rather than exact, which only means the cap is reached a
    /// little later than a real tokenizer's count would put it, never too early.
    public static let characterCap = (OllamaChat.numContext - OllamaChat.numPredict) / 2 * 4

    /// The string to send as the system turn.
    ///
    /// Unchanged `mode.instructions`, whatever the toggles say, for an `s1` mode: its instructions
    /// are a control line the model copies into its answer rather than reads
    /// (``Mode/LLM/API/s1``), so context has nowhere to go that would not corrupt the answer --
    /// the same reasoning is why `ModesPaneView` shows the three toggles disabled under that api.
    ///
    /// Also unchanged when every toggled section is empty: an instructions field with a blank
    /// context preamble glued to it is a system turn that reads as broken to a human debugging it,
    /// for a case (nothing to add) that is the common one -- `Voice` and the shipped `Prompt` both
    /// ship with all three toggles off.
    public var systemTurn: String {
        guard mode.llm.api == .chat else { return mode.instructions }
        let sections = contextSections
        guard !sections.isEmpty else { return mode.instructions }
        return ([mode.instructions, Self.contextPreamble] + sections).joined(separator: "\n\n")
    }

    /// `mode`, with ``systemTurn`` in place of its instructions -- what `TranscriptRefiner` and
    /// everything after it actually sends. Built for one call and thrown away: this is never
    /// written back to `ModeStore`, so it never touches the file Louis edited.
    public var effectiveMode: Mode {
        var mode = self.mode
        mode.instructions = systemTurn
        return mode
    }

    /// Told to the model in its own words, because the failure this exists to prevent is real:
    /// measured on the v3 probe, prose dropped into an `s1` control line came back **verbatim at
    /// the top of the cleaned text** (`Mode.validationError`). A `.chat` model reads its
    /// instructions rather than copying them, but the risk this preamble answers is narrower and
    /// still real -- the context sections below can read exactly like a dictation (a selected
    /// sentence, a copied paragraph), and the transcript that actually IS the dictation arrives
    /// one message later, in the same conversation. Nothing forces the model to keep the two
    /// apart except being told to.
    private static let contextPreamble = """
        The sections below are background context captured when this dictation started -- what \
        was selected, on the clipboard, or in front of whoever was dictating. It is NOT \
        something the user said, and it is NOT text to rewrite. Only the transcript in the next \
        message is that.
        """

    private var contextSections: [String] {
        var sections: [String] = []
        if mode.context.selectedText, let text = Self.usable(captured.selectedText) {
            sections.append("Selected text:\n\(Self.capped(text))")
        }
        if mode.context.clipboard, let text = Self.usable(captured.clipboard) {
            sections.append("Clipboard:\n\(Self.capped(text))")
        }
        if mode.context.appContext, let name = Self.usable(captured.frontmostAppName) {
            sections.append("Frontmost application: \(name)")
        }
        return sections
    }

    /// Nil for nil AND for empty-or-whitespace-only. A toggle switched on with nothing behind it
    /// -- an empty clipboard, a selection of nothing -- must produce the same silence as the
    /// toggle being off, never a section that tells the model "the clipboard is empty", which is
    /// a sentence about Murmure's internals and not something background context should ever say.
    private static func usable(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `.prefix`, matching every other truncation already in this package
    /// (`ModeValidationError.instructionsAreNotControlFields`, `OllamaFailure.refused`): keep the
    /// beginning, drop the end. Chosen for the same reason those were and not re-derived: it is
    /// what a reader of a truncated preview expects, and it is never silent here, unlike the
    /// truncation `OllamaS1.truncate` exists to refuse at the model's own end -- the marker below
    /// says a cut happened and how much was dropped.
    private static func capped(_ text: String) -> String {
        guard text.count > characterCap else { return text }
        return "\(text.prefix(characterCap))… [truncated -- \(text.count) characters captured]"
    }
}
