import Foundation

/// What a mode's refiner (or the no-refiner fallback) actually receives, for the Modes editor's
/// "What the refiner receives" block -- built for the same reason ``RefinementRequest`` is: so the
/// question "does this mode actually do what I typed" has an answer that cannot drift from what a
/// dictation would really send.
///
/// **Built from the SAME assembler.** `render(mode:)` calls ``SystemTurnAssembly/assemble``, the
/// exact function ``RefinementRequest/systemTurn`` calls -- not a second copy of the preamble or
/// the join rule. Drop the preamble from the shared assembler and both this type's tests and
/// `RefinementRequestTests` go red together, which is the property that matters: a preview that
/// could show something the real request would not send is worse than no preview at all.
///
/// **Built from a `Mode` alone, with nothing captured.** The editor is open before any dictation
/// has started, so there is no real selected text, clipboard or frontmost application to show --
/// only where each one will sit and when it is filled in (``ContextSource/placeholder``). That is
/// the one place this type's output differs from ``RefinementRequest``'s: the structure (which
/// sections, the preamble, the ordering) is identical by construction; the *content* of an enabled
/// context section is a placeholder here and real captured text there.
public struct RefinementPreview: Equatable {
    /// One block the preview draws, in the order ``render(mode:)`` returns them: what introduces
    /// it, its body, and -- for the one block whose wording Murmure does not control -- why.
    public struct Turn: Equatable {
        public let heading: String
        public let body: String
        /// Set only for the s1-mini system prompt, which is fixed by the model card rather than
        /// editable: the reader has to be told that in the one place they might otherwise expect
        /// a "Instructions" field to have produced this text.
        public let note: String?

        public init(heading: String, body: String, note: String? = nil) {
            self.heading = heading
            self.body = body
            self.note = note
        }
    }

    /// The literal stand-in for the transcript's own turn. No audio has been recorded yet while
    /// the editor is open, so there is nothing real to show here -- the placeholder is what makes
    /// that honest rather than showing an empty string, which would read as a bug.
    public static let transcriptPlaceholder = "<your transcript>"

    /// Shown verbatim when a mode has no refiner at all -- `llm.enabled == false`. Matches
    /// `DictationSession`'s own fallback: this mode inserts the recognised transcript untouched.
    public static let noRefinerText = "No refiner: the transcript is inserted as recognised."

    public let turns: [Turn]

    public static func render(mode: Mode) -> RefinementPreview {
        guard mode.llm.enabled else {
            return RefinementPreview(turns: [Turn(heading: "No refiner", body: noRefinerText)])
        }
        switch mode.llm.api {
        case .chat:
            let placeholders = ContextSource.allCases
                .filter { $0.isEnabled(for: mode) }
                .map(\.placeholder)
            let systemTurn = SystemTurnAssembly.assemble(
                instructions: mode.instructions, sections: placeholders)
            return RefinementPreview(turns: [
                Turn(heading: "System turn", body: systemTurn),
                Turn(heading: "User turn", body: transcriptPlaceholder),
            ])
        case .s1:
            return RefinementPreview(turns: [
                Turn(
                    heading: "System prompt", body: OllamaS1.systemPrompt,
                    note: "Fixed by the s1-mini model card — Murmure cannot change it."),
                Turn(heading: "Control line", body: mode.instructions),
                Turn(heading: "Transcript", body: transcriptPlaceholder),
            ])
        }
    }
}
