import MurmureCore
import SwiftUI

/// One half of a dictation's collapsed drawing, at whatever size its container hands it.
///
/// **It does not know what it is inside.** The notch draws two of these, one per wing, on either
/// side of the hardware cutout; a Mac with no notch has no cutout to be on either side of, and
/// draws the same two halves as one small floating pill. Nothing below reads a screen, a notch or
/// a window -- the only geometry it has is the `size` its container decided, and the only state is
/// a phase and the instant that phase's drawing started.
///
/// The split of what scales and what does not is deliberate, and it is the whole contract:
///
/// - **Lengths and positions are fractions of `size`.** The mark is `markWidth` of the container's
///   width and travels across it; a bar's height is a fraction of the container's height. A
///   container twice as wide gets the same drawing, twice as wide.
/// - **Line weights are absolute points.** A 3 pt line is a 3 pt line at any container size --
///   scaling it would make the same design read as a hairline in one surface and a slab in the
///   other, which is the opposite of the point. This is already what lot 3 T3's bars do
///   (`barWidth` is absolute, the bar's height is not), and it is kept rather than invented.
/// - **The waveform answers a wider container with more bars and wider gaps, never thicker ones.**
///   That is the same rule read the other way, and it is the reading that survived contact with a
///   five-to-one width ratio: `WaveformLayout` fits the count, the gaps AND the bar to `size.width`,
///   holding the *proportion* of ink constant rather than the number of points. Holding the number
///   is what made a 3 pt bar half the pitch on the panel and a fifth of it on the card -- a
///   hairline in one surface and a slab in the other, which is the outcome the rule forbids.
///
/// Every decision above the pixels -- which family of drawing a phase belongs to, where the mark
/// is at this instant, how bright the breath is, when the counter appears -- is `NotchAppearance`
/// and `NotchPresenter`, in `MurmureCore`, where both surfaces reach the same answers and where
/// they are tested. What is here is arithmetic on a `CGSize`.
struct DictationPhaseView: View {
    /// The thickness of every mark that is not the waveform.
    ///
    /// `WaveformLayout.minimumBarWidth`, which is the weight a bar has on the narrowest surface --
    /// so on the panel the travelling mark that replaces the bars is exactly the line they were,
    /// and the crossfade at the end of a recording changes the shape of what is drawn without
    /// changing how much ink is on the surface. On the card the bars are wider than this and the
    /// mark is not: the marks are progress reports, and a progress report drawn as heavy as a
    /// voice would compete with the sentence above it.
    static let markHeight = CGFloat(WaveformLayout.minimumBarWidth)

    /// The completion's fill, and the only thing in the sequence drawn heavier than a mark -- it
    /// is the only phase that is a result rather than a progress report.
    static let fillHeight: CGFloat = 7

    /// How bright the decoded-so-far bar is, against the 0.9 of the mark sweeping over it.
    ///
    /// **Arbitrary in its digit, ordered on purpose.** It has to stay below the sweep's, or the
    /// mark vanishes into the region it has already crossed and the drawing stops saying that
    /// anything is still happening -- which is the one thing it has to say on the dictations where
    /// the fill barely moves. Dimmer, the two read as what they are: a quiet record of ground
    /// covered, and a bright thing still moving over it.
    static let progressFillOpacity: Double = 0.5


