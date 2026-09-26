import AppKit
import UserNotifications

/// Handles the AppKit lifecycle events `MurmureApp`'s SwiftUI scenes cannot: a click on the Dock
/// tile, a file dropped on the icon, and the notification banner.
///
/// A Dock click: macOS pins that to `applicationShouldHandleReopen`, not to any SwiftUI environment
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
/// built (never a global singleton). What a *drop* needs routes the same way: ``transcribe`` is
/// handed over by `MurmureApp.body`, once the pane that owns the queue exists.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var windowController: WindowController?

    /// Where a source asked for by an AppKit surface goes: a file dropped on the icon, or opened
    /// through "Open With" (both declared by `CFBundleDocumentTypes`, plan §2.7). The pane model
    /// answers it -- it is the thing that owns the library and the queue -- and it is handed in
    /// rather than looked up for the reason `windowController` is: no global, one writer.
    ///
    /// `String` and not `URL`: a drop on the icon is always a file, `application(_:open:)` may hand
    /// over a link a browser registered, and the pane's launch path is written in terms of the text
    /// the user would have pasted (`TranscriptsPaneModel.launch(for:)` decides what it reads).
    var transcribe: (@MainActor (String) -> Void)?

    /// The control server, and its ONLY owner (lot 11-S).
    ///
    /// `nil` until `MurmureApp` has handed over the 10-S seams; the real startup belongs to this
    /// delegate, never to a harness — `start()` had no caller at all until here, and the control
    /// that started it in its own harness proved nothing about the Finder path.
    private var controlServer: TranscriptControlServer?

    /// `true` once `applicationDidFinishLaunching` has run: a handover arriving AFTER the launch
    /// still starts the server, and exactly once.
    private var applicationLaunched = false

    /// The handover, **idempotent** (criterion 2): the configuration may arrive before or after
    /// the launch, and a second configuration creates no second server.
    ///
    /// The guard is a real early return, not a logged `if`: a delegate that re-configures would
    /// otherwise build a second listener on one socket path, and `start()` does `unlink` then
    /// `bind` — the second server would *steal* the socket from the first.
    func configureControlServer(
        submitteur: @escaping @Sendable (String) async -> ControlJobHandle,
        fournisseurStatut: @escaping @Sendable () async -> String
    ) {
        guard controlServer == nil else { return }
        controlServer = TranscriptControlServer(
            submitteur: submitteur, fournisseurStatut: fournisseurStatut)
        if applicationLaunched { controlServer?.start() }
    }

    /// The one thing this delegate sets up at launch, and it asks nothing of anybody: no prompt, no
    /// authorization request -- criterion 18's R6 decision puts that at the FIRST LAUNCHED JOB, in
    /// `TranscriptNotifier`. What it changes is the single case where a notification would
    /// otherwise be swallowed: macOS does not show a banner for an app that is frontmost, so a
    /// transcription ending while Louis is looking at the pane would say nothing at all.
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        applicationLaunched = true
        // The Finder path: the server starts HERE, once, and nowhere else.
        controlServer?.start()
    }

    /// Termination takes the socket away: a socket with no listener behind it makes the CLI's
    /// `connect` fail with `ECONNREFUSED` instead of telling it the application is gone.
    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
    }

    /// A file dropped on Murmure's icon, or "Open With Murmure". The declaration that makes this
    /// reachable is `CFBundleDocumentTypes` in `Info.plist` -- and it is the *local* half of plan
    /// §2.7 only: **no `http`/`https` is declared** (decision R1), so dropping a link on the icon
    /// does not exist and a browser link arrives through the pane's drop target instead.
    ///
    /// Sent by AppKit on the main thread, and only for a running app that was asked for. Launching
    /// Murmure by dropping a file on its icon sends it right after
    /// `applicationDidFinishLaunching(_:)`, which is why the launch path does not depend on a
    /// window being up.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            transcribe?(url.isFileURL ? url.path : url.absoluteString)
        }
    }

    /// Shows the banner even when Murmure is the active app.
    ///
    /// Without this method the notification is *delivered* (it lands in Notification Center) and
    /// never *shown*: the default for a frontmost app is silence, and the work this app announces
    /// runs for minutes while the very window that started it is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

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
