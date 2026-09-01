import AppKit
import ApplicationServices
import MurmureCore
import SwiftUI
import os

/// The dictation status on a display that has no notch to grow.
///
/// Louis works on an external display. `DynamicNotch._compact` refuses to draw on a screen with no
/// cutout -- it calls `hide()` instead (`DynamicNotch.swift:226-229` at tag 1.1.0) -- so on that
/// display the whole of lot 3 is invisible and a dictation gives no feedback at all: he cannot
/// tell recording from thinking from finished. That is the bug this file exists to remove.
///
/// The plan's T7 proposed accepting DynamicNotchKit's own `NotchlessView` fallback. It is not used
/// here, and the plan itself says why: the library refuses `compact()` on such a screen, so every
/// phase would have to be rendered through `expand()`, and what it draws is "a card, not a pill".
/// The plan named the trigger for forking that path -- "Louis actually working on an external
/// display often enough to care" -- and that trigger has fired.
///
/// **On any one display, this panel and `NotchController` never both draw.** Both consume the same
/// state changes; this one asks `StatusSurfaceChoice.surface(on:)` about the display it resolved
/// and shows nothing unless the answer is `.panel`, and a screen with no cutout is a screen the
/// notch cannot appear on at all.
///
/// That is not yet the same as "only one surface is on screen". The two resolve their display by
/// different signals -- `NotchController` uses `NSScreen.main ?? NSScreen.screens.first`, this one
/// uses the ranked signals of `StatusSurfaceChoice.screen` -- so an arrangement where those two
/// disagree puts the notch on the laptop and this panel on the external display at once. Making
/// them agree means one screen choice for both, which is the seam lot 3 T7 hands back rather than
/// takes: `NotchController` belongs to another task.
@MainActor
final class StatusPanelController {
    /// The panel's size. Fixed for every phase: it is a status strip, and a strip that resized
    /// itself per phase would be a shape moving under a sentence being read.
    ///
    /// 260 pt is what the two halves and the sentence need: 28 pt of padding, the 64 pt drawing,
    /// 10 pt between them, and 158 pt left for the longest line `StatusPanelText` can produce --
    /// "Inserted 1234 characters", about 149 pt at the 12 pt size the view uses.
    static let size = CGSize(width: 260, height: 34)