    /// How often the waveform samples the level box. It is a PULL -- nothing about the audio
    /// thread's rate reaches this timeline, and a frame missed here is a bar not drawn, never a
    /// buffer delayed.
    ///
    /// **60 Hz, up from 20.** What it buys is punctuality, not more waveform: `AudioLevels` cuts
    /// each tap buffer into two blocks and appends both at once, so at the 4 096 frames and 48 kHz
    /// of this Mac the levels genuinely change about twelve times a second, 85 ms apart, whatever
    /// this number is. Sampling that on a 50 ms grid put each change up to 50 ms late and made the
    /// wait between two advances alternate 50 ms and 100 ms -- a waveform that hesitates twice a
    /// second, which is what reads as old. On a 16.7 ms grid the lateness is at most 17 ms and the
    /// cadence is the microphone's own.
    ///
    /// `.animation(minimumInterval:)` and not `.periodic`, which is what it was: the schedule is
    /// then a whole number of display frames, so every tick lands on a frame that is about to be
    /// composited. A free-running 16.7 ms timer against an 8.3 ms refresh has no such alignment --
    /// two ticks fall inside one frame and none inside the next -- which is a second uneven rhythm
    /// laid over the one this change exists to remove.
    ///
    /// It is a *minimum interval* and not a promised rate, so what it actually ticks at is worth
    /// measuring rather than assuming. **Measured on this machine, in both placements: 60.0 ticks
    /// a second**, the schedule taking every second frame of a 120 Hz link. That link is the
    /// built-in display's, and it stayed the built-in display's with the window bound to the
    /// external one -- `panel.screen` reporting the 170 Hz panel while uncapped `.animation` still
    /// ticked at 120.0 and not 170.
    ///
    /// **Inferred from the documented semantics and never observed here:** a link that is not a
    /// multiple of 60 would land on the next slower multiple, 56.7 Hz on a 170 Hz one. Nothing in
    /// the harness ever drove the schedule from that link, so it is written down as arithmetic
    /// over what `TimelineView` promises, not as a rate this Mac has been seen to produce.
    ///
    /// Measured cost, one surface's two halves rendered off-screen for 20 s with the levels fed on
    /// the real tap cadence, six interleaved runs each: **7.6-7.9 % of one core at 20 Hz against
    /// 8.5-9.6 % at 60 Hz.** Three times the samples for about a fifth more work, because most of
    /// the work is not the sampling -- the bars are carried between samples by `levelCarry` below,
    /// and CoreAnimation renders that at the display's rate whatever this timeline asks for. A
    /// seventh run of each landed near half those figures, which is this Mac's ProMotion display
    /// choosing a lower refresh: the cost follows the compositor more closely than it follows this
    /// constant. On the 14-core M4 Pro this runs on, 9 % of one core is 0.6 % of the machine, and
    /// only while a recording is on screen -- the same view with no timeline at all costs 0.03 %.
    ///
    /// Uncapped `.animation` measured 10.0-10.9 % for 120 ticks a second, i.e. it pays a third
    /// again over 60 Hz to redraw a waveform that changed twelve times. That is why this is capped
    /// at the 60 Louis asked for rather than left to follow whatever the display runs at.
    static let sampleInterval: TimeInterval = 1.0 / 60

    /// How long a bar takes to travel from one sample's height to the next.
    ///
    /// **Deliberately not `sampleInterval`, which it used to be**, and the two stopped being the
    /// same number the moment the sampling got faster than the levels. This is a carry across the
    /// gap between two *arrivals*, ~85 ms apart; setting it to 1/60 would ramp each new height in
    /// 17 ms and then hold it still for the other 68, which is the stutter this change is meant to
    /// remove, drawn sharper.
    static let levelCarry: TimeInterval = 0.05

    /// The one accent, assembled from the components `NotchAppearance` chose (lot 3 D11, Q-NB2).
    static let accent = Color(
        hue: NotchAppearance.accentHue,
        saturation: NotchAppearance.accentSaturation,
        brightness: NotchAppearance.accentBrightness
    )

