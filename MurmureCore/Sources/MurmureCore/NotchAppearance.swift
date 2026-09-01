import Foundation

/// What a dictation draws for a phase, and how that drawing moves through time.
///
/// The companion of `NotchPresenter`, and split from it along the same seam: the presenter turns
/// a state change into a phase, this turns a phase into a drawing. Both are here rather than in
/// the app target for the reason the presenter's own note gives -- `Murmure` has no test bundle,
/// so anything left in a view is a decision nothing can check.
///
/// Nothing here is a pixel, and nothing here is a notch. There are no point sizes, no colours as
/// such and no SwiftUI: a surface asks which family of mark it is drawing, where along itself the
/// mark sits at this instant, and how bright it should be, and multiplying those by its own size
/// is its whole remaining job. That is what lets the notch's wings and the floating surface a Mac
/// without a cutout needs draw the same dictation from the same answers.
///
/// **This is the one part of lot 3 with no reference anywhere.** Design notes §9 records that
/// Superwhisper's window was never captured while recording, processing or completing, so every
/// value below is Murmure's own and several of them are frankly arbitrary. They are marked as
/// such, in the same words the presenter uses, and the tests pin the *properties* that must hold
/// -- the wrap is invisible, the two motions are told apart, the accent is nobody else's -- rather
/// than the digits, which are Louis's to move.
public enum NotchAppearance {
    // MARK: - Whether there is a shape at all

    /// Whether the phase has a window behind it.
    ///
    /// `hidden` is not an empty notch, it is no window (lot 3 D4), and this is the only phase for
    /// which that is true -- including `nothingHeard`, which must be *seen* to say that nothing
    /// got through. A silence that retracted instantly would be indistinguishable from a hotkey
    /// press the app never received.
    public static func showsShape(in phase: NotchPhase) -> Bool {
        if case .hidden = phase { false } else { true }
    }

    // MARK: - Which family of drawing a phase belongs to

    /// The families of drawing a surface knows how to make.
    ///
    /// A level of indirection over `NotchPhase` for one reason, and it is the acceptance criterion
    /// of this task: phases that must look identical have to *be* identical to the view, or the
    /// crossfade between them is a crossfade between a thing and itself -- which is a flicker.
    /// `transcribing` and `inserting` are that case (see `mark(for:)`).
    public enum Mark: Equatable {
        /// No window, so nothing to draw.
        case none
        /// The bars of lot 3 T3, heights following the microphone.
        case waveform
        /// A short mark crossing the row from its leading edge to its trailing one, over and over,
        /// with the fraction of audio already decoded filling in behind it once there is one.
        case travelling
        /// A bar breathing in the accent across the whole width, and after five seconds a counter.
        case pulsing
        /// The completion fill. Green, and the only green in the interface.
        case success
        /// A dim, still, short mark: the dictation ran and nothing reached the target.
        case quiet
        /// Something went wrong. Lot 3 T6 owns what the expanded panel then says; the collapsed
        /// drawing only has to stop looking like a success.
        case warning
    }

    /// The family a phase draws in.
    ///
    /// `inserting` deliberately maps to the same family as `transcribing`. It lasts one CGEvent
    /// round-trip, so a drawing of its own would be a frame or two of something nobody can read,
    /// arriving as a crossfade in the middle of a sequence whose one criterion is that it never
    /// jumps. Sharing the family means the transition is not merely fast, it does not exist --
    /// and `animationStart(previousMark:previousStart:newMark:now:)` is what keeps the mark's
    /// own clock from restarting underneath it.
    public static func mark(for phase: NotchPhase) -> Mark {
        switch phase {
        case .hidden: .none
        case .recording: .waveform
        case .transcribing, .inserting: .travelling
        case .refining: .pulsing
        case .completed: .success
        case .nothingHeard: .quiet
        case .failed, .alert: .warning
        }
    }

    /// The instant a mark's animation counts from, given the one that was on screen.
    ///
    /// A phase change does not restart the drawing; a change of *family* does. Without this, the
    /// `transcribing` → `inserting` hand-off would send the travelling mark back behind the
    /// cutout mid-flight, which is the one visible discontinuity this task exists to avoid, and
    /// it would happen on every single dictation.
    public static func animationStart(
        previousMark: Mark, previousStart: Date, newMark: Mark, now: Date
    ) -> Date {
        newMark == previousMark ? previousStart : now
    }

