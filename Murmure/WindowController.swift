import AppKit
import MurmureCore
import SwiftUI
import os

/// The one application window: whether it is up, where it sits, and which section it is on.
///
/// **There can never be a second one, and that is structural rather than defended.** The scene is
/// a SwiftUI `Window`, which is single-instance by construction — unlike `WindowGroup`, it cannot
/// be asked to make another. So `show(using:)` has nothing to deduplicate; what it has to do is
/// bring the existing one forward and take the keyboard, which an accessory app does not get for
/// free (plan §2.4, consequence 2).
///
/// Everything decidable was pushed into `MurmureCore` — `WindowSection`, `WindowRestoration`,
/// `WindowPalette`, `WindowLayout` — because `Murmure` has no test bundle. What is left here is
/// AppKit: an `NSWindow`, an activation policy and four notifications, none of which a test bundle
/// could reach anyway.
@MainActor
final class WindowController: ObservableObject {
    /// The scene identifier `openWindow(id:)` is given. Not a storage name — nothing persists it.
    static let windowID = "murmure-main"

    /// Which section the sidebar has selected. Written through to the defaults domain on every
    /// change rather than at close, because a crash or a `kill -9` during development is the
    /// normal way this app stops.
    @Published var section: WindowSection {
        didSet { restoration.section = section }
    }

