import CoreGraphics
import Foundation

/// One display, reduced to the three things the surface choice reads off it.
///
/// A value rather than `NSScreen`, for the reason the rest of `MurmureCore` exists: the `Murmure`
/// target has no test bundle, so a screen choice written against `NSScreen` is a choice nothing
/// can check. And it is worse than untested -- `NSScreen` cannot be constructed at all, its
/// instances come from the hardware attached to the machine running the suite, which is one
/// display on a build machine and never the two-display arrangement that produces the bug.
public struct ScreenGeometry: Equatable, Sendable {
    /// The whole display, in the global space whose origin is the primary screen's bottom-left
    /// corner and whose y grows upwards (`NSScreen.frame`).
    public let frame: CGRect

    /// The part of it left by the menu bar and the Dock (`NSScreen.visibleFrame`). The panel is
    /// placed against this and not against `frame`, which is what keeps it out from under the menu
    /// bar. Measured on Louis's machine: the built-in display reserves 33 pt at the top for the
    /// menu bar, the external one currently reserves nothing at all -- `visibleFrame == frame`
    /// there -- and that stops being true the moment the menu bar moves to it.
    public let visibleFrame: CGRect

    /// Whether the display has a hardware cutout, i.e. `auxiliaryTopLeftArea` and
    /// `auxiliaryTopRightArea` both exist. The built-in display of a recent MacBook has one; no
    /// external display does.
    public let hasNotch: Bool

    public init(frame: CGRect, visibleFrame: CGRect, hasNotch: Bool) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.hasNotch = hasNotch
    }
}

/// Where a dictation's progress is shown on a given display.
public enum StatusSurface: Equatable, Sendable {
    /// The hardware cutout, grown into a surface. `NotchController` and lot 3 T1–T6.
    case notch
    /// A small floating panel, because there is no cutout to grow.
    case panel
}

/// The whole of a dictation's status placement: one display, and therefore one surface.
///
/// **A single value rather than two answers, and that is the fix rather than a tidying.** Murmure
/// used to ask the question twice -- `NotchController` resolved a display from `NSScreen.main` and
/// drew if it had a cutout, `StatusPanelController` resolved one from the ranked signals below and
/// drew if it had none -- and the two agreeing was a coincidence, not a guarantee. When they
/// disagreed both drew (a notch on the laptop *and* a strip on the external display, saying the
/// same thing) or neither did (a refusal nobody ever saw). Both are unrepresentable here: a route
/// names exactly one display and its `surface` is the one that display can show, so the other
/// surface is told not to draw by the same value that tells the first one to.
///
/// The display is an INDEX into the array the caller handed in, not a `ScreenGeometry`. The app
/// needs the `NSScreen` back -- DynamicNotchKit expands on one, and the cutout's width is read off
/// it -- and an index is the one way to return it without `MurmureCore` knowing what an `NSScreen`
/// is.
public struct StatusRoute: Equatable, Sendable {
    /// Which of the screens handed in. Always a valid index into that array.
    public let screenIndex: Int

    /// The surface that display can show, i.e. `StatusSurfaceChoice.surface(on:)` of it.
    public let surface: StatusSurface

    public init(screenIndex: Int, surface: StatusSurface) {
        self.screenIndex = screenIndex
        self.surface = surface
    }
}

/// Which display the status is shown on, which surface it uses there, and where on it.
///
/// The three decisions the floating panel needs and the app target cannot prove. Everything here
/// is a function over injected values -- screen frames, a focused window, a mouse position -- and
/// never a call into `NSScreen` or `NSEvent`, which is what lets a test describe a MacBook with an
/// external display without either being plugged in.
public enum StatusSurfaceChoice {
    // MARK: - Which surface, on one display

    /// The surface that display can show.
    ///
    /// **A function of the chosen display, never of the built-in one.** Louis's machine is a
    /// notched MacBook *plus* an external display, so "this Mac has a notch" is true and useless:
    /// it is true while he is looking at the screen that has none, which is the whole of the bug
    /// this task exists to fix. A cutout can only be grown on the display that has the cutout.
    public static func surface(on screen: ScreenGeometry) -> StatusSurface {
        screen.hasNotch ? .notch : .panel
    }

