import XCTest
@testable import MurmureCore

final class OllamaModelNameTests: XCTestCase {
    func testHuggingFaceJoinsTheRepositoryAndTagInOllamasOwnShape() {
        XCTAssertEqual(
            OllamaModelName.huggingFace(repository: "superwhisper/s1-mini-GGUF", tag: "Q4_K_M"),
            "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M")
    }
}
