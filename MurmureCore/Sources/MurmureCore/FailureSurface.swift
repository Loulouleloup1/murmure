import CoreGraphics
import Foundation

/// The offer a paste failure makes: the dictation it could not deliver, kept where it can be
/// pasted again rather than lost (spec §9).
///
/// A value and not a view, because the decision it carries is which of two losses gets the one
/// surface that takes clicks. Both are recorded here rather than one of them being dropped.
public struct Recovery: Equatable, Sendable {
    /// Why the insertion failed, in the words `DictationSession` produced -- "insert failed:
    /// Murmure needs Accessibility permission to paste into other apps.", and the five other
    /// `InsertError` descriptions. English, like every other failure the menu already shows, and
    /// for the same reason: it names the mechanism, and re-saying it in French here would mean
    /// maintaining `InsertError`'s six cases in two places.
    public let message: String

    /// The text the paste could not deliver. Never empty -- see `FailureSurface.standing`.
    public let text: String

    /// The clipboard's own bad news, when there is some, carried as a second line instead of
    /// competing for the surface. See `FailureSurface.standing`.
    public let clipboardNote: String?

    public init(message: String, text: String, clipboardNote: String?) {
        self.message = message
        self.text = text
        self.clipboardNote = clipboardNote
    }
}

/// What the one clickable surface is showing, or nil for the ordinary state where it is not on
/// screen at all.
public enum StandingProblem: Equatable, Sendable {
    /// A dictation exists and did not reach the target application. The surface holds it.
    case recovery(Recovery)
    /// Murmure itself cannot work. The surface says so and, for Accessibility, offers the pane.
    case alert(AppAlert)
}

/// Which surface says what, when several things are wrong at once.
///
/// Lot 3 gives Murmure two kinds of surface and this type is the seam between them:
///
/// - **Transient** -- the notch card and the floating strip. They belong to a dictation, they
///   retract on `NotchPresenter.dwell(for:)`, and they take no clicks (both windows are
///   `ignoresMouseEvents`, which is what keeps ⌘V going to Louis's terminal).
/// - **Standing** -- one panel that persists until it is dismissed and does take clicks, because
///   Re-paste and Copy are buttons and buttons need them.
///
/// Everything below is a function over values, for the reason the rest of the package exists.
/// What cannot cross is on the other side of each seam: `AXIsProcessTrusted()` produces the
/// `AppAlert`, `NSWorkspace.open` consumes its `settingsURL`, `NSPasteboard` and `CGEvent` are
/// what Copy and Re-paste do, and the panel's own window is AppKit.
public enum FailureSurface {
    // MARK: - The transient surface

    /// What the notch card and the floating strip show.
    ///
    /// **A dictation's own phase always wins.** An alert is about Murmure and stays true for as
    /// long as it is true; a phase is about the sentence Louis just spoke and is gone in seconds.
    /// Painting an alert over a running dictation would replace the waveform -- the one thing on
    /// screen saying the microphone is live -- with a sentence that was equally true a minute ago
    /// and will still be true a minute from now.
    ///
    /// That costs nothing, because an alert raised while a dictation is on screen is not dropped:
    /// it is the `standing` panel's, below, which is the surface that persists and the one that
    /// can be acted on. This function only decides what interrupts.
    ///
    /// `.hidden` when there is neither, which is idle -- no window at all (lot 3 D4).
    public static func transient(dictation: NotchPhase, alert: AppAlert?) -> NotchPhase {
        if NotchAppearance.showsShape(in: dictation) { return dictation }
        guard let alert else { return .hidden }
        return .alert(message: alert.message)
    }

    // MARK: - The standing surface

    /// What the clickable panel offers, for a session in this state.
    ///
    /// **A recoverable transcript outranks every alert, and that is the safety property of this
    /// whole task.** An Accessibility banner is a sentence Louis can read again at any time --
    /// `AXIsProcessTrusted()` will answer the same thing on the next dictation, and the menu
    /// carries it meanwhile. A transcript exists nowhere but in this one value: `DictationSession`
    /// hands it over in `.failed`'s payload, `AppState.recoveredText` holds it until the next
    /// `.recording` clears it, and nothing writes it to disk. An alert taking the surface would
    /// lose exactly what this task exists to save -- and the two arrive together by construction,
    /// since a denied Accessibility is *why* the paste failed.
    ///
    /// **A clipboard loss does not compete for the surface either; it rides inside the offer.**
    /// The two are the same event seen twice -- `PasteInserter` reports the clipboard's fate on
    /// the throwing path as well -- and they are not comparable losses: the clipboard held
    /// something Louis copied and can copy again, the transcript held something he said once. So
    /// the failure takes the headline and the clipboard takes the second line, and neither is
    /// dropped. Which is also why `clipboardWarning` is a parameter and not a third case.
    ///
    /// **Empty recovered text is not an offer.** `PasteInserter.insert` returns early on an empty
    /// string without touching the clipboard, so it cannot be the source of a failure carrying
    /// one; a `.failed` whose payload is empty came from somewhere that had nothing to give, and a
    /// panel offering to re-paste nothing is a button that does nothing. It falls through to the
    /// alert, which is the useful thing left to say.
    ///
    /// Written over `DictationSession.State` rather than over `NotchPhase` on purpose: `.failed`
    /// is the one state the session does *not* leave on its own -- `complete` is what emits a
    /// state and then `.idle` in the same breath, failures stay -- so this needs no `previous`
    /// and cannot be desynchronised from the two callers that do track one.
    public static func standing(
        state: DictationSession.State, alert: AppAlert?, clipboardWarning: String?
    ) -> StandingProblem? {
        if case let .failed(message, recovered) = state, let text = recovered, !text.isEmpty {
            return .recovery(
                Recovery(message: message, text: text, clipboardNote: clipboardWarning))
        }
        guard let alert else { return nil }
        return .alert(alert)
    }

