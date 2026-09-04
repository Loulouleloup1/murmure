import XCTest
@testable import MurmureCore

/// Every bound asserted here is a design promise from
/// `docs/benchmarks/2026-09-vocabulary-prompt.md`, never the constant under test -- a mutant that
/// changed `maximumTermCount` or `maximumCharacterCount` must still fail one of these.
final class VocabularyPromptTests: XCTestCase {
    /// Rule 4: nil rather than "". A prompt of empty string is not the same thing as no prompt.
    func testAnEmptyVocabularyBuildsNoPromptAtAll() {
        XCTAssertNil(VocabularyPrompt.build(from: []))
    }

    /// Rule 1, the single most valuable line measured: `" Claude Code."` repaired 50 of 60
    /// occurrences against 17 of 60 for `"Claude Code."` -- and did it in fewer tokens, because the
    /// tokenizer no longer cuts the leading term into character fragments.
    func testThePromptAlwaysStartsWithALeadingSpace() {
        let prompt = VocabularyPrompt.build(from: [VocabularyEntry(term: "Claude Code")])
        XCTAssertEqual(prompt?.first, " ")
    }

    /// Rule 4 continued, and the exact shape measured in §n03s: a comma-separated list ending on a
    /// full stop, never a sentence -- a sentence would put French grammar in the conditioning
    /// context alongside the words themselves. The filler word sits ahead of the single entry.
    func testASingleEntryBuildsASpaceThenTheTermThenAFullStop() {
        XCTAssertEqual(
            VocabularyPrompt.build(from: [VocabularyEntry(term: "Trucost")]), " Murmure, Trucost."
        )
    }

    /// Rule for `replacement ?? term`: the prompt is only ever allowed to contain correct
    /// spellings, so a mis-hearing on file must never reach it.
    func testAKnownMisHearingContributesItsCorrectionNeverTheMisHearingItself() {
        let prompt = VocabularyPrompt.build(from: [
            VocabularyEntry(term: "cloud code", replacement: "Claude Code"),
        ])
        XCTAssertEqual(prompt, " Murmure, Claude Code.")
        XCTAssertFalse((prompt ?? "").contains("cloud code"))
    }

    /// Rule 2: an entry with a `replacement` is one Louis has explicitly noticed coming out wrong,
    /// and it goes last, nearest the audio -- while a term with no `replacement` is pure bias and
    /// sorts first among the user's own terms, the filler word occupying the penalised slot ahead
    /// of it. Measured: on byte-identical prompt tokens, merely permuted, `WeeFin` repaired 1/10
    /// in first position against 10/10 anywhere else.
    func testEntriesWithAKnownCorrectionAreOrderedAfterThoseWithout() {
        let prompt = VocabularyPrompt.build(from: [
            VocabularyEntry(term: "Trucost", replacement: "Trucost"),
            VocabularyEntry(term: "WeeFin"),
        ])
        XCTAssertEqual(prompt, " Murmure, WeeFin, Trucost.")
    }

    /// Within each of the two groups the order is alphabetical, so the same vocabulary always
    /// builds the same prompt -- nothing here should depend on file order or dictionary iteration.
    func testWithinEachGroupTheOrderIsAlphabetical() {
        let prompt = VocabularyPrompt.build(from: [
            VocabularyEntry(term: "Zulu"),
            VocabularyEntry(term: "Alpha"),
            VocabularyEntry(term: "cloud code", replacement: "Claude Code"),
            VocabularyEntry(term: "Bravo", replacement: "Bravo"),
        ])
        XCTAssertEqual(prompt, " Murmure, Alpha, Zulu, Bravo, Claude Code.")
    }

    /// Rule 3: the note stays under 3 % of words up to ~20 terms, and doubles beyond it -- so the
    /// cap holds at exactly 20, not one more.
    func testExactlyTwentyTermsAreAllKept() {
        let entries = (1...20).map { VocabularyEntry(term: "Term\(String(format: "%02d", $0))") }
        let prompt = VocabularyPrompt.build(from: entries)
        for entry in entries {
            XCTAssertTrue((prompt ?? "").contains(entry.term), "missing \(entry.term)")
        }
    }

