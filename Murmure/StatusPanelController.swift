import AppKit
import MurmureCore
import SwiftUI

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
    /// The parts it is the sum of, and the sentence they have to fit, are `StatusPanelLayout` --
    /// in the package, where the fit is a test rather than a paragraph. It still comes to 260 x 34.
    static let size = StatusPanelLayout.size

    private let model: StatusPanelModel
    private var panel: MurmureStatusPanel?

    /// Closes the panel once a completion or a failure has been on screen long enough. Cancelled
    /// by the next phase, so a dictation started during a flash never has its panel closed by the
    /// previous one's timer.
    private var retraction: Task<Void, Never>?

    /// `levels` is the box the recorder fills; the drawing samples it while a dictation records.
    /// `progress` is the box the decoder advances, sampled while one transcribes.
    /// Handed in rather than made here for the reason `NotchController` is handed the same one --
    /// a second box would be a waveform of a recording nobody is making.
    init(levels: AudioLevels, progress: DecodeProgressBox) {
        model = StatusPanelModel(levels: levels, progress: progress)
    }

    /// The only entry point. `StatusRouter` has already decided which display the status goes on
    /// and therefore which of the two surfaces shows it; a nil `panelScreen` is it saying the
    /// notch has this one. See `NotchController.apply(_:)`.
    func apply(_ placement: StatusPlacement) {
        show(placement.phase, on: placement.panelScreen)
    }

    private func show(_ phase: NotchPhase, on screen: ScreenGeometry?) {
        guard phase != model.phase else { return }
        retraction?.cancel()
        retraction = nil

        // Nothing to draw, or the display the router chose has a cutout and the notch is the
        // surface there. Not a preference: two surfaces saying the same thing at once is one of
        // them being wrong, and one route is what makes that impossible rather than unintended.
        guard NotchAppearance.showsShape(in: phase), let screen else {
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
            self?.show(.hidden, on: nil)
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
    /// `takesClicks` is false for every status surface and true for exactly one window: the
    /// standing failure panel, whose Re-paste and Copy are buttons (`ProblemPanelController`).
    ///
    /// **It does not weaken the guarantee above; that is the point of putting it here rather than
    /// on a window of its own.** `canBecomeKey` is what keeps ⌘V going to the terminal, and it
    /// returns false for every instance of this class whatever this flag says. What
    /// `ignoresMouseEvents` decides is only whether clicks *stop* at the window or fall through
    /// it: an indicator must never swallow a click meant for the window underneath, a control
    /// must receive its own. Neither answer can make a window key.
    init(contentRect: NSRect, takesClicks: Bool = false) {
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
        //
        // The one exception is the standing failure panel, which is a control: see `takesClicks`.
        ignoresMouseEvents = !takesClicks
        // Only relevant when it takes clicks, and harmless otherwise. A click anywhere but on a
        // button must do nothing at all -- dragging the panel by its background would let Louis
        // park a window that never becomes key over something he needs, with no title bar to put
        // it back.
        isMovableByWindowBackground = false

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

    /// The transcription's progress, pulled by the drawing on the same terms as `levels`.
    let progress: DecodeProgressBox

    init(levels: AudioLevels, progress: DecodeProgressBox) {
        self.levels = levels
        self.progress = progress
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

    /// How tall the drawing is. Its WIDTH is `StatusPanelLayout.drawingWidth`, shared out between
    /// however many pieces the phase draws.
    static let drawingHeight: CGFloat = 16

    var body: some View {
        // **The recording is one waveform across the whole 64 pt; every other phase is two
        // mirrored halves of 32.** Which it is belongs to `NotchAppearance.isMirrored(for:)`, on
        // the mark, so this panel and the notch card cannot disagree about it.
        //
        // The panel drew two halves for everything until Louis saw what it cost here as well:
        // "je vois que ça a même changé pour la modale de l'écran externe où maintenant les deux
        // barres du milieu sont aussi collées". They were: each half puts the NEWEST level against
        // the join, so the same instant was drawn twice, side by side -- and once the row filled
        // its frame exactly there was no longer even a stray point of margin between the two
        // copies. One waveform of twelve bars occupies the same 64 pt and carries twelve DISTINCT
        // levels instead of six drawn twice, so nothing about the panel's size or its bars moves.
        let pieces = NotchAppearance.isMirrored(for: model.phase) ? 2 : 1
        let piece = CGSize(
            width: StatusPanelLayout.drawingWidth / CGFloat(pieces), height: Self.drawingHeight)
        return HStack(spacing: StatusPanelLayout.spacing) {
            HStack(spacing: 0) {
                ForEach(Array(0..<pieces), id: \.self) { index in
                    DictationPhaseView(
                        phase: model.phase, markBegan: model.markBegan, levels: model.levels,
                        progress: model.progress,
                        // The second piece is the mirrored one, and it also carries the elapsed
                        // counter on a refinement. A lone piece is never mirrored: one waveform
                        // reads oldest to newest, left to right.
                        mirrored: index == 1, size: piece)
                }
            }
            Text(StatusPanelText.label(for: model.phase))
                .font(.system(size: StatusPanelLayout.labelFontSize, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                // One line, and the tail is what gets cut: the beginning of a failure message is
                // the part that names what failed.
                .lineLimit(1)
                .truncationMode(.tail)
                // **Centred in the slot, and the slot is what moves nothing.** This was a
                // `Spacer(minLength: 0)`, which handed the whole surplus to the right end of the
                // capsule: the slot is 158 pt because a completion needs it, so "Refining" left
                // 111 pt of black against one edge and none against the other -- the "partie a
                // droite de la pastille totalement noire". Centring halves it into 55 pt a side,
                // which reads as a word in the middle rather than as a hole.
                //
                // Two other ways to close that gap were available and are worse, both for the same
                // reason -- they move something that is meant to be still:
                //
                // - Centring the *pair*, drawing and sentence together, moves the drawing sideways
                //   by half the difference between two phases' sentences. Between "Refining"
                //   (46.91 pt) and a completion (142.34 pt) that is 47.7 pt, a fifth of the
                //   capsule, applied to the one element that is continuous across a phase change.
                // - Sizing the capsule to each phase's sentence moves the capsule itself, by the
                //   same 95 pt, mid-dictation. That is the one thing the notch sequence forbids
                //   outright, and this surface is its stand-in.
                //
                // The sentence's own position does shift as its length changes, and that is the
                // one movement this design accepts: the text is *replaced* at a phase change, so
                // arriving somewhere new is what it was going to do anyway.
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, StatusPanelLayout.horizontalPadding)
        .frame(width: StatusPanelController.size.width, height: StatusPanelController.size.height)
        // Nearly black rather than black, with an edge of its own: the panel floats over the target
        // application instead of sitting in a hardware cutout, so nothing else tells it from the
        // window underneath.
        .background(Capsule().fill(Color.black.opacity(0.9)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    }
}
