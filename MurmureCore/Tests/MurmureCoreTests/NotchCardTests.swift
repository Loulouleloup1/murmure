import XCTest
@testable import MurmureCore

/// The cutout of a 14-inch MacBook Pro, and the card built on it. Both are the numbers
/// `NotchController` actually ships, so the assertions below are about the interface Louis sees
/// rather than about round numbers chosen to make arithmetic tidy.
private let notchWidth: Double = 185
private let contentWidth = NotchCard.contentWidth(
    forCardWidth: NotchCard.width, notchWidth: notchWidth)

/// Every phase, so a phase added later has to be added here too rather than being silently
/// untested by the properties that quantify over all of them.
private let everyPhase: [NotchPhase] = [
    .hidden, .recording, .transcribing, .refining, .inserting,
    .completed(insertedCharacters: 47), .nothingHeard,
    .failed(message: "paste refused", recoveredText: "bonjour"), .alert(message: "no hotkey"),
]

final class NotchCardTests: XCTestCase {
    // MARK: - Turning a card width into the width its content gets

    /// The library takes 30 pt on each side of the expanded content, so a 400 pt card draws its
    /// contents at 340. Getting this wrong does not fail loudly -- it lays the content out at one
    /// width while the black is drawn at another.
    func testTheCardIsSixtyPointsWiderThanItsContent() {
        XCTAssertEqual(NotchCard.contentWidth(forCardWidth: 400, notchWidth: 185), 340)
        XCTAssertEqual(NotchCard.contentWidth(forCardWidth: 260, notchWidth: 185), 200)
    }

    /// `NotchView.minWidth` silently widens any card narrower than the cutout plus its two flares,
    /// so a caller asking for less has to be told what it will really get.
    func testACardNarrowerThanTheCutoutIsWidenedToTheLibrarysFloor() {
        // 185 + 2 x 15 = 215 is the floor; 215 - 60 = 155 is what the content gets.
        XCTAssertEqual(NotchCard.contentWidth(forCardWidth: 120, notchWidth: 185), 155)
        XCTAssertEqual(NotchCard.contentWidth(forCardWidth: 215, notchWidth: 185), 155)
        // One point above the floor is one point of content.
        XCTAssertEqual(NotchCard.contentWidth(forCardWidth: 216, notchWidth: 185), 156)
    }

    /// A negative frame width is a crash in AppKit, not a small card.
    func testAContentWidthIsNeverNegative() {
        XCTAssertEqual(NotchCard.contentWidth(forCardWidth: 10, notchWidth: 0), 0)
    }

    // MARK: - How wide the dictation's drawing is

    /// **The recording now fills the card**, and this is the assertion that broke the clump: it
    /// used to be given the waveform's own fixed width, ~30 pt, so twelve bars sat marooned in the
    /// middle of a 340 pt row. The seam is the only width it gives up.
    func testTheRecordingFillsTheCardApartFromItsSeam() {
        let half = NotchCard.drawingHalfWidth(for: .recording, contentWidth: contentWidth)
        XCTAssertEqual(2 * half + NotchCard.waveformCentreGap, contentWidth, accuracy: 0.0001)
    }

    /// Only the recording has a seam. A sweep emerges from the middle, and a completion's green
    /// fill is one object spanning the card -- a notch cut out of either would read as damage.
    func testOnlyTheRecordingIsSplitDownTheMiddle() {
        XCTAssertEqual(NotchCard.centreGap(for: .recording), NotchCard.waveformCentreGap)
        for phase in everyPhase where !isRecording(phase) {
            XCTAssertEqual(NotchCard.centreGap(for: phase), 0, "\(phase) must not be split")
        }
    }

    /// **The seam has to be wider than the gaps inside the row, or it is not a seam.** Louis saw
    /// the two halves collide before anyone described it to him -- both put the newest level
    /// against the join, so one level was drawn twice with no gap between the copies.
    func testTheSeamIsWiderThanTheGapsBetweenTheBars() {
        let half = NotchCard.drawingHalfWidth(for: .recording, contentWidth: contentWidth)
        let spacing = WaveformLayout.barSpacing(
            inWidth: half, barCount: WaveformLayout.barCount(inWidth: half))
        XCTAssertGreaterThanOrEqual(NotchCard.waveformCentreGap, 1.5 * spacing)
    }

