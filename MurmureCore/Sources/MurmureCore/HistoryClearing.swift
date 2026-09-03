import Foundation

/// What Murmure asks before it destroys something.
///
/// Four strings and no behaviour, because the decision is entirely in the words: an alert that
/// says "Are you sure?" has told the user nothing they did not already know from having clicked
/// the button, and the only useful sentence is the one naming what will not be there afterwards.
public struct ConfirmationPrompt: Equatable, Sendable {
    /// The question, as a question.
    public let title: String
    /// What disappears, what survives, and whether it comes back. The load-bearing field.
    public let message: String
    /// The destructive button. It repeats the action rather than saying "OK", so the last thing
    /// read before the click is still the name of what is about to happen.
    public let confirmTitle: String
    public let cancelTitle: String

    public init(title: String, message: String, confirmTitle: String, cancelTitle: String) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
    }
}

/// The two by-hand erasures in the Advanced pane (plan T8, Q-B3), and which of them stops to ask.
///
/// **They are the retention policy with the clock brought forward, and that is the whole design.**
/// `RetentionPurge` already deletes audio after 3 days and text after 30, unprompted, every
/// launch. These two buttons run the same two sweeps with no cutoff, so a button can never
/// produce an outcome the app does not already produce on its own -- which is also why the
/// wording below repeats the two numbers. A user who is told "recordings go after 3 days" and
/// then sees a button whose dialog talks about something else has learned that one of the two is
/// lying.
///
/// **Only one of them asks, and it is not the one that deletes 730 MB.**
///
/// - Recordings do not ask. Murmure deletes them by itself after three days, so the button brings
///   forward by at most three days something that is going to happen anyway, and the thing it
///   destroys is not the recovery path: a failed paste is recovered from the text (lot 3 T6),
///   never from the audio. A confirmation here would be a dialog in front of the app's own
///   routine behaviour, which is the specific way an app teaches someone to click through
///   dialogs -- and the next one is the one that matters.
/// - Transcripts ask. The text is the archive: it is what History searches, what "Process again"
///   re-refines, and what Louis actually goes to the window to find again. It is also the tier
///   with the *longest* automatic clock, so this button destroys up to thirty days of material
///   the app was not going to touch, including the dictation from ten minutes ago. Nothing brings
///   it back.
public enum HistoryClearing: CaseIterable, Sendable {
    /// Every WAV in `recordings/`, including the ones no row points at -- measured at 122 files
    /// and 613.7 MB on 2026-09-02, audio from before the history feature existed. Rows and text
    /// are untouched.
    case recordings

    /// The raw and refined text of every dictation. The rows survive, so the archive still says a
    /// dictation happened, when, how long it took and through which mode -- exactly what
    /// `HistoryStore.clearText` leaves behind after the 30-day sweep.
    case transcripts

    /// Whether clicking it opens a dialog.
    ///
    /// Written without a `default` so a third destructive action cannot inherit "no" -- silence
    /// is the dangerous direction here, which is the opposite of `FeedbackPolicy`, and the
    /// asymmetry is the reason both are spelled out rather than defaulted.
    public var requiresConfirmation: Bool {
        switch self {
        case .recordings: false
        case .transcripts: true
        }
    }

    /// The button in the pane.
    ///
    /// **The ellipsis is derived from ``requiresConfirmation``, not written by hand**, so the two
    /// cannot drift. macOS spells a trailing `…` as "this opens something before it acts", and a
    /// destructive button that acts immediately must not wear one: it is the only warning the
    /// user gets that there is no second chance coming.
    public var buttonTitle: String {
        requiresConfirmation ? "\(baseTitle)…" : baseTitle
    }

    private var baseTitle: String {
        switch self {
        case .recordings: "Delete All Recordings"
        case .transcripts: "Delete All Transcripts"
        }
    }

    /// The line under the button, saying what it destroys -- for BOTH actions.
    ///
    /// Not only for the one that asks. The action without a dialog is precisely the one whose
    /// only chance to explain itself is here, before the click; a row that reads
    /// `Delete All Recordings` and nothing else is a button whose consequences are discovered
    /// afterwards.
    public var summary: String {
        switch self {
        case .recordings:
            "Deletes every recording in the folder now, including ones no dictation points at. "
                + "Transcripts are untouched. Murmure deletes recordings after 3 days on its own."
        case .transcripts:
            "Deletes the raw and refined text of every dictation, including today's. The rows "
                + "stay — date, duration and mode. Murmure deletes text after 30 days on its own."
        }
    }

    /// The dialog, or nil when there is not one.
    ///
    /// Nil exactly when ``requiresConfirmation`` is false -- a test walks every case to hold the
    /// two together, because an action that claims a dialog and cannot produce one is a delete
    /// that happens with no warning at all.
    ///
    /// `dictationCount` is the number of rows the archive holds. The count is in the sentence
    /// because "your transcripts" and "1 469 transcripts" are not the same warning. A caller with
    /// nothing to delete disables the button rather than asking this for a prompt about zero
    /// dictations.
    public func confirmation(dictationCount: Int) -> ConfirmationPrompt? {
        switch self {
        case .recordings:
            nil
        case .transcripts:
            ConfirmationPrompt(
                title: "Delete the text of every dictation?",
                message:
                    "This deletes the raw and refined text of \(Self.dictations(dictationCount)), "
                    + "including today's. The rows stay — date, duration and mode — and "
                    + "recordings are untouched. Murmure already deletes text after 30 days; this "
                    + "deletes all of it now, and it cannot be undone.",
                confirmTitle: baseTitle,
                cancelTitle: "Cancel")
        }
    }

    /// "1 dictation", "2 dictations".
    ///
    /// Spelled out because the alternative is "1 dictations", which is the kind of thing that
    /// makes a warning look machine-written at the exact moment it needs to be read. Same care
    /// `StatusPanelText` takes over "Inserted 1 character".
    private static func dictations(_ count: Int) -> String {
        count == 1 ? "1 dictation" : "\(count) dictations"
    }
}
