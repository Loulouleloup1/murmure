import XCTest
@testable import MurmureCore

/// The mode-drafting system prompt is built from `Mode`'s own encoder and constants rather than
/// typed out by hand -- these tests pin the CONSEQUENCE of that (every real value actually appears
/// in the built string), not a snapshot of the prose around it, so the prompt's wording stays free
/// to be rewritten without breaking a test.
final class ModeDraftSystemPromptTests: XCTestCase {
    private static let installedSpeechModels = [
        "argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo",
    ]
    private static let installedOllamaModels = [
        "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M",
        "gemma4:e2b-it-qat",
        "gemma4:12b-it-qat",
        "nomic-embed-text:latest",
        "mxbai-embed-large:latest",
    ]

    private func build() -> String {
        ModeDraftSystemPrompt.build(
            installedSpeechModels: Self.installedSpeechModels, installedOllamaModels: Self.installedOllamaModels)
    }

    func testListsEveryInstalledSpeechModel() {
        let prompt = build()
        for model in Self.installedSpeechModels {
            XCTAssertTrue(prompt.contains(model), "missing speech model \(model)")
        }
    }

    func testListsTheChatCapableModelsAndTheS1ModelButNotTheEmbeddingModels() {
        let prompt = build()
        XCTAssertTrue(prompt.contains("gemma4:e2b-it-qat"))
        XCTAssertTrue(prompt.contains("gemma4:12b-it-qat"))
        XCTAssertTrue(prompt.contains("hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"))
        XCTAssertFalse(prompt.contains("nomic-embed-text"))
        XCTAssertFalse(prompt.contains("mxbai-embed-large"))
    }

    func testListsEverySymbolInTheLibrary() {
        let prompt = build()
        for symbol in ModeSymbol.library {
            XCTAssertTrue(prompt.contains(symbol), "missing symbol \(symbol)")
        }
    }

    func testShowsTheShippedS1ControlLineExampleVerbatim() {
        // "[Context: general]" -- `Mode.prompt`'s own instructions, not retyped by hand here.
        XCTAssertTrue(build().contains(Mode.prompt.instructions))
    }

    func testIncludesBothShippedModesEncodedByTheRealEncoder() throws {
        let prompt = build()
        let voiceJSON = try XCTUnwrap(String(data: ModeStore.encoder.encode(Mode.voice), encoding: .utf8))
        let promptJSON = try XCTUnwrap(String(data: ModeStore.encoder.encode(Mode.prompt), encoding: .utf8))

        XCTAssertTrue(prompt.contains(voiceJSON))
        XCTAssertTrue(prompt.contains(promptJSON))
    }

    /// Lot 5 review, item 11: the prior version of this test only checked the prompt contained
    /// "null" ANYWHERE -- which the schema's own `"hotkey" : null` line already satisfies, so it
    /// passed whether or not the prose telling the model to leave it null was actually there. This
    /// asserts that sentence itself.
    func testSaysHotkeyStaysNull() {
        XCTAssertTrue(build().contains("\"hotkey\": always null in a draft"))
        XCTAssertTrue(build().contains("Never invent one."))
    }

    func testHasNoInstalledModelsIsHandledWithoutCrashing() {
        let prompt = ModeDraftSystemPrompt.build(installedSpeechModels: [], installedOllamaModels: [])
        XCTAssertFalse(prompt.isEmpty)
    }

    /// The regression backlog §8 names: the FIRST live conversation copied the schema example's
    /// `autoActivate` straight into its answer, because that example carried
    /// `["com.apple.Terminal"]`. Decodes the schema example itself -- the first fenced ```json
    /// block in the built prompt, not `examplesSection`'s "Voice"/"Prompt" ones further down --
    /// and pins that it now has nothing to copy.
    func testTheSchemaExampleHasNoAutoActivateEntryToCopy() throws {
        let prompt = build()
        guard let openRange = prompt.range(of: "```json"),
              let closeRange = prompt.range(of: "```", range: openRange.upperBound..<prompt.endIndex)
        else {
            return XCTFail("no fenced json block in the prompt")
        }
        let json = String(prompt[openRange.upperBound..<closeRange.lowerBound])
        let mode = try JSONDecoder().decode(Mode.self, from: Data(json.utf8))
        XCTAssertTrue(mode.autoActivate.isEmpty)
    }
}
