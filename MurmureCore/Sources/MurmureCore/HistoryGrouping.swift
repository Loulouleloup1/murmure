import Foundation

/// One date header and the rows under it (design notes §1.3: the header is muted, small,
/// left-aligned and sits **outside and above** the cards).
///
/// A value rather than a computed grouping inside the view, for the reason every other decision in
/// this package is here: `Murmure` has no test bundle, and "which day is this row under" is a
/// question with a wrong answer that nobody would see until a dictation at one in the morning
/// filed itself under yesterday.
public struct HistoryDateGroup: Equatable, Sendable, Identifiable {
    /// `Today`, `Yesterday`, or the date itself.
    public let title: String
    /// The day these rows started on, at its local midnight. What makes two groups distinct even
    /// when their titles could not be — and what `Identifiable` needs, because a title is a word
    /// and `Today` is a word that comes back tomorrow.
    public let day: Date
    /// In the order they were handed in, which is the store's order: `startedAt DESC, id DESC`.
    public let records: [HistoryRecord]

    public var id: Date { day }

    public init(title: String, day: Date, records: [HistoryRecord]) {
        self.title = title
        self.day = day
        self.records = records
    }
}

/// History, cut into days.
///
/// **Every boundary here is a LOCAL one**, and that is the whole reason this file exists.
/// `startedAt` is stored in UTC (§5.2, and rightly — it is what makes `ORDER BY` and the purge
/// predicate work on a TEXT column), but Louis is in Paris. A dictation at 00:30 on a summer
/// morning is `22:30Z` the day before: grouped by its UTC date it lands under "Yesterday" the
/// moment it is made, which is not a rounding error, it is the wrong day. The `Calendar` carries
/// the time zone, so every comparison below goes through it and none through `Date` arithmetic.
public enum HistoryGrouping {
    /// Rows, in the order given, cut into contiguous runs of one local day.
    ///
    /// Contiguous **runs**, not a dictionary keyed by day: the store hands these back newest
    /// first and that order is the list's order, so re-sorting here would be this function
    /// quietly overruling the query. The consequence is stated rather than hidden — rows given
    /// out of order produce two groups with the same title, which is a faithful drawing of an
    /// input nothing in the app produces.
    public static func groups(
        for records: [HistoryRecord], now: Date, calendar: Calendar
    ) -> [HistoryDateGroup] {
        var groups: [HistoryDateGroup] = []
        var day: Date?
        var run: [HistoryRecord] = []

        func close() {
            guard let day, !run.isEmpty else { return }
            groups.append(
                HistoryDateGroup(title: header(for: day, now: now, calendar: calendar),
                                 day: day, records: run))
        }

        for record in records {
            let start = calendar.startOfDay(for: record.startedAt)
            if start != day {
                close()
                day = start
                run = []
            }
            run.append(record)
        }
        close()
        return groups
    }

    /// The words above a day's rows.
    ///
    /// `Today` and `Yesterday` are worth their special cases and nothing further is: a third
    /// relative word ("this week") is a phrase that has to be read to be understood, where a date
    /// is one that is recognised. English, as `WindowSection.title` is and for the same settled
    /// reason.
    public static func header(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        // The year is dropped inside the current one and written outside it. A history opened in
        // January and scrolled into December wants to know which December it is looking at; the
        // rest of the time the year is four characters that are the same on every header.
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatted(date, format: sameYear ? "d MMMM" : "d MMMM yyyy", calendar: calendar)
    }

    /// A fixed English locale rather than the system's, everywhere in this file and in
    /// ``HistoryRow``.
    ///
    /// Not an oversight and not laziness: the surrounding chrome is written in English as literal
    /// strings (`Today`, `Copy`, `Refined`), so a month name that followed Louis's French system
    /// locale would put "1 septembre" under an English header — one line in two languages. When
    /// this window is localised, this constant and those literals move together. It is also what
    /// makes the tests assert a string rather than whatever the machine running them is set to.
    static let locale = Locale(identifier: "en_US_POSIX")

    static func formatted(_ date: Date, format: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
