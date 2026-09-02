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

    /// Louis, looking at a row his Prompt mode refined: *"pour le language model, je trouve ça
    /// assez étrange... Pourquoi est-ce qu'on a le lien du modèle et pas juste le nom ? Un peu
    /// plus classique, un peu plus joli à regarder."*
    ///
    /// What was shown was the stored identifier verbatim, registry path and all. The stored value
    /// does not move -- it is what makes the row reproducible -- and the row shows the name.
    func testTheLanguageModelRowNamesTheModelRatherThanWhereItWasPulledFrom() {
        let rows = HistoryDetail.metadata(
            for: record(refined: "Il faut brancher.",
                        llmModel: "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M",
                        refinementSeconds: 0.38),
            calendar: paris)

        XCTAssertEqual(rows.first { $0.label == "Language model" }?.value, "s1-mini-GGUF:Q4_K_M")
    }

    /// Louis again: *"la distinction entre le RAW et le raffiné n'apparaît pas tout le temps... je
    /// ne sais pas trop comment ça se fait."*
    ///
    /// It is correct and it is invisible. D6 stores no `refinedText` when the refinement changed
    /// nothing, so there is no second version and D11 hides the switch -- but from the outside a
    /// control that comes and goes reads as a defect. The block says the thing the missing switch
    /// cannot.
    func testARefinementThatChangedNothingSaysSoWhereTheLensWouldHaveBeen() {
        let unchanged = record(refined: nil, llmModel: "s1-mini", refinementSeconds: 0.38)

        XCTAssertEqual(HistoryDetail.lenses(for: unchanged), [], "nothing to switch to")
        XCTAssertEqual(
            HistoryDetail.metadata(for: unchanged, calendar: paris)
                .first { $0.label == "Refinement" }?.value,
            "ran, no change to show")
    }

    // MARK: - The four cases behind a missing lens

    /// **Case one: the mode does not refine.** Nothing is said, because the block already says
    /// it by not carrying a `Language model` row — and D6's rule at the surface is that an absent
    /// column yields no row rather than a row denying itself.
    func testAModeThatNeverRefinesExplainsItselfByHavingNoLanguageModelRow() {
        let voice = record(llmModel: nil)
        let labels = HistoryDetail.metadata(for: voice, calendar: paris).map(\.label)

        XCTAssertNil(HistoryDetail.refinementNote(for: voice))
        XCTAssertFalse(labels.contains("Refinement"))
        XCTAssertFalse(labels.contains("Language model"))
    }

    /// **Case two: a refiner the dictation never reached** — cancelled, or the run stopped short.
    /// Said, because a `Language model` row with no `Refined in` beside it otherwise leaves the
    /// reader to guess which of the two facts is the missing one.
    func testARefinerThatWasNeverCalledSaysSo() {
        XCTAssertEqual(
            HistoryDetail.refinementNote(
                for: record(refined: nil, llmModel: "s1-mini", refinementSeconds: nil)),
            "did not run")
    }

    /// **Case three: it ran and there is no second version.** The case Louis hit, and the whole
    /// reason for the row.
    func testARefinerThatRanAndChangedNothingSaysSo() {
        XCTAssertEqual(
            HistoryDetail.refinementNote(
                for: record(refined: nil, llmModel: "s1-mini", refinementSeconds: 0.38)),
            "ran, no change to show")
    }

    /// **Case four: it ran and there is something to switch to.** Silent — the switch is on
    /// screen, and a row announcing that the refinement changed the text would only repeat what
    /// the reader is already looking at.
    func testARefinementWithSomethingToShowSaysNothingBecauseTheSwitchIsThere() {
        let refined = record(refined: "Il faut brancher le connecteur.",
                             llmModel: "s1-mini", refinementSeconds: 0.38)

        XCTAssertEqual(HistoryDetail.lenses(for: refined), [.raw, .refined])
        XCTAssertNil(HistoryDetail.refinementNote(for: refined))
    }

    /// The one that would have been a fifth case and is not: a refinement that changed only the
    /// edges. D11 hides its switch by the same rule, so it needs the same sentence — which is why
    /// the note is keyed off `lenses` rather than off `refinedText`, and why it says "no change to
    /// show" rather than "changed nothing". A trailing newline did change the text.
    func testARefinementThatChangedOnlyTheEdgesGetsTheSameSentenceAndNotAFifthOne() {
        XCTAssertEqual(
            HistoryDetail.refinementNote(
                for: record(raw: "  bonjour   Murmure\n", refined: "bonjour   Murmure",
                            llmModel: "s1-mini", refinementSeconds: 0.38)),
            "ran, no change to show")
    }

    /// Silent when there is no transcript to compare against. On a purged row the text is visibly
    /// gone and the missing switch needs no other explanation — and once both texts are NULL the
    /// two refinement cases cannot be told apart anyway, so any sentence here would be a guess.
    func testARowWhoseTextIsGoneMakesNoClaimAboutItsRefinement() {
        XCTAssertNil(
            HistoryDetail.refinementNote(
                for: record(raw: nil, refined: nil, llmModel: "s1-mini",
                            refinementSeconds: 0.38)))
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