    /// Whether the phase's drawing is two mirrored pieces, or one.
    ///
    /// **A drawing that reads as a timeline is one; an ornament is two.** Every phase used to be a
    /// mirrored pair, inherited from the wings: two drawings on either side of the hardware cutout, each running
    /// outward from it. Once a surface draws them side by side with no cutout between them, that
    /// structure stops being a design and becomes a seam -- and for the waveform it is worse than
    /// a seam. Louis, having watched it on both surfaces:
    ///
    ///     "Ça part du centre et c'est symétrique, ce qui rajoute cet effet d'onde comme dans
    ///      l'eau. J'aimerais vraiment avoir une barre unique, parce que là je vois que c'est deux
    ///      choses différentes qui sont symétriques."
    ///
    /// The rule the two cases divide on: **a mark that carries a position in time is drawn once.**
    /// The waveform was the first case. Each half drew the whole history, mirrored, so the newest
    /// level landed against the join on both sides -- one instant drawn twice, side by side -- and
    /// a peak appeared in the middle and travelled outward in both directions at once, which is
    /// what a ripple in water is. Mirroring DATA duplicates it. Mirroring an ORNAMENT -- the dim
    /// mark of a silence, the breath of a refinement, the fill of a completion -- is symmetry, and
    /// those keep their pair.
    ///
    /// **`travelling` is the second case, and it became one when it got a number.** It was mirrored
    /// for a reason that no longer exists, and the reason was written down: a single mark crossing
    /// left to right was rejected because "the cutout is 185 pt against a 32 pt wing, so a mark
    /// crossing at constant speed would spend six wing-widths of every cycle invisible behind it".
    /// There are no wings. The card is one continuous row with the cutout *inside* the shape, and
    /// the panel never had a cutout at all, so the objection retired itself.
    ///
    /// What forces the question rather than merely allowing it is `progressFill`. A fraction of
    /// audio decoded is data in exactly the sense the waveform is: mirroring it would draw one
    /// progress bar as two half-length bars growing out of the centre, which is the "deux choses
    /// différentes qui sont symétriques" Louis asked three times to be rid of -- re-introduced on a
    /// brand-new element. And a fill that reads left-to-right underneath a sweep that reads
    /// outward-from-the-centre is two directions in one row. So both are one row, both read the way
    /// the waveform reads, and a dictation runs left to right from its first bar to its last.
    ///
    /// It is here, on the mark rather than on either surface, because it is not a property of a
    /// notch or a panel: it is a property of what is being drawn, and both surfaces have to reach
    /// the same answer or the same dictation reads as two different things on two displays.
    public static func isMirrored(_ mark: Mark) -> Bool {
        switch mark {
        case .waveform, .travelling: false
        default: true
        }
    }

    /// The same question asked of a phase.
    public static func isMirrored(for phase: NotchPhase) -> Bool {
        isMirrored(mark(for: phase))
    }

    // MARK: - transcribing: a mark travelling out of the notch

    /// How long one sweep takes.
    ///
    /// **Arbitrary, and recorded as arbitrary.** Nothing in this repository measures how long a
    /// transcription takes, so nothing here is fitted to it. What the value has to buy is that the
    /// mark reads as *repeating* rather than as a one-off transition -- a single sweep occupying
    /// the whole wait would be indistinguishable from an entrance animation, and an entrance
    /// animation says "something just happened", not "something is still happening". Tune by use.
    public static let travelPeriod: TimeInterval = 1

    /// The mark's length, as a fraction of the row it travels across.
    ///
    /// **Arbitrary, and halved when the pair became one.** At 0.45 it was 45 % of a *half*, drawn
    /// twice; keeping the digit while the row doubled would have put a single 153 pt slab across
    /// the card's 340 pt, which is a bar sliding about rather than a mark passing. 0.3 restores
    /// roughly the ink the pair carried, and buys a longer beat of empty surface between one pass
    /// and the next -- `markOverhang` needs only to clear half of this, so the wrap gets more
    /// margin rather than less. Louis's to move.
    public static let markWidth: Double = 0.3