    /// Rule 3, and the mechanism from §6: WhisperKit itself truncates a prompt over budget with
    /// `Array(promptTokens.suffix(111))`, silently keeping the tail and dropping the front -- a
    /// 35-term list ordered with its best terms first repaired 0 of 106 where the same words,
    /// reordered, repaired 75. Our cap must therefore drop from the front the same way, so what
    /// survives is always what was placed last, nearest the audio, never what came first.
    func testBeyondTwentyTermsTheExcessIsDroppedFromTheFront() {
        let entries = (1...25).map { VocabularyEntry(term: "Term\(String(format: "%02d", $0))") }
        let prompt = VocabularyPrompt.build(from: entries) ?? ""
        XCTAssertFalse(prompt.contains("Term01"), "the earliest term must be the one dropped")
        XCTAssertTrue(prompt.contains("Term25"), "the term nearest the audio must survive")
        // 20 kept terms plus the filler word ahead of them: 20 commas, 21 comma-separated parts.
        XCTAssertEqual(prompt.components(separatedBy: ",").count, 21)
    }

    /// Rule 3's character cap: 240 characters is a PROXY for the ~70-token budget measured safe,
    /// not a token count run through Whisper's own tokenizer here.
    func testBeyondTwoHundredFortyCharactersTheExcessIsDroppedFromTheFront() {
        // Ten 30-character terms: comma-joined this well exceeds 240 characters before the count
        // cap of 20 could bind on its own, isolating the character cap.
        let entries = (1...10).map { index in
            VocabularyEntry(term: "Term\(index)" + String(repeating: "x", count: 25))
        }
        let prompt = VocabularyPrompt.build(from: entries) ?? ""
        XCTAssertLessThanOrEqual(prompt.count, 240)
        XCTAssertTrue(prompt.hasSuffix("x."), "the term nearest the audio must survive intact")
        XCTAssertFalse(prompt.contains("Term1x"), "the earliest term must be the one dropped")
    }

    /// Defect 1: `VocabularyStore` de-duplicates on `term`, a different key space than the one
    /// this type consumes (`replacement ?? term`) -- the most natural pair a user writes, the
    /// correct term plus one of its mis-hearings, therefore doubled the term in the prompt.
    func testADuplicateContributedFormIsCollapsedKeepingTheLastOccurrence() {
        let prompt = VocabularyPrompt.build(from: [
            VocabularyEntry(term: "Claude Code"),
            VocabularyEntry(term: "cloud code", replacement: "Claude Code"),
        ])
        XCTAssertEqual(prompt, " Murmure, Claude Code.")
    }

    /// Defect 2: the previous `while list.count > cap, let firstComma = ...` exited the instant no
    /// comma was left, WITHOUT its size condition being satisfied -- a two-entry list whose second
    /// entry alone exceeds the cap therefore returned uncapped.
    func testACapExceedingEntryIsDroppedWholeRatherThanCutMidWord() {
        let entries = [
            VocabularyEntry(term: "Alpha"),
            VocabularyEntry(term: String(repeating: "b", count: 400)),
        ]
        let prompt = VocabularyPrompt.build(from: entries) ?? ""
        XCTAssertLessThanOrEqual(prompt.count, VocabularyPrompt.maximumCharacterCount)
    }

    /// Defect 3: a cap that drops an entry must say so -- the type had no channel to name the
    /// loss otherwise, and a user's 21st term would stop guiding the recogniser in silence.
    func testEntriesDroppedByTheTermCapAreReportedInThePlan() {
        let entries = (1...25).map { VocabularyEntry(term: "Term\(String(format: "%02d", $0))") }
        let plan = VocabularyPrompt.plan(for: entries)
        XCTAssertEqual(plan.dropped.map(\.term), entries.prefix(5).map(\.term))
    }

