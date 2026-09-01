import Foundation

/// A selection that could not be honoured as asked. Both cases are hand-editing mistakes, and
/// neither shows in the outcome -- another mode simply runs, with a plausible result. Reported
/// one by one so the report can name the file to fix, exactly like `ModeLoadProblem`.
public enum ModeSelectionProblem: Equatable, CustomStringConvertible {
    case unknownManualSelection(key: String)
    case autoActivateConflict(bundleID: String, claimedBy: [String], selected: String)

    public var description: String {
        switch self {
        case .unknownManualSelection(let key):
            "selected mode \(key.debugDescription) no longer exists; falling back to the other rules"
        case .autoActivateConflict(let bundleID, let claimedBy, let selected):
            """
            \(bundleID) is in the "autoActivate" of \(claimedBy.joined(separator: ", ")); \
            \(selected.debugDescription) wins, being the first key in alphabetical order. Remove \
            the bundle id from the others.
            """
        }
    }
}

/// Which mode a recording runs under (spec §5).
///
/// Resolved when the recording *starts*, not when it ends: what decides is the application Louis
/// was looking at while speaking, not the one he may have switched to since.
///
/// The frontmost bundle id is a parameter rather than a `NSWorkspace` read inside, for two
/// reasons: the app target has no test bundle, so anything untestable in `MurmureCore` is
/// untested; and the caller already knows *when* to sample it, which is the whole point above.
public enum ModeSelection {
    /// The three rules of spec §5, in order:
    ///
    /// 1. `manualKey` -- an explicit choice, which nothing may overrule behind his back.
    /// 2. a mode whose `autoActivate` contains `frontmostBundleID`.
    /// 3. `Voice`, the default mode.
    ///
    /// `report` has no default value on purpose: a caller that dropped it would be told nothing
    /// about two modes fighting over one app, which is the case this function exists to make
    /// predictable.
    public static func resolve(
        among modes: [Mode], manualKey: String?, frontmostBundleID: String?,
        report: (ModeSelectionProblem) -> Void
    ) -> Mode {
        if let manualKey {
            if let manual = modes.first(where: { $0.key == manualKey }) { return manual }
            // Falling through rather than returning `Voice` here: the selection is stale, so the
            // remaining rules are the best answer left. The report is what makes the menu saying
            // "Prompt" and the mode being another one explainable.
            report(.unknownManualSelection(key: manualKey))
        }

        if let frontmostBundleID {
            // Sorted by key, and the first one wins. `key` is the file name, so the winner is
            // readable from the folder listing without running anything, it is the same at every
            // launch, and it does not depend on the order `loadAll()` happened to return -- that
            // order comes from `contentsOfDirectory`, which is the file system's business.
            // Rejected: "the first one loaded" (file-system order), "the most recently edited
            // file" (changes when an unrelated field is touched), "the most specific claim"
            // (`autoActivate` is a flat list of exact ids -- there is no specificity to rank).
            let claimants = modes
                .filter { $0.claims(frontmostBundleID) }
                .sorted { $0.key < $1.key }

            if let selected = claimants.first {
                // Almost always a typo -- a bundle id pasted into a second mode and left in the
                // first. The tie-break makes the outcome stable, not correct; only he can say
                // which mode he meant.
                if claimants.count > 1 {
                    report(.autoActivateConflict(bundleID: frontmostBundleID,
                                                 claimedBy: claimants.map(\.key),
                                                 selected: selected.key))
                }
                return selected
            }
        }

        // `ModeStore.loadAll()` guarantees a `voice` entry, standing in with the built-in when the
        // file is broken. The built-in here keeps this function total for any other caller.
        return modes.first { $0.key == Mode.voice.key } ?? .voice
    }
}

extension Mode {
    /// Bundle ids are compared without case. `autoActivate` is typed by hand and the
    /// capitalisation of `com.apple.Terminal` is invisible to the eye, while getting it wrong
    /// produces a mode that simply never activates, with nothing at all to see.
    fileprivate func claims(_ bundleID: String) -> Bool {
        autoActivate.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}