    private let restoration: WindowRestoration
    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "window")

    /// Weak: AppKit owns the window, and SwiftUI is free to tear it down when it is closed. A
    /// strong reference here would keep a closed window alive and make "is it up" unanswerable.
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    /// Captured once, at launch, from the menu bar label's environment -- see `OpenWindowCapture`
    /// in `MurmureApp`. This is what lets `reopen()` present the `Window` scene itself instead of
    /// relying on AppKit's default reopen handling, which does not re-present a `Window` scene
    /// whose `NSWindow` already exists hidden.
    private var openWindowAction: OpenWindowAction?

    /// Whether Louis has actually asked for the window during this launch.
    ///
    /// D17 — "the window does not open at launch, ever" — is not something SwiftUI offers a switch
    /// for on macOS 14: a `Window` scene may be built at launch whether or not anything asked for
    /// it, and `.restorationBehavior(.disabled)` is macOS 15. Murmure is a hotkey that pastes text,
    /// so a window at launch is a window at every login. This flag is the whole enforcement: a
    /// window that appears without having been asked for is ordered straight back out.
    private var wasAskedFor = false

    init(defaults: UserDefaults) {
        restoration = WindowRestoration(defaults: defaults)
        // Reads the stored section; `didSet` does not fire from an initialiser, which is what is
        // wanted -- this reads a choice, it does not make one. Same shape as `AppState`'s
        // `manualModeKey`.
        section = restoration.section
    }

    // MARK: - The one line that reverts Q-B1

    /// **D2, entire.** `LSUIElement` stays `true` in the plist; the policy moves at runtime.
    ///
    /// `.regular` while the window is up buys a real menu bar — hence the Edit menu, hence ⌘V and
    /// ⌘Z in a text field — plus a Dock icon and a ⌘Tab entry, for exactly as long as the window
    /// is there. `.accessory` when it goes buys back the invisibility Murmure spends 99.9 % of its
    /// life in.
    ///
    /// It is one function so that reverting it is one line: replacing the body with
    /// `NSApp.setActivationPolicy(.accessory)` puts the app back where it was before this lot,
    /// with the window still working and only the editing key equivalents in question. That is the
    /// escape hatch the plan asked for, and the eye-gate that decides whether it is needed.
    private func setActivationPolicy(windowIsUp: Bool) {
        NSApp.setActivationPolicy(windowIsUp ? .regular : .accessory)
    }

    // MARK: - Opening it

    /// Front the window, opening it if it is not there yet.
    ///
    /// `openWindow` is handed in rather than read here: `OpenWindowAction` is a SwiftUI
    /// environment value and this is not a view. It is called unconditionally because it is the
    /// only thing that can present a `Window` scene, and because it cannot open a second one.
    ///
    /// **`NSApp.activate()` comes before `makeKeyAndOrderFront`**, and the order is the point
    /// (§2.4): an accessory app that orders a window front without activating first gets a window
    /// on screen with no keyboard focus, and the first thing Louis types goes to the app he was
    /// in. macOS 14's `activate()` — not the deprecated `activate(ignoringOtherApps:)`.
    func show(using openWindow: OpenWindowAction) {
        register(openWindow: openWindow)
        wasAskedFor = true
        setActivationPolicy(windowIsUp: true)
        openWindow(id: Self.windowID)
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            // The window is being built right now. `adopt(_:)` fronts it when SwiftUI has attached
            // it, which is the same call one runloop turn later.
            log.debug("window not built yet -- fronting deferred to adopt(_:)")
        }
    }

    /// Remembers the `OpenWindowAction` handed over from the menu bar label or the menu item, so
    /// that `reopen()` can present the `Window` scene without needing a view of its own. Idempotent
    /// -- called again on every relayout of the capturing view, and every menu item click.
    func register(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
    }

    /// Handles a Dock-tile click (`AppDelegate.applicationShouldHandleReopen`), which is not a view
    /// and cannot read `OpenWindowAction` from the environment. Returns whether the click was
    /// handled here: `true` means AppKit's default reopen handling must not also run.
    ///
    /// Three cases, in order:
    /// - A window already exists -- up, or dormant from `adopt(_:)`'s D17 guard having kept it
    ///   rather than forgotten it -- so front it directly, the same way `show(using:)` does.
    /// - No window, but the label's `onAppear` already captured an `OpenWindowAction` -- call
    ///   `show(using:)` with it, which does everything `openWindow` in a view would have done.
    /// - Neither -- the action has not been captured yet, which should not happen after launch but
    ///   is not asserted against. Falls back to `expectWindow()` and returns `false`, the original
    ///   behaviour that relies on SwiftUI's default reopen presenting the scene.
    func reopen() -> Bool {
        if let window {
            wasAskedFor = true
            setActivationPolicy(windowIsUp: true)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return true
        }
        if let openWindowAction {
            show(using: openWindowAction)
            return true
        }
        expectWindow()
        return false
    }

    /// Marks a window as expected without opening one -- for the Dock-click case where none
    /// exists yet and `AppDelegate.applicationShouldHandleReopen` is about to let AppKit's default
    /// reopen handling present the `Window` scene on its own. Without this, `adopt(_:)`'s D17
    /// guard would see `wasAskedFor == false` and order the freshly-presented window straight back
    /// out, which is the bug this file exists to fix.
    func expectWindow() {
        wasAskedFor = true
        setActivationPolicy(windowIsUp: true)
    }

    /// Called by `WindowAccessor` the moment SwiftUI has put the content in a real `NSWindow`.
    ///
    /// Idempotent per window: it runs again on every view update, and everything below either
    /// happens once per `NSWindow` or is a no-op.
    func adopt(_ window: NSWindow) {
        guard window !== self.window else { return }

        releaseObservers()
        self.window = window
        window.minSize = NSSize(
            width: WindowLayout.minimumSize.width, height: WindowLayout.minimumSize.height)

        // The frame is restored only if it lands somewhere reachable — `WindowRestoration` decides
        // that against the displays attached right now, which is why the screens are read here and
        // not stored. When it refuses, AppKit's own placement stands and is saved on the first
        // move, so the next launch has a usable frame again.
        if let frame = restoration.frame(onScreens: NSScreen.screens.map(\.visibleFrame)) {
            window.setFrame(frame, display: false)
        }

        observe(window)

        // D17. Nothing asked for this window, so it is AppKit or SwiftUI having decided to restore
        // one. Kept dormant rather than forgotten -- it is `self.window` from here on, so a later
        // Dock click or menu item fronts this same instance instead of asking SwiftUI to build a
        // second one. Ordered out rather than closed: `close()` runs a lifecycle SwiftUI may not
        // expect this early, and `orderOut` leaves the scene able to present itself normally later.
        guard wasAskedFor else {
            log.debug("a window appeared unasked-for at launch -- kept dormant, ordered out (D17)")
            window.orderOut(nil)
            return
        }

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Remembering where it was

    private func observe(_ window: NSWindow) {
        let centre = NotificationCenter.default

        // Both halves of "where it was left". `didMove` fires throughout a drag and
        // `didEndLiveResize` only when the drag of an edge finishes -- writing four doubles into a
        // preferences domain is cheap enough for the first and the second is where the expensive
        // one would have been.
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(
                centre.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.saveFrame() }
                })
        }

        observers.append(
            centre.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.saveFrame()
                    // Plan §2.4 consequence 4 and D2's other half: closing the window puts Murmure
                    // back to being invisible. It must not terminate the app -- and it does not,
                    // because nothing here calls `terminate` and `applicationShouldTerminateAfter\
                    // LastWindowClosed` defaults to false.
                    self?.setActivationPolicy(windowIsUp: false)
                }
            })

        // `terminate(nil)` -- which is what the menu's Quit calls -- does not reliably close
        // windows through `willClose` first, so without this the size Louis quit at is the one
        // thing that would not survive a quit.
        observers.append(
            centre.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveFrame() }
            })
    }

    private func releaseObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func saveFrame() {
        guard let window, window.isVisible else { return }
        restoration.storedFrame = window.frame
    }
}

/// The bridge from `MurmureCore`'s token table to SwiftUI, and **the only place in `Murmure/` that
/// is allowed to name a colour**.
///
/// That rule is the condition attached to shipping this lot dark-only (Q-NB6): dark-only is cheap
/// now and expensive to retrofit, and the entire difference is whether the colours live in one
/// table or are spread across five panes. A single `Color(white: 0.2)` written into a view is what
/// turns "write a second table" into "revisit five panes".
extension Color {
    init(role: WindowRole) {
        let token = WindowPalette.token(for: role)
        self.init(
            hue: token.hue, saturation: token.saturation,
            brightness: token.brightness, opacity: token.opacity)
    }
}
