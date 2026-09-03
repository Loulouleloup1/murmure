import AppKit
import Foundation
import MurmureCore

/// Showing one of Murmure's own files or folders in the Finder. **One implementation, for the two
/// panes that offer it.**
///
/// It exists because there were two, and they disagreed on both halves of the job. The Modes pane
/// created `modes/` and then `NSWorkspace.open`ed it; the Advanced pane created nothing and
/// `activateFileViewerSelecting`ed it. So "Reveal Modes Folder", pressed from two places in one
/// window, opened two different things — and only one of them was capable of building a folder in
/// Louis's Application Support as a side effect of a button whose whole promise is that it only
/// looks.
///
/// **Nothing here creates anything**, which is the Advanced pane's rule and the correct one. The
/// creation the Modes pane did was already redundant twice over: `DictationController.init` calls
/// `Storage.directory(subfolder: "modes")` on every launch that can reach Application Support, and
/// `ModeStore.save` creates the folder before it writes into it. So the only state in which the
/// reveal had anything left to create is the one where those two also failed — Application Support
/// is unreachable — and creating it from here would either fail the same way or, worse, succeed at
/// a moment when the reader has been told nothing about why his modes vanished.
/// `RevealTarget.missingNote` is the answer instead: it names the event that will create the
/// thing, which is what someone pressing the button actually needs to know.
///
/// **What is opened is `RevealTarget.isDirectory`'s answer, never the caller's**, and that is the
/// one place the two implementations were both right. A folder is OPENED, so the window shows the
/// `*.json` files or the WAVs that are the reason for the press (the Modes pane's argument, design
/// notes §6: these files are meant to be edited by hand). A file is SELECTED in its parent, which
/// is the only way to show `vocabulary.json` where it lives — beside two folders rather than in
/// one (the Advanced pane's argument). Deriving it from the same property that already derives the
/// button's own noun is what stops a button that says "Folder" from opening something else.
@MainActor
enum FinderReveal {
    /// Shows `target` in the Finder. Returns nil when it did, and the sentence to put on screen
    /// when it did not — the shape both panes' `problem` state already has, so neither can drop
    /// the answer on the floor (ruling L7).
    static func show(_ target: RevealTarget, inSupportFolder base: URL) -> String? {
        let url = target.url(inSupportFolder: base)
        // Asked before either call below, because neither of them says no. `open` returns false,
        // but `activateFileViewerSelecting` returns nothing at all on a path that is not there:
        // without this, a missing `vocabulary.json` is a button that does nothing and explains
        // nothing, which is `RevealTarget`'s own opening argument.
        guard FileManager.default.fileExists(atPath: url.path) else { return target.missingNote }
        guard target.isDirectory else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return nil
        }
        // The path rather than a noun for the target: the file exists, so a refusal here is the
        // Finder's and not Murmure's, and the only thing Murmure can usefully add is where it was
        // pointing.
        return NSWorkspace.shared.open(url) ? nil : "The Finder would not open \(url.path)."
    }
}
