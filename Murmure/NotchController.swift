import AppKit
import DynamicNotchKit
import MurmureCore
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
    /// What the wings read. Held here because the two are one mechanism: the phase decides both
    /// what is drawn and whether there is a window to draw it in.
    private let model = NotchModel()
    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "notch")

    /// The state the session was in before the one being handled. `NotchPresenter.phase` needs it
    /// because `DictationSession` emits `.completed` and `.idle` in the same breath: without the
    /// previous state the notch would retract in the instant it was told the dictation succeeded.
    private var previousState: DictationSession.State = .idle

    /// Retracts a completion or a failure once it has been on screen long enough. Cancelled by
    /// the next phase, so a dictation started during a flash never has its notch pulled out from
    /// under it by the previous one's timer.
    private var retraction: Task<Void, Never>?

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
            // `let`-captured by `DynamicNotch.init` and never re-made, which is why the phase has
            // to reach them as observed DATA rather than as a rebuilt notch.
            compactLeading: { [model] in NotchWing(model: model) },
            compactTrailing: { [model] in NotchWing(model: model) }
        )
        // The default is `false` (`DynamicNotchTransitionConfiguration.swift:51`), and with it
        // every compact↔expanded conversion animates the notch to `.hidden`, sleeps 0.25 s and
        // animates it back (`DynamicNotch.swift:196-210`, `250-265`). That is the "resized by
        // jumps" anti-model, shipped as a library default. It is off before the first appearance.
        notch.transitionConfiguration.skipIntermediateHides = true
    }

    /// The session changed state. The only entry point, and the only thing allowed to move the
    /// notch: `NotchPresenter` turns the change into a phase, and this shows it.
    func apply(_ state: DictationSession.State) {
        let phase = NotchPresenter.phase(previous: previousState, current: state)
        previousState = state
        show(phase)
    }

    private func show(_ phase: NotchPhase) {
        guard phase != model.phase else { return }
        model.phase = phase
        // Whatever was on its way out is no longer the thing on screen.
        retraction?.cancel()
        retraction = nil

        if case .hidden = phase {
            dictationScreen = nil
            // Idempotent -- `hide()` returns immediately when the state is already `.hidden`
            // (`DynamicNotch.swift:285-288`).
            enqueue { [notch] in await notch.hide() }
            return
        }

        // `NSScreen.main` is the screen with the key window, or with the menu bar when no window
        // is key -- and Murmure is `LSUIElement`, so it never has one. `.first` rather than the
        // plan's `screens[0]`: an index into an empty array would crash the whole app over a
        // decoration, and `NSScreen.screens` is empty on a Mac with every display asleep.
        //
        // Resolved when the dictation starts and then reused, so nothing can move the surface
        // mid-dictation. A phase that arrives with no dictation behind it -- a microphone that
        // refused to start, so there was never a `.recording` -- resolves one here rather than
        // saying nothing at all.
        let screen: NSScreen
        if case .recording = phase {
            guard let current = NSScreen.main ?? NSScreen.screens.first else {
                log.error("no screen available -- the dictation runs, the notch does not appear")
                return
            }
            screen = current
            dictationScreen = current
        } else if let known = dictationScreen {
            screen = known
        } else {
            guard let current = NSScreen.main ?? NSScreen.screens.first else { return }
            screen = current
            dictationScreen = current
        }
        // `.compact` for every phase of a dictation: `compact()`/`expand()` are the only calls
        // that can produce a discontinuity, and lot 3 spends at most two of them per dictation.
        enqueue { [notch] in await notch.compact(on: screen) }

        // Nothing else will ever take these off the screen. The session has no timer -- how long
        // a completion is shown is the interface's business, and it is decided here.
        let dwell: TimeInterval? = switch phase {
        case .completed, .nothingHeard: NotchPresenter.completionDwell
        case .failed, .alert: NotchPresenter.failureDwell
        default: nil // a running dictation leaves when its next state says so
        }
        guard let dwell else { return }
        retraction = Task { [weak self] in
            try? await Task.sleep(for: .seconds(dwell))
            guard !Task.isCancelled else { return }
            self?.show(.hidden)
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = transition
        transition = Task { @MainActor in
            await previous?.value
            await work()
        }
    }
}

/// What the notch's views read, and the only mutable thing between the session and the screen.
///
/// Deliberately not `AppState`: the waveform of task T3 publishes about 20 times a second, and
/// every `@Published` change on `AppState` re-evaluates `MurmureApp.body`, which draws the
/// menu-bar scene. Two observable objects, two refresh rates.
///
/// It decides nothing. Every decision is `NotchPresenter`, in `MurmureCore`, where it is tested.
@MainActor
final class NotchModel: ObservableObject {
    @Published fileprivate(set) var phase: NotchPhase = .hidden
}

/// One side of the notch. A placeholder: tasks T3 and T4 replace it with the waveform bars and
/// with each phase's real drawing.
///
/// The width is a constant and not a function of anything, and that is the point. Amplitude will
/// move bar *heights*; a wing that grew with the voice would make the shape breathe, and every
/// transition after the recording would then have to be read against a shape that never settled.
/// The same holds for the phases: what changes below is a colour, never a size, so the shape does
/// not move when a dictation goes from recording to transcribing to done.
private struct NotchWing: View {
    static let width: CGFloat = 32

    @ObservedObject var model: NotchModel

    var body: some View {
        Capsule()
            .fill(fill)
            .frame(width: Self.width, height: 5)
            .animation(.smooth, value: model.phase)
    }

    /// A stand-in, not a design. T4 owns what each phase actually looks like; what this proves
    /// today is that the phase reaches the wings at all. Green for a completion and nothing for a
    /// silence is the one distinction worth having before then -- it is the reason
    /// `.completed(insertedCharacters:)` exists.
    private var fill: Color {
        switch model.phase {
        case .recording: .white.opacity(0.85)
        case .transcribing, .inserting: .white.opacity(0.55)
        case .refining: .white.opacity(0.35)
        case .completed: .green
        case .nothingHeard: .white.opacity(0.2)
        case .failed, .alert: .orange
        case .hidden: .clear
        }
    }
}
