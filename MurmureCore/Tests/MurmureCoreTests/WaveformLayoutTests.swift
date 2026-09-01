import XCTest
@testable import MurmureCore

/// The two frames the waveform is actually drawn in, so the assertions below are about the
/// interface Louis looks at rather than about round numbers chosen to make arithmetic tidy.
///
/// Both are whole rows: since a recording is no longer mirrored, each surface draws its waveform
/// across its entire drawing area. Both are read from the production constants, so a change to
/// either surface's size runs through these tests.
private let panelRow = Double(StatusPanelLayout.drawingWidth)
private let cardContentWidth = NotchCard.contentWidth(forCardWidth: NotchCard.width, notchWidth: 185)
private let cardRow = NotchCard.drawingPieceWidth(for: .recording, contentWidth: cardContentWidth)

final class WaveformLayoutTests: XCTestCase {
    // MARK: - How many bars a frame draws

    /// **The regression this whole change exists to prevent.** The count used to be a constant, so
    /// the card drew the panel's six bars in a frame five times wider and Louis saw a clump in the
    /// middle: "je trouve ça très resserré vers le centre, ça ne prend pas tout l'espace".
    func testAWiderFrameDrawsMoreBars() {
        XCTAssertGreaterThan(
            WaveformLayout.barCount(inWidth: cardRow),
            WaveformLayout.barCount(inWidth: panelRow))
    }

    /// The floating panel is a surface Louis has already approved, and its INK must come through
    /// unchanged: it drew twelve 3 pt bars across 64 pt when they were two mirrored sixes, and it
    /// draws twelve 3 pt bars across 64 pt now that they are one row. What changed there is that
    /// the twelve are twelve distinct levels rather than six drawn twice.
    func testThePanelDrawsTheSameTwelveThreePointBarsItAlwaysHas() {
        let count = WaveformLayout.barCount(inWidth: panelRow)
        XCTAssertEqual(count, 12)
        XCTAssertEqual(
            WaveformLayout.barWidth(inWidth: panelRow, barCount: count),
            WaveformLayout.minimumBarWidth,
            "the panel's bars must not have been widened under it")
    }

