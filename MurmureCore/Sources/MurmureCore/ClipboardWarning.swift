import Foundation

/// What a restore outcome says to a human, or nothing when there is nothing to say.
///
/// This lived as a `switch` inside `AppState.noteClipboard`, in the app target — so the five
/// sentences Louis actually reads had no test bundle within reach, and the one branch here with
/// real logic in it is a branch that was **wrong once already**: a partial restore where the items
/// all came back but some of their TYPES did not arrives with `lostItems == 0`, and the first
/// version read that as `.restored` and cleared the warning at the exact moment content had been
/// destroyed. A rule with that history belongs where it can be pinned.
///
/// The shape is `AppAlert.message`'s, one layer down: an outcome in, a sentence out, and no
/// `default` — a case added to `RestoreOutcome` fails to compile here rather than falling into a
/// silence.
public enum ClipboardWarning {
    /// The line to show, or nil when the clipboard came back intact.
    ///
    /// Nil is the whole of `.restored` and is not "no message yet": it is what takes the previous
    /// dictation's warning off the screen, so returning a string here would leave a permanent
    /// notice about a clipboard that is fine.
    public static func message(for outcome: PasteboardSnapshot.RestoreOutcome) -> String? {
        switch outcome {
        case .restored:
            nil
        case let .restoredPartially(lost, captured, lostTypes):
            // NOT a `switch` on `(lost, captured)`: `case (_, captured)` would BIND a new
            // `captured` and match everything, silently. An if-expression compares, a case
            // pattern binds. (The comment is carried over with the code because it is the note
            // on a mistake that was made here.)
            if lost == 0 {
                // Every item came back, amputated: an eager `.string` kept, its unfulfilled
                // `.rtf` promise gone for good.
                "Clipboard restored without \(lostTypes.count) format(s)"
            } else if lost == captured {
                // Everything he had copied was promise-only. This reads to him exactly like a
                // failed write, and it is treated as loudly.
                "Clipboard lost (\(lost) item(s) could not be restored)"
            } else {
                "Clipboard partly restored (\(lost) of \(captured) items lost)"
            }
        case .declinedPasteboardChanged:
            // Measured cross-process, after two wrong descriptions of this case: the third
            // party's newer copy is in place and wins, our write was refused, and the
            // pre-dictation contents are deliberately not restored over it.
            "Clipboard changed during dictation — earlier contents not restored"
        case .writeFailed:
            "Could not restore the clipboard"
        }
    }
}
