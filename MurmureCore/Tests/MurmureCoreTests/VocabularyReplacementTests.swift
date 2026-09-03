import XCTest
@testable import MurmureCore

/// The find→replace pass, pinned against the three rules `VocabularyReplacement`'s doc comment
/// argues for: case-insensitive matching with an authoritative replacement, a word-boundary rule
/// stated rather than discovered, and a single non-cascading pass.
final class VocabularyReplacementTests: XCTestCase {
    private func apply(_ text: String, _ entries: [VocabularyEntry]) -> String {
        VocabularyReplacement.apply(to: text, using: entries)
    }

    // MARK: - No-ops

    /// Nothing to search, nothing to search with, or a term that never occurs -- three different
    /// reasons to return the input untouched, all of them a no-op rather than a crash.
    func testEmptyTextEmptyEntriesAndAnAbsentTermAreAllNoOps() {
        XCTAssertEqual(apply("", [VocabularyEntry(term: "cloud code", replacement: "Claude Code")]), "")
        XCTAssertEqual(apply("open cloud code now", []), "open cloud code now")
        XCTAssertEqual(
            apply("nothing here matches", [VocabularyEntry(term: "cloud code", replacement: "Claude Code")]),
            "nothing here matches")
    }

    /// An entry with no `replacement` names a term that is already spelled correctly -- it exists
    /// only to bias the recogniser's prompt (`VocabularyPrompt`), not to rewrite anything here.
    func testATermWithNoReplacementContributesNothing() {
        XCTAssertEqual(
            apply("ask Claude Code to fix it", [VocabularyEntry(term: "Claude Code")]),
            "ask Claude Code to fix it")
    }

    // MARK: - Case-insensitive matching, authoritative replacement casing

    /// `cloud code` and `Cloud Code` are the same mis-hearing; both become exactly what the user
    /// wrote as the replacement, not a case-adjusted echo of what matched.
    func testMatchingIsCaseInsensitiveAndTheReplacementKeepsItsOwnCasing() {
        let entries = [VocabularyEntry(term: "cloud code", replacement: "Claude Code")]
        XCTAssertEqual(apply("open cloud code please", entries), "open Claude Code please")
        XCTAssertEqual(apply("open Cloud Code please", entries), "open Claude Code please")
        XCTAssertEqual(apply("open CLOUD CODE please", entries), "open Claude Code please")
    }

    // MARK: - Word boundary

    /// **The rule this test pins:** a term matches only where the character immediately before and
    /// immediately after it is not a Unicode letter or number. `DCG` fires standing alone but not
    /// as a run inside `ADCGX` -- `A` and `X` are letters.
    func testATermDoesNotFireInsideALongerWord() {
        let entries = [VocabularyEntry(term: "DCG", replacement: "DCG (fixed)")]
        XCTAssertEqual(apply("the DCG file", entries), "the DCG (fixed) file")
        XCTAssertEqual(apply("ADCGX has nothing to do with it", entries), "ADCGX has nothing to do with it")
    }

    /// A term may itself contain a space. The boundary check looks only at the two characters
    /// flanking the WHOLE term, never at the space inside it -- so `cloud code` matches on its own
    /// but not as the head of `cloud coder`, because the character right after it is `r`, a letter.
    func testAMultiWordTermRespectsTheBoundaryAtItsOwnEdgesOnly() {
        let entries = [VocabularyEntry(term: "cloud code", replacement: "Claude Code")]
        XCTAssertEqual(apply("open cloud code now", entries), "open Claude Code now")
        XCTAssertEqual(apply("the cloud coder disagrees", entries), "the cloud coder disagrees")
    }

    /// A French elision: the apostrophe is punctuation, not a letter, so it already reads as a
    /// boundary -- the same reading a human proofreader would give it.
    func testAnApostropheCountsAsABoundary() {
        let entries = [VocabularyEntry(term: "code", replacement: "CODE")]
        XCTAssertEqual(apply("l'code marche", entries), "l'CODE marche")
    }

    // MARK: - No cascade

