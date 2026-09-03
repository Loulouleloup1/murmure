import XCTest
@testable import MurmureCore

/// The two lines of a row: the transcript preview, the timestamp, and the duration.
///
/// Every transcript below is invented. They are written in the register Louis actually dictates --
/// French sentences carrying English technical terms -- because that is the string the truncation
/// and the collapsing have to survive, and because a rule tested on `"hello world"` proves nothing
/// about a line that has to stay legible at 13 pt.
final class HistoryRowTests: XCTestCase {
    private let paris: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.locale = HistoryGrouping.locale
        return calendar
    }()

    private func record(
        raw: String? = nil, refined: String? = nil, outcome: DictationOutcome = .inserted,
        failure: String? = nil
    ) -> HistoryRecord {
        HistoryRecord(
            startedAt: HistoryTimestamp.date(from: "2026-09-01T12:42:03.123Z") ?? .distantPast,
            durationSeconds: 38, outcome: outcome, modeKey: "voice", modeName: "Voice",
            sttModel: "large-v3-turbo", rawTranscript: raw, refinedText: refined,
            failureMessage: failure)
    }

    // MARK: - The preview

    func testThePreviewIsTheTranscriptWhenThereIsNoRefinement() {
        XCTAssertEqual(
            HistoryRow.preview(for: record(raw: "il faut brancher le connecteur sur le staging")),
            "il faut brancher le connecteur sur le staging")
    }

    /// The refined text, because that is what was pasted and therefore what Louis will recognise
    /// when he scans the list for the dictation he is looking for.
    func testThePreviewPrefersTheRefinedTextOverTheRawTranscript() {
        XCTAssertEqual(
            HistoryRow.preview(
                for: record(raw: "euh il faut brancher le connecteur",
                            refined: "Il faut brancher le connecteur.")),
            "Il faut brancher le connecteur.")
    }

    /// A refiner asked for bullet points returns newlines. In a single-line row everything after
    /// the first one is invisible with no sign that it existed -- which is the defect
    /// `StatusPanelText.oneLine` was written for, and this is that rule reused rather than a
    /// second one invented.
    func testThePreviewCollapsesNewlinesAndRunsOfSpacesToSingleSpaces() {
        XCTAssertEqual(
            HistoryRow.preview(for: record(raw: "  premier point\n\n  second   point\t\n")),
            "premier point second point")
    }

    /// Truncated at the tail -- the beginning of a dictation is what identifies it -- and at a
    /// word boundary, so the ellipsis never lands in the middle of `endpoi…`.
    func testALongTranscriptIsTruncatedAtTheTailOnAWordBoundary() {
        let long = String(repeating: "connecteur ", count: 40)
        let preview = HistoryRow.preview(for: record(raw: long))
        XCTAssertTrue(preview.hasSuffix("…"), "the tail is what gets dropped: \(preview)")
        XCTAssertLessThanOrEqual(preview.count, HistoryRow.previewLimit + 1)
        XCTAssertTrue(
            preview.hasPrefix("connecteur connecteur"), "the head is what survives: \(preview)")
        XCTAssertFalse(
            preview.contains("connect…"), "the cut lands between words, not inside one")
    }

    func testATranscriptShorterThanTheLimitIsNotTouched() {
        let short = "on rebranche le connecteur"
        XCTAssertEqual(HistoryRow.preview(for: record(raw: short)), short)
    }

    /// A row with no text still has to say what it is: the transcript is the identity of a row, so
    /// when there is none the outcome is. `inserted` is the case that looks impossible and becomes
    /// the common one -- the 30-day purge clears the text and keeps the row.
    func testARowWhoseTextHasBeenClearedSaysSoRatherThanNothing() {
        XCTAssertEqual(HistoryRow.preview(for: record()), "Text cleared")
        XCTAssertEqual(
            HistoryRow.preview(for: record(outcome: .nothingHeard)), "Nothing heard")
        XCTAssertEqual(HistoryRow.preview(for: record(outcome: .cancelled)), "Cancelled")
        // The clipboard delivery is the same "worked, then the purge took the text" story as
        // `inserted` above, and it deliberately does not say "Text cleared": once the text is gone
        // the only thing left worth saying about the row is the one way it differed from an
        // insertion, which is that nothing ever reached an application.
        XCTAssertEqual(
            HistoryRow.preview(for: record(outcome: .copiedToClipboard)), "Copied to clipboard")
        XCTAssertNotEqual(
            HistoryRow.preview(for: record(outcome: .copiedToClipboard)),
            HistoryRow.preview(for: record(outcome: .inserted)))
    }

    /// A failed dictation shows the message the notch showed, which is the whole reason §5.2 gave
    /// `failureMessage` a column -- a failed row that merely said "Failed" would be a row nobody
    /// can act on.
    func testAFailedRowShowsTheMessageTheNotchShowed() {
        XCTAssertEqual(
            HistoryRow.preview(
                for: record(outcome: .failed, failure: "Ollama is not running\non port 11434")),
            "Ollama is not running on port 11434")
    }

    // MARK: - The timestamp

    /// 12:42 UTC is 14:42 in Paris in September, and 14:42 is what Louis saw on his own clock.
    func testTheTimestampIsTheDateAndTheLocalTimeOfDay() {
        XCTAssertEqual(
            HistoryRow.timestamp(for: record().startedAt, calendar: paris), "1 Sep 14:42")
    }

    // MARK: - The duration

    /// The common case, measured: median 29.7 s over 1 469 real dictations, 49.6 % over 30 s.
    func testASubMinuteRecordingIsWholeSeconds() {
        XCTAssertEqual(HistoryRow.duration(38), "38 s")
    }

    /// Rounded, never truncated. Nothing Louis can perceive measures a recording to the tenth, and
    /// truncation would print `29 s` for something that lasted nearer thirty.
    func testTheMedianRecordingRoundsRatherThanTruncates() {
        XCTAssertEqual(HistoryRow.duration(29.7), "30 s")
    }

    /// **The outlier that names this function.** 478.9 s is the longest dictation in the corpus,
    /// and a row that said `479 s` would make the reader do the division.
    func testTheLongestRealDictationReadsAsMinutesAndSeconds() {
        XCTAssertEqual(HistoryRow.duration(478.9), "7 min 59 s")
    }

    /// A zero remainder is not information, and printing it makes the one round case the ugliest
    /// string in the column.
    func testAWholeNumberOfMinutesDropsTheSeconds() {
        XCTAssertEqual(HistoryRow.duration(120), "2 min")
    }

    func testTheMinuteBoundaryIsCrossedAtSixtySeconds() {
        XCTAssertEqual(HistoryRow.duration(59.4), "59 s")
        XCTAssertEqual(HistoryRow.duration(59.6), "1 min")
        XCTAssertEqual(HistoryRow.duration(61), "1 min 1 s")
    }

    /// A duration is never negative and a clock that went backwards must not print a minus sign in
    /// the corner of a row.
    func testAZeroOrNegativeDurationIsZeroSeconds() {
        XCTAssertEqual(HistoryRow.duration(0), "0 s")
        XCTAssertEqual(HistoryRow.duration(-3), "0 s")
    }

    /// The pipeline timings are the small numbers -- lot 2 measured a 0.38 s median refinement on
    /// `s1-mini` -- so they keep a decimal where a recording does not. A whole-second form would
    /// print `0 s` for the number the metadata block exists to show.
    func testAPipelineTimingKeepsOneDecimalWhereARecordingDoesNot() {
        XCTAssertEqual(HistoryRow.elapsed(0.38), "0.4 s")
        XCTAssertEqual(HistoryRow.elapsed(19.4), "19.4 s")
        XCTAssertEqual(HistoryRow.duration(0.38), "0 s")
    }
}
