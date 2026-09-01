import AppKit
import DynamicNotchKit
import MurmureCore
import SwiftUI
import os

/// The one notch surface, and the only object in Murmure allowed to grow it or retract it.
///
/// **The notch is the ROOT component of the interface, not a window glued under it** (lot 3 §2,
/// non-negotiable), and since lot 3 T9 it is also the whole of it: a dictation grows the cutout
/// into a card that *contains* the cutout, the way an iPhone's Dynamic Island does. Louis's
/// verdict on the wings that preceded it was that the hardware ate them -- "on a l'impression que
/// le notch cache 90 % de ce qu'on est censé voir" -- and the answer he chose was not wider wings
/// but one shape that the hole is part of.
///
/// **What makes the cutout and the card read as one object**, and none of it is a matter of taste:
///
/// 1. **The shape is drawn from the top edge of the display.** DynamicNotchKit's panel is placed
///    with its top at `screen.frame.maxY` (`DynamicNotch.initializeWindow`, tag 1.1.0) and
///    `NotchView` masks its black with a `NotchShape` pinned `alignment: .top`
///    (`NotchView.swift:56-77`). So the card's first ~37 pt *are* the menu-bar row the cutout
///    occupies, and the hole is interior to the drawn shape rather than adjacent to it.
/// 2. **The fill is `.black`, the same black the hole is.** Nothing is drawn behind the cutout
///    either: `NotchView.expandedContent()` reserves `notchSize.height` at the top with a
///    `safeAreaInset` (`NotchView.swift:139`), so every pixel of Murmure's content is below the
///    hardware and the band across the hole is pure fill.
/// 3. **The top corners are inverted.** `NotchShape` flares outward into the menu bar with a
///    15 pt concave radius in the expanded state, which is what the cutout's own corners do -- the
///    card looks poured out of it rather than stuck under it.
///
/// Three mechanical facts hold the "never jumps" rule, and none of them is a matter of intent:
///
/// 1. **One `DynamicNotch`, built at launch and never rebuilt.** Its content view is `let`-captured
///    by `DynamicNotch.init` (`DynamicNotch.swift:105-107`), so a new state of Murmure has to be
///    new *data* read by that view -- rebuilding the notch to change what it draws would tear the
///    window down and put a new one up, which is the jump.
/// 2. **The panel's frame is never reassigned.** The library sizes it half the screen, anchored
///    top-centre, once, in `initializeWindow` and never calls `setFrame` again. Everything Murmure
///    shows happens inside that fixed transparent canvas; the visible black is a SwiftUI mask that
///    follows its content. Morphing is free; resizing is impossible.
/// 3. **The card is ONE size for the whole of a dictation.** `NotchCardView` is laid out at a
///    fixed content width and a fixed content height, and every phase changes only what is drawn
///    inside it. `expand()` and `hide()` are the only two library calls made per dictation, and
///    `compact()` is never called at all -- so the conversion path, whose library default is
///    "animate to hidden, sleep 0.25 s, animate back" (`DynamicNotch.swift:196-210`), is
///    unreachable rather than merely disabled.
///
/// Idle is `hide()`, i.e. **no window at all** (lot 3 D4).
///
/// **Clicks pass through, and that is enforced at the window rather than hoped for in SwiftUI.**
/// The card is ~400 x 126 pt over the menu bar, and DynamicNotchKit draws its black through a
/// `Rectangle().padding(-50)` (`NotchView.swift:58-62`) -- fifty points of hit-testable view in
/// every direction beyond the shape. Rather than reason about whether `.mask` clips hit testing,
/// the panel is made `ignoresMouseEvents`, which is the same guarantee `MurmureStatusPanel` gives
/// for the same reason: this is a status indicator, it takes no clicks, and nothing it covers may
/// lose one. That also settles the risk the plan recorded as unfixable -- `DynamicNotchPanel`
/// overrides `canBecomeKey` to `true`, but a panel that never receives a mouse event can never be
/// made key by one, so ⌘V cannot land in it.
@MainActor
final class NotchController {
    private let notch: DynamicNotch<NotchCardView, EmptyView, EmptyView>
    /// What the card reads. Held here because the two are one mechanism: the phase decides both
    /// what is drawn and whether there is a window to draw it in.
    private let model: NotchModel
    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "notch")

    /// The state the session was in before the one being handled. `NotchPresenter.phase` needs it
    /// because `DictationSession` emits `.completed` and `.idle` in the same breath: without the
    /// previous state the notch would retract in the instant it was told the dictation succeeded.
    private var previousState: DictationSession.State = .idle

    /// Retracts a completion or a failure once it has been on screen long enough. Cancelled by
    /// the next phase, so a dictation started during a flash never has its card pulled out from
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
    /// `expand()` and `hide()` are async and take about 0.4 s of animation, while the state
    /// changes that drive them arrive as fast as the pipeline emits them -- a dictation that fails
    /// to start goes `.recording` → `.failed` in far less than that. Awaiting the previous
    /// transition means the last state change wins, instead of two animations racing over one
    /// window.
    private var transition: Task<Void, Never>?

    /// `levels` is the box the recorder fills; the card samples it while a dictation records.
    /// `progress` is the box the decoder advances; the card samples that while one transcribes.
    /// Handed in rather than made here because the recorder needs the same one.
    init(levels: AudioLevels, progress: DecodeProgressBox) {
        let model = NotchModel(levels: levels, progress: progress)
        self.model = model
        notch = DynamicNotch(
            // Empty rather than `[.keepVisible, .increaseShadow]`, because the panel below ignores
            // mouse events and `NotchView`'s `.onHover` can therefore never fire. Leaving the
            // options set would be a configuration describing behaviour that cannot happen.
            // Nothing is lost: with `isHovering` permanently false, `NotchContentView` gives the
            // expanded state its 0.5-opacity, 10 pt shadow either way -- and `_hide`'s
            // "keepVisible" retry loop, which would otherwise postpone a retraction while the
            // pointer rested on the card, is now unreachable.
            hoverBehavior: [],
            // `let`-captured by `DynamicNotch.init` and never re-made, which is why the phase has
            // to reach it as observed DATA rather than as a rebuilt notch.
            expanded: { NotchCardView(model: model) }
        )
    }

    /// The session changed state. The only entry point, and the only thing allowed to move the
    /// notch: `NotchPresenter` turns the change into a phase, and this shows it.
    func apply(_ state: DictationSession.State) {
        let phase = NotchPresenter.phase(previous: previousState, current: state)
        previousState = state
        show(phase)
    }

    /// A problem with Murmure itself -- Accessibility revoked, ⌥Space refused -- on the surface a
    /// dictation would otherwise be using.
    ///
    /// `FailureSurface.transient` is what decides, and its answer is that a dictation always wins:
    /// with one on screen this resolves to the phase already showing and `show` returns at its
    /// first line. So this can be called at any moment without ever painting over a waveform.
    ///
    /// It leaves on `NotchPresenter.dwell`, like every other notice, because the card is a black
    /// slab across the menu bar and one that outlived what it was about is the "band with no
    /// dictation behind it" the plan refuses. The surface that WAITS is `ProblemPanelController`,
    /// which is also the only one that can be acted on.
    func raise(_ alert: AppAlert) {
        show(FailureSurface.transient(dictation: model.phase, alert: alert))
    }

    private func show(_ phase: NotchPhase) {
        guard phase != model.phase else { return }
        model.enter(phase, at: Date())
        // Whatever was on its way out is no longer the thing on screen.
        retraction?.cancel()
        retraction = nil

        guard NotchAppearance.showsShape(in: phase) else {
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

        // **A guard the library used to make for us.** `_compact` refuses a screen with no cutout
        // and hides instead (`DynamicNotch.swift:226-229`), which is what kept this controller
        // silent on an external display while `StatusPanelController` drew there. `_expand` makes
        // no such check -- it would draw DynamicNotchKit's own `NotchlessView` card, on top of the
        // floating panel, saying the same thing twice. Asking the same question the panel asks
        // (`StatusSurfaceChoice.surface(on:)`) is what keeps exactly one surface per display.
        let geometry = ScreenGeometry(screen)
        guard StatusSurfaceChoice.surface(on: geometry) == .notch else {
            enqueue { [notch] in await notch.hide() }
            return
        }
        model.fit(toNotchWidth: notchWidth(of: screen))

        // `expand()` for every phase of a dictation, and exactly once: it returns immediately when
        // the state is already `.expanded` (`DynamicNotch.swift:172`), so the phases after the
        // first are pure data changes inside a card that the library never touches again.
        enqueue { [notch] in
            // Ordered on the main actor BEFORE the await, so it runs at `expand`'s first
            // suspension point. `_expand` reaches that point (`try? await Task.sleep`) only after
            // `initializeWindow` has made the panel and `showWindow` has ordered it front, so the
            // panel is inert from the frame it becomes visible rather than 0.4 s later.
            let harden = Task { @MainActor in
                notch.windowController?.window?.ignoresMouseEvents = true
            }
            await notch.expand(on: screen)
            await harden.value
            // Unconditional, because the ordering above is a property of the library's *current*
            // control flow. If a future version awaited before making its window, the line above
            // would silently do nothing and this one is what still keeps the guarantee.
            notch.windowController?.window?.ignoresMouseEvents = true
        }

        // Nothing else will ever take these off the screen. The session has no timer -- how long
        // a completion is shown is the interface's business, and which phases get one at all is
        // `NotchPresenter.dwell(for:)`, in the package, where a phase added later cannot quietly
        // inherit "never retracts".
        guard let dwell = NotchPresenter.dwell(for: phase) else { return }
        retraction = Task { [weak self] in
            try? await Task.sleep(for: .seconds(dwell))
            guard !Task.isCancelled else { return }
            self?.show(.hidden)
        }
    }

    /// The cutout's width on this display, by the same arithmetic DynamicNotchKit uses
    /// (`NSScreen.notchSize`, tag 1.1.0): the display minus the two auxiliary areas the menu bar
    /// is split into. Zero when there is no cutout, which the guard above has already excluded.
    private func notchWidth(of screen: NSScreen) -> Double {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else { return 0 }
        return screen.frame.width - left.width - right.width
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = transition
        transition = Task { @MainActor in
            await previous?.value
            await work()
        }
    }
}

