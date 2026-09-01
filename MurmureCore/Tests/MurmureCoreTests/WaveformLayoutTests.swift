import XCTest
@testable import MurmureCore

/// The two frames the waveform is actually drawn in, so the assertions below are about the
/// interface Louis looks at rather than about round numbers chosen to make arithmetic tidy.
///
/// The panel's half is `StatusPanelLayout.drawingWidth / 2`; the card's is what
/// `NotchCard.drawingHalfWidth` gives a recording on the shipped card. Both are read from the
/// production constants, so a change to either surface's size runs through these tests.
private let panelHalf = Double(StatusPanelLayout.drawingWidth) / 2
private let cardContentWidth = NotchCard.contentWidth(forCardWidth: NotchCard.width, notchWidth: 185)
private let cardHalf = NotchCard.drawingHalfWidth(for: .recording, contentWidth: cardContentWidth)

final class WaveformLayoutTests: XCTestCase {
    // MARK: - How many bars a frame draws

    /// **The regression this whole change exists to prevent.** The count used to be a constant, so
    /// the card drew the panel's six bars in a frame five times wider and Louis saw a clump in the
    /// middle: "je trouve ça très resserré vers le centre, ça ne prend pas tout l'espace".
    func testAWiderFrameDrawsMoreBars() {
        XCTAssertGreaterThan(
            WaveformLayout.barCount(inWidth: cardHalf),
            WaveformLayout.barCount(inWidth: panelHalf))
    }

    /// The floating panel is a surface Louis has already approved, and it must come through this
    /// change untouched: 32 pt has always drawn six bars and still does.
    func testThePanelStillDrawsItsSixBars() {
        XCTAssertEqual(WaveformLayout.barCount(inWidth: panelHalf), 6)
    }

    /// The count is capped, and the cap is what makes a wide surface airier instead of merely
    /// busier: without it the card would take every bar that fits at the minimum pitch and become
    /// a dense comb.
    func testTheCountIsCappedSoAWideSurfaceGetsAirAndNotMoreBars() {
        let fittingUncapped = Int(
            (cardHalf + WaveformLayout.minimumBarSpacing)
                / (WaveformLayout.barWidth + WaveformLayout.minimumBarSpacing))
        XCTAssertGreaterThan(fittingUncapped, WaveformLayout.maximumBars)
        XCTAssertEqual(WaveformLayout.barCount(inWidth: cardHalf), WaveformLayout.maximumBars)
    }

    /// A frame narrower than one bar is not a frame with no waveform in it, it is a blank surface.
    func testEvenAnImpossiblyNarrowFrameDrawsABar() {
        XCTAssertEqual(WaveformLayout.barCount(inWidth: 0), 1)
        XCTAssertEqual(WaveformLayout.barCount(inWidth: -50), 1)
    }

    /// The bars and the gaps between them have to fit: `n` bars need `n - 1` gaps, and one more
    /// bar than fits would push the row past its own frame.
    func testTheBarsItCountsActuallyFitAtTheMinimumPitch() {
        for width in stride(from: 6.0, through: 200.0, by: 0.5) {
            let count = WaveformLayout.barCount(inWidth: width)
            let occupied = Double(count) * WaveformLayout.barWidth
                + Double(count - 1) * WaveformLayout.minimumBarSpacing
            XCTAssertLessThanOrEqual(
                occupied, width + 0.0001, "\(count) bars do not fit in \(width) pt")
        }
    }

    // MARK: - How far apart they sit

    /// **The line that removes the clump.** The leftover width goes into the gaps, so the row is
    /// as wide as the frame it was given instead of being a fixed-width block centred in it.
    func testTheRowFillsWhateverFrameItIsGiven() {
        for width in [panelHalf, cardHalf, 48.0, 96.0, 120.0] {
            let count = WaveformLayout.barCount(inWidth: width)
            let spacing = WaveformLayout.barSpacing(inWidth: width, barCount: count)
            let drawn = Double(count) * WaveformLayout.barWidth + Double(count - 1) * spacing
            XCTAssertEqual(drawn, width, accuracy: 0.0001, "a \(width) pt frame drew \(drawn) pt")
        }
    }

