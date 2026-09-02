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

    /// The card's outer width, in points, including the black the library adds around the content.
    ///
    /// **Arbitrary, and recorded as arbitrary.** What it has to buy is stated: the cutout is
    /// 185 pt on this Mac and the design before it added 32 pt of wing on each side, which Louis
    /// read as nothing at all. 400 pt is a little over twice the cutout, so the card reads as a
    /// shape with the hole inside it rather than as the hole with fringes -- and it still leaves
    /// the menu bar's own items, which live at the two ends of the screen, uncovered on a 1512 pt
    /// display. Louis's to move.
    ///
    /// It is here rather than in `NotchController` so that the two things that must agree about it
    /// can be checked together: the widest waveform the card asks for, and the number of levels
    /// `LevelHistory` keeps for it to draw.
    public static let width: Double = 400

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

    /// How much of the content width the refinement's half claims.
    ///
    /// **Arbitrary in its digits, deliberate in what it prevents.** Past five seconds the
    /// refinement stops being symmetric: `DictationPhaseView` replaces the mirrored half's
    /// breathing bar with the elapsed counter (lot 3 D15). At a full half each, the bar would end
    /// at the card's centre and the number would sit a whole half-width away from it, so the card
    /// would read as two unrelated objects at opposite ends rather than as one status. Roughly a
    /// quarter of the card keeps the pair together around the middle. Tune by use.
    public static let refiningHalfFraction: Double = 0.28

    /// How much of the content width the silence's half claims.
    ///
    /// **A tenth: the smallest the drawing ever gets, and that is the point.** `nothingHeard` is
    /// drawn as a short dim mark *centred in each half*, so the two can never meet however wide
    /// the halves are -- at a full half they would be two dashes a third of the card apart, with
    /// nothing in the middle to explain the gap (on the old wings there was a hardware cutout
    /// there; on the card there is not). Shrunk to a tenth they become one small still object in
    /// the middle of a card that is otherwise empty, which is what the phase means.
    public static let silentHalfFraction: Double = 0.10

    /// How many pieces the drawing is laid out from.
    ///
    /// Whether a phase is mirrored is `NotchAppearance.isMirrored(for:)`, on the mark rather than
    /// on this card, because the floating panel has to reach the same answer: a dictation that
    /// drew one waveform on the built-in display and two mirrored halves on an external one would
    /// be two different interfaces. What is card-specific is only how wide the pieces then are.
    public static func drawingPieces(for phase: NotchPhase) -> Int {
        NotchAppearance.isMirrored(for: phase) ? 2 : 1
    }

    /// The width of ONE piece of the drawing -- the whole row when the phase draws a single one,
    /// one of the two mirrored halves otherwise.
    ///
    /// Two answers, and the second one is **derived from `drawingPieces(for:)` rather than listed
    /// beside it**:
    ///
    /// - **The silence and the refinement take a fraction each**, for the two reasons their own
    ///   constants give.
    /// - **Everything else divides the row by however many pieces it is drawn from.** A phase that
    ///   draws one takes the whole row; a mirrored pair takes half each. The fill of a completion
    ///   and the bar of a failure are therefore still the same width as each other, which is what
    ///   lets the crossfade between them change what is drawn without changing where it is.
    ///
    /// **It used to enumerate the phases, and that let the two functions disagree.** `.recording`
    /// was written here as the whole row while every other phase was written as a half; when the
    /// transcription became a single row too, `drawingPieces` said one and this still said half,
    /// so the card would have drawn one sweep across the left half and left the right half empty.
    /// A test caught it, and the fix is to make the disagreement unrepresentable rather than to add
    /// a third phase to the list.
    ///
    /// Together with `drawingPieces(for:)` this never exceeds the content width.
    public static func drawingPieceWidth(for phase: NotchPhase, contentWidth: Double) -> Double {
        let content = max(0, contentWidth)
        switch phase {
        // Both phases drawn as the quiet mark, and the pair is listed rather than left to the
        // `default` below: a cancellation falling through would be drawn at a full half, i.e. two
        // dim marks a third of the card apart with nothing between them -- the exact failure
        // `silentHalfFraction` was measured to prevent, re-introduced by a phase that merely
        // forgot to be named.
        case .nothingHeard, .cancelled:
            return content * silentHalfFraction
        case .refining:
            return content * refiningHalfFraction
        default:
            return content / Double(drawingPieces(for: phase))
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
        // The preparation is white for the reason every working phase is: the card is saying what
        // it is doing, not how it went. It is emphatically NOT a warning -- nothing is wrong with a
        // first run that downloads a model, and orange would turn the ordinary cost of installing
        // Murmure into an incident.
        case .hidden, .recording, .preparingModel, .transcribing, .inserting: .neutral
        case .refining: .accent
        case .completed: .success
        // The cancellation shares the silence's tint because it makes the silence's statement
        // about the target application: nothing got there, and an absence has to be legible AS an
        // absence. What separates them is the glyph and the sentence, never the colour -- and it
        // is deliberately not `.warning`, which would read as something having gone wrong.
        case .nothingHeard, .cancelled: .muted
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
        // The two preparation steps take DIFFERENT glyphs, where `transcribing` and `inserting`
        // share one -- and the asymmetry is the argument, not an inconsistency. Those two share a
        // glyph because sharing makes a two-frame transition invisible. These two are minutes
        // apart: an arrow means bytes are arriving over a network, a processor means they are
        // being compiled for this machine, and telling them apart is what tells "my Wi-Fi died"
        // from "wait, it is nearly there".
        case .preparingModel(let step): symbolName(for: step)
        case .transcribing, .inserting: "waveform"
        case .refining: "sparkles"
        case .completed: "checkmark.circle.fill"
        case .nothingHeard: "mic.slash.fill"
        // **Where the cancellation stops being a silence.** The two share a tint and a mark, so
        // the glyph is the whole of the difference -- and the card is read glyph first. The cross
        // is the completion's checkmark inverted, in the same family and at the same weight,
        // because that is the pair it is actually opposed to: a dictation that landed, and one
        // Louis stopped. A second `mic.slash` would say the microphone failed him.
        case .cancelled: "xmark.circle.fill"
        case .failed, .alert: "exclamationmark.triangle.fill"
        }
    }

    /// The glyph for one step of the model's preparation. Split out so the case above stays one
    /// line, and written without a `default` for the same reason every switch here is.
    private static func symbolName(for step: ModelPreparation) -> String {
        switch step {
        case .downloading: "arrow.down.circle"
        case .loading: "cpu"
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