    /// What stays dismissed, once the standing problem is this.
    ///
    /// **A dismissal covers exactly the problem it was aimed at, and lapses the moment the
    /// standing problem becomes anything else -- including nothing.** Without this the panel goes
    /// permanently deaf to any problem that alternates with another: dismiss the Accessibility
    /// alert, have one dictation fail and open the recovery, and the alert -- still true, still
    /// the reason the paste failed -- would never be shown again for the life of the process,
    /// because a dismissal from two problems ago was still standing against it.
    ///
    /// Called before `visible(problem:dismissed:)` and feeding it, so the two cannot disagree
    /// about what "the same problem" means.
    public static func dismissal(
        _ dismissed: StandingProblem?, given standing: StandingProblem?
    ) -> StandingProblem? {
        standing == dismissed ? dismissed : nil
    }

    /// What is actually on screen, given what has been dismissed.
    ///
    /// Dismissal is per-problem and not per-panel: clicking the cross on an Accessibility alert
    /// means "I know", not "stop telling me things". So a dismissed problem stays hidden for
    /// exactly as long as it is the *same* problem, and anything else -- a different alert, a new
    /// dictation's recovery, the same alert after the intervening problem cleared -- opens the
    /// panel again.
    ///
    /// `Recovery` carries the transcript, so two paste failures are only ever "the same problem"
    /// when they hold the same text and the same message. Dictating the same sentence twice into
    /// an app that still refuses it is the one case that reads as already-dismissed, and that is
    /// the right answer: nothing new has happened.
    ///
    /// **Nothing else ever needs to dismiss a recovery, because the offer erases itself.**
    /// `AppState.recoveredText` and `DictationSession.lastTranscript` are both replaced when the
    /// next dictation reaches `.recording`, and `DictationController.repasteLast()` pastes
    /// `lastTranscript` -- so a panel that outlived its dictation would show one transcript and
    /// paste another. The next `.recording` produces a `standing` of nil or an alert, and this
    /// function passes that through.
    public static func visible(
        problem: StandingProblem?, dismissed: StandingProblem?
    ) -> StandingProblem? {
        guard let problem else { return nil }
        return problem == dismissed ? nil : problem
    }
}

/// The standing panel's fixed geometry, written as the sum it is, the way `StatusPanelLayout` is.
///
/// Two heights and not one, because the two contents differ by a whole block: an alert is a
/// sentence and a button, a recovery is a sentence, the transcript, and three buttons. The notch's
/// "one size for the whole of a dictation" rule does not reach here -- that rule forbids a *shape
/// on screen* changing size under a sentence being read, and this panel is placed once, per
/// appearance, before it is ordered in.
public enum StandingPanelLayout {
    /// The inset on every edge, inside the panel's own stroke.
    public static let padding: CGFloat = 16

    /// The failure's own sentence: two lines at 12 pt, because `InsertError`'s descriptions are
    /// sentences ("Murmure itself is in front -- click into the app you want the text in.") and
    /// the tail is not the disposable half here the way it is on a 34 pt strip.
    public static let headlineHeight: CGFloat = 34

    /// The transcript. Three lines: enough to recognise which dictation this is, which is all the
    /// panel has to answer -- the whole of it is what Re-paste and Copy deliver, not what is read
    /// here. **Arbitrary in its digits**, and the reason it is not larger is that the panel floats
    /// over the window Louis is working in.
    public static let transcriptHeight: CGFloat = 54

    /// The row of buttons.
    public static let buttonRowHeight: CGFloat = 24

    /// Between the blocks. **Arbitrary.**
    public static let blockSpacing: CGFloat = 12

    /// **Arbitrary in its digits, deliberate against one number: 260, the strip's width.** The
    /// panel is wider than the status strip because it holds a transcript rather than one label,
    /// and it is not much wider because it floats over the window being dictated into.
    public static let width: CGFloat = 380

    /// A recovery: sentence, transcript, buttons.
    public static let recoveryHeight =
        padding * 2 + headlineHeight + blockSpacing + transcriptHeight + blockSpacing
            + buttonRowHeight

    /// An alert: sentence, buttons.
    public static let alertHeight =
        padding * 2 + headlineHeight + blockSpacing + buttonRowHeight

    /// The size this problem needs.
    public static func size(for problem: StandingProblem) -> CGSize {
        switch problem {
        case .recovery: CGSize(width: width, height: recoveryHeight)
        case .alert: CGSize(width: width, height: alertHeight)
        }
    }
}