    private let model: StatusPanelModel
    private var panel: MurmureStatusPanel?
    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "status-panel")

    /// The state the session was in before the one being handled. `NotchPresenter.phase` needs it
    /// because `DictationSession` emits `.completed` and `.idle` in the same breath: without it
    /// the panel would close in the instant it was told the dictation succeeded.
    private var previousState: DictationSession.State = .idle

    /// The display the dictation in progress is drawn on, resolved once when its recording starts.
    ///
    /// Resolved once and then read, never re-derived: the signals below are a moving pointer and a
    /// focused window, and both change during a dictation. A panel that re-asked would hop to
    /// another display mid-sentence, which is worse than being on the wrong one -- Louis would be
    /// watching the place it just left.
    private var dictationScreen: ScreenGeometry?

    /// Closes the panel once a completion or a failure has been on screen long enough. Cancelled
    /// by the next phase, so a dictation started during a flash never has its panel closed by the
    /// previous one's timer.
    private var retraction: Task<Void, Never>?

    /// `levels` is the box the recorder fills; the drawing samples it while a dictation records.
    /// Handed in rather than made here for the reason `NotchController` is handed the same one --
    /// a second box would be a waveform of a recording nobody is making.
    init(levels: AudioLevels) {
        model = StatusPanelModel(levels: levels)
    }

    /// The session changed state. The only entry point.
    func apply(_ state: DictationSession.State) {
        let phase = NotchPresenter.phase(previous: previousState, current: state)
        previousState = state
        show(phase)
    }

    private func show(_ phase: NotchPhase) {
        guard phase != model.phase else { return }
        retraction?.cancel()
        retraction = nil

        guard NotchAppearance.showsShape(in: phase) else {
            dictationScreen = nil
            hide()
            return
        }

        // A phase with no dictation behind it -- a microphone that refused to start, so there was
        // never a `.recording` -- resolves a display of its own rather than saying nothing.
        let screen: ScreenGeometry
        if case .recording = phase {
            guard let resolved = resolveScreen() else {
                log.error("no screen available -- the dictation runs, the panel does not appear")
                return
            }
            screen = resolved
            dictationScreen = resolved
        } else if let held = dictationScreen {
            screen = held
        } else {
            guard let resolved = resolveScreen() else { return }
            screen = resolved
            dictationScreen = resolved
        }

        // The display has a cutout, so the notch is the surface there and this panel is not. Not a
        // preference: two surfaces saying the same thing at once is one of them being wrong.
        guard StatusSurfaceChoice.surface(on: screen) == .panel else {
            hide()
            return
        }

        model.enter(phase, at: Date())
        present(on: screen)

        // Nothing else takes a finished dictation off the screen. Which phases get a timer at all
        // is `NotchPresenter.dwell(for:)`, in the package, where a phase added later cannot
        // quietly inherit "never closes".
        guard let dwell = NotchPresenter.dwell(for: phase) else { return }
        retraction = Task { [weak self] in
            try? await Task.sleep(for: .seconds(dwell))
            guard !Task.isCancelled else { return }
            self?.show(.hidden)
        }
    }

    private func present(on screen: ScreenGeometry) {
        let frame = StatusSurfaceChoice.frame(size: Self.size, on: screen)
        let panel = panel ?? makePanel()
        self.panel = panel
        // Set before ordering in, so the panel is never seen at the previous dictation's position
        // for a frame. Repositioning a *hidden* panel is not the notch's "never resize" rule: that
        // rule is about a visible shape jumping, and this one is not on screen yet.
        panel.setFrame(frame, display: false)
        // `orderFrontRegardless()` and not `orderFront(nil)`, which is a deviation from the task
        // brief and the one place this file argues with it. The two differ only in ORDERING, never
        // in focus: neither can make a window key, and the calls that can -- `makeKey`,
        // `makeKeyAndOrderFront` -- are refused outright by `canBecomeKey` below. What
        // `orderFront(_:)` does not promise is showing a window belonging to an application that
        // is not active, and Murmure is `LSUIElement` and never active. DynamicNotchKit reaches
        // the same conclusion for the same window on the same code path
        // (`DynamicNotch.initializeWindow`, `showWindow`, tag 1.1.0), and that is the path whose
        // notch Louis can already see appear.
        panel.orderFrontRegardless()
    }

    private func hide() {
        model.enter(.hidden, at: Date())
        panel?.orderOut(nil)
    }

    private func makePanel() -> MurmureStatusPanel {
        let panel = MurmureStatusPanel(contentRect: CGRect(origin: .zero, size: Self.size))
        panel.contentView = NSHostingView(rootView: StatusPanelView(model: model))
        return panel
    }

    // MARK: - Which display

    /// The display to draw on, from the signals `StatusSurfaceChoice.screen` ranks.
    ///
    /// The AppKit half of the decision, and deliberately nothing but reading: which of the values
    /// wins is in the package, where a two-display arrangement can be described without either
    /// display being plugged in.
    private func resolveScreen() -> ScreenGeometry? {
        StatusSurfaceChoice.screen(
            among: NSScreen.screens.map(ScreenGeometry.init(_:)),
            focusedWindow: focusedWindowFrame(),
            mouseLocation: NSEvent.mouseLocation
        )
    }

    /// The frame of the window Louis is typing into, or nil if it cannot be had.
    ///
    /// The frontmost application is the same object `PasteInserter` sends its keystroke to, so
    /// this is not a guess about where Louis is looking: it is the window the dictation is about
    /// to land in. Nil is a normal answer -- Accessibility not granted yet, an application that
    /// does not implement the API, a Finder desktop with no window at all -- and the caller falls
    /// through to the pointer.
    ///
    /// Bounded at 150 ms because it is a synchronous message into another process, made on the
    /// main actor, on the path that opens the panel at the start of a dictation. The API's own
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

/// A status strip that cannot take the keyboard away from the window Louis is dictating into.
///
/// **This is the property the whole surface stands on.** Murmure inserts a dictation by sending
/// ⌘V to `NSWorkspace.frontmostApplication` (`PasteInserter`). If this panel ever became the key
/// window, the paste would land in it -- which is to say nowhere -- and the dictation would be
/// lost silently at the last step.
///
/// It is guaranteed by `canBecomeKey` returning `false`, and by nothing softer. AppKit refuses to
/// make a window key when its `canBecomeKey` is `false`: `makeKeyAndOrderFront(_:)` then orders
/// the window front without making it key, and `becomeKey` is never sent. Every other flag here
/// narrows the ways focus could be *asked* for; this one removes the ability to receive it, so a
/// later call added by mistake cannot lose a dictation.
///
/// This is exactly the line DynamicNotchKit gets wrong for our purposes -- `DynamicNotchPanel`
/// overrides `canBecomeKey` to return `true` (`DynamicNotchPanel.swift:29`), which the plan's
/// risk table records as unfixable from outside the library.
final class MurmureStatusPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // `.nonactivatingPanel` is the second half of the same property, at the application
            // level rather than the window level: without it, a click reaching this panel would
            // activate Murmure and take the front from the terminal being dictated into.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Belt to `canBecomeKey`'s brace, and inert given it: it makes a panel take the keyboard
        // only when something inside needs text input, and nothing inside this one does.
        becomesKeyOnlyIfNeeded = true
        // The panel outlives the dictation that opened it -- it is closed and reopened -- so it
        // must not be released when ordered out.
        isReleasedWhenClosed = false
        // Murmure is never the active application, so a panel that hid on deactivation would be a
        // panel that is never seen.
        hidesOnDeactivate = false

        // A status indicator, not a control (lot 3 T7, V1). Mouse events pass straight through to
        // whatever is underneath, which is the window being dictated into -- so the panel cannot
        // swallow a click meant for the text Louis is about to paste into.
        ignoresMouseEvents = true

        hasShadow = false
        isOpaque = false
        backgroundColor = .clear

        level = .screenSaver
        // The pair DynamicNotchKit ships (`DynamicNotchPanel.swift:26`) and the pair lot 3 T1
        // observed drawing over a full-screen application. `.fullScreenAuxiliary` is deliberately
        // NOT added: it is documented as letting a window share a Space with a full-screen window,
        // but nothing here can observe whether it changes anything on top of `.canJoinAllSpaces`,
        // and a flag whose effect has not been seen is not a mitigation, it is a guess in the
        // shape of one.
        collectionBehavior = [.canJoinAllSpaces, .stationary]
    }

    /// Never. See the type's note -- this is the line that keeps ⌘V going to the terminal.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What the panel's view reads. Deliberately not `AppState`: that object drives the menu-bar