    /// The silence is the smallest the drawing ever gets. Its mark is centred in each half and so
    /// can never meet its mirror; at a full half the card would show two dashes a third of its
    /// width apart, with nothing between them to explain the gap.
    func testTheSilenceIsTheSmallestDrawingOnTheCard() {
        let silence = NotchCard.drawingHalfWidth(for: .nothingHeard, contentWidth: contentWidth)
        for phase in everyPhase where !isNothingHeard(phase) {
            XCTAssertLessThan(
                silence,
                NotchCard.drawingHalfWidth(for: phase, contentWidth: contentWidth),
                "the silence must be smaller than \(phase)")
        }
    }

    /// Everything that is not a recording, a silence or a refinement is drawn at the same full
    /// half, which is what lets a sweep become a completion without the drawing changing where it
    /// is.
    func testEverySteadyPhaseIsDrawnAtTheSameFullHalf() {
        let full = contentWidth / 2
        for phase in everyPhase
        where !isRecording(phase) && !isRefining(phase) && !isNothingHeard(phase) {
            XCTAssertEqual(
                NotchCard.drawingHalfWidth(for: phase, contentWidth: contentWidth),
                full,
                accuracy: 0.0001,
                "\(phase) must be drawn at the full half")
        }
    }

    /// The ordering is the decision: the silence is the smallest, the refinement sits between, and
    /// the recording spans the card like the rest. Collapsing any two of them loses either the
    /// silence's legibility or the counter's pairing.
    func testTheSilenceIsTighterThanTheRefinementWhichIsTighterThanTheRest() {
        let silence = NotchCard.drawingHalfWidth(for: .nothingHeard, contentWidth: contentWidth)
        let refining = NotchCard.drawingHalfWidth(for: .refining, contentWidth: contentWidth)
        let steady = NotchCard.drawingHalfWidth(
            for: .completed(insertedCharacters: 1), contentWidth: contentWidth)
        XCTAssertLessThan(silence, refining)
        XCTAssertLessThan(refining, steady)
    }

    /// Two halves plus the seam are the card, never more: a drawing wider than that would be drawn
    /// outside the black shape.
    func testTheTwoHalvesAndTheSeamNeverExceedTheCard() {
        for content in [contentWidth, 40.0, 12.0] {
            for phase in everyPhase {
                let half = NotchCard.drawingHalfWidth(for: phase, contentWidth: content)
                XCTAssertLessThanOrEqual(
                    2 * half + NotchCard.centreGap(for: phase), content + 0.0001,
                    "\(phase) spills out of a \(content) pt card")
                XCTAssertGreaterThanOrEqual(half, 0, "\(phase) has a negative width")
            }
        }
    }

    /// A card with no content area at all still hands out non-negative widths rather than
    /// crashing AppKit on the way past.
    func testAnEmptyCardHandsOutNothingRatherThanANegativeWidth() {
        for phase in everyPhase {
            XCTAssertEqual(
                NotchCard.drawingHalfWidth(for: phase, contentWidth: -10), 0,
                "\(phase) must be empty in an empty card")
        }
    }

    // MARK: - What colour a phase claims

    /// Lot 3 D11: the accent belongs to the refinement and to nothing else in the interface.
    func testTheAccentBelongsToTheRefinementAlone() {
        let accented = everyPhase.filter { NotchCard.tint(for: $0) == .accent }
        XCTAssertEqual(accented.count, 1)
        XCTAssertEqual(NotchCard.tint(for: .refining), .accent)
    }

    /// Green means text landed. A silence and a failure are the two phases that would be a lie in
    /// green, and the completion is the only phase that is one.
    func testOnlyACompletionIsGreen() {
        let green = everyPhase.filter { NotchCard.tint(for: $0) == .success }
        XCTAssertEqual(green.count, 1)
        XCTAssertEqual(NotchCard.tint(for: .completed(insertedCharacters: 47)), .success)
        XCTAssertNotEqual(NotchCard.tint(for: .nothingHeard), .success)
        XCTAssertNotEqual(
            NotchCard.tint(for: .failed(message: "boom", recoveredText: nil)), .success)
    }

