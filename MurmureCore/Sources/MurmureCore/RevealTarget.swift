import Foundation

/// The three things the Advanced pane can open in the Finder.
///
/// **Here rather than in the view because a wrong path is a button that does nothing and says
/// nothing.** `NSWorkspace.activateFileViewerSelecting` on a URL that is not there returns without
/// complaining, so `recording/` for `recordings/` would be a control that looks fine, compiles
/// fine, and is dead. The names below are the ones `Storage`, `AudioRecorder` and
/// `DictationController` already write, and a test pins them against `Storage` itself.
///
/// Why the pane has these at all: design notes §6 makes the case for the modes folder -- Application
/// Support is the correct home but "it does hide them", and these files are meant to be opened in a
/// text editor. The same is true of `vocabulary.json`, which is hand-editable by design, and of
/// `recordings/`, which is the only way to hear a WAV the retention sweep has not taken yet.
public enum RevealTarget: CaseIterable, Sendable {
    /// `modes/` -- the JSON files spec §5 makes hand-editable.
    case modes
    /// `recordings/` -- the WAVs, until the 3-day sweep takes them.
    case recordings
    /// `vocabulary.json`. **A file, not a folder**, and it lives directly in `Murmure/` beside the
    /// two folders above (Q-NB3) rather than in one of its own. Revealing it selects it in the
    /// enclosing folder, which is `activateFileViewerSelecting`'s whole behaviour and is why this
    /// case is not a hardship.
    case vocabulary

    /// Whether the target is a folder. The one fact the other three members are derived from, so
    /// the URL and the button cannot end up disagreeing about what is being opened.
    ///
    /// Written without a `default`: a fourth target has to say which it is, because guessing wrong
    /// is `Storage`'s own measured bug one line down.
    public var isDirectory: Bool {
        switch self {
        case .modes, .recordings: true
        case .vocabulary: false
        }
    }

    /// Where it is, given `Application Support/Murmure`.
    ///
    /// The base is passed in rather than read from `Storage.applicationSupport` here for §5.4's
    /// reason: a test must be able to point this at a temporary directory, and nothing about
    /// resolving a path may reach the real folder. Nothing here creates anything either -- a
    /// reveal that made the folder it was asked to show would answer a question nobody asked, in
    /// Louis's real Application Support directory.
    ///
    /// `isDirectory:` is passed explicitly for the reason `Storage.url(subfolder:)` spells out at
    /// length: the one-argument `appendingPathComponent` STATS the path to decide on a trailing
    /// slash, so without it this answers `.../modes` before the folder exists and `.../modes/`
    /// after -- two unequal URLs for one location.
    public func url(inSupportFolder base: URL) -> URL {
        base.appendingPathComponent(component, isDirectory: isDirectory)
    }

    /// The last path component, which is the part that can be silently wrong.
    private var component: String {
        switch self {
        case .modes: "modes"
        case .recordings: "recordings"
        case .vocabulary: "vocabulary.json"
        }
    }

    /// The button.
    ///
    /// Title case, matching `HistoryClearing.buttonTitle` -- these sit in the same pane, and one
    /// casing rule per surface is the argument `Keycap` already made about key names.
    ///
    /// **The noun is derived from ``isDirectory``, never written per case**, the same way
    /// `HistoryClearing` derives its ellipsis from `requiresConfirmation`: a button promising a
    /// folder that opens a window with one JSON selected in it has mis-described what it did, and
    /// the next thing the reader does is go looking for the folder it meant.
    public var buttonTitle: String {
        "Reveal \(subject) \(isDirectory ? "Folder" : "File")"
    }

    private var subject: String {
        switch self {
        case .modes: "Modes"
        case .recordings: "Recordings"
        case .vocabulary: "Vocabulary"
        }
    }

    /// What to say when it is not on disk yet, instead of opening nothing.
    ///
    /// **Every one of these is a normal state and none of them is a failure**, which is why they
    /// each name the event that will create the thing rather than apologising. `modes/` appears at
    /// the first launch that can reach Application Support, `recordings/` at the first dictation
    /// (`AudioRecorder` makes it, because it is what writes into it), and `vocabulary.json` at the
    /// first word Louis adds -- `VocabularyStore.loadAll()` treats an absent file as an empty list
    /// precisely so it does not have to exist.
    public var missingNote: String {
        switch self {
        case .modes:
            "There is no modes folder yet — Murmure writes it on the next launch that can reach "
                + "Application Support."
        case .recordings:
            "There is no recordings folder yet — the first dictation creates it."
        case .vocabulary:
            "There is no vocabulary.json yet — adding the first word in Vocabulary writes it."
        }
    }
}
