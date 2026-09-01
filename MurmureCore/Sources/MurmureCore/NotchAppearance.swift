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
        /// A short mark travelling from the inner edge of each half towards its outer one.
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
    /// **The waveform is one; everything else is two.** Every phase used to be a mirrored pair,
    /// inherited from the wings: two drawings on either side of the hardware cutout, each running
    /// outward from it. Once a surface draws them side by side with no cutout between them, that
    /// structure stops being a design and becomes a seam -- and for the waveform it is worse than
    /// a seam. Louis, having watched it on both surfaces:
    ///
    ///     "Ça part du centre et c'est symétrique, ce qui rajoute cet effet d'onde comme dans
    ///      l'eau. J'aimerais vraiment avoir une barre unique, parce que là je vois que c'est deux
    ///      choses différentes qui sont symétriques."
    ///
    /// The rule the two cases divide on: **`waveform` is the only mark that is data over time.**
    /// Each half drew the whole history, mirrored, so the newest level landed against the join on
    /// both sides -- one instant drawn twice, side by side -- and a peak appeared in the middle and
    /// travelled outward in both directions at once, which is what a ripple in water is. Mirroring
    /// DATA duplicates it. Mirroring an ORNAMENT -- the travelling mark of a transcription leaving
    /// the centre in both directions, the dim mark of a silence, the fill of a completion -- is
    /// symmetry, and those keep their pair.
    ///
    /// It is here, on the mark rather than on either surface, because it is not a property of a
    /// notch or a panel: it is a property of what is being drawn, and both surfaces have to reach
    /// the same answer or the same dictation reads as two different things on two displays.
    public static func isMirrored(_ mark: Mark) -> Bool {
        mark != .waveform
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

    /// The mark's length, as a fraction of the width of the half it travels across.
    public static let markWidth: Double = 0.45

    /// How far past each end the mark's centre travels, as a fraction of the same width.
    ///
    /// Not decoration: it is what makes the wrap invisible. The mark is teleported from the far
    /// end back to the near one at the end of every cycle, and the only thing that keeps that from
    /// being seen is that it is entirely outside the drawn area at both instants -- which needs
    /// the overhang to be at least half the mark's own length. The margin above that half is what
    /// gives a beat of empty surface between one sweep and the next, so the two read as separate
    /// passes rather than as a loop with a seam.
    public static let markOverhang: Double = 0.35

    /// Where the mark's centre sits at this instant, as a fraction of one half's width measured
    /// **from its inner edge outwards**: 0 is the inner edge, 1 the outer one.
    ///
    /// One number for both halves, which is what makes them each other's reflection: the mark
    /// leaves the middle on both sides at once and runs outwards, the way lot 3 T3's waveform is
    /// already mirrored. In the notch the middle is the hardware cutout, and that is also why the
    /// obvious alternative -- one mark travelling left to right across both wings -- was rejected:
    /// the cutout is 185 pt against a 32 pt wing (`NotchController`, `NotchView.swift:32-34` at
    /// tag 1.1.0), so a mark crossing at constant speed would spend six wing-widths of every cycle
    /// invisible behind it, and the notch would look stopped for most of a transcription.
    ///
    /// Negative values are the mark short of the inner edge, values past 1 are it beyond the outer
    /// one; a surface draws neither, and does not need to know that.
    public static func markDistanceOutward(elapsed: TimeInterval) -> Double {
        -markOverhang + cyclicProgress(elapsed: elapsed, period: travelPeriod) * (1 + 2 * markOverhang)
    }

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