/// What the notch's view reads, and the only mutable thing between the session and the screen.
///
/// Deliberately not `AppState`: the waveform of task T3 publishes about 20 times a second, and
/// every `@Published` change on `AppState` re-evaluates `MurmureApp.body`, which draws the
/// menu-bar scene. Two observable objects, two refresh rates.
///
/// It decides nothing. Every decision is `NotchPresenter`, `NotchAppearance` and `NotchCard`, in
/// `MurmureCore`, where they are tested.
@MainActor
final class NotchModel: ObservableObject {
    @Published private(set) var phase: NotchPhase = .hidden

    /// The phase the card is DRAWING, which is the last one that had a card at all.
    ///
    /// It exists because retracting takes 0.4 s and the drawing must not go blank first. `phase`
    /// becomes `.hidden` the instant the controller decides to retract, but `hide()` is *queued*
    /// behind whatever transition is in flight -- up to 0.4 s of it. Reading `phase` in the view
    /// therefore emptied the card ("Inserted 47 characters" → nothing, tint → white, drawing →
    /// `Color.clear`) and left a blank black slab on screen for as long as the queue took, before
    /// it even began to shrink. That was already true of the wings this replaces; on a 400 pt card
    /// it is the most visible thing in the sequence.
    ///
    /// So the card keeps showing the completion, the silence or the failure the whole way back
    /// into the cutout, and only the next dictation replaces it.
    private(set) var displayPhase: NotchPhase = .hidden

