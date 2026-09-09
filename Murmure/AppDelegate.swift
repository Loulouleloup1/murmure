import AppKit

/// Handles the one AppKit lifecycle event `MurmureApp`'s `Window` scene cannot: a click on the
/// Dock tile. macOS pins that to `applicationShouldHandleReopen`, not to any SwiftUI environment
/// action -- `openWindow` is unreachable here, because this is not a view.
///
/// Murmure is `LSUIElement: true`, so before this existed a Dock click did nothing at all: AppKit
/// asked SwiftUI to reopen the window, SwiftUI presented the `Window` scene, and
/// `WindowController.adopt(_:)`'s D17 guard -- built for the launch case, where a window appearing
/// unasked-for is AppKit restoring one nobody wanted -- saw `wasAskedFor == false` and ordered it
/// straight back out. The fix is telling the controller a window is now legitimately expected
/// before AppKit gets there.
///
/// Owns no reference of its own to `AppState` or `DictationController`: everything a Dock click
/// needs to do routes through `WindowController`, which `MurmureApp.init` hands over after both are
/// built (never a global singleton).
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: WindowController?

    /// Delegates entirely to `WindowController.reopen()`, which now handles both the "window
    /// exists, even dormant" case and the "no window yet, but an `OpenWindowAction` was captured
    /// from the menu bar label" case by presenting the scene itself -- so this no longer relies on
    /// SwiftUI's default reopen behaviour for anything but the last-resort fallback inside
    /// `reopen()` itself, for the case where no `OpenWindowAction` has been captured yet.
    ///
    /// `reopen()` returning `true` means it handled everything; AppKit must not also do its default
    /// reopen, hence the negation. Returning `false` means the fallback ran and AppKit's own
    /// handling is still wanted.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let windowController else { return true }
        return !windowController.reopen()
    }
}
