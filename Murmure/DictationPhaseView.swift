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
///   That is the same rule read the other way: `WaveformLayout` fits the count and the spacing to
///   `size.width` so the row fills it, and `barWidth` is the one number it never touches.
///
/// Every decision above the pixels -- which family of drawing a phase belongs to, where the mark
/// is at this instant, how bright the breath is, when the counter appears -- is `NotchAppearance`
/// and `NotchPresenter`, in `MurmureCore`, where both surfaces reach the same answers and where
/// they are tested. What is here is arithmetic on a `CGSize`.
struct DictationPhaseView: View {
    /// The thickness of every mark that is not the waveform.
    ///
    /// The same as `barWidth` on purpose: the travelling mark that replaces the bars is then the
    /// same weight of line they were, so the crossfade at the end of a recording changes the shape
    /// of what is drawn without changing how much ink is on the surface.
    static let markHeight: CGFloat = 3

    /// The completion's fill, and the only thing in the sequence drawn heavier than a mark -- it
    /// is the only phase that is a result rather than a progress report.
    static let fillHeight: CGFloat = 7

    /// A bar's width. `WaveformLayout`'s, because how many bars a frame draws and how far apart
    /// they sit are now decided in the package, from this number and the frame's own width.
    static let barWidth = CGFloat(WaveformLayout.barWidth)

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

    /// This half runs outward to the **right**; `false` runs outward to the left.
    ///
    /// In the notch that is the trailing wing against the leading one, so the two are each other's
    /// reflection across the cutout and everything moves away from the hardware. A surface that is
    /// one piece rather than two draws the same pair side by side, and the two halves then run
    /// outward from its centre.
    ///
    /// It also carries the elapsed counter (see `breath(at:)`), so a container drawing a single
    /// half rather than a pair wants this one.
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
        let spacing = WaveformLayout.barSpacing(inWidth: size.width, barCount: shown.count)
        return HStack(spacing: spacing) {
            ForEach(Array((mirrored ? shown.reversed() : shown).enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(
                        width: Self.barWidth,
                        // Never below its own width: a bar shorter than it is wide is a dot, and a
                        // row of dots is what silence looks like -- present, flat, and still.
                        height: max(Self.barWidth, CGFloat(level) * size.height)
                    )
            }
        }
        // The meter's own attack and release do the smoothing; this only carries each bar from one
        // arrival to the next so a burst of levels reads as movement rather than as a flicker.
        .animation(.linear(duration: Self.levelCarry), value: shown)
    }

    /// The transcription -- and the insertion behind it: a mark leaving the inner edge and running
    /// to the outer one, over and over.
    ///
    /// The distance runs outward and is the same number on both halves. Turning it into an
    /// x-offset is the only line in this view that knows which half it is: the left half's inner
    /// edge is its right, the right half's is its left.
    private func travellingMark(at date: Date) -> some View {
        let distance = NotchAppearance.markDistanceOutward(
            elapsed: date.timeIntervalSince(markBegan))
        return Capsule()
            .fill(.white.opacity(0.9))
            .frame(width: size.width * NotchAppearance.markWidth, height: Self.markHeight)
            .offset(x: size.width * (mirrored ? distance - 0.5 : 0.5 - distance))
            .frame(width: size.width, height: size.height)
            .mask(Self.edgeFade)
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
