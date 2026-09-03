import XCTest
@testable import MurmureCore

/// The three reveal buttons of the Advanced pane.
///
/// **The subject is a control that fails by doing nothing.**
/// `NSWorkspace.activateFileViewerSelecting` on a path that is not there returns quietly, so a
/// wrong last path component compiles, runs, and is dead. The paths below are checked against the
/// components the rest of the app actually writes.
final class RevealTargetTests: XCTestCase {
    /// Never a real folder. `url(inSupportFolder:)` takes its base with no default for exactly
    /// this reason — a path can only be reached here by being named.
    private let base = URL(fileURLWithPath: "/tmp/RevealTargetTests/Murmure", isDirectory: true)

    // MARK: - The paths, against the call sites that create them

    /// `Storage.url(subfolder:)` is what `DictationController` and `AudioRecorder` use, so it is
    /// the authority on what the folders are called. Asserted against it rather than against a
    /// literal, which would just be this file agreeing with itself.
    func testTheTwoFoldersAreTheOnesStorageResolves() {
        XCTAssertEqual(
            RevealTarget.modes.url(inSupportFolder: base),
            Storage.url(subfolder: "modes", in: base.deletingLastPathComponent()))
        XCTAssertEqual(
            RevealTarget.recordings.url(inSupportFolder: base),
            Storage.url(subfolder: "recordings", in: base.deletingLastPathComponent()))
    }

    /// `vocabulary.json` sits directly in `Murmure/`, beside the two folders (Q-NB3) — not in a
    /// folder of its own. This is the assertion that catches somebody "tidying" it into one.
    func testTheVocabularyIsAFileBesideTheFoldersAndNotInsideOne() {
        XCTAssertEqual(
            RevealTarget.vocabulary.url(inSupportFolder: base).lastPathComponent,
            "vocabulary.json")
        XCTAssertEqual(
            RevealTarget.vocabulary.url(inSupportFolder: base).deletingLastPathComponent(), base)
    }

    /// `Storage`'s measured bug, guarded one layer up: a folder URL built without `isDirectory:`
    /// compares unequal to the same folder built with it, so a `modes/` resolved here would not
    /// match the `modes` the rest of the app resolves. The one that is a file must NOT wear the
    /// slash, which is the other half of the same rule.
    func testFoldersCarryTheTrailingSlashAndTheFileDoesNot() {
        XCTAssertTrue(RevealTarget.modes.url(inSupportFolder: base).hasDirectoryPath)
        XCTAssertTrue(RevealTarget.recordings.url(inSupportFolder: base).hasDirectoryPath)
        XCTAssertFalse(RevealTarget.vocabulary.url(inSupportFolder: base).hasDirectoryPath)
    }

    /// Nothing here reaches the disk. The whole type is a path calculation, and a reveal that
    /// created what it was asked to show would make a folder in Louis's real Application Support
    /// to show him it was empty.
    func testResolvingAPathCreatesNothing() {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RevealTargetTests-\(UUID().uuidString)", isDirectory: true)

        for target in RevealTarget.allCases {
            _ = target.url(inSupportFolder: workspace)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
    }

    // MARK: - The words

    /// The button says **File** for the one that is a file. A button promising a folder that opens
    /// a window with one JSON selected in it has mis-described what it did, and the next thing the
    /// reader does is go looking for the folder it meant.
    func testTheVocabularyButtonPromisesAFileAndTheOthersPromiseFolders() {
        XCTAssertEqual(RevealTarget.vocabulary.buttonTitle, "Reveal Vocabulary File")
        XCTAssertEqual(RevealTarget.modes.buttonTitle, "Reveal Modes Folder")
        XCTAssertEqual(RevealTarget.recordings.buttonTitle, "Reveal Recordings Folder")
    }

    /// Every button is distinct and every one starts the same way, so three of them in a column
    /// read as one control repeated rather than as three unrelated actions.
    func testTheThreeButtonsAreDistinctAndShareTheirVerb() {
        let titles = RevealTarget.allCases.map(\.buttonTitle)
        XCTAssertEqual(Set(titles).count, RevealTarget.allCases.count)
        XCTAssertTrue(titles.allSatisfy { $0.hasPrefix("Reveal ") })
    }

    /// **The reason `missingNote` exists at all**: an absent folder is the normal state of a fresh
    /// install, and the button's only alternative is to open nothing and say nothing. Each note
    /// names the event that creates the thing, so the reader knows it is a "not yet" and not a
    /// "something is broken".
    func testEveryMissingNoteNamesWhatWillCreateTheThingRatherThanApologising() {
        for target in RevealTarget.allCases {
            let note = target.missingNote
            XCTAssertTrue(
                note.contains("yet"),
                "\(target) should read as a not-yet rather than as a failure: \(note)")
            XCTAssertFalse(
                note.lowercased().contains("error"),
                "\(target) is not a failure: \(note)")
        }
    }

    /// A note that names the thing it is about. "There is nothing there" would leave the reader
    /// working out which of the three buttons they pressed.
    func testEachMissingNoteNamesItsOwnTarget() {
        XCTAssertTrue(RevealTarget.modes.missingNote.contains("modes folder"))
        XCTAssertTrue(RevealTarget.recordings.missingNote.contains("recordings folder"))
        XCTAssertTrue(RevealTarget.vocabulary.missingNote.contains("vocabulary.json"))
    }
}
