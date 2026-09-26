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
///
/// **One label here is not a menu item**: ``revealTranscriptsFolder`` is the Transcripts pane's own
/// button. It lives in this table for the same reason the rest do — it is a decision nothing else
/// can check — and it is the only new interface word the transcripts lot adds (R3).
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

    /// The Transcripts panel's button: show the folder the transcripts live in, in the Finder.
    ///
    /// **This is what the R3 decision is compensated with, and it is the whole of it.** The
    /// transcripts moved under `Application Support/Murmure/Transcripts` so that writing them
    /// needs no macOS permission — and the price of that move is that the Finder never shows them
    /// on its own. A window whose library is invisible is a library the user believes he has lost,
    /// and the button is the one click that answers "where are my transcripts?".
    ///
    /// **Not an action of a tile** (criterion 17 is open and delete, nothing else): the button
    /// belongs to the panel, above the grid. Wording follows the two buttons that already reveal a
    /// folder in this window (`RevealTarget.buttonTitle`) — "Reveal <Subject> Folder" — because
    /// it is the third such button and one casing rule per surface is the rule `Keycap` set for
    /// key names.
    ///
    /// **C'est ce libellé-ci que le bouton du panneau Transcripts affiche**, et le contrat de
    /// `MenuTextTests` le fige mot pour mot : le bouton et le dossier qu'il ouvre ne peuvent donc
    /// pas dériver l'un de l'autre. Le panneau le lit au lieu de l'écrire — un mot d'interface
    /// écrit dans une vue échappe à la règle de langue ci-dessous, qui ne voit que cette table.
    public static let revealTranscriptsFolder = "Reveal Transcripts Folder"

    // MARK: - Lot 10 : le lancement, la fin, l'échec

    /// The menu's launch entry (plan §2.7): paste a link, and Murmure transcribes it.
    ///
    /// **The plan's own wording, and the only launch path there is.** "Fichier local" reaches the
    /// app through `CFBundleDocumentTypes` (drop on the Dock icon, "Open with"), and a URL reaches
    /// it either here — pasted — or through the Transcripts pane's drop target. There is no
    /// `http`/`https` declaration (tour 7, R1: it would make Murmure a candidate handler for every
    /// link on the machine) and no global shortcut (tour 4: the dictation keeps ⌥Space).
    ///
    /// A menu item whose title is empty is not a menu item, so the sentinel is what
    /// `MenuTextTests` catches first.
    public static let newTranscription = "New Transcription"

    /// The notification that a video job **finished** (criterion 18, decision R6).
    ///
    /// The notification is how the end of a transcription is announced when the window is
    /// closed — and the queue (criterion 19) is exactly what makes that necessary: with three
    /// links in a row, the answer arrives minutes after the click, on a window Louis has left.
    ///
    /// R6's refusal case keeps the badge and the progress bar: what a refusal costs is this
    /// sentence, not the outcome.
    public static let transcriptionFinished = "Transcription finished"

    /// The notification that a video job **failed**. Its own sentence, not the one above with a
    /// different body: the two send Louis to different places (the transcript, or the reason), and
    /// the contract for the queue says a failure does not stop the rest — so a failure that read
    /// as a completion would hide a dead link behind the next notification.
    public static let transcriptionFailed = "Transcription failed"

    /// The body of those notifications: the transcript's own title, left exactly as it is.
    ///
    /// **Why this is a decision and not a line in the notifier.** `Murmure/` has no test bundle,
    /// so "what does the notification say about *which* transcript finished?" written there would
    /// be a decision nothing can read. The answer matters here and nowhere else: with three links
    /// queued, `transcriptionFinished` alone says that something ended, not what.
    ///
    /// **The title is the user's own text** — it may be French, Japanese, or empty — so this
    /// string is deliberately **not** one of ``allFixedLabels``: the language rule the test
    /// enforces covers the words Murmure owns, and this one is the video's. An empty title gives
    /// an empty body, and the notification shows its title alone rather than inventing a word
    /// (the rule `TranscriptTile.summary` follows for the same reason).
    public static func notificationBody(_ title: String) -> String {
        // The video's title, passed through. Nothing is prefixed, suffixed or quoted: an empty
        // title gives an empty body, and the notification then shows its title alone rather than
        // a word nobody wrote.
        title
    }

    public static let quit = "Quit"

    /// Every fixed label above, for a test to walk. Parameterised strings are exercised by name in
    /// the test rather than listed here, because a sample value chosen at this end would be the
    /// test writing its own input.
    ///
    /// ``revealTranscriptsFolder`` is listed with the rest even though it is a pane's button and
    /// not a menu item: the language rule below only ever sees what is in here, and a label left
    /// out of this list is a label the rule does not cover.
    ///
    /// **Lot 10's three words belong in this list** — the launch entry and the two notifications.
    /// `MenuTextTests` freezes their wording *and* their membership here, for the same reason the
    /// pane's button is listed: a word that is not in this array is a word no rule sees.
    /// ``notificationBody(_:)`` is the one lot-10 string that stays out: it carries the user's own
    /// title, not a word Murmure owns.
    public static let allFixedLabels: [String] = [
        automaticMode, openWindow, repasteLastTranscription, copyLastTranscription,
        revealTranscriptsFolder, newTranscription, transcriptionFinished, transcriptionFailed, quit,
    ]
}