    /// Defect 3 continued: a term merged into an identical contributed form is not "dropped" -- it
    /// is the same word, and reporting it as lost would be a lie the interface repeats to the user.
    func testADeduplicatedEntryIsNotReportedAsDropped() {
        let entries = [
            VocabularyEntry(term: "Claude Code"),
            VocabularyEntry(term: "cloud code", replacement: "Claude Code"),
        ]
        let plan = VocabularyPrompt.plan(for: entries)
        XCTAssertTrue(plan.dropped.isEmpty)
    }

    /// `build(from:)` and `plan(for:).prompt` must never disagree -- `build` is defined in terms
    /// of `plan` precisely so the two cannot drift apart.
    func testBuildAgreesWithPlan() {
        let entries = (1...25).map { VocabularyEntry(term: "Term\(String(format: "%02d", $0))") }
        XCTAssertEqual(VocabularyPrompt.build(from: entries), VocabularyPrompt.plan(for: entries).prompt)
    }

    /// Defect 4: the existing assertions (<= 240, ends on "x.", first term absent) are all true of
    /// a cap far smaller than 240 -- mutating `maximumCharacterCount` to 10, 40, 80, 120, 180, 239,
    /// 240 or 241 left every one of them green. Eight 30-character terms make the true
    /// 240-character budget keep exactly 7 of them; a materially smaller cap keeps fewer.
    func testTheCharacterCapKeepsSevenOfEightThirtyCharacterTerms() {
        let entries = (1...8).map { index in
            VocabularyEntry(term: "Term\(String(format: "%02d", index))" + String(repeating: "z", count: 24))
        }
        let prompt = VocabularyPrompt.build(from: entries) ?? ""
        let survivingCount = entries.filter { prompt.contains($0.term) }.count
        XCTAssertEqual(survivingCount, 7, "the 240-character cap must keep exactly 7 of 8 thirty-character terms")
    }

    /// Defect (follow-up): an entry that cannot fit under the character cap ON ITS OWN can never
    /// be part of any valid prompt -- it is not competing for the tail, it is simply unusable, and
    /// must not be allowed to push out entries that DO fit. Front-drop applied blindly did exactly
    /// that: `Alpha` fits with 235 characters to spare and was dropped anyway, chasing a
    /// 400-character term that could never fit regardless.
    func testAnOverlongEntryIsDroppedAloneLeavingTheRestOfThePromptIntact() {
        let overlong = VocabularyEntry(term: String(repeating: "b", count: 400))
        let plan = VocabularyPrompt.plan(for: [VocabularyEntry(term: "Alpha"), overlong])
        XCTAssertEqual(plan.prompt, " Murmure, Alpha.")
        XCTAssertEqual(plan.dropped, [overlong])
    }

    /// The other direction of the same boundary: when every entry is individually too long to
    /// ever fit, the prompt is nil -- and every single one of them is named in `dropped`, never a
    /// nil prompt with an empty `dropped`, which would be the silent truncation this plan exists
    /// to prevent.
    func testAVocabularyOfOnlyOverlongEntriesReturnsNilWithEveryEntryReportedDropped() {
        let entries = [
            VocabularyEntry(term: String(repeating: "a", count: 300)),
            VocabularyEntry(term: String(repeating: "b", count: 300)),
        ]
        let plan = VocabularyPrompt.plan(for: entries)
        XCTAssertNil(plan.prompt)
        XCTAssertEqual(Set(plan.dropped.map(\.term)), Set(entries.map(\.term)))
    }

    /// Landed measurement: prepending a filler word ahead of the ordered list raised repairs from
    /// 86 to 92 of 106 (`Claude Code` 49/60 -> 58/60) for 4 more tokens, the best result of the
    /// whole campaign -- and unconditionally, not only when the displaced term is bias-only, since
    /// the arm that measured it carried no `replacement` field at all.
    func testTheFillerWordSitsAheadOfEveryRealEntry() {
        let prompt = VocabularyPrompt.build(from: [
            VocabularyEntry(term: "cloud code", replacement: "Claude Code"),
            VocabularyEntry(term: "Trucost"),
            VocabularyEntry(term: "WeeFin"),
        ])
        XCTAssertEqual(prompt, " Murmure, Trucost, WeeFin, Claude Code.")
    }

