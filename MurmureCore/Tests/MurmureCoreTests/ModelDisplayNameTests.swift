import XCTest
@testable import MurmureCore

/// How a stored model identifier is written when a person reads it.
///
/// Every identifier below is a shape, not a model Murmure has an opinion about: the rule knows
/// where a slash is and nothing else, so it has to hold for a name it has never seen.
final class ModelDisplayNameTests: XCTestCase {
    /// The identifier Louis was shown in full, and the reason this type exists.
    func testARegistryPathIsNotPartOfTheName() {
        XCTAssertEqual(
            ModelDisplayName.readable("hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"),
            "s1-mini-GGUF:Q4_K_M")
    }

    /// **The tag stays.** `12b-it-qat` is which model this is, not how it was packed, and a rule
    /// that stripped tags would describe text a 12b model wrote as the work of a name shared with
    /// a 27b one.
    func testTheTagIsPartOfTheNameAndSurvives() {
        XCTAssertEqual(ModelDisplayName.readable("gemma4:12b-it-qat"), "gemma4:12b-it-qat")
        XCTAssertEqual(ModelDisplayName.readable("qwen3:8b-q4_K_M"), "qwen3:8b-q4_K_M")
    }

    /// An identifier that was already only a name comes back as it went in. Most of Ollama's
    /// library is written this way, and none of it should acquire or lose a character here.
    func testAPlainNameIsLeftExactlyAsItIs() {
        XCTAssertEqual(ModelDisplayName.readable("s1-mini"), "s1-mini")
        XCTAssertEqual(ModelDisplayName.readable("llama3.2"), "llama3.2")
    }

    func testANamespaceWithoutAHostIsStillAPath() {
        XCTAssertEqual(ModelDisplayName.readable("superwhisper/s1-mini"), "s1-mini")
    }

    /// The split is at the last slash and not at the first colon, which is what keeps a host's
    /// port out of the name instead of taking `11434/library/gemma4` for a tag.
    func testAHostWithAPortLosesTheWholeHost() {
        XCTAssertEqual(ModelDisplayName.readable("localhost:11434/library/gemma4:2b"), "gemma4:2b")
    }

    /// Never nothing. An identifier that is all path keeps what was stored — a metadata row
    /// saying too much beats one that has quietly become blank.
    func testAnIdentifierThatEndsOnItsSlashKeepsWhatWasStored() {
        XCTAssertEqual(ModelDisplayName.readable("hf.co/superwhisper/"), "hf.co/superwhisper/")
    }

    func testSurroundingWhitespaceIsNotPartOfAName() {
        XCTAssertEqual(ModelDisplayName.readable("  gemma4:12b-it-qat\n"), "gemma4:12b-it-qat")
    }

    /// An empty identifier stays empty, which is what makes the metadata block drop the row
    /// rather than print a label with nothing after it.
    func testAnEmptyIdentifierStaysEmpty() {
        XCTAssertEqual(ModelDisplayName.readable(""), "")
        XCTAssertEqual(ModelDisplayName.readable("   "), "")
    }
}