    /// **The property most likely to be got wrong.** `"cloud code" → "Claude Code"` and
    /// `"Code" → "CODE"`, run against a naive `for entry in entries { text = text.replacing(...) }`
    /// loop, give different output depending on which entry runs first: entry 1 turns `code` into
    /// `Code`, and entry 2 -- reading that OUTPUT -- then turns it into `CODE`; run the other way,
    /// entry 2 finds no bare `Code` in the original text at all. Measured directly against that
    /// naive loop before this test was written: order A gave `"open Claude CODE now"`, order B gave
    /// `"open Claude Code now"` -- a real, observed disagreement, not a hypothetical one. Every
    /// entry here must be matched against the ORIGINAL text, so both orders give the same answer.
    func testNoReplacementCascadesIntoAnothersOutputRegardlessOfEntryOrder() {
        let forward = [
            VocabularyEntry(term: "cloud code", replacement: "Claude Code"),
            VocabularyEntry(term: "Code", replacement: "CODE"),
        ]
        let reversed = Array(forward.reversed())

        let outputForward = apply("open cloud code now", forward)
        let outputReversed = apply("open cloud code now", reversed)

        XCTAssertEqual(outputForward, outputReversed)
        // Pinned to the single correct reading: `cloud code` is consumed whole by the longer,
        // earlier-ending match before the bare `Code` entry ever gets a chance at the leftover `e`
        // of "code" -- there is none, since the whole span is already spoken for.
        XCTAssertEqual(outputForward, "open Claude Code now")
    }

    /// A second pair, independent of the first, isolating that ordering has no effect even when
    /// both entries could in principle match the same word.
    func testOrderOfIndependentEntriesNeverChangesTheResult() {
        let entriesA = [
            VocabularyEntry(term: "vertex ai", replacement: "Vertex AI"),
            VocabularyEntry(term: "gpt", replacement: "GPT"),
        ]
        let entriesB = Array(entriesA.reversed())
        let text = "compare vertex ai against gpt today"

        XCTAssertEqual(apply(text, entriesA), apply(text, entriesB))
        XCTAssertEqual(apply(text, entriesA), "compare Vertex AI against GPT today")
    }

    // MARK: - Unicode safety (NSRange vs. String.Index)

    /// `é` is one Swift `Character` but the boundary regex and the range arithmetic run through
    /// `NSString`/`NSRange`, which count UTF-16 code units -- this must not crash or mis-slice.
    func testAnAccentedWordAroundTheMatchIsHandledCorrectly() {
        let entries = [VocabularyEntry(term: "DCG", replacement: "Data Catalog Global")]
        XCTAssertEqual(
            apply("le référentiel DCG est à jour", entries),
            "le référentiel Data Catalog Global est à jour")
    }

    /// An emoji is one `Character` but several UTF-16 units (a surrogate pair, sometimes more with
    /// a variation selector) -- the same crash risk `NSRange` poses for `é`, sharper.
    func testAnEmojiAroundTheMatchIsHandledCorrectly() {
        let entries = [VocabularyEntry(term: "cloud code", replacement: "Claude Code")]
        XCTAssertEqual(apply("🚀 cloud code 🚀", entries), "🚀 Claude Code 🚀")
    }

    // MARK: - Combining marks (Defect C)

    /// **Defect C, direction 1.** The boundary class `[\p{L}\p{N}]` omits `\p{M}`, so a combining
    /// mark reads as a boundary where it is not one. `café` decomposed to NFD is the letters
    /// `c a f e` followed by a COMBINING ACUTE ACCENT (U+0301) -- a different word from `cafe`, one
    /// character longer. Before the fix, the mark after `cafe` counts as "not a letter," so `cafe`
    /// matches INSIDE `café` and corrupts it into `COFFEÉ` (the mark now dangling off `COFFEE`'s
    /// `E`). The base string content is built from scalars, not a literal, so this is exactly the
    /// same code point sequence a macOS filename would hand the app, not a hypothetical.
    func testACombiningMarkDoesNotReadAsABoundarySoATermDoesNotFireInsideADecomposedWord() {
        let nfdCafe = "café".decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(
            Array(nfdCafe.utf16), Array("café".utf16),
            "fixture must actually be decomposed, or this test proves nothing")

        let entries = [VocabularyEntry(term: "cafe", replacement: "COFFEE")]
        let text = "le \(nfdCafe) est chaud"

        XCTAssertEqual(apply(text, entries), text, "\"cafe\" must not match inside the longer word \"café\"")
    }

    /// **Defect C, direction 2.** Neither side of the match normalizes today, so a term copied out
    /// of a macOS filename in NFD form fails to match an NFC transcript byte-for-byte -- 0 matches,
    /// no signal, the correction silently never fires. Swift's `String ==` treats NFD and NFC as
    /// canonically equal, which is exactly why a test must check the UTF-16 units directly to prove
    /// the fixture is genuinely decomposed before trusting the behavioural assertion below.
    func testATermWrittenInDecomposedUnicodeStillMatchesAPrecomposedTranscript() {
        let nfcReferentiel = "référentiel"
        let nfdReferentiel = nfcReferentiel.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(
            Array(nfdReferentiel.utf16), Array(nfcReferentiel.utf16),
            "fixture must actually be decomposed, or this test proves nothing")

        let entries = [VocabularyEntry(term: nfdReferentiel, replacement: "REFERENTIEL")]

        XCTAssertEqual(
            apply("voir le \(nfcReferentiel) maintenant", entries),
            "voir le REFERENTIEL maintenant")
    }

