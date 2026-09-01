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

    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 2.5

    /// How often the waveform samples the level box. ~20 Hz: fast enough that the bars move with
    /// the voice, slow enough that it is not a redraw storm. It is a PULL -- nothing about the
    /// audio thread's rate reaches this timeline, and a frame missed here is a bar not drawn,
    /// never a buffer delayed.
    static let sampleInterval: TimeInterval = 0.05

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
                TimelineView(.periodic(from: .now, by: Self.sampleInterval)) { _ in
                    bars(levels.bars())
                }
            case .travelling:
                // `.animation` rather than the waveform's 20 Hz sample, and with no `.animation()`
                // modifier under it: the position is recomputed at display rate, so it is
                // continuous by construction. Interpolating between 20 Hz samples the way the bars
                // do would animate the end-of-cycle wrap as a flyback back across the whole
                // surface, which is the one visible jump this phase is able to produce.
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

    private func bars(_ levels: [Float]) -> some View {
        HStack(spacing: Self.barSpacing) {
            ForEach(Array((mirrored ? levels.reversed() : levels).enumerated()), id: \.offset) { _, level in
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
        // sample to the next so 20 Hz of steps reads as movement rather than as a flicker.
        .animation(.linear(duration: Self.sampleInterval), value: levels)
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
