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

    /// - If a window already exists (Louis closed it earlier this launch, then clicked the Dock
    ///   icon again): front it directly and return `false` -- AppKit does not need to do anything
    ///   else.
    /// - If none exists yet: mark one as expected and return `true`, so AppKit's default reopen
    ///   handling presents the `Window` scene itself; `WindowController.adopt(_:)` then fronts it
    ///   because D17's guard now sees `wasAskedFor == true`.
    ///
    /// **This second path is unverified by any automated test.** There is no test bundle for
    /// `Murmure/`, and nothing here is something an agent may click through without launching the
    /// app on Louis's own desktop. It relies on SwiftUI's default reopen behaviour actually
    /// presenting the `Window` scene when this method returns `true`, and is verified by the user's
    /// own eye-gate: quit Murmure, launch it, click the Dock tile.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let windowController else { return true }
        if windowController.frontIfOpen() {
            return false
        }
        windowController.expectWindow()
        return true
    }
}
