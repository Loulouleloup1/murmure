import AppKit
import ApplicationServices
import MurmureCore
import os

/// One state change, turned into one placement: the phase to show, and the single surface that
/// shows it.
///
/// **At most one of the two screens is ever non-nil, and that is the point of the type.** A
/// controller handed a nil screen is being told to hide, and it cannot be told anything else by
/// the same value that told its twin to draw.
struct StatusPlacement {
    /// What both surfaces would draw, if it were theirs to draw.
    let phase: NotchPhase

    /// The display to grow the cutout on, or nil -- the route chose the strip, the phase draws
    /// nothing, or every display is asleep. An `NSScreen` because DynamicNotchKit expands on one
    /// and the cutout's width is read off it.
    let notchScreen: NSScreen?

    /// The display to open the floating strip on, or nil, for the mirrored reasons.
    let panelScreen: ScreenGeometry?

    /// Neither surface draws: the phase has no shape, or there is no display at all.
    static func nothing(_ phase: NotchPhase) -> StatusPlacement {
        StatusPlacement(phase: phase, notchScreen: nil, panelScreen: nil)
    }
}

/// The one place Murmure decides which display a dictation's status goes on, and therefore which
/// of its two transient surfaces shows it.
///
/// **It exists because that decision used to be made twice.** `NotchController` resolved a display
/// from `NSScreen.main` and grew the cutout if it had one; `StatusPanelController` resolved its own
/// from the ranked signals in `StatusSurfaceChoice` and opened the strip if it had none. Nothing
/// made the two agree, and on Louis's machine they systematically disagree: `NSScreen.main`,
/// measured for a process with no key window while the frontmost application and the pointer were
/// both on the external display, returns the built-in NOTCHED display. So every dictation he ran on
/// the external display grew a notch card on the laptop as well as the strip in front of him --
/// "les deux écrans qui vont réagir sur le recording" -- and, in the mirrored case, a phase whose
/// two resolutions crossed the other way was shown by neither surface at all.
///
/// The rules are all in `MurmureCore` (`StatusSurfaceChoice.route`), where a two-display
/// arrangement can be described without either display being plugged in. What is here is the
/// reading: `NSScreen`, `NSEvent` and the Accessibility API, none of which a test bundle could
/// reach, and no decision at all.
@MainActor
final class StatusRouter {
    /// The state the last placement was made for, so the phase can be derived the way both
    /// surfaces used to derive it separately. See `NotchPresenter.phase(previous:current:)` for
    /// why the previous one is not decoration.
    private var previousState: DictationSession.State = .idle

    /// The display the dictation in progress resolved, held so that nothing moves the surface
    /// mid-dictation, and released by `StatusSurfaceChoice.route(for:held:resolved:)` the moment a
    /// phase with no shape arrives. There is exactly one of it now; there used to be one per
    /// controller, and the panel's was never released.
    private var held: StatusRoute?

    /// The phase the dictation itself is in, kept because a model preparation arrives on its own
    /// schedule and has to be composed with it. See `NotchPresenter.phase(dictation:preparing:)`.
    private var dictationPhase: NotchPhase = .hidden

