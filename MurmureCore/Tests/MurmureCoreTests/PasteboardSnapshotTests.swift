import AppKit
import XCTest
@testable import MurmureCore

/// A data provider that never supplies its promised type, standing in for an app that has
/// quit or refuses to materialise a lazy representation.
private final class SilentProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        // Deliberately provides nothing.
    }
}

/// A data provider that DOES supply its promised type, standing in for a live app answering the
/// request -- and counts how many times it was asked, which is how the tests below know the lazy
/// representation was really resolved rather than skipped.
private final class AnsweringProvider: NSObject, NSPasteboardItemDataProvider {
    private(set) var fired = 0

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        fired += 1
        item.setData(Data("{\\rtf1\\ansi promised}".utf8), forType: type)
    }
}

/// The seam that makes the capture-time race deterministic. `capture()` resolves a lazy
/// representation by CALLING its provider -- synchronously, on this thread, in the middle of the
/// capture -- so a provider that copies is a third party copying at exactly the instant that used
/// to lose data, with no clock and no `sleep` anywhere.
private final class CopyingProvider: NSObject, NSPasteboardItemDataProvider {
    private let target: NSPasteboard
    private(set) var fired = 0

    init(copyingInto target: NSPasteboard) {
        self.target = target
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        fired += 1
        target.clearContents()
        target.setString("THIRD PARTY COPY", forType: .string)
    }
}

final class PasteboardSnapshotTests: XCTestCase {
    /// A private pasteboard per test: the general pasteboard belongs to the user, and a test
    /// that borrows it destroys whatever was copied.
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("murmure-test-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        return pasteboard
    }

