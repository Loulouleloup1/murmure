import XCTest
@testable import MurmureCore

/// The right-hand pane: which lenses a record offers, and the metadata rows under them.
///
/// Every transcript below is invented.
final class HistoryDetailTests: XCTestCase {
    private let paris: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.locale = HistoryGrouping.locale
        return calendar
    }()

    private func record(
        raw: String? = "euh il faut brancher le connecteur",
        refined: String? = nil,
        llmModel: String? = nil,
        outcome: DictationOutcome = .inserted,
        appName: String? = "Zed",
        bundleID: String? = "dev.zed.Zed",
        transcriptionSeconds: Double? = nil,
        refinementSeconds: Double? = nil,
        insertedCharacters: Int = 30,
        failure: String? = nil
    ) -> HistoryRecord {
        HistoryRecord(
            startedAt: HistoryTimestamp.date(from: "2026-09-01T12:42:03.123Z") ?? .distantPast,
            durationSeconds: 38, outcome: outcome, modeKey: "prompt", modeName: "Prompt",
            sttModel: "large-v3-turbo", llmModel: llmModel, rawTranscript: raw,
            refinedText: refined, insertedCharacters: insertedCharacters,
            targetBundleID: bundleID, targetAppName: appName,
            transcriptionSeconds: transcriptionSeconds, refinementSeconds: refinementSeconds,
            failureMessage: failure)
    }

    // MARK: - Which lens a record offers

    /// D11: a record whose mode had no refiner shows **no switch at all**, not a disabled one. A
    /// control that cannot be operated is a control that has to be explained.
    func testAnUnrefinedDictationOffersNoLens() {
        XCTAssertEqual(HistoryDetail.lenses(for: record()), [])
    }

    func testARefinedDictationOffersBothLenses() {
        XCTAssertEqual(
            HistoryDetail.lenses(
                for: record(raw: "euh il faut brancher le connecteur",
                            refined: "Il faut brancher le connecteur.")),
            [.raw, .refined])
    }

    /// **The one-invisible-character trap, and the reason this rule is split from the storage
    /// rule.** `OllamaChat.verdict(on:)` trims the model's answer while the transcript reaches
    /// storage byte for byte -- lot 1 pins that deliberately, and its fixture is literally
    /// `"  bonjour   Murmure\n"`. So a refinement that changed nothing but the edges stores a
    /// `refinedText` that differs only in characters nobody can see, and a naive rule offers a
    /// switch between two panes that look identical.
    func testARefinementThatDiffersOnlyAtTheEdgesOffersNoLens() {
        XCTAssertEqual(
            HistoryDetail.lenses(
                for: record(raw: "  bonjour   Murmure\n", refined: "bonjour   Murmure")),
            [])
    }

    /// The other half of that split, stated as its own test because it is the half that is easy to
    /// lose: **what is OFFERED is decided trimmed, what is STORED is compared exactly.** T4 keeps
    /// the stored text byte for byte, and this row still carries both texts.
    func testTheStoredTextsAreUntouchedByTheRuleThatHidesTheLens() {
        let stored = record(raw: "  bonjour   Murmure\n", refined: "bonjour   Murmure")
        XCTAssertEqual(HistoryDetail.lenses(for: stored), [])
        XCTAssertEqual(stored.rawTranscript, "  bonjour   Murmure\n")
        XCTAssertEqual(stored.refinedText, "bonjour   Murmure")
    }

    /// Only the EDGES are ignored. A refinement that collapsed a run of spaces inside the sentence
    /// did change the text -- invisibly to a glance, really to the file -- and the lens is offered
    /// for it. This is why the rule trims rather than collapsing.
    func testARefinementThatChangedTheInsideOfTheSentenceStillOffersTheLens() {
        XCTAssertEqual(
            HistoryDetail.lenses(
                for: record(raw: "bonjour   Murmure", refined: "bonjour Murmure")),
            [.raw, .refined])
    }

    /// Nothing to switch between: there is a refinement and no transcript to compare it against,
    /// which is a row a hand or an older version could write.
    func testARecordWithNoRawTranscriptOffersNoLens() {
        XCTAssertEqual(
            HistoryDetail.lenses(for: record(raw: nil, refined: "Il faut brancher.")), [])
    }

    /// The pane opens on what was pasted, switch or no switch.
    func testThePaneOpensOnTheRefinedTextWhenThereIsOne() {
        let refined = record(raw: "euh il faut brancher", refined: "Il faut brancher.")
        XCTAssertEqual(HistoryDetail.defaultLens(for: refined), .refined)
        XCTAssertEqual(HistoryDetail.text(HistoryDetail.defaultLens(for: refined), of: refined),
                       "Il faut brancher.")

        let plain = record()
        XCTAssertEqual(HistoryDetail.defaultLens(for: plain), .raw)
        XCTAssertEqual(HistoryDetail.text(HistoryDetail.defaultLens(for: plain), of: plain),
                       "euh il faut brancher le connecteur")
    }

    /// A lens over a text that is not there answers nil rather than an empty string, which is D6
    /// followed to the surface: absent and empty are different things.
    func testALensOverATextThatIsNotThereAnswersNothing() {
        XCTAssertNil(HistoryDetail.text(.refined, of: record()))
        XCTAssertNil(HistoryDetail.text(.raw, of: record(raw: nil)))
    }

    // MARK: - Process again (D12)

    func testProcessAgainNeedsARawTranscriptToReRefine() {
        XCTAssertTrue(HistoryDetail.canProcessAgain(record()))
        XCTAssertFalse(HistoryDetail.canProcessAgain(record(raw: nil)))
        XCTAssertFalse(HistoryDetail.canProcessAgain(record(raw: "   \n")))
    }

    // MARK: - The metadata block

    /// **The row that must not exist.** A `Voice` dictation never had a language model, and
    /// `Language model —` would say the opposite of the truth about it. D6 followed to the
    /// surface: a NULL column yields no row at all, not an empty one.
    func testARecordWithNoLanguageModelYieldsNoLanguageModelRow() {
        let labels = HistoryDetail.metadata(for: record(), calendar: paris).map(\.label)
        XCTAssertFalse(labels.contains("Language model"))
        XCTAssertTrue(labels.contains("Speech model"))
    }

    func testARefinedRecordNamesTheLanguageModelThatDidIt() {
        let rows = HistoryDetail.metadata(
            for: record(refined: "Il faut brancher.", llmModel: "s1-mini"), calendar: paris)
        XCTAssertEqual(rows.first { $0.label == "Language model" }?.value, "s1-mini")
    }

    /// The mode by NAME, which is the denormalised column §5.2 argued for: a row that could only
    /// say `modeKey = "prompt"` for a file that has since been renamed is a row that cannot be
    /// read.
    func testTheModeIsNamedRatherThanKeyed() {
        let rows = HistoryDetail.metadata(for: record(), calendar: paris)
        XCTAssertEqual(rows.first { $0.label == "Mode" }?.value, "Prompt")
    }

    /// `targetAppName` is what Louis recognises; the bundle identifier is the fallback for an
    /// application that had no localised name, and it is better than nothing because it still
    /// names the app. Neither, and the row goes.
    func testTheApplicationFallsBackToItsBundleIdentifierAndThenDisappears() {
        XCTAssertEqual(
            HistoryDetail.metadata(for: record(), calendar: paris)
                .first { $0.label == "Application" }?.value,
            "Zed")
        XCTAssertEqual(
            HistoryDetail.metadata(for: record(appName: nil), calendar: paris)
                .first { $0.label == "Application" }?.value,
            "dev.zed.Zed")
        XCTAssertNil(
            HistoryDetail.metadata(for: record(appName: nil, bundleID: nil), calendar: paris)
                .first { $0.label == "Application" })
    }

    /// The timings are rows only when they happened. A dictation that never reached the refiner
    /// has no refinement to have taken time.
    func testTheTimingsAppearOnlyWhenTheyHappened() {
        let bare = HistoryDetail.metadata(for: record(), calendar: paris).map(\.label)
        XCTAssertFalse(bare.contains("Transcribed in"))
        XCTAssertFalse(bare.contains("Refined in"))

        let timed = HistoryDetail.metadata(
            for: record(transcriptionSeconds: 2.14, refinementSeconds: 0.38), calendar: paris)
        XCTAssertEqual(timed.first { $0.label == "Transcribed in" }?.value, "2.1 s")
        XCTAssertEqual(timed.first { $0.label == "Refined in" }?.value, "0.4 s")
    }

    /// "Inserted 0 characters" reads as a measurement of a thing that did not happen -- the same
    /// distinction `StatusPanelText` draws between a completion and `nothingHeard`.
    func testTheInsertedCountAppearsOnlyOnADictationThatInsertedSomething() {
        XCTAssertEqual(
            HistoryDetail.metadata(for: record(insertedCharacters: 30), calendar: paris)
                .first { $0.label == "Inserted" }?.value,
            "30 characters")
        XCTAssertEqual(
            HistoryDetail.metadata(for: record(insertedCharacters: 1), calendar: paris)
                .first { $0.label == "Inserted" }?.value,
            "1 character")
        XCTAssertNil(
            HistoryDetail.metadata(
                for: record(outcome: .cancelled, insertedCharacters: 0), calendar: paris
            ).first { $0.label == "Inserted" })
    }

    /// A failed dictation is a readable row rather than a row that merely says it failed (§5.2),
    /// and the message is collapsed for the same reason the preview is.
    func testAFailedRecordCarriesItsMessageAsARow() {
        XCTAssertEqual(
            HistoryDetail.metadata(
                for: record(outcome: .failed, failure: "Ollama is not running\non port 11434"),
                calendar: paris
            ).first { $0.label == "Failure" }?.value,
            "Ollama is not running on port 11434")
    }

    /// D9 priced this block at "about six rows, which fits under the transcript" -- that is what
    /// makes it a block rather than the doc corpus's third pane. A typical row stays inside it.
    func testATypicalRecordYieldsABlockThatFitsUnderTheTranscript() {
        let rows = HistoryDetail.metadata(
            for: record(refined: "Il faut brancher.", llmModel: "s1-mini",
                        transcriptionSeconds: 2.14, refinementSeconds: 0.38),
            calendar: paris)
        XCTAssertLessThanOrEqual(rows.count, 9)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "labels identify rows, so they differ")
    }
}
