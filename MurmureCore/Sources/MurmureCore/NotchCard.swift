import Foundation

/// The card the cutout grows into, as decisions rather than as pixels.
///
/// Lot 3 T1–T4 drew a dictation as two wings 32 pt wide poking out of either side of the notch.
/// Louis's verdict on the built-in display was that the hardware hides nine tenths of it: "on a
/// l'impression que le notch cache 90 % de ce qu'on est censé voir". The answer is not wider
/// wings -- it is the Dynamic Island's: **one shape that contains the cutout**, grown out of it,
/// with the physical hole indistinguishable from the shape's own black.
///
/// What is here is everything about that card a test can hold: how a chosen outer width becomes
/// the width the content actually gets, how wide the dictation's drawing is in each phase, and
/// which of the interface's colours and glyphs a phase claims. What is deliberately NOT here is
/// every point size, gradient, blur radius and font of the card itself: those are `NotchController`
/// in the app target, which has no test bundle, and a test over them would only assert that a
/// literal is the literal it is.
///
/// The seam with `NotchAppearance` is the same one that type already draws with `NotchPresenter`:
/// `NotchAppearance` answers *what the dictation's own drawing is doing at this instant* and is
/// shared with the floating panel, this answers *how big the card is and what it puts around that
/// drawing*, and only the notch has a card.
public enum NotchCard {
    // MARK: - Turning a card width into the width its content gets

    /// The horizontal room DynamicNotchKit takes on each side of the expanded content, in points.
    ///
    /// **Read off the library, not chosen.** At tag 1.1.0 `NotchView.expandedContent()` puts a
    /// 15 pt `safeAreaInset` on the leading and trailing edges (`NotchView.swift:141-146`), and
    /// `NotchView.notchContent()` then adds `.padding(.horizontal, topCornerRadius)`, which in the
    /// expanded state is the style's top corner radius -- 15 pt for the `.auto`/`.notch` style
    /// (`NotchView.swift:22-27`, `88`). 15 + 15 = 30, twice, and the card is 60 pt wider than
    /// whatever view is handed to it.
    ///
    /// It is a constant here rather than a measurement at runtime because the library exposes
    /// neither number: both are `private var`s of an internal view. The package pin is
    /// `exactVersion: "1.1.0"` (`project.yml`) precisely so that reading a library's private
    /// layout is a fact with a version attached rather than a guess.
    public static let contentInsetPerSide: Double = 30

    /// The expanded style's top corner radius, i.e. the concave flare where the card meets the
    /// menu bar. Also the library's own horizontal padding (see above), which is why the floor
    /// below is `notchWidth + 2 × 15`.
    public static let expandedTopCornerRadius: Double = 15

    /// The width the card's content actually gets, for a card of this outer width on a display
    /// whose cutout is this wide.
    ///
    /// The `max` is not defensive, it is the library's floor: `NotchView.minWidth` is
    /// `notchSize.width + 2 × topCornerRadius` (`NotchView.swift:29-31`), so a card asked to be
    /// narrower than the cutout plus its flares is silently widened to it. A caller that ignored
    /// the floor would lay its content out at one width while the black was drawn at another, and
    /// the content would sit in a card with unequal margins -- on a shape whose whole claim is
    /// that it is symmetric about the cutout.
    ///
    /// Never negative: a card narrower than its own insets has no content area, and a negative
    /// frame width is a crash in AppKit rather than a small card.
    public static func contentWidth(forCardWidth cardWidth: Double, notchWidth: Double) -> Double {
        let floor = notchWidth + 2 * expandedTopCornerRadius
        return max(0, max(cardWidth, floor) - 2 * contentInsetPerSide)
    }

    // MARK: - How wide the dictation's drawing is

