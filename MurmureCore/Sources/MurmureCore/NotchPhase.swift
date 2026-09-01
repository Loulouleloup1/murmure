import Foundation

/// What the notch is showing, at one instant.
///
/// One level of indirection away from `DictationSession.State` on purpose, and not a typealias:
/// the machine has states the interface must not draw one-for-one. `.completed(0)` is the case
/// that forces the split -- the same state means "it worked" or "nothing you said got through"
/// depending on a number, and the notch has to say two different things about it.
///
/// `hidden` is not "an empty notch": it is no window at all. Idle costs zero pixels (lot 3 D4).
public enum NotchPhase: Equatable {
    /// No window. Between dictations, and after a completion has finished being shown.
    case hidden
    case recording
    case transcribing
    /// The long one: 19 s at the p-high of the measured refinements, 57.5 s on the worst real
    /// case. It has to look different from `transcribing`, which is why it is a phase of its own
    /// here as well as a state of its own in the session.
    case refining
    case inserting
    /// The dictation inserted text, and this is how much. Never zero -- that is `nothingHeard`.
    case completed(insertedCharacters: Int)
    /// The dictation ran and inserted nothing: an empty recording, or a transcript Whisper
    /// returned empty. Deliberately NOT a failure (nothing went wrong) and deliberately not a
    /// success (nothing was pasted). A green flash here would be a lie.
    case nothingHeard
    /// `recoveredText` is the dictation the paste could not deliver; lot 3 T6 offers it for a
    /// re-paste rather than losing it (spec §9).
    case failed(message: String, recoveredText: String?)
    /// Something is wrong with Murmure itself rather than with a dictation -- Accessibility
    /// revoked, the hotkey refused. Produced by lot 3 T6, which owns what is worth interrupting
    /// for and what merely belongs in the menu; nothing in T2 raises one.
    case alert(message: String)
}