    /// How far past each end the mark's centre travels, as a fraction of the same width.
    ///
    /// Not decoration: it is what makes the wrap invisible. The mark is teleported from the far
    /// end back to the near one at the end of every cycle, and the only thing that keeps that from
    /// being seen is that it is entirely outside the drawn area at both instants -- which needs
    /// the overhang to be at least half the mark's own length. The margin above that half is what
    /// gives a beat of empty surface between one sweep and the next, so the two read as separate
    /// passes rather than as a loop with a seam.
    public static let markOverhang: Double = 0.35

    /// Where the mark's centre sits at this instant, as a fraction of the row's width measured
    /// **from the leading edge**: 0 is the left edge, 1 the right one.
    ///
    /// **It used to be measured outward from the centre**, one number driving two mirrored halves,
    /// and the alternative now implemented was rejected in as many words: "the cutout is 185 pt
    /// against a 32 pt wing, so a mark crossing at constant speed would spend six wing-widths of
    /// every cycle invisible behind it". That was true of wings either side of a hardware cutout.
    /// The card absorbed the cutout and the panel never had one, so a single pass now crosses
    /// continuous surface for its whole length, and `isMirrored` explains why it must.
    ///
    /// The arithmetic did not change with the name -- the same 0…1 ramp with the same overhang at
    /// both ends -- so every property already pinned about it still holds. What changed is which
    /// edge 0 means.
    ///
    /// Negative values are the mark short of the leading edge, values past 1 are it beyond the
    /// trailing one; a surface draws neither, and does not need to know that.
    public static func markDistanceAlong(elapsed: TimeInterval) -> Double {
        -markOverhang + cyclicProgress(elapsed: elapsed, period: travelPeriod) * (1 + 2 * markOverhang)
    }

    /// How much of the row the decoded fraction fills, or **nil for no bar at all**.
    ///
    /// **The whole design of the transcription drawing is in this optional**, because the number
    /// behind it is honest for only about half of Louis's dictations and there is no way to know
    /// in advance which half a given one is. WhisperKit decodes in 30 s windows and advances its
    /// progress once per window, so audio that fits in a single window measures NOTHING: 0 updates
    /// over the 0.43-0.60 s it takes. Across 1 469 real dictations the median is 29.7 s and 49.6 %
    /// exceed 30 s, so both regimes are the common case, not one plus an edge.
    ///
    /// A determinate bar sitting at zero for the whole wait is worse than no bar: it says the work
    /// has not started, when in fact it is nearly done. So the drawing does not commit up front and
    /// does not guess from audio length -- it asks what has actually been observed. `steps` is that
    /// question, and it is why `DecodeProgress.finish()` deliberately does not count as one: a
    /// short dictation reaches `fraction == 1` on success and must still draw no bar, or every
    /// short dictation would end with a bar flashing from empty to full in a single frame.
    ///
    /// **There is no switch between the two regimes, which is what keeps the boundary from being a
    /// glitch.** The sweep runs identically either way, from the first frame to the last; the fill
    /// is an addition underneath it, not a replacement for it. A short dictation is simply the case
    /// where the addition never happens, and it draws exactly what it drew before this existed. A
    /// long one grows a bar beneath a mark that never stopped moving -- and it appears at the
    /// fraction actually reached, a third of the way along for a 90 s dictation, so it reads as
    /// having been under way rather than as starting over.
    ///
    /// Returning nil rather than 0 is what makes those two states different at the type level, and
    /// they can never be confused: `observe` only counts a STRICT advance, so `steps >= 1` implies
    /// `fraction > 0` and a bar is never drawn empty.
    ///
    /// The mark is asked for as well as the progress so that no other phase can show a stale bar:
    /// the fraction outlives the transcription -- it is still 1 while `completed` is on screen --
    /// and only `travelling` has any business drawing it.
    public static func progressFill(for mark: Mark, progress: DecodeProgress?) -> Double? {
        guard mark == .travelling, let progress, progress.steps > 0 else { return nil }
        return progress.fraction
    }

