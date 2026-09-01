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
    private let sentences: [NotchPhase] = [
        .recording, .transcribing, .refining, .inserting, .nothingHeard,
        .completed(insertedCharacters: 1), .completed(insertedCharacters: 12345),
    ]

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