    /// The family of drawing the card is making, and the instant its animation counts from.
    ///
    /// Deliberately NOT `@Published`: both change only when `phase` does, and `phase` already
    /// publishes, so a second publisher would be a second redraw for one event. And `markBegan`
    /// cannot be derived in the view at all -- it is a function of the mark that was on screen
    /// *before*, which a view redrawing itself has no way to see.
    ///
    /// The clock outliving a phase change is the whole reason it is stored rather than reset:
    /// `transcribing` → `inserting` keeps one travelling mark in flight instead of sending it back
    /// behind the cutout for the one CGEvent round-trip an insertion lasts.
    private(set) var mark: NotchAppearance.Mark = .none
    private(set) var markBegan: Date = .distantPast

    /// The width the card lays its content out at, from the cutout of the display it is on.
    ///
    /// Published, unlike `mark` and `markBegan`, because it is the one value that does NOT change
    /// in step with `phase`: the controller resolves a screen after it has entered the phase, so a
    /// silent property would leave the card laid out at the previous display's width until some
    /// later phase happened to redraw it. It publishes at most once per dictation and, on a Mac
    /// with one cutout, never at all -- the guard below is what makes that true rather than
    /// hoped for.
    @Published private(set) var contentWidth: Double = NotchCard.contentWidth(
        forCardWidth: NotchCard.width, notchWidth: 0)

    /// The waveform's levels. Deliberately NOT `@Published`: they change about twenty-three times
    /// a second, and publishing them would re-evaluate the card's whole body on the audio thread's
    /// schedule. The view PULLS from it on a timeline of its own instead, so a level that arrives
    /// while nothing is being drawn costs nothing at all.
    let levels: AudioLevels

    /// The transcription's progress, pulled by the drawing for the same reason and on the same
    /// terms as `levels`: it moves on somebody else's schedule and no view should be rebuilt by it.
    let progress: DecodeProgressBox