    /// The stretch of the row the sweep is allowed to run in, as fractions of the row.
    ///
    /// **The fix to the complaint the additive drawing earned.** The fill and the sweep shared the
    /// whole row: the mark crossed the filled part, carried on past it and ran out the far end,
    /// brighter than the bar and the only thing moving. Louis: *"l'animation qu'on voit beaucoup
    /// mieux passe par-dessus, donc on a un peu du mal à voir comment ça se fait."* Two things in
    /// one row, and the louder one won.
    ///
    /// So they stop sharing it. The fill owns `[0, f]` and the sweep is confined to `[f, 1]` --
    /// the part that has NOT been decoded yet, which is the only part where anything is still
    /// happening. They never overlap a pixel, so neither can drown the other, and the boundary
    /// between them is a single edge the eye can follow.
    ///
    /// **The confinement is itself a second reading of the same number**, which is what makes this
    /// one object rather than two placed apart: as the fraction rises the sweep's runway shrinks
    /// and its mark shortens with it, so a nearly-finished transcription is a long bright bar with
    /// a small quick thing working at its end. Nothing needs to be read off; the geometry says it.
    ///
    /// **It degrades exactly, not approximately.** With no fraction the runway is the whole row and
    /// the mark is `markWidth` of it, which is the drawing to the point of the pixel that a short
    /// dictation has always shown. Half of Louis's dictations never leave that case.
    ///
    /// Rejected, in order of how close they came:
    ///
    /// - **The sweep inside the FILLED part.** The mirror of this, and it fails the short case: with
    ///   no fraction there is no filled part, so there would be nowhere to sweep and the common
    ///   dictation would draw nothing at all. Its motion would also grow as the work finished,
    ///   which is the wrong way round.
    /// - **Dropping the sweep entirely once a fraction exists**, leaving a pulsing leading edge. It
    ///   reads well, but it makes the first measurement a change of drawing rather than an addition
    ///   to one -- and the additive structure is the thing that keeps the boundary between the two
    ///   regimes from being a glitch.
    /// - **Just making the fill brighter.** It was the previous answer's mistake in a louder voice:
    ///   two things still overlapping in one row, one of them still the only one moving.
    public static func sweepRunway(fill: Double?) -> (start: Double, width: Double) {
        guard let fill else { return (0, 1) }
        let done = min(max(fill, 0), 1)
        return (done, 1 - done)
    }

    /// Whether there is still room to draw the sweep at all, given the runway and how thick the
    /// surface draws its marks.
    ///
    /// **The mark, not the runway, is what has to fit.** A capsule narrower than it is tall is not
    /// a short mark, it is a dot -- and a dot parked against the end of the bar reads as a defect
    /// rather than as the last of the work. Since the mark is `markWidth` of the runway, the runway
    /// can still look roomy while the mark inside it has already collapsed: measured on the
    /// shipped surfaces at 94 % decoded, the card's mark is 6.1 pt and the panel's is 1.2 pt in a
    /// 3.8 pt runway. Guarding the runway would have let the panel draw that dot.
    ///
    /// It is here rather than in either view because it is the panel that hits it first, and a
    /// rule that fires on one surface and not the other has to be one rule.
    public static func drawsSweep(runwayWidth: Double, markThickness: Double) -> Bool {
        runwayWidth * markWidth >= markThickness
    }

    /// How loud the sweep is, against `fillEmphasis`, 0…1 of whatever ink the surface draws with.
    ///
    /// **The emphasis inverts the moment there is a number.** Alone, the sweep is the whole message
    /// -- *something is still happening* -- and it is drawn at full strength. Beside a fill it is
    /// answering a question the fill has already answered better, so it steps back and lets the bar
    /// carry the row. It does not step back to nothing: between two measurements the bar is still,
    /// and a still bar with nothing moving anywhere is indistinguishable from a stalled one.
    ///
    /// **Arbitrary in its digits**, ordered on purpose, and the order is what the tests pin: full
    /// when alone, below the fill when beside it, never zero.
    public static func sweepEmphasis(hasFill: Bool) -> Double {
        hasFill ? sweepEmphasisBesideFill : sweepEmphasisAlone
    }

    /// The sweep alone, with no fraction to defer to. Full strength: it is the entire message.
    public static let sweepEmphasisAlone: Double = 1

    /// The sweep beside a fill. Quiet enough to be background, bright enough to be seen moving.
    public static let sweepEmphasisBesideFill: Double = 0.45

    /// The decoded bar. The loud element whenever it exists, because it is the answer.
    public static let fillEmphasis: Double = 1

