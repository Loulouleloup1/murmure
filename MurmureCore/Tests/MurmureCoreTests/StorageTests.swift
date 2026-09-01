import XCTest
@testable import MurmureCore

final class StorageTests: XCTestCase {
    /// Only the tests that must prove creation get a directory, and it is a fresh temporary one.
    /// Nothing here may reach `~/Library/Application Support/Murmure`, which holds Louis's real
    /// recordings, models and modes -- the tests about `url(subfolder:)` name that folder and
    /// never write a byte into it, which is the whole point of the function.
    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StorageTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testURLIsTheMurmureSubfolderOfApplicationSupport() {
        let url = Storage.url(subfolder: "recordings")

        XCTAssertTrue(url.path.hasSuffix("/Murmure/recordings"), url.path)
        XCTAssertTrue(url.path.hasPrefix(Storage.applicationSupport.path), url.path)
    }

    /// The regression this whole split exists for: the old function created the folder it was
    /// asked to name. The subfolder is a UUID so it cannot collide with `recordings`, `models` or
    /// `modes` -- if `url` ever creates again, this fails without having touched anything real.
    func testURLCreatesNothingUnderTheRealApplicationSupport() {
        let url = Storage.url(subfolder: "StorageTests-must-not-exist-\(UUID().uuidString)")

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.path)
    }

    /// The same claim where every level can be checked: given a base that does not exist, `url`
    /// leaves the base, the `Murmure` folder inside it and the subfolder all absent.
    func testURLCreatesNoLevelOfThePathItReturns() {
        let url = Storage.url(subfolder: "history", in: base)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
    }

    func testDirectoryCreatesTheSubfolderAndItsParents() throws {
        let url = try Storage.directory(subfolder: "history", in: base)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// A store that reads through `url` and writes through `directory` has to land in one place,
    /// so the two may never drift apart.
    func testDirectoryCreatesExactlyThePathURLNames() throws {
        let created = try Storage.directory(subfolder: "history", in: base)

        XCTAssertEqual(created, Storage.url(subfolder: "history", in: base))
    }

    /// It runs at every launch, on a folder that already holds recordings.
    func testDirectorySucceedsOnAnExistingFolderAndKeepsWhatIsInIt() throws {
        let url = try Storage.directory(subfolder: "history", in: base)
        let file = url.appendingPathComponent("already-there.txt")
        try Data("kept".utf8).write(to: file)

        _ = try Storage.directory(subfolder: "history", in: base)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "kept")
    }
}