    init(levels: AudioLevels, progress: DecodeProgressBox) {
        self.levels = levels
        self.progress = progress
    }

    /// The notch is now showing this. The one mutation on this object, so that the phase and the
    /// clock its drawing reads can never be set apart from each other.
    fileprivate func enter(_ phase: NotchPhase, at now: Date) {
        // A phase with no card of its own does not touch the drawing: it is the retraction, and
        // the card goes on saying what it said until it is gone. See `displayPhase`.
        if NotchAppearance.showsShape(in: phase) {
            let next = NotchAppearance.mark(for: phase)
            markBegan = NotchAppearance.animationStart(
                previousMark: mark, previousStart: markBegan, newMark: next, now: now)
            mark = next
            displayPhase = phase
        }
        // Published last, deliberately: the three silent properties above are read by the view on
        // the redraw this line schedules, so they have to be settled before it fires.
        self.phase = phase
    }

    /// The card is about to appear on a display whose cutout is this wide.
    ///
    /// Guarded on inequality so that the common case -- the same display, dictation after
    /// dictation -- publishes nothing at all.
    fileprivate func fit(toNotchWidth notchWidth: Double) {
        let width = NotchCard.contentWidth(
            forCardWidth: NotchCard.width, notchWidth: notchWidth)
        guard width != contentWidth else { return }
        contentWidth = width
    }
}

/// The card itself: a line saying what is happening, and the dictation's own drawing under it.
///
/// **It is centred, and that is a consequence rather than a taste.** The library reveals this view
/// by animating the frame it is clipped to from the cutout's width out to the card's, with the
/// content already laid out at full size behind the mask (`NotchView.notchContent()`,
/// `expandedContent()` -- `.fixedSize()` inside a frame whose `maxWidth` goes 0 → nil). So the
/// card opens from the middle outward, and anything pinned to an edge would spend the first
/// frames of every dictation clipped in half.
///
/// **Nothing in it changes the card's size.** The two rows have fixed heights and the whole thing
/// has a fixed width; a phase moves the *contents* of that rectangle and never its bounds, which
/// is the T4 acceptance criterion carried forward to a shape twenty times the area.
struct NotchCardView: View {
    /// The status line. 20 pt is the cap height of the 14 pt rounded face plus room for the
    /// glyph's own box, and it is fixed so a longer sentence cannot make the card taller.
    static let headlineHeight: CGFloat = 20

    /// The dictation's drawing. **Arbitrary**, and the one number that is pure gain over the
    /// wings: `DictationPhaseView` scales bar heights with the frame it is given, so at 42 pt
    /// instead of 16 the waveform is two and a half times taller for the same 3 pt bars. Line
    /// weights stay absolute by that view's contract -- the marks are not made heavier, the
    /// waveform is made taller.
    static let drawingHeight: CGFloat = 42

    /// **Arbitrary.** Enough that the sentence and the drawing read as two things rather than one
    /// stacked block.
    static let rowSpacing: CGFloat = 12

    /// The glow behind the drawing: the card's only mass, and how the phase's colour reaches a
    /// surface bigger than a 3 pt line.
    ///
    /// It exists because of `DictationPhaseView`'s contract, not in spite of it: that view's line
    /// weights are absolute points on purpose, so a card four times the width of a wing gets a
    /// mark that is four times as long and exactly as thin. Scaling the mark would have made the
    /// same design read as a slab; a blurred capsule of the phase's own colour behind it gives the
    /// card presence without touching a single stroke. All three numbers are **arbitrary**.
    static let glowHeight: CGFloat = 20
    static let glowBlur: CGFloat = 22
    /// How far past the drawing the glow spreads, so the halo is a halo and not an outline.
    static let glowSpill: CGFloat = 36

    /// The one accent, assembled from the components `NotchAppearance` chose (lot 3 D11, Q-NB2).
    static let accent = Color(
        hue: NotchAppearance.accentHue,
        saturation: NotchAppearance.accentSaturation,
        brightness: NotchAppearance.accentBrightness
    )

    @ObservedObject var model: NotchModel

    var body: some View {
        // The phase the card DRAWS, which is not the phase the controller is in while it retracts.
        let phase = model.displayPhase
        let piece = CGSize(
            width: NotchCard.drawingPieceWidth(for: phase, contentWidth: model.contentWidth),
            height: Self.drawingHeight
        )
        VStack(spacing: Self.rowSpacing) {
            headline(phase)
            drawing(phase, piece: piece)
        }
        .frame(width: model.contentWidth)
        // One timing for the glyph, the sentence, the tint and the width of the drawing, so a
        // phase change arrives as a single event rather than as four things settling in turn.
        .animation(.smooth(duration: NotchCard.phaseMorph), value: phase)
        // Belt to the panel's brace. `NotchController` makes the whole window ignore mouse events;
        // this makes the SwiftUI side inert too, so the guarantee does not rest on the exact
        // instant the window flag is set.
        .allowsHitTesting(false)
    }