    /// The three outcomes of a dictation have to be three different colours: "it worked",
    /// "nothing got through" and "something broke" are the answers Louis reads at a glance.
    func testTheThreeOutcomesAreThreeDifferentTints() {
        let outcomes: Set<NotchCard.Tint> = [
            NotchCard.tint(for: .completed(insertedCharacters: 47)),
            NotchCard.tint(for: .nothingHeard),
            NotchCard.tint(for: .failed(message: "boom", recoveredText: nil)),
        ]
        XCTAssertEqual(outcomes.count, 3)
    }

    /// The insertion must not repaint the card on its way past: it lasts one CGEvent round-trip.
    func testAnInsertionLooksExactlyLikeTheTranscriptionItFollows() {
        XCTAssertEqual(NotchCard.tint(for: .inserting), NotchCard.tint(for: .transcribing))
        XCTAssertEqual(
            NotchCard.symbolName(for: .inserting), NotchCard.symbolName(for: .transcribing))
    }

    /// A failure and an alert are both "something is wrong"; nothing is gained by colouring them
    /// apart, and the pair is pinned so a later edit cannot split them by accident.
    func testAFailureAndAnAlertAreTheSameColour() {
        XCTAssertEqual(
            NotchCard.tint(for: .failed(message: "boom", recoveredText: nil)),
            NotchCard.tint(for: .alert(message: "accessibility")))
    }

    // MARK: - The glyph

    /// The glyph is read before the word is, so the three outcomes must differ here too -- a
    /// silence wearing the completion's checkmark would be the worst lie the card can tell.
    func testTheThreeOutcomesCarryThreeDifferentGlyphs() {
        let glyphs: Set<String> = [
            NotchCard.symbolName(for: .completed(insertedCharacters: 47)),
            NotchCard.symbolName(for: .nothingHeard),
            NotchCard.symbolName(for: .failed(message: "boom", recoveredText: nil)),
        ]
        XCTAssertEqual(glyphs.count, 3)
    }

    /// A recording is not a transcription, and telling them apart is what the card is for.
    func testTheRunningPhasesCarryTheirOwnGlyphs() {
        let glyphs: Set<String> = [
            NotchCard.symbolName(for: .recording),
            NotchCard.symbolName(for: .transcribing),
            NotchCard.symbolName(for: .refining),
        ]
        XCTAssertEqual(glyphs.count, 3)
    }

    /// Every phase with a card has a glyph, and `hidden` -- which has no card -- has none.
    func testOnlyTheHiddenPhaseHasNoGlyph() {
        XCTAssertEqual(NotchCard.symbolName(for: .hidden), "")
        for phase in everyPhase where NotchAppearance.showsShape(in: phase) {
            XCTAssertFalse(
                NotchCard.symbolName(for: phase).isEmpty, "\(phase) must carry a glyph")
        }
    }

    // MARK: - How long the card takes to change its mind

    /// A completion that was still arriving as its retraction began would never be seen finished.
    /// The morph has to fit inside the shortest thing the card ever shows.
    func testTheCardFinishesChangingBeforeTheShortestDwellIsOver() {
        XCTAssertLessThan(NotchCard.phaseMorph, NotchPresenter.completionDwell)
        XCTAssertLessThan(NotchCard.phaseMorph, NotchPresenter.nothingHeardDwell)
        XCTAssertLessThan(NotchCard.phaseMorph, NotchPresenter.failureDwell)
    }

    /// Below roughly a fifth of a second a crossfade reads as a cut, which is the flicker the
    /// whole phase sequence is built to avoid.
    func testTheMorphIsSlowEnoughToBeACrossfadeRatherThanACut() {
        XCTAssertGreaterThanOrEqual(NotchCard.phaseMorph, 0.2)
    }
}

// MARK: - Helpers

private func isRecording(_ phase: NotchPhase) -> Bool {
    if case .recording = phase { true } else { false }
}

private func isRefining(_ phase: NotchPhase) -> Bool {
    if case .refining = phase { true } else { false }
}

private func isNothingHeard(_ phase: NotchPhase) -> Bool {
    if case .nothingHeard = phase { true } else { false }
}