    /// The filler is never named as a loss -- it was never a user entry to begin with.
    func testTheFillerWordIsNeverReportedAsDropped() {
        let entries = [VocabularyEntry(term: "Trucost"), VocabularyEntry(term: "WeeFin")]
        let plan = VocabularyPrompt.plan(for: entries)
        XCTAssertFalse(plan.dropped.contains { $0.term == "Murmure" })
    }

    /// The filler does not compete for the user's 20-term budget -- that cap is about the user's
    /// own entries, so all 20 must still be kept in full once the filler is prepended.
    func testTheFillerWordDoesNotCountAgainstTheTermCap() {
        let entries = (1...20).map { VocabularyEntry(term: "Term\(String(format: "%02d", $0))") }
        let prompt = VocabularyPrompt.build(from: entries) ?? ""
        for entry in entries {
            XCTAssertTrue(prompt.contains(entry.term), "missing \(entry.term)")
        }
        XCTAssertTrue(prompt.hasPrefix(" Murmure, "))
    }

    /// An empty vocabulary still returns nil -- a prompt of nothing but the filler word teaches
    /// the recogniser nothing and costs words for no reason.
    func testAnEmptyVocabularyStillBuildsNoPromptEvenWithTheFillerWord() {
        XCTAssertNil(VocabularyPrompt.build(from: []))
    }

    // MARK: - noticeText

    func testNoticeTextIsNilWhenNothingWasDropped() {
        let plan = VocabularyPrompt.plan(for: [VocabularyEntry(term: "Trucost")])
        XCTAssertNil(plan.noticeText)
    }

    /// A dropped bare term did nothing but bias the recogniser -- once out of the prompt it does
    /// nothing at all, so the sentence must not claim it still corrects the transcript.
    func testADroppedBareTermSaysOnlyThatItNoLongerGuidesTheRecogniser() {
        let entries = (1...25).map { VocabularyEntry(term: "Term\(String(format: "%02d", $0))") }
        let plan = VocabularyPrompt.plan(for: entries)

        let text = plan.noticeText ?? ""
        XCTAssertTrue(text.contains("no longer guide"), text)
        XCTAssertFalse(text.contains("still corrects the text"), text)
    }

    /// A dropped correction still finds and replaces in the transcript, whether or not it shaped
    /// what Whisper heard -- the sentence must say so, unlike the bare-term case above.
    func testADroppedCorrectionSaysItStillCorrectsTheTextAfterwards() {
        let entries = (1...25).map {
            VocabularyEntry(term: "Term\(String(format: "%02d", $0))", replacement: "Term\($0)")
        }
        let plan = VocabularyPrompt.plan(for: entries)

        let text = plan.noticeText ?? ""
        XCTAssertTrue(text.contains("still corrects the text afterwards"), text)
    }

    /// A cap that drops one of each kind must not pretend they lost the same thing -- two
    /// sentences, one true of each.
    func testACapThatDropsBothKindsProducesOneSentenceForEach() {
        let overlong1 = VocabularyEntry(term: String(repeating: "a", count: 300))
        let overlong2 = VocabularyEntry(
            term: String(repeating: "b", count: 300), replacement: String(repeating: "b", count: 300))
        let plan = VocabularyPrompt.plan(for: [overlong1, overlong2])

        let text = plan.noticeText ?? ""
        XCTAssertTrue(text.contains("no longer guides the recogniser."), text)
        XCTAssertTrue(text.contains("still corrects the text afterwards"), text)
    }

    /// Not scoped to either of the pane's two groups: `replacement ?? term` is what reaches the
    /// prompt, so a correction costs a slot exactly like a bare term, and a single dropped
    /// correction is named just as plainly as a single dropped bare term.
    func testASingleDroppedCorrectionIsNamedInTheNotice() {
        let overlong = VocabularyEntry(
            term: String(repeating: "b", count: 300), replacement: String(repeating: "b", count: 300))
        let plan = VocabularyPrompt.plan(for: [VocabularyEntry(term: "Alpha"), overlong])

        XCTAssertEqual(plan.dropped, [overlong])
        XCTAssertTrue((plan.noticeText ?? "").contains(overlong.term), plan.noticeText ?? "")
    }