    /// Fades the last eighth of each end instead of cutting it.
    ///
    /// A container's frame generally sits a few points inside whatever draws behind it (the notch's
    /// wings sit inside DynamicNotchKit's own insets), so a hard clip would cut the travelling mark
    /// off in mid-black, several points before anything the eye reads as an edge. Fading it lets
    /// the mark leave and arrive without ever showing a cut.
    static let edgeFade = LinearGradient(
        stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.12),
            .init(color: .black, location: 0.88),
            .init(color: .clear, location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    let phase: NotchPhase

    /// The instant the current drawing started -- **not** the instant the phase started.
    ///
    /// The two differ exactly where it matters: `transcribing` → `inserting` changes the phase and
    /// not the drawing, and restarting the clock there would send the travelling mark back to its
    /// starting edge mid-flight, on every dictation. The owner of this view is what keeps them
    /// apart, through `NotchAppearance.animationStart(previousMark:previousStart:newMark:now:)`.
    let markBegan: Date

    /// The waveform's levels, sampled while a dictation records.
    let levels: AudioLevels

    /// How far the transcription has got, pulled while one is running.
    ///
    /// `levels`'s shape and for `levels`'s reason: one box, written by whoever is working and read
    /// by whoever is drawing, never `@Published`. Not optional, so that a surface added later
    /// cannot quietly draw a transcription with no way of saying how far along it is -- the
    /// compiler asks, rather than this comment.
    let progress: DecodeProgressBox

    /// This half runs outward to the **right**; `false` runs outward to the left.
    ///
    /// It exists because the drawing used to live on either side of a hardware cutout: two wings,
    /// each other's reflection, everything moving away from the notch. The floating panel draws
    /// the same pair side by side, running outward from its own centre.
    ///
    /// **A container drawing ONE piece passes `false`**, and both surfaces do exactly that for a
    /// recording and for a transcription. Mirroring a waveform means drawing the same instant
    /// twice, once on each side of the join, which is a duplication rather than a symmetry; a
    /// transcription joined it once it had a fraction to fill in. `NotchAppearance.isMirrored(_:)`
    /// is the single answer both surfaces ask. Unmirrored, a drawing reads left to right, the way
    /// every other meter and every reading eye does.
    ///
    /// It also carries the elapsed counter (see `breath(at:)`), so a container drawing a single
    /// half of a REFINEMENT rather than a pair wants `true` instead.
    let mirrored: Bool

    /// The container's decision, never this view's.
    ///
    /// There is no intrinsic size and there is deliberately no `GeometryReader`: a surface whose
    /// content sized itself would be a surface whose width moved with what it was drawing, and the
    /// one criterion of this sequence is that the shape never moves.
    let size: CGSize

    var body: some View {
        Group {
            switch NotchAppearance.mark(for: phase) {
            case .none:
                Color.clear
            case .waveform:
                TimelineView(.animation(minimumInterval: Self.sampleInterval)) { _ in
                    bars(levels.bars())
                }
            case .travelling:
                // Uncapped, unlike the waveform's `minimumInterval`, and with no `.animation()`
                // modifier under it: the position is a function of the date, so recomputing it at
                // the display's own rate is what makes it continuous, and there is no source
                // cadence above which the extra frames would be redundant the way there is for the
                // bars. Carrying it between samples the way the bars are carried would animate the
                // end-of-cycle wrap as a flyback back across the whole surface, which is the one
                // visible jump this phase is able to produce.
                TimelineView(.animation) { context in
                    travellingMark(at: context.date)
                }
            case .pulsing:
                TimelineView(.animation) { context in
                    breath(at: context.date)
                }
            case .success:
                // The full width, on both halves, in the one green the interface has. This is
                // Murmure's replacement for a notification, and nothing else is drawn this heavy.
                Capsule()
                    .fill(.green)
                    .frame(height: Self.fillHeight)
            case .quiet:
                // A progress mark with all of its movement and all of its colour taken away: an
                // absence has to be legible AS an absence, next to a green fill it must never be
                // mistaken for.
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(width: size.width * NotchAppearance.markWidth, height: Self.markHeight)
            case .warning:
                Capsule()
                    .fill(.orange)
                    .frame(height: Self.markHeight)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.smooth, value: phase)
    }

    /// The recording: one bar per level, **fitted to the frame rather than centred in it**.
    ///
    /// This used to be an `HStack` of every level at a fixed spacing, which made the row a block
    /// of fixed width wherever it was drawn -- 32 pt of bars on a 32 pt panel half, and the same
    /// 32 pt marooned in the middle of the card's 165 pt half. `WaveformLayout` decides both
    /// numbers from `size.width` instead: how many of the newest levels this surface has room for,
    /// and how far apart they go so that they fill it exactly.
    ///
    /// The newest levels and not the first ones: `levels` is oldest-first and a narrow surface
    /// showing the *start* of the history would be a waveform running a second behind the voice.
    private func bars(_ levels: [Float]) -> some View {
        let shown = Array(levels.suffix(WaveformLayout.barCount(inWidth: size.width)))
        let width = CGFloat(WaveformLayout.barWidth(inWidth: size.width, barCount: shown.count))
        let spacing = WaveformLayout.barSpacing(inWidth: size.width, barCount: shown.count)
        return HStack(spacing: spacing) {
            ForEach(Array((mirrored ? shown.reversed() : shown).enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(
                        width: width,
                        // Never below its own width: a bar shorter than it is wide is a dot, and a
                        // row of dots is what silence looks like -- present, flat, and still.
                        height: max(width, CGFloat(level) * size.height)
                    )
            }
        }
        // The meter's own attack and release do the smoothing; this only carries each bar from one
        // arrival to the next so a burst of levels reads as movement rather than as a flicker.
        .animation(.linear(duration: Self.levelCarry), value: shown)
    }

    /// The transcription -- and the insertion behind it: a mark crossing the row from left to
    /// right, over and over, with the audio already decoded filling in behind it.
    ///
    /// **Two layers, and only the lower one is ever absent.** The sweep runs from the first frame
    /// of the phase to the last whatever the decoder reports, so it is what a short dictation
    /// draws, unchanged, for the half-second it lasts. The fill appears underneath it only once
    /// something has genuinely been measured -- `NotchAppearance.progressFill(for:progress:)` owns
    /// that rule and the reasoning behind it. There is no moment where one drawing is swapped for
    /// another, which is what stops the boundary between the two regimes being a glitch.
    ///
    /// `mirrored` is deliberately not read here. A travelling mark is never a mirrored pair any
    /// more (`NotchAppearance.isMirrored(_:)`), so there is no second half whose reflection this
    /// would have to be, and one direction -- leading edge to trailing edge, the way the waveform
    /// before it and the fill beneath it both read -- is the only one in the row.
    private func travellingMark(at date: Date) -> some View {
        let distance = NotchAppearance.markDistanceAlong(elapsed: date.timeIntervalSince(markBegan))
        let fill = NotchAppearance.progressFill(for: .travelling, progress: progress.current())
        return ZStack(alignment: .leading) {
            if let fill {
                Capsule()
                    .fill(.white.opacity(Self.progressFillOpacity))
                    // Never narrower than it is tall, for the reason a bar is never shorter than
                    // it is wide: below that a capsule stops being a short bar and becomes a dot.
                    .frame(
                        width: max(Self.markHeight, size.width * fill), height: Self.markHeight)
                    .animation(.easeOut(duration: NotchAppearance.progressSettle), value: fill)
            }
            Capsule()
                .fill(.white.opacity(0.9))
                .frame(width: size.width * NotchAppearance.markWidth, height: Self.markHeight)
                .offset(x: size.width * (distance - 0.5))
                .frame(width: size.width, height: size.height)
                .mask(Self.edgeFade)
        }
        .frame(width: size.width, height: size.height)
    }

    /// The refinement: a bar breathing in the accent, and past the fifth second a counter in its
    /// place on the half that carries it.
    ///
    /// This is the one phase where the two halves stop being each other's reflection, and it is
    /// deliberate: one says *still working*, the other says *for how long*. Both stay inside the
    /// same fixed frame, so the counter arriving changes what is drawn and never the width of the
    /// shape -- and it arrives as a crossfade, because a number appearing out of nothing at 5 s
    /// would otherwise be the one pop in a sequence that has none.
    private func breath(at date: Date) -> some View {
        let showsCounter = mirrored
            && NotchPresenter.showsElapsedCounter(in: phase, since: markBegan, now: date)
        return Group {
            if showsCounter {
                Text(NotchPresenter.elapsed(since: markBegan, now: date))
                    // 11 pt, the muted one of the two sizes the interface has (lot 3 D11).
                    // Monospaced digits so the number does not re-centre itself every second.
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Self.accent)
                    .lineLimit(1)
                    // A refinement past ten minutes is not a thing that happens -- 57.5 s is the
                    // worst measured -- but if it did, `10:00` would shrink rather than truncate.
                    .minimumScaleFactor(0.7)
            } else {
                Capsule()
                    .fill(Self.accent)
                    .frame(height: Self.markHeight)
                    .opacity(
                        NotchAppearance.pulseFloor
                            + (1 - NotchAppearance.pulseFloor)
                            * NotchAppearance.pulse(elapsed: date.timeIntervalSince(markBegan)))
            }
        }
        .animation(.smooth, value: showsCounter)
    }
}