    /// The count is capped, and the cap is what makes a wide surface airier instead of merely
    /// busier: without it the card would take every bar that fits at the minimum pitch and become
    /// a dense comb.
    func testTheCountIsCappedSoAWideSurfaceGetsAirAndNotMoreBars() {
        let fittingUncapped = Int(
            (cardRow + WaveformLayout.minimumBarSpacing)
                / (WaveformLayout.minimumBarWidth + WaveformLayout.minimumBarSpacing))
        XCTAssertGreaterThan(fittingUncapped, WaveformLayout.maximumBars)
        XCTAssertEqual(WaveformLayout.barCount(inWidth: cardRow), WaveformLayout.maximumBars)
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
            let occupied = Double(count) * WaveformLayout.minimumBarWidth
                + Double(count - 1) * WaveformLayout.minimumBarSpacing
            XCTAssertLessThanOrEqual(
                occupied, width + 0.0001, "\(count) bars do not fit in \(width) pt")
        }
    }

    // MARK: - How far apart they sit

    /// **The line that removes the clump.** The leftover width goes into the gaps, so the row is
    /// as wide as the frame it was given instead of being a fixed-width block centred in it.
    func testTheRowFillsWhateverFrameItIsGiven() {
        for width in [panelRow, cardRow, 48.0, 96.0, 120.0] {
            let count = WaveformLayout.barCount(inWidth: width)
            let spacing = WaveformLayout.barSpacing(inWidth: width, barCount: count)
            let drawn = Double(count) * WaveformLayout.barWidth(inWidth: width, barCount: count)
                + Double(count - 1) * spacing
            XCTAssertEqual(drawn, width, accuracy: 0.0001, "a \(width) pt frame drew \(drawn) pt")
        }
    }

    /// Above the cap the gaps keep opening, which is the other half of Louis's request -- "un peu
    /// plus aéré", not merely wider.
    func testTheCardsBarsSitFurtherApartThanThePanels() {
        let card = WaveformLayout.barSpacing(
            inWidth: cardRow, barCount: WaveformLayout.barCount(inWidth: cardRow))
        let panel = WaveformLayout.barSpacing(
            inWidth: panelRow, barCount: WaveformLayout.barCount(inWidth: panelRow))
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

    /// **Both surfaces draw a recording as one waveform, and neither may drift.** The panel is a
    /// wider window than a single wing was and a narrower one than the card; what must hold is
    /// that they are the same signal at the same cadence, so the panel's window sits between.
    func testEachSurfaceIsAWiderWindowThanTheOneBelowIt() {
        XCTAssertGreaterThan(
            WaveformLayout.barCount(inWidth: cardRow), WaveformLayout.barCount(inWidth: panelRow))
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

    /// And long enough to hold the shape of a spoken clause. Below about half a second the
    /// waveform is a level meter with steps, which is what the six-bar wing was.
    func testTheWindowIsLongEnoughToShowAClauseRatherThanALevel() {
        XCTAssertGreaterThanOrEqual(WaveformLayout.window, 0.5)
    }

    /// **The number the window is really fitted to.** The cap is written as a duration, but which
    /// duration is decided by the pitch it produces across the card's own row -- so this is the
    /// assertion that holds, and `window` is free to move as long as it keeps holding.
    ///
    /// Below about 6 pt the bars close up into a comb on a row this wide; above about 10 pt they
    /// read as a row of separate sticks rather than as a waveform. Both bounds are taste, stated
    /// as taste; what is not taste is that four constants and the card's width have to agree for
    /// the result to land between them.
    func testTheCardsBarsKeepTheirShareOfTheRowRatherThanThinningOut() {
        let count = WaveformLayout.barCount(inWidth: cardRow)
        let bar = WaveformLayout.barWidth(inWidth: cardRow, barCount: count)
        let gap = WaveformLayout.barSpacing(inWidth: cardRow, barCount: count)
        XCTAssertGreaterThan(
            bar, WaveformLayout.minimumBarWidth * 1.5,
            "a card five times the panel's width drawing the panel's hairline is absurd")
        XCTAssertGreaterThan(
            gap, bar, "the row has to stay aéré: closing the gap below the bar makes a block")
    }

    /// **The floor that keeps the panel intact.** A bar is never thinner than it has always been;
    /// `inkFraction` may only widen it.
    func testABarIsNeverThinnerThanItHasAlwaysBeen() {
        for width in stride(from: 1.0, through: 400.0, by: 0.5) {
            let count = WaveformLayout.barCount(inWidth: width)
            XCTAssertGreaterThanOrEqual(
                WaveformLayout.barWidth(inWidth: width, barCount: count),
                WaveformLayout.minimumBarWidth, "at \(width) pt")
        }
    }

    /// **The floor under the window.** Below about twenty bars a scrolling row stops being a
    /// waveform and becomes a handful of blocks: the shape of a word is no longer in it. This is
    /// what stops the window being shortened indefinitely to chase dynamism.
    func testTheCardKeepsEnoughBarsToStillReadAsAWaveform() {
        XCTAssertGreaterThanOrEqual(WaveformLayout.barCount(inWidth: cardRow), 20)
    }

    /// **The dynamism Louis lost.** The whole picture turns over `1 / window` times a second, and
    /// two seconds -- the value he rejected as "des grandes ondes qui se propagent très longuement"
    /// -- turned it over once every two. Measured against the frame cost, which is 0.63 ms for the
    /// widest row Murmure draws and therefore not what he was seeing.
    func testThePictureTurnsOverAtLeastOncePerSecond() {
        XCTAssertLessThanOrEqual(WaveformLayout.window, 1)
    }

    /// The card genuinely shows further back than the panel, and both draw the same bars at the
    /// same cadence -- the surfaces differ in how wide a window they open, never in scale.
    func testTheCardIsAWiderWindowOntoTheSameSignal() {
        XCTAssertGreaterThan(
            Double(WaveformLayout.barCount(inWidth: cardRow)) * WaveformLayout.blockDuration,
            Double(WaveformLayout.barCount(inWidth: panelRow)) * WaveformLayout.blockDuration)
    }

    // MARK: - The history behind it

    /// **The coupling that would fail silently.** `LevelHistory` holds one level per slot and a
    /// surface draws the newest slice it can show; if the card asked for more bars than the ring
    /// keeps, it would draw a short row and no test of either type on its own would notice.
    func testTheHistoryHoldsEveryBarTheWidestSurfaceDraws() {
        XCTAssertGreaterThanOrEqual(
            LevelHistory.defaultCapacity, WaveformLayout.barCount(inWidth: cardRow))
        XCTAssertGreaterThanOrEqual(
            LevelHistory.defaultCapacity, WaveformLayout.barCount(inWidth: panelRow))
    }

    /// And it holds no more than that plus the read head's look-back: a ring longer still is
    /// history nothing will ever show, allocated on every frame of every recording.
    ///
    /// **This used to assert exact equality with `maximumBars`, and `WaveformScroll` is why it no
    /// longer can.** The head is parked a margin behind the newest level, and the oldest bar of a
    /// full row reads a whole row behind THAT; with the ring exactly as long as the row those bars
    /// fall off its end and clamp, which drew the left of the card as a small block that held still
    /// and jumped by two. The bound is still a bound -- the extra is a named constant, not slack --
    /// and the assertion below is what keeps the two from drifting apart.
    func testTheHistoryHoldsNoMoreThanTheRowPlusItsLookBack() {
        XCTAssertEqual(
            LevelHistory.defaultCapacity,
            WaveformLayout.maximumBars + WaveformLayout.scrollHeadroom)
    }

    /// The look-back has to be at least the margin, or the oldest bar of the widest row reads past
    /// the oldest level kept. This is the coupling that broke, pinned where both halves are.
    func testTheLookBackCoversTheMarginTheReadHeadKeeps() {
        for burst in 0...12 {
            XCTAssertLessThanOrEqual(
                WaveformScroll.margin(burst: burst), Double(WaveformLayout.scrollHeadroom),
                "a burst of \(burst) would push the oldest bar off the end of the ring")
        }
    }
}