    // MARK: - budgetLine(totalEntries:) -- the pane-level line below the problem banner / cap notice

    /// A vocabulary with nothing in it has no budget to report -- shown beside an already-empty
    /// pane, "0 of 0 reach the recogniser" would be noise, not information.
    func testBudgetLineIsNilForAnEmptyVocabulary() {
        let plan = VocabularyPrompt.plan(for: [])
        XCTAssertNil(plan.budgetLine(totalEntries: 0))
    }

    /// The common day: nothing dropped, and the line still says so, briefly -- it is a standing
    /// readout of a real feature, not a message that only ever appears to report a problem.
    func testBudgetLineSaysAllTermsReachWhenNothingIsDropped() {
        let entries = (1...16).map { VocabularyEntry(term: "Term\(String(format: "%02d", $0))") }
        let plan = VocabularyPrompt.plan(for: entries)

        XCTAssertEqual(
            plan.budgetLine(totalEntries: entries.count), "All 16 terms reach the recogniser.")
    }

    /// Singular grammar for the one-entry vocabulary, not "All 1 terms reach".
    func testBudgetLineUsesSingularWordingForOneEntryNoneDropped() {
        let entries = [VocabularyEntry(term: "Trucost")]
        let plan = VocabularyPrompt.plan(for: entries)

        XCTAssertEqual(
            plan.budgetLine(totalEntries: entries.count), "All 1 term reaches the recogniser.")
    }

    /// Once the cap bites, the line reports the counts on both sides of it -- kept and dropped --
    /// rather than the named list `noticeText` already carries. No noun on the dropped count: it
    /// is always a count of terms, already said once earlier in the same sentence.
    func testBudgetLineReportsKeptAndDroppedCountsWhenTheCapBites() {
        let entries = (1...25).map { VocabularyEntry(term: "Term\(String(format: "%02d", $0))") }
        let plan = VocabularyPrompt.plan(for: entries)

        XCTAssertEqual(plan.dropped.count, 5)
        XCTAssertEqual(
            plan.budgetLine(totalEntries: entries.count),
            "20 of 25 terms reach the recogniser -- 5 dropped by the cap.")
    }

    /// The verb agrees with how many REACH (singular when exactly one survives), independently
    /// of how many the vocabulary held in total -- a 2-term vocabulary reduced to 1 survivor says
    /// "reaches", even though "2 terms" (the total) stays plural.
    func testBudgetLineSingularisesTheVerbWhenExactlyOneTermReaches() {
        let overlong = VocabularyEntry(term: String(repeating: "b", count: 300))
        let entries = [VocabularyEntry(term: "Alpha"), overlong]
        let plan = VocabularyPrompt.plan(for: entries)

        XCTAssertEqual(plan.dropped, [overlong])
        XCTAssertEqual(
            plan.budgetLine(totalEntries: entries.count),
            "1 of 2 terms reaches the recogniser -- 1 dropped by the cap.")
    }

    /// The noun agrees with the TOTAL independently of the verb: a one-term vocabulary that drops
    /// its only entry says "term", not "terms", even though what reaches is zero -- "reach"
    /// stays plural (zero is not "one"), so the sentence pairs a plural verb with a singular noun.
    func testBudgetLineSingularisesTheNounWhenTheVocabularyHoldsExactlyOneTerm() {
        let overlong = VocabularyEntry(term: String(repeating: "b", count: 300))
        let plan = VocabularyPrompt.plan(for: [overlong])

        XCTAssertEqual(plan.dropped, [overlong])
        XCTAssertEqual(
            plan.budgetLine(totalEntries: 1),
            "0 of 1 term reach the recogniser -- 1 dropped by the cap.")
    }
}