    /// The model preparation in flight, or nil. Kept for the mirror reason: a state change arriving
    /// during a download has to be composed with the download, or the card would drop back to
    /// "Transcribing" for one frame every time the session said anything.
    ///
    /// It is never cleared here. `NotchPresenter.phase(dictation:preparing:)` shows it only over
    /// `.transcribing`, and `WhisperKitEngine` reports nil on both exits of the load, so a value
    /// left standing here can reach the screen through neither route.
    private var preparation: ModelPreparation?

    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "status")

    /// The placement for a session state change. The only caller is `DictationController`, once
    /// per change, which is what makes the release rule above reachable.
    func placement(for state: DictationSession.State) -> StatusPlacement {
        let phase = NotchPresenter.phase(previous: previousState, current: state)
        previousState = state
        dictationPhase = phase
        let placement = placement(
            for: NotchPresenter.phase(dictation: phase, preparing: preparation))
        // AFTER the placement, so the state that ends a dictation is still shown on the display
        // that dictation resolved. `StatusSurfaceChoice.routeOutlives(_:)` argues why this is
        // keyed on the state and cannot be keyed on the phase.
        if !StatusSurfaceChoice.routeOutlives(state) { held = nil }
        return placement
    }

    /// The placement for a step of the model's preparation, which happens inside a dictation and
    /// therefore on the display that dictation already resolved.
    ///
    /// Called from `WhisperKitEngine`'s reporter, about once a second while 1.6 GB comes down. It
    /// goes through the same one router as everything else on purpose: a download that resolved a
    /// display of its own would be the two-surfaces bug (`643165c`) reintroduced by a new caller.
    func placement(preparing: ModelPreparation?) -> StatusPlacement {
        preparation = preparing
        return placement(
            for: NotchPresenter.phase(dictation: dictationPhase, preparing: preparing))
    }

    /// The placement for a phase that has no state change behind it -- an alert raised at launch.
    func placement(for phase: NotchPhase) -> StatusPlacement {
        let screens = NSScreen.screens
        let geometries = screens.map(ScreenGeometry.init(_:))
        // Resolved only when it can change the answer. `focusedWindowFrame()` is a synchronous
        // Accessibility message into the front application, bounded at 150 ms, on the main actor --
        // affordable a few times per dictation, and a few hundred cross-process round-trips over a
        // download that reports once a second. `resolvesAfresh(for:held:)` is a reading of
        // `route(for:held:resolved:)` rather than a second rule about displays, and the package
        // tests pin that the two agree for every phase.
        let resolved = StatusSurfaceChoice.resolvesAfresh(for: phase, held: held)
            ? StatusSurfaceChoice.route(
                among: geometries,
                focusedWindow: focusedWindowFrame(),
                mouseLocation: NSEvent.mouseLocation)
            : nil
        let route = StatusSurfaceChoice.route(for: phase, held: held, resolved: resolved)
        held = route

        guard let route else { return .nothing(phase) }
        guard screens.indices.contains(route.screenIndex) else {
            // `route` indexes the array it was handed one line ago, so this cannot happen; it is
            // here because the alternative to a log is a crash over a decoration.
            log.error("route named a display that is not attached -- nothing is shown")
            return .nothing(phase)
        }
        switch route.surface {
        case .notch:
            return StatusPlacement(
                phase: phase, notchScreen: screens[route.screenIndex], panelScreen: nil)
        case .panel:
            return StatusPlacement(
                phase: phase, notchScreen: nil, panelScreen: geometries[route.screenIndex])
        }
    }

    // MARK: - Reading the desktop

    /// The frame of the window Louis is typing into, or nil if it cannot be had.
    ///
    /// Moved here from `StatusPanelController`, unchanged, because it is now read once per state
    /// change instead of once per surface: it is a synchronous message into another process and
    /// the two surfaces asking it separately was both a second cost and a second chance to
    /// disagree.
    ///
    /// The frontmost application is the same object `PasteInserter` sends its keystroke to, so
    /// this is not a guess about where Louis is looking: it is the window the dictation is about
    /// to land in. Nil is a normal answer -- Accessibility not granted yet, an application that
    /// does not implement the API, a Finder desktop with no window at all, and Murmure itself in
    /// front (an application cannot usefully ask the Accessibility server about its own main
    /// thread from that thread) -- and the caller falls through to the pointer.
    ///
    /// Bounded at 150 ms because it is a synchronous message into another process, made on the
    /// main actor, on the path that opens a surface at the start of a dictation. The API's own
    /// default is not stated in `AXUIElement.h`; what is certain is that it is not instant and
    /// that a wedged front application would hold the interface for all of it.
    private func focusedWindowFrame() -> CGRect? {
        guard AXIsProcessTrusted(),
              let frontmost = NSWorkspace.shared.frontmostApplication,
              let primary = NSScreen.screens.first
        else { return nil }

        let application = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)

        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
            let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else { return nil }
        // Checked against `AXUIElementGetTypeID()` on the line above, which is the only way this
        // cast can be made safe -- the attribute is typed `CFTypeRef` and an application is free
        // to return anything at all for it.
        let window = windowValue as! AXUIElement

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(
                window, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue, let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        // The conversion between the two coordinate spaces is in the package, because getting it
        // wrong does not fail loudly: it returns a plausible rectangle mirrored about the middle
        // of the primary display, which on a two-display arrangement opens the panel on the other
        // screen and looks exactly like a bad screen choice.
        return StatusSurfaceChoice.screenFrame(
            accessibilityPosition: origin, size: size, primaryScreenFrame: primary.frame)
    }
}

extension ScreenGeometry {
    /// The three things the surface choice reads off a display.
    ///
    /// `hasNotch` is computed here rather than taken from DynamicNotchKit's own `NSScreen.hasNotch`
    /// because that extension is internal to the library. The test is the same one it makes: both
    /// auxiliary top areas exist, i.e. the menu bar is split by something.
    init(_ screen: NSScreen) {
        self.init(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            hasNotch: screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
        )
    }
}
