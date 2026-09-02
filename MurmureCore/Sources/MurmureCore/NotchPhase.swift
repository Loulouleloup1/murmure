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
    /// The model itself is being fetched or loaded, which is what the FIRST dictation on a machine
    /// spends its minutes doing while the session sits in `.transcribing`.
    ///
    /// **It is a phase of its own rather than a variant of `transcribing`, and the split is this
    /// type's founding argument applied a second time.** `NotchPhase` exists because the machine
    /// has states the interface must not draw one-for-one: `.completed(0)` had to become two
    /// phases because one state meant two things. This is the mirror case -- one *state*,
    /// `.transcribing`, covers three waits that are minutes apart in length and different in kind,
    /// and the interface has to say which. Louis installed Murmure on a second Mac, watched
    /// "Transcribing" for a long time and concluded the app was broken; it was downloading 1.6 GB.
    ///
    /// It is one case with a payload rather than two cases because everything the surfaces decide
    /// about it is shared -- the same white tint, the same travelling mark, the same "never
    /// retracts on a timer" -- and only the sentence, the glyph and whether there is a bar differ.
    /// Two cases would have to be kept in step by hand at five call sites.
    case preparingModel(ModelPreparation)
    /// Louis abandoned the dictation with Escape. Nothing was transcribed, nothing was pasted,
    /// and the recording is kept (`DictationSession.cancel()`).
    ///
    /// **A phase of its own rather than `nothingHeard` reused, and the distinction is the same one
    /// `DictationOutcome` already keeps one layer down (lot 4 D8).** The two agree about the
    /// target application -- nothing reached it -- and about the tint and the mark, which is why
    /// they share both. They disagree about the only thing Louis is reading: "Nothing heard" says
    /// the microphone got nothing, and here the microphone got everything and he threw it away.
    /// On the floating panel the sentence is most of the interface, so borrowing the silence's
    /// would be a lie told in the one place he can see one.
    ///
    /// It is emphatically not `failed` either. Nothing went wrong; orange and an exclamation
    /// triangle would turn a deliberate act into an incident.
    case cancelled
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
