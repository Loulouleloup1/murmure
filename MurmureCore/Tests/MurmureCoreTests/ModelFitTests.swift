import XCTest
@testable import MurmureCore

final class ModelFitTests: XCTestCase {
    let memory: Int64 = 24 * 1_073_741_824   // 24 GiB

    func testBoundariesAreInclusive() {
        XCTAssertEqual(ModelFit.classify(modelBytes: Int64(Double(memory) * 0.45), memoryBytes: memory), .recommended)
        XCTAssertEqual(ModelFit.classify(modelBytes: Int64(Double(memory) * 0.45) + 1, memoryBytes: memory), .tight)
        XCTAssertEqual(ModelFit.classify(modelBytes: Int64(Double(memory) * 0.70), memoryBytes: memory), .tight)
        XCTAssertEqual(ModelFit.classify(modelBytes: Int64(Double(memory) * 0.70) + 1, memoryBytes: memory), .tooLarge)
    }

    func testRealisticModels() {
        XCTAssertEqual(ModelFit.classify(modelBytes: 8_100_000_000, memoryBytes: memory), .recommended)  // 12b q4
        XCTAssertEqual(ModelFit.classify(modelBytes: 20_000_000_000, memoryBytes: memory), .tooLarge)
    }

    func testUnknownMemoryNeverRecommends() {
        XCTAssertEqual(ModelFit.classify(modelBytes: 1, memoryBytes: 0), .tooLarge)
    }

    func testLabels() {
        XCTAssertEqual(ModelFit.recommended.label, "Recommended for this Mac")
        XCTAssertEqual(ModelFit.tight.label, "Tight on this Mac")
        XCTAssertEqual(ModelFit.tooLarge.label, "Too large for this Mac")
    }

    func testCurrentProfileReadsThisMachine() {
        let profile = HardwareProfile.current()
        XCTAssertGreaterThan(profile.physicalMemoryBytes, 1_073_741_824)
    }
}
