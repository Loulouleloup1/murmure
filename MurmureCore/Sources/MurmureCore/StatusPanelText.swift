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
        // **The two sentences this task was written for.** Neither may read as "Transcribing":
        // that word is what a fresh Mac showed Louis for minutes while it pulled 1.6 GB, and a
        // wait whose cause is not stated is indistinguishable from a hang. The percentage is not
        // decoration either -- it is the difference between "it is working" and "it is working and
        // it will end", and it is a percentage of BYTES (`ModelDownload`), never of the file count
        // WhisperKit reports, which reaches 91.7 % in the first seconds.
        //
        // Both fit `StatusPanelLayout.labelSlot` at their widest, which is what
        // `StatusPanelLayoutTests` measures rather than estimates: "Downloading model 100%" is
        // 147.53 pt against a 158 pt slot.
        case .preparingModel(.downloading(let download)):
            "Downloading model \(download.percent)%"
        // "Loading", not "Preparing": it names the mechanism, the log line beside it already says
        // "model loaded in …s", and the wait it covers is CoreML compiling the model for this
        // machine -- 112 s the first time, seconds after that. No number, because there is none to
        // have; the word and the glyph are the whole of the distinction.
        //
        // **"don't quit" is not politeness, it is the one thing that can still go wrong here.**
        // The compilation is not resumable: the second Mac's installer quit Murmure twice during
        // it, unknowingly, and turned seven minutes into a perceived half hour of restarts. This
        // is precisely the moment somebody who believes the app has hung reaches for ⌘Q, and it is
        // the only moment in the whole sequence where doing so costs them the wait again.
        //
        // Three words and no reason given, because the slot is 158 pt and this sentence measures
        // 143.18 of it (`StatusPanelLayoutTests`) -- "quitting starts it over" does not fit at any
        // wording, and the panel shares its sentence with the notch card by design. The reason
        // lives where there is room for it: the README, and what `bootstrap.sh` prints while it
        // pays the same wait for you.
        case .preparingModel(.loading):
            "Loading model, don't quit"
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
    ///
    /// Visible to the package rather than private, because `HistoryRow.preview` has the identical
    /// problem one lot later -- a transcript with newlines in a single-line row -- and the plan
    /// asked for it to follow this rule rather than invent a second one. Two collapsing functions
    /// that agreed today would be two that could stop agreeing, in the two places Murmure shows a
    /// long text on one line.
    static func oneLine(_ message: String) -> String {
        message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