    // MARK: - The one decision both surfaces are given

    /// Which display the status goes on, and therefore which surface draws it.
    ///
    /// **The whole fix is that this is ONE function.** Murmure asked the question twice and got
    /// two answers: `NotchController` resolved a display from `NSScreen.main` and grew the cutout
    /// if it had one, `StatusPanelController` resolved its own from the signals below and opened
    /// the strip if it had none. Nothing made those agree. On Louis's machine they systematically
    /// do not: `NSScreen.main`, measured for a process with no key window while the frontmost
    /// application and the pointer are both on the external display, is the built-in NOTCHED
    /// display -- so the notch grew on the laptop for every dictation he ran on the external one,
    /// where the strip was already open. Two surfaces saying the same thing, which is one of them
    /// being wrong.
    ///
    /// `NSScreen.main` is not among the signals here and never was among `screen(among:)`'s, for
    /// the reason written there: its documented meaning is "the screen containing the window with
    /// the keyboard focus", which for an app that spends its life without one is a sentence about
    /// somebody else's window -- and what it answers instead, measured, is the display holding the
    /// menu bar. That is a fact about the Mac's arrangement, not about where Louis is looking.
    ///
    /// Nil only when there are no screens at all.
    public static func route(
        among screens: [ScreenGeometry], focusedWindow: CGRect?, mouseLocation: CGPoint?
    ) -> StatusRoute? {
        guard let chosen = screen(
            among: screens, focusedWindow: focusedWindow, mouseLocation: mouseLocation),
            let index = screens.firstIndex(of: chosen)
        else { return nil }
        return StatusRoute(screenIndex: index, surface: surface(on: chosen))
    }

    /// The route to use for this phase, given the one the dictation in progress is holding.
    ///
    /// Three rules, and each of them was a line of `NotchController` and a line of
    /// `StatusPanelController` that had to stay in step by hand:
    ///
    /// 1. **A phase with no shape releases the hold.** The dictation is over; the next thing to
    ///    arrive resolves a display of its own. The shipped panel could not do this -- `hide()`
    ///    had already put its model in `.hidden`, so the `.hidden` phase that clears the hold was
    ///    swallowed by the `phase != model.phase` guard above it, and the display of a dictation
    ///    that had ended stayed pinned. The consequence was exact: the next phase to arrive with
    ///    no `.recording` in front of it -- which is precisely the ⌥Space refused because Murmure
    ///    is in front -- was placed on that stale display and the strip hid itself there.
    /// 2. **A recording resolves afresh.** So a monitor plugged in between two dictations needs
    ///    nothing switched.
    /// 3. **Everything else keeps what the press resolved.** Nothing moves the surface
    ///    mid-dictation: the pointer travelling to the other screen while Louis speaks must not
    ///    take the strip with it. A phase arriving with nothing held -- a refusal, an alert at
    ///    launch -- takes the freshly resolved one rather than saying nothing at all.
    ///
    /// The caller stores the result as the new hold, so those three rules are the hold's whole
    /// life and there is exactly one of it.
    public static func route(
        for phase: NotchPhase, held: StatusRoute?, resolved: StatusRoute?
    ) -> StatusRoute? {
        guard NotchAppearance.showsShape(in: phase) else { return nil }
        if case .recording = phase { return resolved }
        return held ?? resolved
    }