    private func contents(of pasteboard: NSPasteboard) -> [[(String, Data)]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.map { ($0.rawValue, item.data(forType: $0) ?? Data()) }
        }
    }

    private func assertContentsEqual(
        _ lhs: [[(String, Data)]], _ rhs: [[(String, Data)]], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(lhs.count, rhs.count, "item count", file: file, line: line)
        for (index, (left, right)) in zip(lhs, rhs).enumerated() {
            XCTAssertEqual(left.map(\.0), right.map(\.0), "types of item \(index)", file: file, line: line)
            XCTAssertEqual(left.map(\.1), right.map(\.1), "bytes of item \(index)", file: file, line: line)
        }
    }

    func testSnapshotRestoresPreviousStringContent() {
        let pasteboard = makePasteboard()
        pasteboard.setString("original content", forType: .string)

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("dictated text", forType: .string)
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated text")

        XCTAssertEqual(snapshot.restore(to: pasteboard), .restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "original content")
    }

    /// The test that matters: a real clipboard is not a string. Louis copies a file or a chunk
    /// of styled text, dictates, and every representation must come back byte for byte.
    func testRestoresEveryRepresentationOfEveryItem() throws {
        let pasteboard = makePasteboard()
        let rich = NSPasteboardItem()
        rich.setString("plain text", forType: .string)
        rich.setData(Data("{\\rtf1\\ansi styled}".utf8), forType: .rtf)
        rich.setString("<b>styled</b>", forType: .html)
        rich.setData(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x42]), forType: .png)
        rich.setData(Data("private payload".utf8), forType: NSPasteboard.PasteboardType("com.example.private"))
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("murmure.txt")
        XCTAssertTrue(pasteboard.writeObjects([rich, fileURL as NSURL]))

        let before = contents(of: pasteboard)
        XCTAssertEqual(before.count, 2, "fixture should hold two items")
        XCTAssertGreaterThanOrEqual(before[0].count, 5, "fixture item should carry several types")

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        XCTAssertEqual(snapshot.droppedTypes, [], "nothing should be unreadable in this fixture")

        // The paste cycle: the dictated text replaces everything.
        pasteboard.clearContents()
        pasteboard.setString("dictated text", forType: .string)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertNil(pasteboard.data(forType: .rtf))

        XCTAssertEqual(snapshot.restore(to: pasteboard), .restored)

        assertContentsEqual(contents(of: pasteboard), before)
        // Spelt out for the representations a user would actually notice losing.
        XCTAssertEqual(pasteboard.string(forType: .string), "plain text")
        XCTAssertEqual(pasteboard.data(forType: .rtf), Data("{\\rtf1\\ansi styled}".utf8))
        XCTAssertEqual(pasteboard.string(forType: .html), "<b>styled</b>")
        XCTAssertEqual(
            pasteboard.data(forType: NSPasteboard.PasteboardType("com.example.private")),
            Data("private payload".utf8)
        )
        let readBack = try XCTUnwrap(
            pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        )
        XCTAssertEqual(readBack.map(\.path), [fileURL.path], "the copied file must survive a dictation")
    }

    func testEmptyPasteboardRestoresToEmpty() {
        let pasteboard = makePasteboard()
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.setString("noise", forType: .string)

        XCTAssertEqual(snapshot.restore(to: pasteboard), .restored)
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 0)
    }

    /// The user copies something while the paste is still in flight. Restoring then would
    /// silently replace their brand-new clipboard with a stale one.
    func testDeclinesRestoreWhenSomethingWasCopiedAfterOurWrite() {
        let pasteboard = makePasteboard()
        pasteboard.setString("original content", forType: .string)
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        let ourGeneration = pasteboard.changeCount
        pasteboard.setString("dictated text", forType: .string)

        // The user presses ⌘C on something else: a copy always clears first, which bumps the count.
        pasteboard.clearContents()
        pasteboard.setString("what the user just copied", forType: .string)

        XCTAssertEqual(
            snapshot.restore(to: pasteboard, ifChangeCountIs: ourGeneration), .declinedPasteboardChanged
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "what the user just copied")
    }

    func testRestoresWhenNobodyTouchedThePasteboardAfterOurWrite() {
        let pasteboard = makePasteboard()
        pasteboard.setString("original content", forType: .string)
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        let ourGeneration = pasteboard.clearContents()
        pasteboard.setString("dictated text", forType: .string)

        XCTAssertEqual(snapshot.restore(to: pasteboard, ifChangeCountIs: ourGeneration), .restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "original content")
    }

    /// A promised representation nobody will supply is dropped -- but it is NAMED, so the app
    /// can say the clipboard came back incomplete instead of losing it in silence.
    func testUnreadablePromisedTypeIsReportedRatherThanSilentlyLost() {
        let pasteboard = makePasteboard()
        let provider = SilentProvider()
        let item = NSPasteboardItem()
        item.setString("readable", forType: .string)
        item.setDataProvider(provider, forTypes: [.rtf])
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        // AppKit also advertises a derived `public.utf16-external-plain-text` on an item that
        // carries a pending promise, and refuses to materialise it too -- measured, not assumed.
        XCTAssertTrue(snapshot.droppedTypes.contains(.rtf), "got \(snapshot.droppedTypes)")
        XCTAssertFalse(snapshot.droppedTypes.contains(.string), "readable types are not dropped")
        pasteboard.clearContents()
        pasteboard.setString("dictated text", forType: .string)

        // The item survives, amputated -- and that is NOT `.restored`. Reporting a complete
        // success here is the same lie one level down: the user copied styled text, gets bare
        // characters back, and nothing anywhere said so.
        XCTAssertEqual(
            snapshot.restore(to: pasteboard),
            .restoredPartially(lostItems: 0, capturedItems: 1, lostTypes: snapshot.droppedTypes)
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "readable", "readable types still come back")
        XCTAssertNil(pasteboard.data(forType: .rtf), "the promised type really is gone")
    }

    /// The case the eager `.string` in the test above was hiding: an item whose ONLY types are
    /// promises nobody fulfils. There is nothing to rebuild it from, so it is destroyed by the
    /// dictation -- and the outcome has to say that, not `.restored`.
    func testItemWhoseOnlyTypesArePromisesIsReportedLostRatherThanRestored() {
        let pasteboard = makePasteboard()
        let provider = SilentProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.rtf])
        XCTAssertTrue(pasteboard.writeObjects([item]))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1, "fixture holds one item")

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        XCTAssertTrue(snapshot.droppedTypes.contains(.rtf), "got \(snapshot.droppedTypes)")

        pasteboard.clearContents()
        pasteboard.setString("dictated text", forType: .string)

        XCTAssertEqual(
            snapshot.restore(to: pasteboard),
            .restoredPartially(lostItems: 1, capturedItems: 1, lostTypes: snapshot.droppedTypes),
            "the whole clipboard was lost -- reporting .restored would be a false success"
        )
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 0, "the item really is gone")
        XCTAssertNil(pasteboard.data(forType: .rtf))
    }

    /// The partial case: one item survives, one cannot. The survivor must come back AND the loss
    /// must be counted -- "some of it" is neither a success nor a total failure.
    func testItemsThatCannotBeRebuiltAreCountedWhileTheRestComeBack() {
        let pasteboard = makePasteboard()
        let survivor = NSPasteboardItem()
        survivor.setString("keep me", forType: .string)
        let doomed = NSPasteboardItem()
        doomed.setDataProvider(SilentProvider(), forTypes: [.rtf])
        XCTAssertTrue(pasteboard.writeObjects([survivor, doomed]))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2, "fixture holds two items")

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("dictated text", forType: .string)

        XCTAssertEqual(
            snapshot.restore(to: pasteboard),
            .restoredPartially(lostItems: 1, capturedItems: 2, lostTypes: snapshot.droppedTypes)
        )
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    // ========================================================================
    // Borrowing
    // ========================================================================

    func testBorrowWritesTheTextAndHandsTheWholeClipboardBack() throws {
        let pasteboard = makePasteboard()
        let rich = NSPasteboardItem()
        rich.setString("plain text", forType: .string)
        rich.setData(Data("{\\rtf1\\ansi styled}".utf8), forType: .rtf)
        XCTAssertTrue(pasteboard.writeObjects([rich]))
        let before = contents(of: pasteboard)

        let borrowed = try borrowOrFail(pasteboard, writing: "dictated text")
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated text", "the borrow must write")
        XCTAssertEqual(borrowed.droppedTypes, [])

        XCTAssertEqual(borrowed.handBack(), .restored)
        assertContentsEqual(contents(of: pasteboard), before)
    }

    /// A refused write must not cost the user their clipboard. `borrow` has already cleared it by
    /// then, so the hand-back cannot be left to the caller's error path -- it happens here.
    func testARefusedWriteStillHandsTheClipboardBack() {
        let pasteboard = makePasteboard()
        pasteboard.setString("original content", forType: .string)

        let borrowing = PasteboardSnapshot.borrow(pasteboard) { _ in false }

        guard case let .writeRefused(handedBack, droppedTypes) = borrowing else {
            return XCTFail("a refused write must not hand out a Borrowed handle")
        }
        XCTAssertEqual(handedBack, .restored)
        XCTAssertEqual(droppedTypes, [])
        XCTAssertEqual(pasteboard.string(forType: .string), "original content")
    }

    /// The premise the capture-time guard rests on: `capture()` reads the pasteboard, it never
    /// writes to it, so it cannot bump the generation counter itself -- not even when it forces a
    /// lazy representation to be materialised. If a future macOS breaks that, the guard would see
    /// its own capture as a third party's copy and every dictation would re-capture for nothing;
    /// this test says so immediately instead.
    func testCaptureNeverBumpsTheChangeCountEvenWhenItResolvesAPromise() {
        let pasteboard = makePasteboard()
        let provider = AnsweringProvider()
        let item = NSPasteboardItem()
        item.setString("eager", forType: .string)
        item.setDataProvider(provider, forTypes: [.rtf])
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let before = pasteboard.changeCount
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        XCTAssertEqual(provider.fired, 1, "the fixture must actually resolve a lazy representation")
        XCTAssertFalse(snapshot.droppedTypes.contains(.rtf), "got \(snapshot.droppedTypes)")
        XCTAssertEqual(pasteboard.changeCount, before, "capture() must not look like somebody's copy")
    }

    /// The regression that `borrow` exists for. A third party copies WHILE the snapshot is being
    /// taken -- not after our write, which is the case the generation counter already covered.
    ///
    /// Taking the snapshot is not instantaneous: it resolves every representation, which means
    /// calling into whichever app owns a lazy one. Measured at 0.6-1.3 ms for the first call in a
    /// process and 10-20 µs warm on a trivial clipboard, 97 µs on a rich eager one, and 3.1 ms
    /// with a single 1 MB lazy representation to materialise -- and Word, Pages, Excel and Figma
    /// all publish lazy representations. A clipboard manager polling `changeCount` reaches a
    /// window of that size.
    ///
    /// What used to happen in it: their copy erased by our `clearContents()`, then overwritten by
    /// the hand-back's pre-dictation contents, with the outcome reading `.restored`. Their copy
    /// was gone and nothing anywhere said it had ever existed.
    func testACopyMadeWhileTheSnapshotIsBeingTakenIsNotDestroyed() throws {
        let pasteboard = makePasteboard()
        let provider = CopyingProvider(copyingInto: pasteboard)
        let item = NSPasteboardItem()
        item.setString("ORIGINAL", forType: .string)
        item.setDataProvider(provider, forTypes: [.rtf])
        XCTAssertTrue(pasteboard.writeObjects([item]))
        // TYPES ONLY. Reading the bytes here would resolve the promise and cache it, the provider
        // would never fire during the capture, and this test would pass without exercising
        // anything -- which is exactly how it was got wrong the first time.
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.types.contains(.rtf), true)
        XCTAssertEqual(provider.fired, 0, "the seam must still be loaded when the borrow starts")

        let borrowed = try borrowOrFail(pasteboard, writing: "dictated text")
        let outcome = borrowed.handBack()

        // Fires once: the re-capture reads the third party's plain string, which has no provider,
        // so the loop ends after one extra snapshot. It is also the assertion that keeps this test
        // honest -- a `fired` of 0 would mean the seam was consumed early and nothing was tested.
        XCTAssertEqual(provider.fired, 1, "the seam must fire exactly once, during the capture")
        XCTAssertEqual(
            pasteboard.string(forType: .string), "THIRD PARTY COPY",
            "their copy is newer than ours and wins -- restoring over it is the data loss this type prevents"
        )
        XCTAssertEqual(outcome, .restored, "and the outcome must not claim a restore that overwrote them")
    }

    private func borrowOrFail(
        _ pasteboard: NSPasteboard, writing text: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> PasteboardSnapshot.Borrowed {
        let borrowing = PasteboardSnapshot.borrow(pasteboard) { $0.setString(text, forType: .string) }
        guard case let .borrowed(borrowed) = borrowing else {
            XCTFail("the borrow was refused: \(borrowing)", file: file, line: line)
            throw XCTSkip("no handle")
        }
        return borrowed
    }
}