    // MARK: - Unusable terms (Defect F)

    /// **Defect F.** Defect E's normalization strips `""`, whitespace-only, and `"\n"` down to nil
    /// before they ever reach the matcher -- all three are Unicode whitespace, trimmed away. A lone
    /// combining mark is not whitespace, though, so it survives as a one-character term. It still
    /// never matches real text: a mark always attaches to a preceding base character, so its
    /// neighbour is a letter, which fails the very boundary rule Defect C fixed. That is a correct
    /// empty result flowing through the normal matching path, not a swallowed regex-compile error.
    func testATermThatIsOnlyACombiningMarkSurvivesNormalizationButNeverMatchesRealText() {
        let entries = [VocabularyEntry(term: "\u{0301}", replacement: "X")]
        XCTAssertEqual(apply("café", entries), "café")
    }

    // MARK: - Normalization cannot be bypassed (Defect E)

    /// An entry built directly (a settings pane, never touching `VocabularyStore`) with
    /// `replacement: ""` must not reach the matcher literally -- "replace with nothing" would erase
    /// the matched term from the transcript, when an empty field means "no correction."
    func testAnEntryBuiltDirectlyWithAnEmptyReplacementDoesNotEraseTheMatchedTerm() {
        let entries = [VocabularyEntry(term: "cloud code", replacement: "")]
        XCTAssertEqual(apply("open cloud code now", entries), "open cloud code now")
    }

    /// An entry built directly with an untrimmed term must still match -- the store's trimming is
    /// not the only path an entry can take to reach `apply`.
    func testAnEntryBuiltDirectlyWithAnUntrimmedTermStillMatches() {
        let entries = [VocabularyEntry(term: "  cloud code  ", replacement: "Claude Code")]
        XCTAssertEqual(apply("open cloud code now", entries), "open Claude Code now")
    }

    // MARK: - Deterministic tie-break (Defect D)

    /// Two entries whose terms are case-variants of the same word (`gpt` and `GPT`) can produce a
    /// match tied on BOTH position and length -- `_resolveOverlaps` had no criterion left, so the
    /// entries' array order decided, contradicting the doc comment's unqualified promise that order
    /// never affects the result. The tie-break must be total: same answer regardless of which entry
    /// came first in the array.
    func testATrueTieInPositionAndLengthResolvesTheSameRegardlessOfEntryOrder() {
        let forward = [
            VocabularyEntry(term: "gpt", replacement: "GPT"),
            VocabularyEntry(term: "GPT", replacement: "ChatGPT"),
        ]
        let reversed = Array(forward.reversed())
        let text = "use gpt now"

        XCTAssertEqual(apply(text, forward), apply(text, reversed))
    }

    // MARK: - Output normalization is unconditional

    /// `apply`'s contract (its own doc comment) is that the returned text is ALWAYS NFC, whether or
    /// not any entry matched -- otherwise the same NFD dictation comes back as NFC on a run where
    /// an unrelated word happens to fire and as untouched NFD on a run where nothing does: two
    /// different byte sequences archived for the same transcript, depending on something the caller
    /// cannot predict. Checked on unicode scalars, not `String` equality: NFC and NFD compare EQUAL
    /// under Swift's `==` (canonical equivalence), which is exactly the gap that let output
    /// normalization depend on whether the matcher happened to fire go unnoticed.
    func testTheOutputsNormalizationDoesNotDependOnWhetherAnUnrelatedEntryMatched() {
        let nfdText = "le cafe\u{0301} ouvre cloud code"
        let firing = [VocabularyEntry(term: "cloud code", replacement: "Claude Code")]
        let notFiring = [VocabularyEntry(term: "does not occur", replacement: "NOPE")]

        let combiningAcuteAccent = Unicode.Scalar(0x0301)!
        XCTAssertFalse(apply(nfdText, notFiring).unicodeScalars.contains(combiningAcuteAccent))
        XCTAssertFalse(apply(nfdText, firing).unicodeScalars.contains(combiningAcuteAccent))
    }
}