    /// How long the fill takes to travel from one measurement to the next.
    ///
    /// **Arbitrary in its digit, bounded by a measured one.** The bar advances in visible jumps --
    /// a 90 s dictation is 3 windows, so a third of the row at a time -- and landing that instantly
    /// reads as a teleport rather than as progress. Animating it says the same true thing with the
    /// motion the eye expects.
    ///
    /// The ceiling is not taste: consecutive updates arrive 0.66-1.5 s apart (measured, the 478.9 s
    /// recording), so a settle longer than the shortest gap would still be moving when the next
    /// measurement lands and the bar would lag the truth by a growing amount. 0.3 s leaves better
    /// than a factor of two.
    public static let progressSettle: TimeInterval = 0.3

    // MARK: - refining: a breath, not a journey

    /// How long one breath takes.
    ///
    /// **Arbitrary in its digits, deliberate in its ratio.** `refining` is the phase that has to
    /// be told apart from `transcribing` at a glance -- 19 s of median wait and 57.5 s at the
    /// worst (lot 2 measurements, plan §1) against a transcription of seconds -- and half of that
    /// distinction is tempo. A pulse only slightly slower than the sweep would read as the same
    /// motion running a little differently, i.e. as nothing at all, so the period is kept at
    /// **at least twice** `travelPeriod` and a test refuses the two ever drifting together.
    public static let pulsePeriod: TimeInterval = 2.6

    /// The breath, 0…1, at this instant.
    ///
    /// A raised cosine rather than a triangle or a sawtooth, for two properties the eye reads
    /// directly. It is continuous **and flat** at both ends of the cycle, so the brightest and
    /// dimmest moments are dwelt on rather than crossed at speed -- which is what makes it a
    /// breath and not a blink; and it starts at its minimum, so the accent fades up out of the
    /// white mark that preceded it instead of arriving at full strength on the first frame.
    public static func pulse(elapsed: TimeInterval) -> Double {
        (1 - cos(2 * .pi * cyclicProgress(elapsed: elapsed, period: pulsePeriod))) / 2
    }

    // MARK: - The one accent

    /// The single accent hue, 0…1 the way SwiftUI counts them: **292°**, a violet-magenta.
    ///
    /// Used by `refining` and by nothing else in the interface (lot 3 D11). Green stays a system
    /// semantic for the completion and orange one for a failure, so the accent has to sit clear of
    /// both, and anti-goal §8 puts the rest of the circle off limits: "no sampled brand colours",
    /// which rules out the `#3C7FF5` blue and the `#7675E4` indigo design notes §2 measured off
    /// the installed app (hues 218° and 240°). 292° is more than 50° from either and more than 90°
    /// from the green and the orange, which is the whole of the constraint; where it lands inside
    /// what is left is a taste, and a taste that is **Louis's to overrule** -- the plan's Q-NB2
    /// leaves this open and this is a placeholder answering it, not a decision taken from him.
    public static let accentHue: Double = 292.0 / 360

    /// Restrained rather than saturated: the accent is drawn as a 4 pt bar on pure black, and a
    /// fully saturated violet at that size reads as a fringe of colour rather than as a shape.
    public static let accentSaturation: Double = 0.55

    /// Full. The notch is black and nothing is ever drawn behind this, so brightness is the only
    /// axis carrying legibility, and the pulse already spends half its cycle giving it away.
    public static let accentBrightness: Double = 1

    /// How dim the pulse gets at the bottom of its breath, as a fraction of full.
    ///
    /// Not zero. A mark that vanished entirely would leave an empty surface every 1.3 s, and an
    /// empty surface is what `hidden` looks like -- during the longest wait in the app, the one
    /// moment Louis is actually asking whether it is still alive.
    public static let pulseFloor: Double = 0.3

    /// A phase's progress through a repeating cycle, 0…1.
    ///
    /// Clamped at 0 below, which covers the two ways a caller can arrive with a negative elapsed:
    /// a clock correction mid-dictation, and the first frame after a phase change, where the view
    /// samples a display-link date that may lead the instant the phase was recorded. Without it a
    /// negative elapsed wraps to somewhere in the middle of a cycle, so a phase would open on
    /// whatever fraction of a breath the clock skew happened to name.
    private static func cyclicProgress(elapsed: TimeInterval, period: TimeInterval) -> Double {
        guard elapsed > 0 else { return 0 }
        return elapsed.truncatingRemainder(dividingBy: period) / period
    }
}
