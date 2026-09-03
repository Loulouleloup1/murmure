import AppKit
import XCTest
@testable import MurmureCore

/// The panel's one geometric rule: every sentence it can be *sure* of saying has to fit the room
/// it left for sentences.
///
/// The widths are measured here rather than pinned as constants, so the test is not a copy of the
/// answer. It sets the same font the view sets -- `.system(size:weight:design:.rounded)` resolves
/// to `.AppleSystemUIFontRounded-Medium` -- and asks CoreText, which is what will actually lay the
/// sentence out. A label made longer, a slot made narrower, or the point size raised each break it
/// on their own.
final class StatusPanelLayoutTests: XCTestCase {
    /// The view's font, rebuilt from the same three inputs.
    private func labelFont() throws -> NSFont {
        let base = NSFont.systemFont(ofSize: StatusPanelLayout.labelFontSize, weight: .medium)
        let rounded = try XCTUnwrap(base.fontDescriptor.withDesign(.rounded))
        return try XCTUnwrap(NSFont(descriptor: rounded, size: StatusPanelLayout.labelFontSize))
    }

    private func width(_ text: String) throws -> CGFloat {
        (text as NSString).size(withAttributes: [.font: try labelFont()]).width
    }

    /// Every phase whose sentence the panel writes itself. `failed` and `alert` are excluded on
    /// purpose -- their text comes from outside and truncates by design -- and `hidden` has no
    /// panel to fit into.
    ///
    /// The completion is listed at five digits, which is more than a dictation will ever insert;
    /// the point is that the count truncating is the one failure this slot exists to prevent.
    ///
    /// The download is listed at 100 %, which a running one never reaches
    /// (`ModelDownload.ceilingWhileRunning`) -- for the same reason: the widest form has to fit
    /// even though it will not be shown, so a later change to the wording is measured against the
    /// worst case rather than the usual one. It is the sentence with the least headroom of the
    /// three the panel writes itself for a running dictation, and a truncated "Downloading model
    /// 10…" would take away the one number this whole task exists to put on screen.
    private let sentences: [NotchPhase] = [
        .recording,
        .preparingModel(.downloading(ModelDownload(expectedBytes: 1_638_467_188))),
        .preparingModel(.loading),
        .transcribing, .refining, .inserting, .nothingHeard, .cancelled,
        .completed(insertedCharacters: 1), .completed(insertedCharacters: 12345),
        .copiedToClipboard(characters: 1), .copiedToClipboard(characters: 12345),
    ]

    /// The widest the download's sentence can be, measured rather than assumed: three digits.
    ///
    /// `sentences` above carries a download at 0 %, which is what the panel actually opens on; this
    /// pins the other end, because the digits grow the sentence and the slot is a fixed budget.
    func testTheDownloadFitsTheSlotAtEveryPercentageItCanShow() throws {
        var download = ModelDownload(expectedBytes: 1_638_467_188)
        for percent in 0...100 {
            download.observe(receivedBytes: Int64(percent) * 16_384_672)
            let label = StatusPanelText.label(for: .preparingModel(.downloading(download)))
            let measured = try width(label)
            XCTAssertLessThanOrEqual(
                measured, StatusPanelLayout.labelSlot,
                "\"\(label)\" needs \(measured) pt and the slot is \(StatusPanelLayout.labelSlot)")
        }
        XCTAssertEqual(download.percent, ModelDownload.ceilingWhileRunning)
        // The form that can never actually be reached, kept as the true ceiling of the budget.
        XCTAssertLessThanOrEqual(try width("Downloading model 100%"), StatusPanelLayout.labelSlot)
    }

    func testEverySentenceThePanelWritesItselfFitsTheSlot() throws {
        for phase in sentences {
            let label = StatusPanelText.label(for: phase)
            let measured = try width(label)
            XCTAssertLessThanOrEqual(
                measured, StatusPanelLayout.labelSlot,
                "\"\(label)\" needs \(measured) pt and the slot is \(StatusPanelLayout.labelSlot)")
        }
    }

    /// The complaint this layout answers, as an arithmetic fact: a short sentence uses under a
    /// third of the slot, so wherever the surplus goes it is *seen*. "Refining" measures 46.91 pt
    /// in a 158 pt slot; left-aligned that was one hole of 111 pt against the right end of the
    /// capsule, which is the "totalement noire" Louis is looking at, and centred it is two of 55.
    ///
    /// Pinned because it is the premise of the alignment, not a consequence of it: a slot narrow
    /// enough that the surplus stopped mattering would make centring pointless, and the view would
    /// then be centring for a reason that had quietly stopped being true.
    func testTheShortestSentenceLeavesEnoughSurplusToBeWorthCentring() throws {
        let shortest = try width(StatusPanelText.label(for: .refining))
        XCTAssertGreaterThan(StatusPanelLayout.labelSlot - shortest, 100)
    }

    /// **Why the drawing is not widened, priced rather than argued.**
    ///
    /// Handing the waveform every point the longest sentence can spare buys it at most one more
    /// bar -- 43 ms of history -- because the panel's bars sit on `minimumBarWidth` and each one
    /// therefore costs a flat pitch in width. That is the whole case for leaving `drawingWidth`
    /// alone, and it is arithmetic rather than taste, so it belongs in a test: if a future change
    /// to the bar geometry ever makes width cheap here, this fails and the question reopens on its
    /// own instead of staying settled by a comment nobody rechecks.
    func testTheSlotsHeadroomCannotBuyTheDrawingAWaveform() throws {
        let widest = try XCTUnwrap(sentences.map { try width(StatusPanelText.label(for: $0)) }.max())
        let headroom = StatusPanelLayout.labelSlot - widest
        XCTAssertGreaterThan(headroom, 0, "the slot must clear its longest sentence at all")
        let asIs = WaveformLayout.barCount(inWidth: Double(StatusPanelLayout.drawingWidth))
        let ifWidened = WaveformLayout.barCount(
            inWidth: Double(StatusPanelLayout.drawingWidth + headroom))
        XCTAssertLessThanOrEqual(
            ifWidened - asIs, 1,
            "width has become cheap enough here that widening the drawing is worth reconsidering")
    }

    /// The total, pinned deliberately as a total.
    ///
    /// This is a change-detector and it is meant to be one. `width` is a sum of five numbers that
    /// are each somebody's taste, and 260 x 34 is the strip Louis has been looking at and has not
    /// objected to; the failure it prevents is one of those five being nudged for a local reason
    /// and the panel on his desk quietly changing size. A deliberate change updates this line and
    /// says so, which is the whole difference.
    func testTheStripIsTheSizeLouisHasBeenLookingAt() {
        XCTAssertEqual(StatusPanelLayout.size, CGSize(width: 260, height: 34))
    }
}