    /// The width a waveform of `barCount` bars occupies, at the bar geometry the drawing uses.
    ///
    /// `DictationPhaseView` lays its bars out in an `HStack` of **absolute** widths and spacings
    /// and then centres that stack in whatever frame it is given -- its line weights are points,
    /// by contract, and only lengths and positions scale. So a waveform handed a frame wider than
    /// this floats in the middle of it, and on the card, where the two halves are drawn edge to
    /// edge, two floating clusters would be separated by a gap the width of the card. The
    /// recording phase therefore asks for exactly this width and no more.
    ///
    /// The three inputs are passed rather than declared here because the app target owns them:
    /// duplicating `barWidth`/`barSpacing` in the package would be a second source of truth that
    /// goes stale silently, and the failure it produces -- a seam down the middle of the waveform
    /// -- is small enough to survive a review.
    ///
    /// `n` bars have `n - 1` gaps; zero bars occupy nothing.
    public static func waveformWidth(
        barCount: Int, barWidth: Double, barSpacing: Double
    ) -> Double {
        guard barCount > 0 else { return 0 }
        return Double(barCount) * barWidth + Double(barCount - 1) * barSpacing
    }

    /// How much of the content width the refinement's half claims.
    ///
    /// **Arbitrary in its digits, deliberate in what it prevents.** Past five seconds the
    /// refinement stops being symmetric: `DictationPhaseView` replaces the mirrored half's
    /// breathing bar with the elapsed counter (lot 3 D15). At a full half each, the bar would end
    /// at the card's centre and the number would sit a whole half-width away from it, so the card
    /// would read as two unrelated objects at opposite ends rather than as one status. Roughly a
    /// quarter of the card keeps the pair together around the middle. Tune by use.
    public static let refiningHalfFraction: Double = 0.28

    /// The width of ONE of the two mirrored halves of the dictation's drawing, in a card whose
    /// content area is `contentWidth` wide.
    ///
    /// Three answers, and the ordering between them is the decision:
    ///
    /// - **`recording` is the narrowest**, and its width is not a fraction of anything: it is the
    ///   waveform's own, so the two halves meet with no seam (see `waveformWidth`).
    /// - **`nothingHeard` is drawn at exactly that same width**, and this is the one answer here
    ///   that is about meaning rather than about fit. Its drawing is a short dim mark *centred in
    ///   each half*, so the two can never meet however wide the halves are -- at a full half they
    ///   would be two disconnected dashes a third of the card apart, with nothing in the middle to
    ///   explain the gap (on the wings there was a hardware cutout there; on the card there is
    ///   not). Shrunk to the waveform's own footprint they become one small still object sitting
    ///   exactly where the voice would have been, which is what the phase means.
    /// - **`refining` is in between**, so the breathing bar and the elapsed counter form one
    ///   centred pair (see `refiningHalfFraction`).
    /// - **Everything else takes half the card.** The sweep of a transcription, the fill of a
    ///   completion and the bar of a failure are all drawn at the same full width, which is what
    ///   lets the crossfade between them change what is drawn without changing where it is -- the
    ///   same argument `NotchAppearance.mark(for:)` makes for `transcribing` and `inserting`
    ///   sharing a family.
    ///
    /// Clamped to half the content width, so a waveform whose bar count outgrew the card spills
    /// over the card's own edge rather than out of the black shape.
    public static func drawingHalfWidth(
        for phase: NotchPhase, contentWidth: Double, waveformWidth: Double
    ) -> Double {
        let full = max(0, contentWidth) / 2
        switch phase {
        case .recording, .nothingHeard:
            return min(waveformWidth, full)
        case .refining:
            // Not clamped to `full`, unlike the waveform above, and the asymmetry is deliberate:
            // `refiningHalfFraction` is a constant in this file that a test holds below a half
            // (the refinement must stay tighter than a sweep), whereas `waveformWidth` is a
            // measurement passed in from the app and can outgrow any card. A clamp here would be
            // a line no test could ever reach.
            return max(0, contentWidth) * refiningHalfFraction
        case .hidden, .transcribing, .inserting, .completed, .failed, .alert:
            return full
        }
    }

