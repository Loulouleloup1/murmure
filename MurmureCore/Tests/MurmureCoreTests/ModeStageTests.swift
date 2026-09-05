import XCTest
@testable import MurmureCore

/// The trailing readout of a list row: how many models this mode runs, and which.
final class ModeStageTests: XCTestCase {
    /// One badge, and it is the transcription one -- not "no badges", which would read as a mode
    /// that does nothing rather than as a mode that only transcribes.
    func testATranscribeOnlyModeShowsOneBadgeForTheModelItDoesRun() {
        XCTAssertEqual(Mode.voice.stages, [.transcription])
    }

    func testARefiningModeShowsTwoInTheOrderTheyRun() {
        XCTAssertEqual(Mode.prompt.stages, [.transcription, .refinement])
    }

    /// `llm.enabled` and nothing else decides, because it is what `TranscriptRefiner` branches on.
    /// A mode with a model configured and the refiner off runs one stage, and a row saying two
    /// would promise a refinement the dictation never performs.
    func testTheCountFollowsTheRefinerAndNotTheModelThatIsConfigured() {
        var configuredButOff = Mode.prompt
        configuredButOff.llm.enabled = false

        XCTAssertEqual(configuredButOff.stages.count, 1)
        XCTAssertEqual(Mode.prompt.stages.count, 2)
    }

    /// D14: the glyph is derived, so a mode file carries no icon field to fill in or explain.
    /// The two symbols are the ones `MainWindowView`'s header already draws for the active mode --
    /// the same mode wearing two different glyphs in one window would read as two modes.
    func testTheRowGlyphSaysWhetherTheModeSendsWhatIsSaidToALanguageModel() {
        XCTAssertEqual(Mode.voice.symbolName, ModeStage.transcription.symbolName)
        XCTAssertEqual(Mode.prompt.symbolName, ModeStage.refinement.symbolName)
        XCTAssertNotEqual(Mode.voice.symbolName, Mode.prompt.symbolName)
    }

    /// An explicit `symbol` wins over the stage's own default in both directions -- a
    /// transcribe-only mode can wear `sparkles` and a refining one can wear `mic.fill` -- because
    /// picking an icon is meant to say what the mode is FOR, not merely restate whether it refines.
    func testAnExplicitSymbolOverridesTheStageDefault() {
        var voiceWithSparkles = Mode.voice
        voiceWithSparkles.symbol = "sparkles"
        XCTAssertEqual(voiceWithSparkles.symbolName, "sparkles")

        var promptWithMic = Mode.prompt
        promptWithMic.symbol = "mic.fill"
        XCTAssertEqual(promptWithMic.symbolName, "mic.fill")
    }

    /// Nil is not "no icon" visually -- it is "use the derived one", which is what every mode file
    /// written before `symbol` existed already gets.
    func testANilSymbolFallsBackToTheStageDefault() {
        XCTAssertNil(Mode.voice.symbol)
        XCTAssertNil(Mode.prompt.symbol)
        XCTAssertEqual(Mode.voice.symbolName, ModeStage.transcription.symbolName)
        XCTAssertEqual(Mode.prompt.symbolName, ModeStage.refinement.symbolName)
    }

    /// A `symbol` outside `ModeSymbol.library` -- the shape of a hand-typed mistake in the JSON --
    /// must not draw nothing. This is the actual regression review lot 3a item 6 flags: a file
    /// with `"symbol": "nonsense"` still has to show a real glyph somewhere.
    func testASymbolNotInTheLibraryFallsBackToTheStageDefault() {
        var voice = Mode.voice
        voice.symbol = "nonsense"
        XCTAssertEqual(voice.symbolName, ModeStage.transcription.symbolName)

        var prompt = Mode.prompt
        prompt.symbol = "nonsense"
        XCTAssertEqual(prompt.symbolName, ModeStage.refinement.symbolName)
    }

    /// Every entry the grid actually offers must round-trip through `symbolName` unchanged --
    /// otherwise the tile shown selected in the grid (task 4, `iconPicker`) would not be the tile
    /// that was actually picked.
    func testEveryLibraryEntryIsAcceptedAsIs() {
        for symbol in ModeSymbol.library {
            var mode = Mode.voice
            mode.symbol = symbol
            XCTAssertEqual(mode.symbolName, symbol, symbol)
        }
    }

    /// Each badge names the model its stage runs, so the readout is provenance and not decoration
    /// -- design notes §5, minus the availability half, which collapses when every model is local.
    func testEachBadgeNamesTheModelItsStageRuns() {
        XCTAssertEqual(Mode.prompt.model(for: .transcription), Mode.prompt.stt.model)
        XCTAssertEqual(Mode.prompt.model(for: .refinement), Mode.prompt.llm.model)
    }

    /// Two stages, two glyphs. One symbol on both badges would say "two models" and nothing about
    /// what the second one does, which is the whole reason `ModeStage` is an enum.
    func testTheTwoStagesAreToldApartByTheirGlyph() {
        let symbols = ModeStage.allCases.map(\.symbolName)

        XCTAssertEqual(Set(symbols).count, ModeStage.allCases.count)
        XCTAssertFalse(symbols.contains { $0.isEmpty })
    }
}
