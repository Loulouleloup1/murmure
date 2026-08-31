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
        XCTAssertEqual(snapshot.restore(to: pasteboard), .restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "readable", "readable types still come back")
    }
}
