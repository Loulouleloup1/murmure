import Foundation

/// The two lines of one history row (D10): a truncated line of transcript, then date · time with
/// the duration at the right edge.
///
/// D10 against the installed app, deliberately. Design notes §1.3 measured that its card "renders
/// **only** the transcript excerpt. No timestamp, no duration, no mode name" — which is right for
/// an app whose rows are found by reading them and wrong for Louis, whose median dictation is
/// 29.7 s and who tells two dictations about the same subject five minutes apart apart by *when*
/// and *how long*. The doc corpus's own row is the one taken here.
public enum HistoryRow {
    // MARK: - The line of transcript

    /// How much of the transcript the row carries.
    ///
    /// A cap on what is BUILT, not the truncation the eye sees — `Text` does that at whatever
    /// width the window happens to be. It is here because the alternative is handing SwiftUI a
    /// 400-word string per row for a thousand rows and asking it to lay out and throw away all of
    /// it, and because a row cannot be wider than a window: 140 characters is already past the
    /// ~110 a 13 pt line fits at the default width (`WindowLayout.defaultSize`).
    public static let previewLimit = 140

    /// The one line a row shows.
    ///
    /// **The refined text when there is one**, because that is what was pasted and therefore what
    /// Louis will recognise; the raw transcript otherwise.
    ///
    /// Collapsed through `StatusPanelText.oneLine` rather than through a rule of this file's own.
    /// A transcript carries newlines — a refiner asked for bullet points returns them — and in a
    /// single-line row everything after the first newline is invisible with no sign that it
    /// existed, which is the exact defect that function was written for.
    public static func preview(for record: HistoryRecord) -> String {
        if let text = record.refinedText ?? record.rawTranscript {
            let line = StatusPanelText.oneLine(text)
            if !line.isEmpty { return truncated(line) }
        }
        // No text, and the row still has to say what it is. §5.5's rule one level down: the
        // transcript is the identity of a row, so when there is none the outcome is.
        if let message = record.failureMessage {
            return truncated(StatusPanelText.oneLine(message))
        }
        return placeholder(for: record.outcome)
    }

    /// What a row says when it has no text of its own.
    ///
    /// `inserted` is the case that looks impossible and is the common one in a month's time: the
    /// retention policy of 2026-09-01 clears the text after 30 days and keeps the row, so a
    /// dictation that worked perfectly ends its life here.
    private static func placeholder(for outcome: DictationOutcome) -> String {
        switch outcome {
        case .inserted: "Text cleared"
        case .nothingHeard: "Nothing heard"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    /// Cut at the tail, at a word boundary, with an ellipsis.
    ///
    /// At the tail and not in the middle: the middle is macOS's default for a path, where both
    /// ends identify the thing, and it is wrong for a sentence — the beginning of a dictation is
    /// what identifies it. The word boundary is what keeps the ellipsis from arriving in the
    /// middle of `endpoi…`.
    private static func truncated(_ line: String) -> String {
        guard line.count > previewLimit else { return line }
        let head = line.prefix(previewLimit)
        guard let lastSpace = head.lastIndex(of: " ") else { return head + "…" }
        return head[..<lastSpace] + "…"
    }

    // MARK: - The second line

    /// `1 Sep 14:42` — the date and the time of day, in the local zone the `Calendar` carries.
    ///
    /// The date is kept even though the group header above already carries the day, which is the
    /// doc corpus's row and not an oversight: a row read on its own — scrolled to, searched to,
    /// selected — is the one being read, and the header may be several rows above the fold.
    ///
    /// 24-hour, and that is a format rather than a language: `14:42` is what Louis reads on every
    /// other clock he owns, and `2:42 PM` in a French afternoon would be the one American thing in
    /// the window.
    public static func timestamp(for date: Date, calendar: Calendar) -> String {
        HistoryGrouping.formatted(date, format: "d MMM HH:mm", calendar: calendar)
    }

    /// How long the recording was, at the right edge of the second line.
    ///
    /// Written across the range Louis actually produces, measured over 1 469 real dictations:
    /// median 29.7 s, mean 41.9 s, 49.6 % over 30 s, longest 478.9 s. So the sub-minute case is
    /// the common one and gets the short form, and the long one must read as `7 min 59 s` — a row
    /// that said `479 s` would make the reader do the division, which is the whole job of this
    /// function.
    ///
    /// Rounded to the second, never truncated: 29.7 s is `30 s`. A recording is not measured to
    /// the tenth by anything Louis can perceive, and truncation would print `29 s` for something
    /// that lasted nearer thirty.
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        guard total >= 60 else { return "\(total) s" }
        let minutes = total / 60
        let remainder = total % 60
        // `1 min`, not `1 min 0 s`. A zero remainder is not information, and printing it makes
        // the one round case the ugliest string in the column.
        return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder) s"
    }

    /// The same seconds, for a pipeline timing rather than a recording: `0.4 s`, `19.4 s`.
    ///
    /// One decimal, because this is where the small numbers live — lot 2 measured a 0.38 s median
    /// refinement on `s1-mini` — and a whole-second form would print `0 s` for the number the
    /// metadata block exists to show.
    public static func elapsed(_ seconds: Double) -> String {
        String(format: "%.1f s", max(0, seconds))
    }
}