    // MARK: - What colour a phase claims

    /// The card's colours, named by what they mean rather than by what they are.
    ///
    /// The card tints three things at once -- the glyph, the glow behind the drawing, and nothing
    /// else -- and they must never disagree, which is the whole reason this is one value and not
    /// three lookups. Which sRGB each one is stays in the view: `success` is the system green and
    /// `accent` is assembled from `NotchAppearance.accentHue`/`accentSaturation`/`accentBrightness`,
    /// and neither is a number this package should own twice.
    public enum Tint: Equatable, Sendable {
        /// White. The card is saying what it is doing, not how it went.
        case neutral
        /// The one accent (lot 3 D11), and `refining` is the only phase that may claim it.
        case accent
        /// Green, and only a completion that actually inserted something is green.
        case success
        /// Dimmed white. An absence has to be legible AS an absence.
        case muted
        /// Orange.
        case warning
    }

    /// The tint a phase claims.
    ///
    /// `transcribing` and `inserting` share one deliberately, for the reason
    /// `NotchAppearance.mark(for:)` gives at length: an insertion is one CGEvent round-trip, and a
    /// colour of its own would be a frame of something nobody can read arriving in the middle of a
    /// sequence whose one criterion is that it never jumps.
    ///
    /// Written without a `default`, so a phase added later fails to compile here rather than
    /// quietly inheriting white.
    public static func tint(for phase: NotchPhase) -> Tint {
        switch phase {
        case .hidden, .recording, .transcribing, .inserting: .neutral
        case .refining: .accent
        case .completed: .success
        case .nothingHeard: .muted
        case .failed, .alert: .warning
        }
    }

    /// The SF Symbol drawn beside the sentence.
    ///
    /// The glyph is the card's fastest signal -- it is read before the word is -- so the pairs
    /// that must never be confused have to differ here first: a completion, a silence and a
    /// failure carry three different symbols, and a test pins that.
    ///
    /// `transcribing` and `inserting` share one, and it is the same argument as the tint above:
    /// the drawing does not change across that hand-off, so the glyph must not either. The
    /// *sentence* does change, and that is the point -- the word updates inside a card that has
    /// not moved.
    ///
    /// `hidden` has no glyph because it has no card. The empty string is the answer to a question
    /// that is not asked, and a test pins it so a phase added later cannot silently acquire a
    /// blank square instead of a symbol -- the same shape of guarantee `StatusPanelText` makes for
    /// its own empty line.
    public static func symbolName(for phase: NotchPhase) -> String {
        switch phase {
        case .hidden: ""
        case .recording: "mic.fill"
        case .transcribing, .inserting: "waveform"
        case .refining: "sparkles"
        case .completed: "checkmark.circle.fill"
        case .nothingHeard: "mic.slash.fill"
        case .failed, .alert: "exclamationmark.triangle.fill"
        }
    }

    // MARK: - How long the card takes to change its mind

    /// How long the card takes to change what it is showing: the glyph, the sentence, the tint and
    /// the width of the drawing, all on one timing so they arrive as one event.
    ///
    /// **Arbitrary in its digits, constrained at both ends.** Below roughly a fifth of a second a
    /// crossfade reads as a cut, which is the flicker `NotchAppearance.mark(for:)` exists to
    /// avoid; above the shortest dwell a completion would still be arriving as its own retraction
    /// began, and Louis would never see the finished card at all. `NotchPresenter.completionDwell`
    /// is 0.9 s, and a test refuses the two ever crossing.
    ///
    /// It is deliberately NOT the shape's own timing. The card grows out of the cutout and
    /// retracts into it on DynamicNotchKit's `.bouncy(duration: 0.4)` and `.smooth(duration: 0.4)`
    /// (`DynamicNotchStyle.swift:74-84` at tag 1.1.0), which are the library's and are left alone:
    /// they are tuned to that shape, and this is the timing of the contents inside it.
    public static let phaseMorph: TimeInterval = 0.35
}
