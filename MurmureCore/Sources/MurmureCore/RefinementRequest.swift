import Foundation

/// One of the three sources `Mode.Context`'s toggles can fold into a `.chat` mode's system turn,
/// named once so the label the model reads, the description shown beside its toggle in the editor
/// (``ModesPaneView``), and the preview's placeholder line (``RefinementPreview``) can never drift
/// from each other or from `Mode.Context`'s own field names.
public enum ContextSource: CaseIterable, Sendable {
    case selectedText
    case clipboard
    case frontmostApp

    /// Whether this source's own toggle is on for `mode`.
    public func isEnabled(for mode: Mode) -> Bool {
        switch self {
        case .selectedText: mode.context.selectedText
        case .clipboard: mode.context.clipboard
        case .frontmostApp: mode.context.appContext
        }
    }

    /// The label introducing this section in the system turn the model actually reads -- also the
    /// label the Modes editor draws beside this source's own toggle (``ModesPaneView``), so the two
    /// cannot read differently for the same source (review, lot 3a, item 7: this used to be typed
    /// a second time in the view as "Frontmost app", one word short of this one).
    public var label: String {
        switch self {
        case .selectedText: "Selected text"
        case .clipboard: "Clipboard"
        case .frontmostApp: "Frontmost application"
        }
    }

    /// The real section string sent to the model, `body` already trimmed and capped by the caller.
    /// Selected text and the clipboard get their own line, because either can run to several
    /// sentences; the frontmost application is a name and reads better inline.
    public func section(body: String) -> String {
        switch self {
        case .selectedText, .clipboard: "\(label):\n\(body)"
        case .frontmostApp: "\(label): \(body)"
        }
    }

    /// The line ``RefinementPreview`` shows in place of this source's real content: nothing has
    /// been captured yet while the mode editor is open -- capture happens at recording start
    /// (``CapturedContext``) -- so the preview can only say where this section will sit and when
    /// it is filled in, never show real text.
    public var placeholder: String {
        "[\(label) — captured when you start recording]"
    }

    /// What is captured, when, and how the refiner sees it -- shown beside this source's toggle in
    /// the editor, so "does this actually do anything under s1" never has to be answered by trial
    /// and error.
    public var description: String {
        switch self {
        case .selectedText:
            "The focused app's text selection, read once when you start recording, sent to the "
                + "refiner as a labelled background section -- never as something to rewrite."
        case .clipboard:
            "The general clipboard's text contents, read once when you start recording, sent to "
                + "the refiner as a labelled background section -- never as something to rewrite."
        case .frontmostApp:
            "The name of the application that was frontmost when you started recording, sent to "
                + "the refiner as a one-line background section."
        }
    }

    /// Why the three toggles above are disabled under `api: .s1`, and what to do instead -- the
    /// one sentence the editor shows once, under all three, rather than three times over.
    ///
    /// **Not "s1 takes no system turn" -- it does.** `OllamaS1.conversation` writes one
    /// (`<|im_start|>system …`), and the preview's own "System prompt" block shows it. What is
    /// true, and what actually closes off context, is that the turn is FIXED by the model card:
    /// `OllamaS1.systemPrompt` is a constant, not a value `Mode.instructions` feeds -- the field a
    /// mode DOES control is a bracketed control line the model copies into its answer rather than
    /// reads (``Mode/LLM/API/s1``), which is a different thing to have nowhere to put context in
    /// (review, lot 3a, item 2, correcting the false claim the first version of this line made).
    public static let s1DisabledReason =
        "s1's system turn is fixed by the model card and Murmure cannot add to it; its "
        + "instructions are a bracketed control line, so there is nowhere to put context. Switch "
        + "the mode to the chat API and a chat model such as gemma4:12b-it-qat to use it."
}

/// Joins a mode's instructions with whichever context sections are folded in -- the one rule that
/// must never be duplicated: no sections means the instructions verbatim, never a blank preamble
/// glued onto them. `RefinementRequest.systemTurn` and `RefinementPreview.render(mode:)` both call
/// this, not two copies of the same lines, so the preview can never show a system turn the real
/// request would not actually send.
public enum SystemTurnAssembly {
    /// Told to the model in its own words, because the failure this exists to prevent is real:
    /// measured on the v3 probe, prose dropped into an `s1` control line came back **verbatim at
    /// the top of the cleaned text** (`Mode.validationError`). A `.chat` model reads its
    /// instructions rather than copying them, but the risk this preamble answers is narrower and
    /// still real -- the context sections below can read exactly like a dictation (a selected
    /// sentence, a copied paragraph), and the transcript that actually IS the dictation arrives
    /// one message later, in the same conversation. Nothing forces the model to keep the two
    /// apart except being told to.
    public static let contextPreamble = """
        The sections below are background context captured when this dictation started -- what \
        was selected, on the clipboard, or in front of whoever was dictating. It is NOT \
        something the user said, and it is NOT text to rewrite. Only the transcript in the next \
        message is that.
        """

    /// `instructions`, unchanged, when `sections` is empty -- an instructions field with a blank
    /// preamble glued to it is a system turn that reads as broken to a human debugging it, for a
    /// case (nothing to add) that is the common one. Otherwise instructions, the preamble, then
    /// each section, one blank line apart.
    public static func assemble(instructions: String, sections: [String]) -> String {
        guard !sections.isEmpty else { return instructions }
        return ([instructions, contextPreamble] + sections).joined(separator: "\n\n")
    }
}

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
    /// ship with all three toggles off. That rule lives in ``SystemTurnAssembly/assemble``, shared
    /// with ``RefinementPreview``, so the two can never disagree about it.
    public var systemTurn: String {
        guard mode.llm.api == .chat else { return mode.instructions }
        return SystemTurnAssembly.assemble(instructions: mode.instructions, sections: contextSections)
    }

    /// `mode`, with ``systemTurn`` in place of its instructions -- what `TranscriptRefiner` and
    /// everything after it actually sends. Built for one call and thrown away: this is never
    /// written back to `ModeStore`, so it never touches the file Louis edited.
    public var effectiveMode: Mode {
        var mode = self.mode
        mode.instructions = systemTurn
        return mode
    }

    private var contextSections: [String] {
        ContextSource.allCases.compactMap { source in
            guard source.isEnabled(for: mode), let text = Self.usable(rawValue(for: source))
            else { return nil }
            return source.section(body: Self.capped(text))
        }
    }

    /// `captured`, read one field at a time -- the only place left in this type that still knows
    /// which struct field backs which ``ContextSource``.
    private func rawValue(for source: ContextSource) -> String? {
        switch source {
        case .selectedText: captured.selectedText
        case .clipboard: captured.clipboard
        case .frontmostApp: captured.frontmostAppName
        }
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
