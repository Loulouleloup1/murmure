import AppKit
import DynamicNotchKit
import SwiftUI
import os

/// The one notch surface, and the only object in Murmure allowed to grow it or retract it.
///
/// **The notch is the ROOT component of the interface, not a window glued under it** (lot 3 §2,
/// non-negotiable). Three mechanical facts hold that here, and none of them is a matter of intent:
///
/// 1. **One `DynamicNotch`, built at launch and never rebuilt.** Its content views are
///    `let`-captured by `DynamicNotch.init` (`DynamicNotch.swift:75-77` at tag 1.1.0), so a new
///    state of Murmure has to be new *data* read by those views -- rebuilding the notch to change
///    what it draws would tear the window down and put a new one up, which is the jump.
/// 2. **The panel's frame is never reassigned.** The library sizes it half the screen, anchored
///    top-centre, once, in `initializeWindow` (`DynamicNotch.swift:350-392`) and never calls
///    `setFrame` again. Everything Murmure ever shows happens *inside* that fixed transparent
///    canvas; the visible black shape is a SwiftUI mask that follows its content through
///    `.animation(.smooth, ...)` (`NotchView.swift:56-77`). Morphing is free; resizing is
///    impossible.
/// 3. **Every phase of a dictation is one library state, `.compact`.** `compact()`/`expand()` are
///    the only calls that can produce a discontinuity, so they are rationed: lot 3 spends two per
///    dictation at most.
///
/// Idle is `hide()`, i.e. **no window at all**. Keeping the panel alive in `.compact` with empty
/// wings would still draw `notchSize.width + 2 × topCornerRadius` = 185 + 12 = 197 pt of black
/// against a 185 pt physical cutout (`NotchView.swift:32-34`): a 6 pt black tab poking out on each
/// side of the notch, permanently, over a light menu bar.
@MainActor
final class NotchController {
    private let notch: DynamicNotch<EmptyView, NotchWing, NotchWing>
    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "notch")

    /// The screen the dictation in progress is drawn on, captured once when its recording starts
    /// and passed explicitly to every appearance.
    ///
    /// The library's own defaults are `NSScreen.screens[0]` (`DynamicNotch.swift:173`, `219`) --
    /// the display holding the coordinate origin, which is not the one Louis is typing on. Nil
    /// between dictations, and read rather than re-derived by the later phases: a screen resolved
    /// afresh mid-dictation could move the surface out from under a shape that is meant never to
    /// jump.
    private var dictationScreen: NSScreen?

    /// Appearances and disappearances are chained, never overlapped.
    ///
    /// `compact()` and `hide()` are async and take about 0.4 s of animation, while the state
    /// changes that drive them arrive as fast as the pipeline emits them -- a dictation that fails
    /// to start goes `.recording` → `.failed` in far less than that. Awaiting the previous
    /// transition means the last state change wins, instead of two animations racing over one
    /// window.
    private var transition: Task<Void, Never>?

    init() {
        notch = DynamicNotch(
            // `.all` minus `.hapticFeedback`: the pointer crosses the notch on every trip to the
            // menu bar, and a tap of feedback on an accidental crossing is a notification about
            // nothing. `.keepVisible` and `.increaseShadow` are what a hover is meant to do.
            hoverBehavior: [.keepVisible, .increaseShadow],
            expanded: { EmptyView() },
            compactLeading: { NotchWing() },
            compactTrailing: { NotchWing() }
        )
        // The default is `false` (`DynamicNotchTransitionConfiguration.swift:51`), and with it
        // every compact↔expanded conversion animates the notch to `.hidden`, sleeps 0.25 s and
        // animates it back (`DynamicNotch.swift:196-210`, `250-265`). That is the "resized by
        // jumps" anti-model, shipped as a library default. It is off before the first appearance.
        notch.transitionConfiguration.skipIntermediateHides = true
    }

    /// A recording has started: fix the screen for this dictation and grow the notch.
    func recordingStarted() {
        // `NSScreen.main` is the screen with the key window, or with the menu bar when no window
        // is key -- and Murmure is `LSUIElement`, so it never has one. `.first` rather than the
        // plan's `screens[0]`: an index into an empty array would crash the whole app over a
        // decoration, and `NSScreen.screens` is empty on a Mac with every display asleep.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            log.error("no screen available -- the dictation runs, the notch does not appear")
            return
        }
        dictationScreen = screen
        enqueue { [notch] in await notch.compact(on: screen) }
    }

    /// The dictation is over, one way or another: retract the notch and let the panel go.
    ///
    /// Idempotent -- `hide()` returns immediately when the state is already `.hidden`
    /// (`DynamicNotch.swift:285-288`) -- which is what lets the caller drive this from every
    /// non-recording state without tracking which one it came from.
    func dictationEnded() {
        dictationScreen = nil
        enqueue { [notch] in await notch.hide() }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = transition
        transition = Task { @MainActor in
            await previous?.value
            await work()
        }
    }
}

/// One side of the notch. A placeholder: task T3 replaces it with the waveform bars.
///
/// The width is a constant and not a function of anything, and that is the point. Amplitude will
/// move bar *heights*; a wing that grew with the voice would make the shape breathe, and every
/// transition after the recording would then have to be read against a shape that never settled.
private struct NotchWing: View {
    static let width: CGFloat = 32

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.85))
            .frame(width: Self.width, height: 5)
    }
}