    /// The glyph and the sentence, side by side and centred.
    ///
    /// The sentence is `StatusPanelText`, the floating panel's, not a second set of strings: the
    /// two surfaces are the same dictation seen on two displays, and a word that differed between
    /// them would be a difference Louis has to learn for nothing.
    private func headline(_ phase: NotchPhase) -> some View {
        let symbol = NotchCard.symbolName(for: phase)
        return HStack(spacing: 7) {
            if !symbol.isEmpty {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Self.color(for: phase))
                    // A fixed box, so swapping one glyph for another cannot move the sentence
                    // beside it: SF Symbols are not all the same width, and the transition below
                    // has both on screen at once.
                    .frame(width: 16, height: 16)
                    .id(symbol)
                    .transition(.opacity)
            }
            Text(StatusPanelText.label(for: phase))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                // Crossfades the characters in place instead of cutting them. A failure message
                // is the one line long enough to be read, and it arrives while the card is
                // already up.
                .contentTransition(.opacity)
                // One line, and the tail is what gets cut: the beginning of a failure message is
                // the part that names what failed.
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(height: Self.headlineHeight)
    }

    /// The dictation's own drawing -- the notch's, unchanged -- over a glow in the phase's colour.
    ///
    /// **The recording is ONE waveform across the whole row; every other phase is two mirrored
    /// pieces.** Which it is belongs to `NotchCard.isMirroredPair(for:)`, where the reason is
    /// written out: the waveform is the only phase whose drawing is data over time, and two
    /// mirrored copies of a time series draw the same instant twice, against the join, with no gap
    /// between the copies. The others mirror an ornament rather than data -- a transcription's mark
    /// leaves the centre in both directions, a completion's fill spans the row -- and keep the pair.
    ///
    /// `id: \.self` on the index, so the piece that is already on screen keeps its identity when a
    /// recording ends: piece 0 animates from the full row to a half while piece 1 fades in beside
    /// it, rather than both being torn down and rebuilt. That transition is the one place in the
    /// sequence where the drawing changes structure and not merely content.
    private func drawing(_ phase: NotchPhase, piece: CGSize) -> some View {
        let pieces = NotchCard.drawingPieces(for: phase)
        return ZStack {
            Capsule()
                .fill(Self.color(for: phase))
                .frame(
                    width: Double(pieces) * piece.width + Self.glowSpill,
                    height: Self.glowHeight)
                .blur(radius: Self.glowBlur)
                .opacity(Self.glowOpacity(for: phase))
            HStack(spacing: 0) {
                ForEach(Array(0..<pieces), id: \.self) { index in
                    DictationPhaseView(
                        phase: phase, markBegan: model.markBegan, levels: model.levels,
                        progress: model.progress,
                        // The second piece is the mirrored one. A lone piece is never mirrored:
                        // one waveform reads oldest to newest, left to right, the way every other
                        // meter and every reading eye does.
                        mirrored: index == 1, size: piece)
                }
            }
        }
        // The row is the card's full width whatever the drawing inside it is doing, so a recording
        // becoming a transcription changes the drawing and never the shape.
        .frame(width: model.contentWidth, height: Self.drawingHeight)
    }

    // MARK: - The tints, which are `NotchCard`'s decision and this view's pixels

    /// The sRGB behind `NotchCard.Tint`. Which phase claims which is in the package; what green
    /// and orange *are* is `Color`'s, and the accent's three components are `NotchAppearance`'s.
    private static func color(for phase: NotchPhase) -> Color {
        switch NotchCard.tint(for: phase) {
        case .neutral: .white
        case .accent: accent
        case .success: .green
        case .muted: .white.opacity(0.35)
        case .warning: .orange
        }
    }

    /// How much of that colour the glow carries. **Every number arbitrary.** The ordering is not:
    /// a completion is the loudest thing the card ever does, a silence the quietest -- an absence
    /// that glowed would be competing with the success it must never be mistaken for.
    private static func glowOpacity(for phase: NotchPhase) -> Double {
        switch NotchCard.tint(for: phase) {
        case .neutral: 0.22
        case .accent: 0.42
        case .success: 0.50
        case .muted: 0.10
        case .warning: 0.40
        }
    }
}
