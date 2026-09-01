import Foundation

/// Every word the menu bar shows, in one place.
///
/// **The reason this is a table is not the table.** These strings lived as literals in
/// `MurmureApp` and `DictationController`, which are in the app target — and the app target has
/// no test bundle, so a label there is a decision nothing can check and nothing can enumerate.
/// Moving them here is what makes `MenuTextTests` able to walk all of them at once and assert a
/// property over the whole set, which is how the language rule below is enforced rather than
/// remembered.
///
/// The second reason is the one Louis's decision came with: **the mix has to disappear, not
/// move.** The menu was French in places ("Recoller la dernière transcription") and English in
/// others ("Quit"), which is the state a window with six English section names would have made
/// worse. English throughout, decided 2026-09-01. If French ever comes back it is this file and
/// `AppAlert.message`, not a hunt through five views — the same argument `WindowPalette` makes
/// about colours.
public enum MenuText {
    /// The mode the dictation in progress is running under. Not a checkmark: with "Automatic"
    /// ticked the checkmarks cannot answer which mode actually won.
    public static func activeMode(_ name: String) -> String {
        "Mode: \(name)"
    }

    /// The "let the rules decide" item. A real choice and the shipped one, not the absence of a
    /// choice — see `ModeSelection`.
    public static let automaticMode = "Automatic"

    /// The window, from the only entry point there is: an accessory app is not in ⌘Tab.
    public static let openWindow = "Open Murmure Window"

    /// The two recoveries. The second is the one that survives a denied Accessibility, where
    /// `CGEvent.post` does nothing and the clipboard is the only way the transcript leaves
    /// Murmure.
    public static let repasteLastTranscription = "Paste last transcription again"
    public static let copyLastTranscription = "Copy last transcription"

    /// The re-paste itself failed. Says which failure, because the remedies differ.
    public static func repasteFailed(_ reason: String) -> String {
        "Could not paste again: \(reason)"
    }

    public static let quit = "Quit"

    /// Every fixed label above, for a test to walk. Parameterised strings are exercised by name in
    /// the test rather than listed here, because a sample value chosen at this end would be the
    /// test writing its own input.
    public static let allFixedLabels: [String] = [
        automaticMode, openWindow, repasteLastTranscription, copyLastTranscription, quit,
    ]
}
