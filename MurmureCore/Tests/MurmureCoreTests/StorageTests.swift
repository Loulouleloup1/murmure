import XCTest
@testable import MurmureCore

final class StorageTests: XCTestCase {
    func testAppSupportDirectoryIsCreated() throws {
        let url = try Storage.appSupportDirectory(subfolder: "recordings")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(url.path.hasSuffix("Murmure/recordings"))
    }
}
