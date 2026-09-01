import Foundation

/// The one line of text the floating panel shows, per phase.
///
/// In the package rather than in the view for the reason `NotchPresenter` gives, and for one that
/// is specific to this surface: the panel has no waveform, no wings and no hardware anchor, so on
/// an external display **the sentence is most of the interface**. A phase that read as another
/// phase would be a lie told in the only place Louis can see one.
///
/// The panel is a strip roughly 220 pt wide; every line below is written to be read at a glance
/// out of the corner of an eye, not studied.
public enum StatusPanelText {
    /// What the panel says while it is in this phase.
    ///
    /// `hidden` has no line because it has no panel -- the empty string is the answer to a
    /// question that is not asked, and a test pins it so that a phase added later cannot silently
    /// acquire a blank strip instead of a sentence.
    ///
    /// Written without a `default`, so a phase added later fails to compile here rather than
    /// shipping an empty panel.
    public static func label(for phase: NotchPhase) -> String {
        switch phase {
        case .hidden:
            ""
        case .recording:
            "Recording"
        case .transcribing:
            "Transcribing"
        // Its own word, not "Transcribing" continued. The two phases are seconds and 19 s
        // respectively (lot 2 measurements, plan §1), and on the panel the word is the only thing
        // that distinguishes them -- the notch has a second signal, a change of motion, which a
        // 26 pt strip carries far less of.
        case .refining:
            "Refining"
        case .inserting:
            "Inserting"
        // The count is the point, not decoration. It is the difference between "it worked" and
        // "it thinks it worked": Louis reads the number and knows whether what landed under his
        // cursor is the sentence he said or three characters of it.
        case .completed(let characters):
            characters == 1 ? "Inserted 1 character" : "Inserted \(characters) characters"
        // Deliberately shares no wording with the completion above. This phase is the one the
        // panel exists to make legible -- a dictation that ran, took the same time, made the same
        // noises and pasted nothing -- and if it read as a small success Louis would go looking
        // for text that is not there. `NotchPresenter.nothingHeardDwell` keeps it on screen
        // longer than a completion for the same reason: it is the only witness there is.
        case .nothingHeard:
            "Nothing heard"
        // The failure's own sentence, because a generic word would send Louis to a menu to find
        // out what happened, and lot 3 exists because that menu is not read. `recoveredText` is
        // not shown here: offering text to re-paste needs a control, and this panel takes no
        // clicks (it is `ignoresMouseEvents`); the notch's expanded panel owns that (lot 3 T6).
        case .failed(let message, _):
            oneLine(message)
        case .alert(let message):
            oneLine(message)
        }
    }

    /// A message with its line breaks and runs of whitespace collapsed to single spaces.
    ///
    /// `failed` and `alert` carry a message from wherever the failure came from -- an
    /// `Error`'s description, an Ollama response -- and nothing upstream promises it is one line.
    /// A newline inside a strip 34 pt tall does not wrap, it pushes the rest of the sentence out
    /// of the panel, so the half of the message after the break would be invisible with no sign
    /// that it existed.
    private static func oneLine(_ message: String) -> String {
        message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