    /// Above the cap the gaps keep opening, which is the other half of Louis's request -- "un peu
    /// plus aéré", not merely wider.
    func testTheCardsBarsSitFurtherApartThanThePanels() {
        let card = WaveformLayout.barSpacing(
            inWidth: cardHalf, barCount: WaveformLayout.barCount(inWidth: cardHalf))
        let panel = WaveformLayout.barSpacing(
            inWidth: panelHalf, barCount: WaveformLayout.barCount(inWidth: panelHalf))
        XCTAssertGreaterThan(card, panel)
    }

    /// Never below the floor. Bars drawn closer than their own gap would eventually overlap, and
    /// overlapping bars read as one thick bar -- which is exactly the artefact at the centre of
    /// the card that `NotchCard.waveformCentreGap` also exists to remove.
    func testTheGapNeverFallsBelowItsFloor() {
        for width in stride(from: 1.0, through: 200.0, by: 0.5) {
            let count = WaveformLayout.barCount(inWidth: width)
            XCTAssertGreaterThanOrEqual(
                WaveformLayout.barSpacing(inWidth: width, barCount: count),
                count > 1 ? WaveformLayout.minimumBarSpacing : 0,
                "at \(width) pt")
        }
        // And when a caller asks for more bars than the frame can hold -- `DictationPhaseView`
        // passes the number of levels it actually got, which a short history could make larger
        // than the fit -- the row overflows at the floor instead of computing a negative gap and
        // stacking the bars on top of each other.
        XCTAssertEqual(
            WaveformLayout.barSpacing(inWidth: 32, barCount: 20),
            WaveformLayout.minimumBarSpacing)
    }

    /// One bar has nothing to be spaced from.
    func testASingleBarHasNoSpacing() {
        XCTAssertEqual(WaveformLayout.barSpacing(inWidth: 100, barCount: 1), 0)
        XCTAssertEqual(WaveformLayout.barSpacing(inWidth: 100, barCount: 0), 0)
    }

    // MARK: - How much time is on screen

    /// The cap is a duration, not a number of bars: it is how far back the waveform reaches, and
    /// truncating rather than rounding is what keeps it a ceiling.
    func testTheCapIsTheWindowAndNeverOverstepsIt() {
        XCTAssertLessThanOrEqual(
            Double(WaveformLayout.maximumBars) * WaveformLayout.blockDuration,
            WaveformLayout.window)
        XCTAssertGreaterThan(
            Double(WaveformLayout.maximumBars + 1) * WaveformLayout.blockDuration,
            WaveformLayout.window)
    }

    /// The window has to be long enough to hold the shape of a spoken clause. Below about half a
    /// second the waveform is a level meter with steps, which is what the six-bar wing was.
    func testTheWindowIsLongEnoughToShowAClauseRatherThanALevel() {
        XCTAssertGreaterThanOrEqual(WaveformLayout.window, 0.5)
    }

    /// The card genuinely shows further back than the panel, and both draw the same bars at the
    /// same cadence -- the surfaces differ in how wide a window they open, never in scale.
    func testTheCardIsAWiderWindowOntoTheSameSignal() {
        XCTAssertGreaterThan(
            Double(WaveformLayout.barCount(inWidth: cardHalf)) * WaveformLayout.blockDuration,
            Double(WaveformLayout.barCount(inWidth: panelHalf)) * WaveformLayout.blockDuration)
    }

    // MARK: - The history behind it

    /// **The coupling that would fail silently.** `LevelHistory` holds one level per slot and a
    /// surface draws the newest slice it can show; if the card asked for more bars than the ring
    /// keeps, it would draw a short row and no test of either type on its own would notice.
    func testTheHistoryHoldsEveryBarTheWidestSurfaceDraws() {
        XCTAssertGreaterThanOrEqual(
            LevelHistory.defaultCapacity, WaveformLayout.barCount(inWidth: cardHalf))
        XCTAssertGreaterThanOrEqual(
            LevelHistory.defaultCapacity, WaveformLayout.barCount(inWidth: panelHalf))
    }

    /// And it holds no more than that: a ring longer than the widest surface can draw is history
    /// nothing will ever show, allocated on every frame of every recording.
    func testTheHistoryHoldsNoMoreThanThat() {
        XCTAssertEqual(LevelHistory.defaultCapacity, WaveformLayout.maximumBars)
    }
}