/// scene, and re-evaluating it once per phase change would redraw a menu for a panel.
@MainActor
final class StatusPanelModel: ObservableObject {
    @Published private(set) var phase: NotchPhase = .hidden

    /// The family of drawing the indicator is making, and the instant its animation counts from.
    ///
    /// Not `@Published`: both change only when `phase` does, and `phase` already publishes.
    /// `markBegan` cannot be derived inside the view at all -- it is a function of the mark that
    /// was on screen *before*, which a view redrawing itself has no way to see.
    private(set) var mark: NotchAppearance.Mark = .none
    private(set) var markBegan: Date = .distantPast

    /// The waveform's levels. Deliberately NOT `@Published`: they change about twenty-three times
    /// a second, and publishing them would re-evaluate the panel on the audio thread's schedule.
    /// The drawing PULLS from it on a timeline of its own instead.
    let levels: AudioLevels

    init(levels: AudioLevels) {
        self.levels = levels
    }

    /// The panel is now showing this. The one mutation, so the phase and the clock its drawing
    /// reads can never be set apart from each other.
    fileprivate func enter(_ phase: NotchPhase, at now: Date) {
        let next = NotchAppearance.mark(for: phase)
        markBegan = NotchAppearance.animationStart(
            previousMark: mark, previousStart: markBegan, newMark: next, now: now)
        mark = next
        self.phase = phase
    }
}

/// The strip: the dictation's own drawing, and one line saying which phase it is.
///
/// The drawing is `DictationPhaseView`, the notch's, not a second one written here. Lot 3 T4 made
/// it container-agnostic for exactly this: it knows a phase, a clock and a `CGSize`, and nothing
/// about notches or screens. Two of them side by side are the pill its own note describes -- the
/// waveform mirrored about the centre, the travelling marks running outward from it, and on
/// `refining` the accent breathing on one half while the elapsed counter arrives on the other.
///
/// The sentence beside it is what this surface has and the notch does not need. A floating panel
/// has no hardware anchor and no six months of habit behind it, so on an external display the word
/// is most of what Louis reads -- and `nothingHeard` against `completed` is the pair that has to
/// be unmistakable (`StatusPanelText`).
private struct StatusPanelView: View {
    @ObservedObject var model: StatusPanelModel

    /// One half of the drawing. The notch's wing exactly (`NotchWing`, 32 x 16): the halves are
    /// the same view at the same size on both surfaces, so a dictation looks the same whichever
    /// display Louis started it on.
    static let half = CGSize(width: 32, height: 16)

    var body: some View {
        HStack(spacing: 10) {
            // Zero spacing between the halves: on the notch they are separated by the hardware
            // cutout, and here there is none to separate them -- they are one shape.
            HStack(spacing: 0) {
                DictationPhaseView(
                    phase: model.phase, markBegan: model.markBegan, levels: model.levels,
                    mirrored: false, size: Self.half)
                DictationPhaseView(
                    phase: model.phase, markBegan: model.markBegan, levels: model.levels,
                    mirrored: true, size: Self.half)
            }
            Text(StatusPanelText.label(for: model.phase))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                // One line, and the tail is what gets cut: the beginning of a failure message is
                // the part that names what failed.
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: StatusPanelController.size.width, height: StatusPanelController.size.height)
        // Nearly black rather than black, with an edge of its own: the panel floats over the target
        // application instead of sitting in a hardware cutout, so nothing else tells it from the
        // window underneath.
        .background(Capsule().fill(Color.black.opacity(0.9)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    }
}
