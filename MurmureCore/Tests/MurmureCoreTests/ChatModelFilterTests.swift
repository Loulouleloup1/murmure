import XCTest
@testable import MurmureCore

/// Which of Ollama's own listing can hold a mode-drafting conversation over `/api/chat` -- pinned
/// against the five models actually installed on the machine this feature was built on (`ollama
/// list`), not against invented names, so the rule is proved on the real shape it has to work.
final class ChatModelFilterTests: XCTestCase {
    private static let realListing = [
        "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M",
        "gemma4:e2b-it-qat",
        "gemma4:12b-it-qat",
        "nomic-embed-text:latest",
        "mxbai-embed-large:latest",
    ]

    func testTheTwoGemmaModelsAreChatCapable() {
        XCTAssertTrue(ChatModelFilter.isChatCapable("gemma4:e2b-it-qat"))
        XCTAssertTrue(ChatModelFilter.isChatCapable("gemma4:12b-it-qat"))
    }

    func testTheS1ModelIsExcluded() {
        XCTAssertFalse(ChatModelFilter.isChatCapable("hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"))
        XCTAssertTrue(ChatModelFilter.looksLikeS1("hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"))
    }

    func testTheTwoEmbeddingModelsAreExcluded() {
        XCTAssertFalse(ChatModelFilter.isChatCapable("nomic-embed-text:latest"))
        XCTAssertFalse(ChatModelFilter.isChatCapable("mxbai-embed-large:latest"))
        XCTAssertTrue(ChatModelFilter.looksLikeEmbedding("nomic-embed-text:latest"))
        XCTAssertTrue(ChatModelFilter.looksLikeEmbedding("mxbai-embed-large:latest"))
    }

    func testFilteringTheRealListingLeavesExactlyTheTwoGemmaModels() {
        let chatCapable = Self.realListing.filter(ChatModelFilter.isChatCapable)
        XCTAssertEqual(chatCapable, ["gemma4:e2b-it-qat", "gemma4:12b-it-qat"])
    }

    // MARK: - The default model

    func testDefaultsToTheTwelveBModelWhenInstalled() {
        XCTAssertEqual(
            ChatModelFilter.defaultModel(among: Self.realListing), "gemma4:12b-it-qat")
    }

    func testFallsBackToTheFirstChatCapableModelWhenThePreferredOneIsAbsent() {
        let listing = ["gemma4:e2b-it-qat", "nomic-embed-text:latest"]
        XCTAssertEqual(ChatModelFilter.defaultModel(among: listing), "gemma4:e2b-it-qat")
    }

    func testMatchesThePreferredModelThroughItsTagLikeEveryOtherPickerInTheApp() {
        // A mode or a caller naming the bare "gemma4:12b-it-qat" has to match the listing's own
        // spelling even if it differed -- here it is identical, so this also proves the match is
        // not accidentally requiring exact-string equality by circumstance.
        XCTAssertEqual(
            ChatModelFilter.defaultModel(among: ["gemma4:12b-it-qat"], preferring: "gemma4:12b-it-qat"),
            "gemma4:12b-it-qat")
    }

    func testNilWhenNothingInstalledCanHoldTheConversation() {
        XCTAssertNil(ChatModelFilter.defaultModel(among: ["hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"]))
        XCTAssertNil(ChatModelFilter.defaultModel(among: []))
    }
}