    /// Whether the display a dictation resolved outlives this state.
    ///
    /// **The hold has to be released by something, and the phase alone cannot do it.** A dictation
    /// that succeeds emits `.completed` and then `.idle` in the same breath, and both map to the
    /// `.completed` PHASE -- so a release keyed on the phase would either never fire (the notch's
    /// `.hidden` arrives only from a cancel) or fire between those two, re-resolving a display
    /// under a flash that is already on screen and handing it to the other surface. Keyed on the
    /// state, `.completed` still carries the hold and the `.idle` behind it drops it.
    ///
    /// `.failed` drops it too, and it is the reason this exists: a ⌥Space refused because Murmure
    /// is in front produces a `.failed` with no `.recording` in front of it and no state after it,
    /// so a hold kept there would place the NEXT refusal on the display of the last one.
    ///
    /// Written without a `default`, so a state added later has to say which it is.
    public static func routeOutlives(_ state: DictationSession.State) -> Bool {
        switch state {
        case .recording, .transcribing, .refining, .inserting, .completed: true
        case .idle, .failed: false
        }
    }

    // MARK: - Which display

    /// The display to show the status on, best signal first.
    ///
    /// The signals are ranked by how directly they answer the only question that matters -- which
    /// screen is Louis reading while he dictates:
    ///
    /// 1. **The focused window.** It is not merely a good guess: it is the *same object the
    ///    dictation is aimed at*. `PasteInserter` sends its keystroke to the frontmost
    ///    application, so a panel placed on the focused window's display is by construction on
    ///    the display the text is about to appear on. No other signal has that property.
    /// 2. **The mouse.** Right nearly always and free, but it is only where the pointer was left.
    ///    A pointer parked on the laptop while Louis types on the external display would put the
    ///    panel on the wrong screen -- exactly the failure being fixed -- so it is the fallback
    ///    and not the signal.
    /// 3. **The first screen**, which is the display holding the coordinate origin. Not a guess
    ///    about Louis at all, just somewhere rather than nowhere.
    ///
    /// `NSScreen.main` is deliberately not among them. Its documented meaning is "the screen
    /// containing the window with the keyboard focus", which for an `LSUIElement` app that never
    /// takes focus is a sentence about somebody else's window; what it returns then is not
    /// specified. Passing the focused window in explicitly asks the question `NSScreen.main` only
    /// approximates.
    ///
    /// Nil only when there are no screens at all, which is a Mac with every display asleep.
    public static func screen(
        among screens: [ScreenGeometry], focusedWindow: CGRect?, mouseLocation: CGPoint?
    ) -> ScreenGeometry? {
        if let focusedWindow, let holding = screenHoldingMostOf(focusedWindow, among: screens) {
            return holding
        }
        if let mouseLocation,
           let under = screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return under
        }
        return screens.first
    }

    /// The display showing the largest part of a rectangle, or nil if none shows any of it.
    ///
    /// Largest overlap rather than "the screen containing its origin": a window dragged across the
    /// boundary between two displays has its origin on one of them while nearly all of it is on
    /// the other, and the origin is the top-left corner, i.e. the corner the user is least likely
    /// to be reading. Overlapping by nothing is not a tie to break, it is no answer -- a zero-area
    /// intersection returns nil so the caller falls through to the mouse. That covers a focused
    /// window that is minimised or on a display that has since been unplugged, both of which
    /// report a frame that touches no screen.
    private static func screenHoldingMostOf(
        _ rect: CGRect, among screens: [ScreenGeometry]
    ) -> ScreenGeometry? {
        var best: ScreenGeometry?
        var bestArea: CGFloat = 0
        for screen in screens {
            let overlap = screen.frame.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }

    // MARK: - Where on that display

    /// How far the panel floats below the top of the usable area.
    ///
    /// **Arbitrary in its digits, deliberate in its edge -- and the edge is the opposite of the one
    /// this constant was born with.** It used to be a bottom margin, argued for on two grounds that
    /// were real and are still real: the top-centre strip of a maximised window is its title or tab
    /// bar, the one row of it that is always occupied; and the bottom centre is where macOS puts
    /// its own volume and brightness HUDs, so a small dark shape there reads as the system saying
    /// something. Louis overruled both with a third, which outranks them because it is about the
    /// two surfaces being one interface: on a display with a cutout the dictation is drawn *in* the
    /// cutout, which is at the top, so a display without one draws it at the top as well and the
    /// same dictation is read in the same place whichever screen it was started on.
    ///
    /// The title-bar cost that argued for the bottom is bounded rather than dismissed. 96 pt is
    /// measured from the top of `visibleFrame`, i.e. from below the menu bar, and a standard title
    /// bar is 32 pt (`NSWindow.frameRect(forContentRect:styleMask:)` on a `.titled` window), so the
    /// panel clears a maximised window's chrome by 64 pt and floats over its content instead.
    ///
    /// The distance is 96 because it is the gap Louis approved at the bottom edge, kept unchanged
    /// and turned upside down; the digits are his to move.
    public static let topMargin: CGFloat = 96

    /// How far the standing failure panel floats below the top of the usable area.
    ///
    /// **Derived, not chosen: it is exactly the strip's own margin plus the strip.** The two
    /// surfaces can be on screen at the same instant -- a paste failure opens the standing panel
    /// while the transient one is still showing the failure it is about, for the four seconds of
    /// `NotchPresenter.failureDwell` -- and on a display with no cutout they are both placed by
    /// this function, centred on the same midX. Any margin under `topMargin + StatusPanelLayout
    /// .height` would put the panel over the sentence explaining it. `StatusSurfaceTests` pins
    /// the inequality rather than the digits.
    ///
    /// The gap over the floor is `StandingPanelLayout.blockSpacing`, so the space between the two
    /// surfaces is the space between two blocks inside one of them. **That much is arbitrary**;
    /// the floor under it is not.
    public static let standingTopMargin =
        topMargin + StatusPanelLayout.height + StandingPanelLayout.blockSpacing

    /// Where a panel of this size sits on that display.
    ///
    /// Measured against `visibleFrame`, so the menu bar pushes the panel down instead of putting it
    /// behind itself. That distinction is new work for this function rather than the same work at
    /// another edge: nothing macOS reserves at the bottom is drawn *over* a `.screenSaver`-level
    /// panel, so the old bottom placement was still legible when it got `visibleFrame` wrong,
    /// while a top placement measured from `frame` would open 33 pt into the menu bar.
    ///
    /// The origin is rounded to whole points. `midX - width / 2` lands on a half point whenever
    /// the display's usable width and the panel's width have different parities -- and a
    /// half-point origin puts a 1 pt border of the capsule across two physical pixels on a
    /// non-Retina external display, which is a border drawn at half strength twice instead of
    /// once. Louis's external display is exactly that: `backingScaleFactor` 1.0.
    public static func frame(
        size: CGSize, on screen: ScreenGeometry, topMargin: CGFloat = topMargin
    ) -> CGRect {
        CGRect(
            x: (screen.visibleFrame.midX - size.width / 2).rounded(),
            // From the top edge downwards, so the *gap* above the panel is `topMargin`. Deriving
            // the origin from `minY` plus a height would put the margin below the panel instead,
            // and the panel would hang 34 pt further down than the number says.
            y: (screen.visibleFrame.maxY - topMargin - size.height).rounded(),
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Reading a window frame out of the Accessibility API

    /// An Accessibility position and size, as a rectangle in `NSScreen`'s coordinate space.
    ///
    /// The two spaces disagree on where the world starts and which way it runs: `kAXPosition` is
    /// measured from the **top-left** of the primary display with y growing **downwards**, while
    /// `NSScreen.frame` is measured from its **bottom-left** with y growing **upwards**. Feeding
    /// one to the other unconverted does not fail loudly -- it returns a plausible rectangle that
    /// is mirrored about the middle of the primary display, so on a two-display arrangement the
    /// panel opens on the wrong screen and every test of the choice above still passes.
    ///
    /// `primaryScreenFrame` is `NSScreen.screens[0].frame`, the display that defines the origin of
    /// both spaces. It is passed rather than assumed to be `(0, 0, w, h)` so that this is a
    /// conversion and not a coincidence.
    public static func screenFrame(
        accessibilityPosition position: CGPoint, size: CGSize, primaryScreenFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: position.x,
            y: primaryScreenFrame.maxY - position.y - size.height,
            width: size.width,
            height: size.height
        )
    }
}
