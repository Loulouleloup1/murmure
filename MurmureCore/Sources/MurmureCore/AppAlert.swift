import Foundation

/// Something wrong with Murmure itself, rather than with one dictation.
///
/// The distinction is not a category, it is a lifetime. A `NotchPhase` belongs to the dictation
/// that produced it and is gone when that dictation is: `DictationController` clears
/// `clipboardWarning`, `lastFailureMessage`, `recoveredText` and `refinementNotice` on the next
/// `.recording`, and the surfaces retract on their own dwell. These two outlive every dictation,
/// because what is broken is the app's access to the system and pressing the hotkey again does
/// not repair it. `AppState.modeProblems` is a third of the same shape and stays in the menu
/// (lot 3 D14) -- it is one line per file to edit, which is a list, not an alert.
///
/// Here rather than in the app target for the reason the rest of this package exists: the
/// `Murmure` target has no test bundle, so the ranking below and the strings would be decisions
/// nothing can check. What genuinely cannot cross is the two calls that produce and consume
/// these: `AXIsProcessTrusted()`, which reads a system trust database, and `NSWorkspace.open`,
/// which opens `settingsURL`. The URL itself is a value and stays here -- a typo in it opens
/// nothing at all and reports no error, which is exactly the failure a test can catch and a
/// reader cannot.
///
/// **Declaration order is severity order**, ascending, and `mostSevere(among:)` is the only
/// reader of that fact. See its note for why the hotkey outranks Accessibility.
public enum AppAlert: String, Equatable, Sendable, CaseIterable {
    /// Carbon refused ⌥Space at launch, because another application already holds it
    /// (`DictationController.init`). There is no retry: the combination is taken for as long as
    /// that application runs.
    case hotkeyUnavailable

    /// `AXIsProcessTrusted()` is false, so `CGEvent.post` does nothing at all and reports nothing
    /// (`PasteInserter.insert`, which is why it throws before touching the clipboard).
    ///
    /// **Checked at launch AND at the start of every dictation.** Permission survives in a system
    /// database keyed by the app's code signature, and a rebuild changes that signature: Louis
    /// lost Accessibility silently that way, and the only symptom was a ⌘V that did nothing. A
    /// launch-only check would have gone on reporting the state of the world at launch for as long
    /// as the app stayed running, which is a lie told with a stale value.
    case accessibilityDenied

    /// What Murmure says about it, in one line.
    ///
    /// English, decided 2026-09-01 with the rest of the interface -- and translated HERE rather
    /// than moved into `MenuText`, because this is already the table for these two sentences and a
    /// second layer of indirection over it would buy nothing. `hotkeyUnavailable`'s is the sentence
    /// `MurmureApp`'s menu shows, read off this property rather than rewritten: the menu and the
    /// surfaces are two places the same problem is read, and two wordings would be a difference
    /// Louis has to learn for nothing.
    public var message: String {
        switch self {
        case .hotkeyUnavailable:
            "⌥Space unavailable — another app holds the shortcut"
        case .accessibilityDenied:
            "Accessibility denied — Murmure cannot paste anything"
        }
    }

    /// The button on the standing panel, or nil when there is nothing to click.
    ///
    /// Nil for the hotkey deliberately. Nothing Murmure can open helps: the combination belongs to
    /// another running application, and the only fixes are quitting that application or choosing
    /// another shortcut, which is a settings window lot 3 does not have (plan, out of scope). A
    /// button that opened a pane where the problem is not visible would be worse than none.
    public var actionTitle: String? {
        switch self {
        case .hotkeyUnavailable: nil
        case .accessibilityDenied: "Open Settings…"
        }
    }

    /// Where that button goes.
    ///
    /// Spec §9's deep link, verbatim. The pane identifier is still `com.apple.preference.security`
    /// on the System Settings of macOS 13 and later -- the panes were renamed, their identifiers
    /// were not -- and `Privacy_Accessibility` is the anchor within it.
    ///
    /// A `String` rather than a `URL` because `URL(string:)` is failable and a non-optional
    /// `URL` here would need a force-unwrap in a package that has none. The app parses it once;
    /// `AppAlertTests` parses it too, so a typo fails a test rather than opening nothing.
    public var settingsURL: String? {
        switch self {
        case .hotkeyUnavailable: nil
        case .accessibilityDenied:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
    }

    /// The one alert to show, when more than one is standing.
    ///
    /// **The hotkey outranks Accessibility, and it is a containment argument rather than a taste.**
    /// Without ⌥Space no dictation can start at all, so there is never a transcript for the paste
    /// to refuse -- the Accessibility problem is real and unreachable. Showing the reachable one
    /// first is what makes fixing them one at a time terminate: repair the hotkey, dictate, and the
    /// next check surfaces the other. Reversed, Louis would grant Accessibility and press a key
    /// that still does nothing.
    ///
    /// Reads `allCases`, whose order is the declaration order above, so adding a case in the right
    /// place is the whole of ranking it. Nil for an empty list, which is the ordinary state.
    public static func mostSevere(among alerts: [AppAlert]) -> AppAlert? {
        allCases.first(where: alerts.contains)
    }
}
