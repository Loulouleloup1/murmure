# Home statistics pane — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `Home` pane, first in the sidebar and the default first screen, showing dictation statistics (average WPM, words, applications, time saved) with a 52-week heatmap, an hour profile, streaks, records and top applications, computed from the existing `dictation` table plus two new word-count columns.

**Architecture:** Every decision lives in `MurmureCore` as pure, tested types: `WordCount` (counting), a `v3-wordCounts` GRDB migration with in-migration backfill, a text-free projection `HistoryStore.statisticsRows()`, `StatisticsPeriod`, `DictationStatistics.compute(...)`, `StatisticsFormatting`, `HomeLayout`, and two `AppSettings` keys. The app target adds a thin `HomePaneModel` (loads the projection, computes off the main actor, publishes) and `HomePaneView` (cards + Swift Charts), wired through `WindowSection.home` and the exhaustive `pane` switch.

**Tech Stack:** Swift 5.10, macOS 14 floor, SwiftUI, Swift Charts, GRDB 7.11.1, XCTest. SPM package `MurmureCore/` (tests run with `swift test`), app target `Murmure/` (no test bundle; verified by `xcodebuild`).

**Spec:** `docs/specs/2026-09-09-home-statistics-design.md`. One deviation, agreed here: the backfill of word counts for existing rows runs inside the `v3-wordCounts` migration (a migration closure is ordinary Swift and runs exactly once), instead of a separate launch job. Same effect, less machinery.

## Global Constraints

- macOS deployment target 14.0; Swift tools 5.10; do not add third-party dependencies (Swift Charts is first-party).
- All rules, computations and constants live in `MurmureCore` with XCTest tests; app-target files are wiring only. XCTest, one test file per type, descriptive `testSentenceCase()` names, Given/When/Then comments as in the existing tests.
- Design tokens only: `Color(role:)` from `WindowRole`, `WindowLayout` chrome constants, `NotchAppearance.accentHue/accentSaturation/accentBrightness` for the accent. Success = green only, warning = orange, no emoji anywhere. UI copy in English with British spelling ("colour" never appears in copy; avoid words that differ if possible).
- No hardcoding of the owner's own data (bundle ids, app names, dates) outside tests.
- Migrations are immutable once shipped; `v1-dictation` and `v2-correctedText` must not change. The new migration is named exactly `v3-wordCounts`.
- `UserDefaults` keys are never renamed; new keys: `typingWordsPerMinute`, `homeStatisticsPeriod`.
- Safety for executors (the owner's desktop is live): never launch the GUI app, never post key events, never use the clipboard or microphone, never write under `~/Library/Application Support/Murmure/` (reading is allowed), never `git stash`, never commit (the orchestrator commits). Tests use temp directories only. Do not quote dictated text from any fixture or database in reports.
- Verification commands: `cd MurmureCore && swift test --filter <TestClass>` for a task, `cd MurmureCore && swift test` for the whole package (expect 1317 + new tests, 0 failures), and for the app target from the repo root: `xcodegen generate && xcodebuild -project Murmure.xcodeproj -scheme Murmure -configuration Debug -derivedDataPath .build/xcode build CODE_SIGNING_ALLOWED=NO` which must print `BUILD SUCCEEDED`. A claim of a passing build without that literal line is not a proof.

## File structure

Create in `MurmureCore/Sources/MurmureCore/`:
- `WordCount.swift` — the counting rule.
- `DictationStatisticsRow.swift` — text-free projection type fetched by `HistoryStore.statisticsRows()`.
- `StatisticsPeriod.swift` — the four periods and their start date.
- `DictationStatistics.swift` — the computed value and `compute(...)`.
- `StatisticsFormatting.swift` — pure string formatting for figures.
- `HomeLayout.swift` — layout constants.

Modify in `MurmureCore/Sources/MurmureCore/`:
- `HistoryRecord.swift` — two `Int?` properties.
- `HistoryStore.swift` — `v3-wordCounts` migration, `statisticsRows()`.
- `DictationSession.swift` — fill the counts when archiving (around line 623, `archive`).
- `AppSettings.swift` — `typingWordsPerMinute`, `homeStatisticsPeriod`.
- `WindowSection.swift` — `case home` first, `fallback = .home`.

Create in `MurmureCore/Tests/MurmureCoreTests/`: `WordCountTests.swift`, `StatisticsPeriodTests.swift`, `DictationStatisticsTests.swift`, `StatisticsFormattingTests.swift`, `HomeLayoutTests.swift`. Extend `HistoryStoreTests.swift`, `AppSettingsTests.swift`, the `DictationSession` tests, the `WindowSection` tests.

Create in `Murmure/`: `HomePaneModel.swift`, `HomePaneView.swift`, `HomeCards.swift` (StatCard, HeatmapCard, HourProfileCard, StreakCard, RecordsCard, TopApplicationsCard). Modify `Murmure/MainWindowView.swift` (property + `pane` case) and `Murmure/MurmureApp.swift` (construct and pass the model, mirroring `HistoryPaneModel`).

Docs: `docs/plans/2026-09-backlog.md` (§9 Home), `docs/design/ui-design-notes.md` (Home section).

---

### Task 1: `WordCount`

**Files:**
- Create: `MurmureCore/Sources/MurmureCore/WordCount.swift`
- Test: `MurmureCore/Tests/MurmureCoreTests/WordCountTests.swift`

**Interfaces:**
- Produces: `public enum WordCount { public static func count(_ text: String?) -> Int }`. `nil` and empty give 0.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MurmureCore

final class WordCountTests: XCTestCase {
    func testWhitespaceSeparatedTokensWithALetterOrDigitAreWords() {
        XCTAssertEqual(WordCount.count("bonjour tout le monde"), 4)
        XCTAssertEqual(WordCount.count("dbt runs 2026 pipelines"), 4)
        XCTAssertEqual(WordCount.count("line one\nline two\ttabbed"), 5)
    }

    func testAnApostropheKeepsTheContractionAsOneWord() {
        XCTAssertEqual(WordCount.count("l'affaire fit grand bruit"), 4)
        XCTAssertEqual(WordCount.count("qu'il n'y avait"), 3)
    }

    func testPunctuationOnlyTokensAreNotWords() {
        XCTAssertEqual(WordCount.count("--"), 0)
        XCTAssertEqual(WordCount.count("…"), 0)
        XCTAssertEqual(WordCount.count("fin . -- …"), 1)
        XCTAssertEqual(WordCount.count("Bonjour, ça va ?"), 3)
    }

    func testAThinSpaceInsideANumberSplitsItInTwo() {
        XCTAssertEqual(WordCount.count("12\u{202F}000 euros"), 3)
    }

    func testNilAndEmptyAndBlankCountZero() {
        XCTAssertEqual(WordCount.count(nil), 0)
        XCTAssertEqual(WordCount.count(""), 0)
        XCTAssertEqual(WordCount.count("   \n\t "), 0)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd MurmureCore && swift test --filter WordCountTests`
Expected: compile error, `WordCount` not found.

- [ ] **Step 3: Implement**

```swift
// MurmureCore/Sources/MurmureCore/WordCount.swift
import Foundation

/// The one word-counting rule of the app. Deliberately simple and language-agnostic: split on
/// Unicode whitespace and newlines, keep the tokens that carry at least one letter or digit.
/// `l'affaire` is one word, `--` is none. Statistics are only comparable if every row was counted
/// the same way, so nothing else in the app may count words differently.
public enum WordCount {
    public static func count(_ text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        var words = 0
        for token in text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            if token.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                words += 1
            }
        }
        return words
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd MurmureCore && swift test --filter WordCountTests`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Report** files touched; the orchestrator commits (`feat(stats): word counting rule`).

---

### Task 2: word-count columns, migration `v3-wordCounts` with backfill, `statisticsRows()`

**Files:**
- Modify: `MurmureCore/Sources/MurmureCore/HistoryRecord.swift` (properties after `insertedCharacters`, init parameters after `insertedCharacters`)
- Modify: `MurmureCore/Sources/MurmureCore/HistoryStore.swift` (migrator, new method after `countWithText()`)
- Create: `MurmureCore/Sources/MurmureCore/DictationStatisticsRow.swift`
- Test: `MurmureCore/Tests/MurmureCoreTests/HistoryStoreTests.swift`

**Interfaces:**
- Consumes: `WordCount.count(_:)` (Task 1).
- Produces: `HistoryRecord.rawWordCount: Int?`, `HistoryRecord.finalWordCount: Int?` (init parameters `rawWordCount: Int? = nil, finalWordCount: Int? = nil`); `public struct DictationStatisticsRow` (fields below); `HistoryStore.statisticsRows() throws -> [DictationStatisticsRow]`.

- [ ] **Step 1: Write the failing tests** (append to `HistoryStoreTests`; helper `at(_:)` already exists there)

```swift
    func testWordCountsSurviveTheRoundTripAndDefaultToNil() throws {
        let store = try makeStore()
        let counted = HistoryRecord(
            startedAt: at("2026-09-02T09:00:00.000Z"), durationSeconds: 12, outcome: .inserted,
            modeKey: "voice", modeName: "Voice", sttModel: "turbo",
            rawTranscript: "un deux trois", refinedText: "Un, deux, trois.",
            insertedCharacters: 16, rawWordCount: 3, finalWordCount: 3)
        let uncounted = HistoryRecord(
            startedAt: at("2026-09-02T09:01:00.000Z"), durationSeconds: 5, outcome: .inserted,
            modeKey: "voice", modeName: "Voice", sttModel: "turbo")

        let a = try store.insert(counted)
        let b = try store.insert(uncounted)

        XCTAssertEqual(try store.record(id: XCTUnwrap(a.id))?.rawWordCount, 3)
        XCTAssertEqual(try store.record(id: XCTUnwrap(a.id))?.finalWordCount, 3)
        XCTAssertNil(try store.record(id: XCTUnwrap(b.id))?.rawWordCount)
        XCTAssertNil(try store.record(id: XCTUnwrap(b.id))?.finalWordCount)
    }

    func testMigratingAV2DatabaseBackfillsCountsOnlyWhereTextIsStillPresent() throws {
        // Given -- a database migrated only up to v2 (the migrator is internal, hence @testable),
        // with three rows written without the new columns
        let queue = try DatabaseQueue(path: databaseURL.path)
        try HistoryStore.migrator.migrate(queue, upTo: "v2-correctedText")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO dictation (startedAt, durationSeconds, outcome, modeKey, modeName, sttModel,
                    rawTranscript, correctedText, refinedText, insertedCharacters)
                VALUES ('2026-08-01T10:00:00.000Z', 20, 'inserted', 'voice', 'Voice', 'turbo',
                    'un deux trois quatre', NULL, 'Un deux trois.', 14),
                       ('2026-08-02T10:00:00.000Z', 20, 'inserted', 'voice', 'Voice', 'turbo',
                    'cinq six', 'cinq six sept', NULL, 13),
                       ('2026-07-01T10:00:00.000Z', 20, 'inserted', 'voice', 'Voice', 'turbo',
                    NULL, NULL, NULL, 0)
                """)
        }

        // When -- the store opens and runs v3
        _ = try makeStore()

        // Then
        let counts = try inspect { db in
            try Row.fetchAll(db, sql: "SELECT rawWordCount, finalWordCount FROM dictation ORDER BY startedAt")
                .map { ($0["rawWordCount"] as Int?, $0["finalWordCount"] as Int?) }
        }
        XCTAssertEqual(counts.count, 3)
        XCTAssertEqual(counts[0].0, nil); XCTAssertEqual(counts[0].1, nil)   // purged row stays nil
        XCTAssertEqual(counts[1].0, 4); XCTAssertEqual(counts[1].1, 3)       // refined wins
        XCTAssertEqual(counts[2].0, 2); XCTAssertEqual(counts[2].1, 3)       // corrected when no refined
    }
```

Note for the implementer: the `startedAt` literal must match the exact text format `HistoryRecord`
writes (check how a row looks with `SELECT startedAt FROM dictation` after an insert through the
store in another test, and copy that format); if the v1 schema declares `startedAt` differently,
mirror it. `HistoryStore.migrator` is `static var` without `private`, so `@testable import` sees it.

```swift
    func testStatisticsRowsCarryNoTextAndMatchTheRecords() throws {
        let store = try makeStore()
        let written = HistoryRecord(
            startedAt: at("2026-09-03T14:42:03.123Z"), durationSeconds: 38.25, outcome: .copiedToClipboard,
            modeKey: "prompt", modeName: "Prompt", sttModel: "turbo",
            rawTranscript: "sept mots dans cette phrase de test", refinedText: "Sept.",
            insertedCharacters: 5, targetBundleID: "com.example.editor", targetAppName: "Editor",
            rawWordCount: 7, finalWordCount: 1)
        _ = try store.insert(written)

        let rows = try store.statisticsRows()

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].startedAt, written.startedAt)
        XCTAssertEqual(rows[0].durationSeconds, 38.25)
        XCTAssertEqual(rows[0].outcome, .copiedToClipboard)
        XCTAssertEqual(rows[0].rawWordCount, 7)
        XCTAssertEqual(rows[0].finalWordCount, 1)
        XCTAssertEqual(rows[0].targetBundleID, "com.example.editor")
        XCTAssertEqual(rows[0].targetAppName, "Editor")
        XCTAssertEqual(rows[0].modeName, "Prompt")
        // The projection type has no text field at all: this is a compile-time guarantee,
        // asserted here by listing every stored property of the row.
        let mirror = Mirror(reflecting: rows[0]).children.compactMap(\.label)
        XCTAssertEqual(Set(mirror), ["startedAt", "durationSeconds", "outcome", "rawWordCount",
                                     "finalWordCount", "targetBundleID", "targetAppName", "modeName"])
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd MurmureCore && swift test --filter HistoryStoreTests`
Expected: compile errors (`rawWordCount` unknown, `statisticsRows` unknown).

- [ ] **Step 3: Implement**

`HistoryRecord.swift`: after `public var insertedCharacters: Int` add

```swift
    /// Words in `rawTranscript`, counted by `WordCount` at archive time; nil for rows archived
    /// before the counts existed whose text had already been purged.
    public var rawWordCount: Int?
    /// Words in the text that reached the target application (refined, else corrected, else raw).
    public var finalWordCount: Int?
```

and in `init`, after `insertedCharacters: Int = 0,` add `rawWordCount: Int? = nil, finalWordCount: Int? = nil,` and assign both. Keep every existing call site compiling (defaults).

`DictationStatisticsRow.swift`:

```swift
import Foundation
import GRDB

/// The text-free projection of a dictation row used by the Home statistics. It carries no
/// transcript on purpose: statistics never need the words, only their number.
public struct DictationStatisticsRow: Equatable, Sendable, Decodable, FetchableRecord {
    public var startedAt: Date
    public var durationSeconds: Double
    public var outcome: DictationOutcome
    public var rawWordCount: Int?
    public var finalWordCount: Int?
    public var targetBundleID: String?
    public var targetAppName: String?
    public var modeName: String

    public init(startedAt: Date, durationSeconds: Double, outcome: DictationOutcome,
                rawWordCount: Int? = nil, finalWordCount: Int? = nil,
                targetBundleID: String? = nil, targetAppName: String? = nil, modeName: String) {
        self.startedAt = startedAt; self.durationSeconds = durationSeconds; self.outcome = outcome
        self.rawWordCount = rawWordCount; self.finalWordCount = finalWordCount
        self.targetBundleID = targetBundleID; self.targetAppName = targetAppName; self.modeName = modeName
    }
}
```

If `HistoryRecord`'s GRDB conformance (around line 197) declares a `databaseDateDecodingStrategy` or a custom `Date` coding, declare the identical static on `DictationStatisticsRow`; the third test above fails on `startedAt` if the strategies differ.

`HistoryStore.swift`: register after `v2-correctedText`:

```swift
        migrator.registerMigration("v3-wordCounts") { db in
            try db.alter(table: "dictation") { t in
                t.add(column: "rawWordCount", .integer)
                t.add(column: "finalWordCount", .integer)
            }
            // Backfill once, here, for rows whose text still exists. Rows already purged of text
            // keep NULL counts and simply contribute no words. Uses the app's single counting rule.
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, rawTranscript, correctedText, refinedText FROM dictation
                WHERE rawTranscript IS NOT NULL OR correctedText IS NOT NULL OR refinedText IS NOT NULL
                """)
            for row in rows {
                let raw: String? = row["rawTranscript"]
                let corrected: String? = row["correctedText"]
                let refined: String? = row["refinedText"]
                let final = refined ?? corrected ?? raw
                try db.execute(
                    sql: "UPDATE dictation SET rawWordCount = ?, finalWordCount = ? WHERE id = ?",
                    arguments: [WordCount.count(raw), WordCount.count(final), row["id"] as Int64])
            }
        }
```

and after `countWithText()`:

```swift
    /// Every row, without any text column, oldest first. Small (a few hundred kilobytes for
    /// thousands of rows) and deliberately unfiltered: period and outcome filtering happen in
    /// `DictationStatistics.compute`, where the local calendar is known.
    public func statisticsRows() throws -> [DictationStatisticsRow] {
        try dbQueue.read { db in
            try DictationStatisticsRow.fetchAll(db, sql: """
                SELECT startedAt, durationSeconds, outcome, rawWordCount, finalWordCount,
                       targetBundleID, targetAppName, modeName
                FROM dictation ORDER BY startedAt ASC
                """)
        }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `cd MurmureCore && swift test --filter HistoryStoreTests`
Expected: all existing HistoryStore tests still pass plus the 3 new ones.

- [ ] **Step 5: Report**; orchestrator commits (`feat(history): word-count columns, v3 migration with backfill, statistics projection`).

---

### Task 3: counts filled at archive time

**Files:**
- Modify: `MurmureCore/Sources/MurmureCore/DictationSession.swift` (the `archive` function around line 623 where `HistoryRecord(` is constructed)
- Test: the existing `DictationSession` test file (find it with `grep -l "DictationSession" MurmureCore/Tests/MurmureCoreTests/*.swift`; add to the file that already asserts on the archived `HistoryRecord`)

**Interfaces:**
- Consumes: `WordCount.count(_:)`, `HistoryRecord.rawWordCount/finalWordCount`.
- Produces: every archived record carries both counts (`rawWordCount = WordCount.count(rawTranscript)`, `finalWordCount = WordCount.count(refinedText ?? correctedText ?? rawTranscript)`), including records with outcome `nothingHeard`/`failed` (counts 0 or of whatever text exists).

- [ ] **Step 1: Write the failing test** (append to `DictationSessionTests`, which already defines `FakeRecorder`, `FakeTranscriber(result:)`, `SpyInserter`, `SpyRefiner(mode:answer:)`, `SpyRecording` with a `records: [HistoryRecord]` accessor, `FakeVocabulary`, `SpyContextCapture`; mirror `testAModeWithAnLLMInsertsTheRefinedTextRatherThanTheRawOne`)

```swift
    func testTheArchivedRecordCarriesRawAndFinalWordCounts() async throws {
        // Given -- four raw words, refined down to two
        let recording = SpyRecording()
        let refiner = SpyRefiner(mode: .prompt, answer: { _ in "Un, deux." })
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("un deux trois quatre")),
            inserter: SpyInserter(), refiner: refiner, recording: recording,
            vocabulary: FakeVocabulary(),
            contextCapture: SpyContextCapture(), onStateChange: { _ in }
        )
        // When
        await session.toggle()
        await session.toggle()
        // Then
        let record = try XCTUnwrap(recording.records.last)
        XCTAssertEqual(record.rawWordCount, 4)
        XCTAssertEqual(record.finalWordCount, 2)
    }

    func testAVoiceDictationCountsTheSameWordsRawAndFinal() async throws {
        let recording = SpyRecording()
        let session = DictationSession(
            recorder: FakeRecorder(),
            transcriber: FakeTranscriber(result: .success("un deux trois")),
            inserter: SpyInserter(), refiner: SpyRefiner(mode: .voice, answer: { $0 }), recording: recording,
            vocabulary: FakeVocabulary(),
            contextCapture: SpyContextCapture(), onStateChange: { _ in }
        )
        await session.toggle()
        await session.toggle()
        let record = try XCTUnwrap(recording.records.last)
        XCTAssertEqual(record.rawWordCount, 3)
        XCTAssertEqual(record.finalWordCount, 3)
    }
```

If `SpyRecording.records` needs an `await` or the fakes' initialisers differ slightly from the above, follow the file; the assertions are the contract.

- [ ] **Step 2: Run to verify failure**

Run: `cd MurmureCore && swift test --filter DictationSessionTests` (or the actual class name)
Expected: FAIL, counts are nil.

- [ ] **Step 3: Implement** — in `archive`, where `HistoryRecord(` is built, add the two arguments:

```swift
            rawWordCount: WordCount.count(rawTranscript),
            finalWordCount: WordCount.count(refinedText ?? correctedText ?? rawTranscript),
```

placed right after `insertedCharacters: insertedCharacters,` in the `HistoryRecord(` call at `DictationSession.swift:623`; the local names `rawTranscript`, `correctedText`, `refinedText` are the ones already passed on the lines above.

- [ ] **Step 4: Run to verify pass**; then run the whole package once: `cd MurmureCore && swift test` — expected 0 failures.

- [ ] **Step 5: Report**; orchestrator commits (`feat(history): archive word counts with every dictation`).

---

### Task 4: settings — typing baseline and period

**Files:**
- Modify: `MurmureCore/Sources/MurmureCore/AppSettings.swift` (`Key` enum + two computed properties)
- Create: `MurmureCore/Sources/MurmureCore/StatisticsPeriod.swift`
- Test: `MurmureCore/Tests/MurmureCoreTests/AppSettingsTests.swift`, create `StatisticsPeriodTests.swift`

**Interfaces:**
- Produces: `public enum StatisticsPeriod: String, CaseIterable, Sendable { case last7Days, last30Days, last12Months, allTime }` with `title: String` and `func start(now: Date, calendar: Calendar) -> Date?`; `AppSettings.typingWordsPerMinute: Int` (default 40, clamped 20…120, nonmutating set); `AppSettings.homeStatisticsPeriod: StatisticsPeriod` (default `.allTime`).

- [ ] **Step 1: Write the failing tests**

`StatisticsPeriodTests.swift`:

```swift
import XCTest
@testable import MurmureCore

final class StatisticsPeriodTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        c.firstWeekday = 2
        return c
    }()
    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter(); return f.date(from: iso)!
    }

    func testSevenDaysStartsSixLocalDaysBeforeTodayAtMidnight() {
        let now = date("2026-09-09T15:30:00+02:00")
        XCTAssertEqual(StatisticsPeriod.last7Days.start(now: now, calendar: calendar),
                       date("2026-09-03T00:00:00+02:00"))
    }

    func testThirtyDaysStartsTwentyNineDaysBeforeToday() {
        let now = date("2026-09-09T00:10:00+02:00")
        XCTAssertEqual(StatisticsPeriod.last30Days.start(now: now, calendar: calendar),
                       date("2026-08-11T00:00:00+02:00"))
    }

    func testTwelveMonthsStartsTwelveCalendarMonthsBeforeToday() {
        let now = date("2026-09-09T15:30:00+02:00")
        XCTAssertEqual(StatisticsPeriod.last12Months.start(now: now, calendar: calendar),
                       date("2025-09-09T00:00:00+02:00"))
    }

    func testAllTimeHasNoStart() {
        XCTAssertNil(StatisticsPeriod.allTime.start(now: Date(), calendar: calendar))
    }

    func testTitlesAndOrderArePinned() {
        XCTAssertEqual(StatisticsPeriod.allCases.map(\.title), ["7 days", "30 days", "12 months", "All time"])
    }
}
```

Append to `AppSettingsTests`:

```swift
    func testTypingSpeedDefaultsToFortyAndIsClampedBothWays() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.typingWordsPerMinute, 40)
        settings.typingWordsPerMinute = 300
        XCTAssertEqual(settings.typingWordsPerMinute, 120)
        settings.typingWordsPerMinute = 5
        XCTAssertEqual(settings.typingWordsPerMinute, 20)
        settings.typingWordsPerMinute = 55
        XCTAssertEqual(settings.typingWordsPerMinute, 55)
        defaults.set(999, forKey: "typingWordsPerMinute")      // a hand-edited plist
        XCTAssertEqual(settings.typingWordsPerMinute, 120)
    }

    func testHomePeriodDefaultsToAllTimeAndSurvivesAnUnknownValue() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.homeStatisticsPeriod, .allTime)
        settings.homeStatisticsPeriod = .last7Days
        XCTAssertEqual(settings.homeStatisticsPeriod, .last7Days)
        defaults.set("fortnight", forKey: "homeStatisticsPeriod")
        XCTAssertEqual(settings.homeStatisticsPeriod, .allTime)
    }
```

- [ ] **Step 2: Run to verify failure**: `cd MurmureCore && swift test --filter "StatisticsPeriodTests|AppSettingsTests"` — compile errors.

- [ ] **Step 3: Implement**

`StatisticsPeriod.swift`:

```swift
import Foundation

/// The window the Home figures are computed over. The period ends at `now` and starts at a local
/// midnight, so "7 days" is today plus the six days before it.
public enum StatisticsPeriod: String, CaseIterable, Sendable {
    case last7Days
    case last30Days
    case last12Months
    case allTime

    public var title: String {
        switch self {
        case .last7Days: "7 days"
        case .last30Days: "30 days"
        case .last12Months: "12 months"
        case .allTime: "All time"
        }
    }

    /// Inclusive start of the period, or nil for all time.
    public func start(now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .last7Days: return calendar.date(byAdding: .day, value: -6, to: today)
        case .last30Days: return calendar.date(byAdding: .day, value: -29, to: today)
        case .last12Months: return calendar.date(byAdding: .month, value: -12, to: today)
        case .allTime: return nil
        }
    }
}
```

`AppSettings.swift`: add `static let typingWordsPerMinute = "typingWordsPerMinute"` and `static let homeStatisticsPeriod = "homeStatisticsPeriod"` to `Key`, then:

```swift
    /// Typing speed the Home pane compares dictation against for "time saved". 40 wpm is the
    /// common default of dictation apps; the user adjusts it from the pane. Clamped so a stray
    /// value in the plist can never produce absurd figures.
    public static let typingWordsPerMinuteRange = 20...120

    public var typingWordsPerMinute: Int {
        get {
            guard defaults.object(forKey: Key.typingWordsPerMinute) != nil else { return 40 }
            return min(max(defaults.integer(forKey: Key.typingWordsPerMinute),
                           Self.typingWordsPerMinuteRange.lowerBound),
                       Self.typingWordsPerMinuteRange.upperBound)
        }
        nonmutating set {
            defaults.set(min(max(newValue, Self.typingWordsPerMinuteRange.lowerBound),
                             Self.typingWordsPerMinuteRange.upperBound),
                         forKey: Key.typingWordsPerMinute)
        }
    }

    public var homeStatisticsPeriod: StatisticsPeriod {
        get {
            guard let stored = defaults.string(forKey: Key.homeStatisticsPeriod),
                  let period = StatisticsPeriod(rawValue: stored) else { return .allTime }
            return period
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.homeStatisticsPeriod) }
    }
```

Check `EphemeralDefaults` supports `integer(forKey:)` and `set(_ Int, forKey:)`; if it is a `UserDefaults` subclass it does.

- [ ] **Step 4: Run to verify pass**: same filter, 0 failures.

- [ ] **Step 5: Report**; orchestrator commits (`feat(settings): typing baseline and Home period`).

---

### Task 5: `DictationStatistics` — figures, applications, time saved

**Files:**
- Create: `MurmureCore/Sources/MurmureCore/DictationStatistics.swift`
- Test: `MurmureCore/Tests/MurmureCoreTests/DictationStatisticsTests.swift`

**Interfaces:**
- Consumes: `DictationStatisticsRow`, `StatisticsPeriod`, `DictationOutcome`.
- Produces (this task fills the first group; Task 6 fills heatmap, hour profile, streak, records, leaving them empty here):

```swift
public struct DictationStatistics: Equatable, Sendable {
    public struct Application: Equatable, Sendable {
        public let bundleID: String
        public let name: String
        public let dictations: Int
    }
    public struct HeatmapDay: Equatable, Sendable {
        public let day: Date          // local midnight
        public let dictations: Int
        public let words: Int
        public let level: Int         // 0 (none) … 4 (busiest quartile)
        public let column: Int        // 0…51, week index oldest first
        public let row: Int           // 0 Monday … 6 Sunday
    }
    public struct Streak: Equatable, Sendable { public let current: Int; public let longest: Int }
    public struct Record<Value: Equatable & Sendable>: Equatable, Sendable {
        public let value: Value
        public let day: Date          // local midnight of the dictation (or of the day, for daily records)
    }
    public struct Records: Equatable, Sendable {
        public let longestDictationSeconds: Record<Double>?
        public let mostWordsInADay: Record<Int>?
        public let fastestWordsPerMinute: Record<Double>?
    }

    public let period: StatisticsPeriod
    public let hasAnyDictation: Bool          // all time, drives the empty state
    public let dictations: Int
    public let words: Int
    public let spokenSeconds: Double
    public let averageWordsPerMinute: Double? // nil when no counted spoken time
    public let applicationCount: Int
    public let topApplications: [Application] // at most 5, most dictations first, ties by name
    public let timeSavedMinutes: Double?      // nil when no row in the period has a final count
    public let wordCountsSince: Date?         // earliest counted row, all time; nil if none
    public let heatmap: [HeatmapDay]
    public let hourProfile: [Int]             // 24 entries
    public let streak: Streak
    public let records: Records

    public static func compute(rows: [DictationStatisticsRow], period: StatisticsPeriod,
                               now: Date, calendar: Calendar, typingWordsPerMinute: Int) -> DictationStatistics
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MurmureCore

final class DictationStatisticsTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        c.firstWeekday = 2
        return c
    }()
    /// Wednesday 2026-09-09, 15:30 Paris.
    private let now = ISO8601DateFormatter().date(from: "2026-09-09T15:30:00+02:00")!

    private func t(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func row(_ startedAt: String, seconds: Double = 60, outcome: DictationOutcome = .inserted,
                     raw: Int? = nil, final: Int? = nil, app: (String, String)? = ("com.example.a", "A"),
                     mode: String = "Voice") -> DictationStatisticsRow {
        DictationStatisticsRow(startedAt: t(startedAt), durationSeconds: seconds, outcome: outcome,
                               rawWordCount: raw, finalWordCount: final,
                               targetBundleID: app?.0, targetAppName: app?.1, modeName: mode)
    }

    private func compute(_ rows: [DictationStatisticsRow], period: StatisticsPeriod = .allTime,
                         typing: Int = 40) -> DictationStatistics {
        DictationStatistics.compute(rows: rows, period: period, now: now, calendar: calendar,
                                    typingWordsPerMinute: typing)
    }

    // MARK: Which rows count

    func testOnlyInsertedAndCopiedRowsCount() {
        let stats = compute([
            row("2026-09-09T10:00:00+02:00", raw: 10, final: 10),
            row("2026-09-09T10:01:00+02:00", outcome: .copiedToClipboard, raw: 10, final: 10),
            row("2026-09-09T10:02:00+02:00", outcome: .nothingHeard),
            row("2026-09-09T10:03:00+02:00", outcome: .failed, raw: 99, final: 99),
            row("2026-09-09T10:04:00+02:00", outcome: .cancelled),
        ])
        XCTAssertEqual(stats.dictations, 2)
        XCTAssertEqual(stats.words, 20)
        XCTAssertEqual(stats.spokenSeconds, 120)
        XCTAssertTrue(stats.hasAnyDictation)
    }

    func testNoCountingRowAnywhereMeansNoDictation() {
        let stats = compute([row("2026-09-09T10:00:00+02:00", outcome: .failed)])
        XCTAssertFalse(stats.hasAnyDictation)
        XCTAssertEqual(stats.dictations, 0)
        XCTAssertNil(stats.averageWordsPerMinute)
        XCTAssertNil(stats.timeSavedMinutes)
    }

    // MARK: Period

    func testSevenDaysIncludesTodayAndSixDaysBeforeInLocalTime() {
        let stats = compute([
            row("2026-09-03T00:30:00+02:00", raw: 1, final: 1),   // first minute of the window
            row("2026-09-02T23:30:00+02:00", raw: 1, final: 1),   // just before it
            row("2026-09-09T23:00:00+02:00", raw: 1, final: 1),   // later today
        ], period: .last7Days)
        XCTAssertEqual(stats.dictations, 2)
    }

    func testAllTimeIgnoresTheWindow() {
        let stats = compute([row("2019-01-01T10:00:00+01:00", raw: 3, final: 3)])
        XCTAssertEqual(stats.dictations, 1)
        XCTAssertEqual(stats.words, 3)
    }

    // MARK: Figures

    func testAverageWpmIsWeightedByDurationNotAMeanOfMeans() {
        // 60 s with 60 words (60 wpm) and 180 s with 60 words (20 wpm): 120 words / 4 min = 30 wpm
        let stats = compute([
            row("2026-09-09T10:00:00+02:00", seconds: 60, raw: 60, final: 60),
            row("2026-09-09T10:05:00+02:00", seconds: 180, raw: 60, final: 60),
        ])
        XCTAssertEqual(stats.averageWordsPerMinute!, 30, accuracy: 0.0001)
    }

    func testRowsWithoutARawCountDoNotDragTheAverageDown() {
        let stats = compute([
            row("2026-09-09T10:00:00+02:00", seconds: 60, raw: 100, final: 100),
            row("2026-09-09T10:05:00+02:00", seconds: 600),      // purged row, no counts
        ])
        XCTAssertEqual(stats.averageWordsPerMinute!, 100, accuracy: 0.0001)
        XCTAssertEqual(stats.spokenSeconds, 660)                  // it still counts as spoken time
        XCTAssertEqual(stats.dictations, 2)
    }

    func testTimeSavedUsesTheTypingBaselineAndMayBeNegative() {
        // 80 final words at 40 wpm = 2 min to type, spoken in 1 min: +1 min
        let fast = compute([row("2026-09-09T10:00:00+02:00", seconds: 60, raw: 80, final: 80)])
        XCTAssertEqual(fast.timeSavedMinutes!, 1, accuracy: 0.0001)
        // 20 words = 0.5 min to type, spoken in 2 min: −1.5 min
        let slow = compute([row("2026-09-09T10:00:00+02:00", seconds: 120, raw: 20, final: 20)])
        XCTAssertEqual(slow.timeSavedMinutes!, -1.5, accuracy: 0.0001)
        // baseline 80 wpm halves the typing time
        let quickTypist = compute([row("2026-09-09T10:00:00+02:00", seconds: 60, raw: 80, final: 80)], typing: 80)
        XCTAssertEqual(quickTypist.timeSavedMinutes!, 0, accuracy: 0.0001)
    }

    func testRowsWithoutAFinalCountAreExcludedFromTimeSaved() {
        let stats = compute([
            row("2026-09-09T10:00:00+02:00", seconds: 60, raw: 80, final: 80),
            row("2026-09-09T10:05:00+02:00", seconds: 3600),      // an hour of purged dictation
        ])
        XCTAssertEqual(stats.timeSavedMinutes!, 1, accuracy: 0.0001)
    }

    func testWordCountsSinceIsTheEarliestCountedRowAllTime() {
        let stats = compute([
            row("2026-01-05T10:00:00+01:00"),
            row("2026-03-05T10:00:00+01:00", raw: 2, final: 2),
            row("2026-09-09T10:00:00+02:00", raw: 2, final: 2),
        ], period: .last7Days)
        XCTAssertEqual(stats.wordCountsSince, t("2026-03-05T10:00:00+01:00"))
    }

    // MARK: Applications

    func testApplicationsAreCountedDistinctAndRankedWithTiesByName() {
        let stats = compute([
            row("2026-09-09T10:00:00+02:00", app: ("com.b", "Bravo")),
            row("2026-09-09T10:01:00+02:00", app: ("com.b", "Bravo")),
            row("2026-09-09T10:02:00+02:00", app: ("com.a", "Alpha")),
            row("2026-09-09T10:03:00+02:00", app: ("com.c", "Charlie")),
            row("2026-09-09T10:04:00+02:00", app: nil),
        ])
        XCTAssertEqual(stats.applicationCount, 3)
        XCTAssertEqual(stats.topApplications.map(\.name), ["Bravo", "Alpha", "Charlie"])
        XCTAssertEqual(stats.topApplications.first?.dictations, 2)
    }

    func testTopApplicationsIsCappedAtFive() {
        let rows = (0..<7).map { i in
            row("2026-09-09T10:0\(i):00+02:00", app: ("com.app\(i)", "App \(i)"))
        }
        XCTAssertEqual(compute(rows).topApplications.count, 5)
    }

    func testAnApplicationSeenUnderTwoNamesKeepsTheMostRecentName() {
        let stats = compute([
            row("2026-09-08T10:00:00+02:00", app: ("com.x", "Old Name")),
            row("2026-09-09T10:00:00+02:00", app: ("com.x", "New Name")),
        ])
        XCTAssertEqual(stats.topApplications.map(\.name), ["New Name"])
    }
}
```

- [ ] **Step 2: Run to verify failure**: `cd MurmureCore && swift test --filter DictationStatisticsTests` — compile errors.

- [ ] **Step 3: Implement** (`DictationStatistics.swift`; heatmap, hour profile, streak and records are computed in Task 6, return placeholders `[]`, `Array(repeating: 0, count: 24)`, `Streak(current: 0, longest: 0)`, `Records(nil, nil, nil)` for now)

```swift
import Foundation

public struct DictationStatistics: Equatable, Sendable {
    // (nested types exactly as in the Interfaces block above)

    public static func compute(rows: [DictationStatisticsRow], period: StatisticsPeriod,
                               now: Date, calendar: Calendar, typingWordsPerMinute: Int) -> DictationStatistics {
        let counting = rows.filter { $0.outcome == .inserted || $0.outcome == .copiedToClipboard }
        let start = period.start(now: now, calendar: calendar)
        let inPeriod = counting.filter { row in
            guard let start else { return true }
            return row.startedAt >= start          // no upper bound: "today" is inclusive whatever the hour
        }

        let words = inPeriod.reduce(0) { $0 + ($1.finalWordCount ?? 0) }
        let spoken = inPeriod.reduce(0.0) { $0 + $1.durationSeconds }

        let rawCounted = inPeriod.filter { $0.rawWordCount != nil }
        let rawWords = rawCounted.reduce(0) { $0 + ($1.rawWordCount ?? 0) }
        let rawSeconds = rawCounted.reduce(0.0) { $0 + $1.durationSeconds }
        let averageWPM: Double? = rawSeconds > 0 ? Double(rawWords) / (rawSeconds / 60) : nil

        let finalCounted = inPeriod.filter { $0.finalWordCount != nil }
        let timeSaved: Double? = finalCounted.isEmpty ? nil : finalCounted.reduce(0.0) { acc, row in
            acc + Double(row.finalWordCount ?? 0) / Double(typingWordsPerMinute) - row.durationSeconds / 60
        }

        // Applications: distinct bundle ids, name taken from the most recent row, top 5 by count.
        var byApp: [String: (name: String, count: Int, lastSeen: Date)] = [:]
        for row in inPeriod {
            guard let bundleID = row.targetBundleID else { continue }
            let name = row.targetAppName ?? bundleID
            if let existing = byApp[bundleID] {
                byApp[bundleID] = (row.startedAt > existing.lastSeen ? name : existing.name,
                                   existing.count + 1, max(existing.lastSeen, row.startedAt))
            } else {
                byApp[bundleID] = (name, 1, row.startedAt)
            }
        }
        let top = byApp.map { Application(bundleID: $0.key, name: $0.value.name, dictations: $0.value.count) }
            .sorted { $0.dictations != $1.dictations ? $0.dictations > $1.dictations : $0.name < $1.name }
            .prefix(5)

        let since = counting.filter { $0.finalWordCount != nil }.map(\.startedAt).min()

        return DictationStatistics(
            period: period, hasAnyDictation: !counting.isEmpty,
            dictations: inPeriod.count, words: words, spokenSeconds: spoken,
            averageWordsPerMinute: averageWPM, applicationCount: byApp.count,
            topApplications: Array(top), timeSavedMinutes: timeSaved, wordCountsSince: since,
            heatmap: [], hourProfile: Array(repeating: 0, count: 24),
            streak: Streak(current: 0, longest: 0),
            records: Records(longestDictationSeconds: nil, mostWordsInADay: nil, fastestWordsPerMinute: nil))
    }
}
```

Give `DictationStatistics` a public memberwise `init` (write it out) so tests in the app or later tasks can build fixtures.

- [ ] **Step 4: Run to verify pass**: same filter, 0 failures.

- [ ] **Step 5: Report**; orchestrator commits (`feat(stats): figures, applications and time saved`).

---

### Task 6: `DictationStatistics` — heatmap, hour profile, streak, records

**Files:**
- Modify: `MurmureCore/Sources/MurmureCore/DictationStatistics.swift`
- Test: `MurmureCore/Tests/MurmureCoreTests/DictationStatisticsTests.swift`

**Interfaces:**
- Produces the remaining fields. Heatmap definition: days from the Monday of the week 51 weeks before the current week, up to and including today; `column = index / 7`, `row = index % 7` (Monday 0); `level`: 0 when `dictations == 0`; 1 when `dictations > 0` and `words == 0`; else quartile of `words / maxWords` over the heatmap: ≤ 0.25 → 1, ≤ 0.5 → 2, ≤ 0.75 → 3, else 4. Heatmap, streak and records ignore the period (all time); hour profile follows the period.

- [ ] **Step 1: Write the failing tests** (append)

```swift
    // MARK: Heatmap

    func testHeatmapRunsFromTheMondayFiftyOneWeeksAgoToToday() {
        let stats = compute([row("2026-09-09T10:00:00+02:00", raw: 5, final: 5)])
        // now is Wednesday 2026-09-09; this week's Monday is 09-07; 51 weeks earlier: 2025-09-15.
        XCTAssertEqual(stats.heatmap.first?.day, t("2025-09-15T00:00:00+02:00"))
        XCTAssertEqual(stats.heatmap.last?.day, t("2026-09-09T00:00:00+02:00"))
        XCTAssertEqual(stats.heatmap.count, 51 * 7 + 3)          // 51 full weeks + Mon, Tue, Wed
        XCTAssertEqual(stats.heatmap.first?.column, 0)
        XCTAssertEqual(stats.heatmap.first?.row, 0)
        XCTAssertEqual(stats.heatmap.last?.column, 51)
        XCTAssertEqual(stats.heatmap.last?.row, 2)
    }

    func testHeatmapLevelsAreQuartilesOfTheBusiestDayWithActivityWithoutWordsAtLevelOne() {
        let stats = compute([
            row("2026-09-01T10:00:00+02:00", raw: 100, final: 100),   // max → 4
            row("2026-09-02T10:00:00+02:00", raw: 30, final: 30),     // 0.30 → 2
            row("2026-09-03T10:00:00+02:00", raw: 25, final: 25),     // 0.25 → 1
            row("2026-09-04T10:00:00+02:00", raw: 76, final: 76),     // 0.76 → 4
            row("2026-09-05T10:00:00+02:00"),                         // dictated, no count → 1
        ], period: .last7Days)                                         // period must not matter
        func level(_ iso: String) -> Int? { stats.heatmap.first { $0.day == t(iso) }?.level }
        XCTAssertEqual(level("2026-09-01T00:00:00+02:00"), 4)
        XCTAssertEqual(level("2026-09-02T00:00:00+02:00"), 2)
        XCTAssertEqual(level("2026-09-03T00:00:00+02:00"), 1)
        XCTAssertEqual(level("2026-09-04T00:00:00+02:00"), 4)
        XCTAssertEqual(level("2026-09-05T00:00:00+02:00"), 1)
        XCTAssertEqual(level("2026-09-06T00:00:00+02:00"), 0)
    }

    func testHeatmapIgnoresTheSelectedPeriodButNotTheOutcome() {
        let stats = compute([
            row("2026-06-01T10:00:00+02:00", raw: 1, final: 1),
            row("2026-06-02T10:00:00+02:00", outcome: .failed, raw: 1, final: 1),
        ], period: .last7Days)
        XCTAssertEqual(stats.heatmap.first { $0.day == t("2026-06-01T00:00:00+02:00") }?.dictations, 1)
        XCTAssertEqual(stats.heatmap.first { $0.day == t("2026-06-02T00:00:00+02:00") }?.dictations, 0)
    }

    // MARK: Hour profile

    func testHourProfileUsesLocalHoursOverTheSelectedPeriod() {
        let stats = compute([
            row("2026-09-09T08:15:00+02:00"),
            row("2026-09-09T08:45:00+02:00"),
            row("2026-09-09T23:59:00+02:00"),
            row("2026-01-01T08:00:00+01:00"),          // outside 7 days
        ], period: .last7Days)
        XCTAssertEqual(stats.hourProfile.count, 24)
        XCTAssertEqual(stats.hourProfile[8], 2)
        XCTAssertEqual(stats.hourProfile[23], 1)
        XCTAssertEqual(stats.hourProfile.reduce(0, +), 3)
    }

    // MARK: Streak

    func testCurrentStreakCountsBackFromTodayWhenTodayHasADictation() {
        let stats = compute(["09-07", "09-08", "09-09"].map { row("2026-\($0)T10:00:00+02:00") })
        XCTAssertEqual(stats.streak.current, 3)
    }

    func testCurrentStreakSurvivesADayWithoutADictationYet() {
        let stats = compute(["09-06", "09-07", "09-08"].map { row("2026-\($0)T10:00:00+02:00") })
        XCTAssertEqual(stats.streak.current, 3)
    }

    func testCurrentStreakIsZeroWhenNeitherTodayNorYesterdayHasADictation() {
        let stats = compute(["09-05", "09-06", "09-07"].map { row("2026-\($0)T10:00:00+02:00") })
        XCTAssertEqual(stats.streak.current, 0)
        XCTAssertEqual(stats.streak.longest, 3)
    }

    func testLongestStreakSpansAGapAndIgnoresDuplicateDays() {
        let stats = compute(["03-01", "03-02", "03-03", "03-03", "03-04", "03-10", "03-11"]
            .map { row("2026-\($0)T10:00:00+01:00") })
        XCTAssertEqual(stats.streak.longest, 4)
    }

    func testStreakDaysAreLocalDaysAcrossMidnight() {
        // 23:30 Paris on the 8th and 00:30 Paris on the 9th are two consecutive days
        let stats = compute([row("2026-09-08T23:30:00+02:00"), row("2026-09-09T00:30:00+02:00")])
        XCTAssertEqual(stats.streak.current, 2)
    }

    // MARK: Records

    func testRecordsPickTheLongestTheBiggestDayAndTheFastestWithGuards() {
        let stats = compute([
            row("2026-09-01T10:00:00+02:00", seconds: 300, raw: 400, final: 400),   // 80 wpm
            row("2026-09-02T10:00:00+02:00", seconds: 60, raw: 150, final: 150),    // 150 wpm ← fastest
            row("2026-09-02T11:00:00+02:00", seconds: 60, raw: 100, final: 100),    // day total 250 ← biggest day
            row("2026-09-03T10:00:00+02:00", seconds: 5, raw: 30, final: 30),       // 360 wpm but < 10 s: ignored
            row("2026-09-04T10:00:00+02:00", seconds: 20, raw: 10, final: 10),      // 30 wpm but < 20 words: ignored
        ], period: .last7Days)                                                       // records are all time
        XCTAssertEqual(stats.records.longestDictationSeconds?.value, 300)
        XCTAssertEqual(stats.records.longestDictationSeconds?.day, t("2026-09-01T00:00:00+02:00"))
        XCTAssertEqual(stats.records.mostWordsInADay?.value, 400)
        XCTAssertEqual(stats.records.mostWordsInADay?.day, t("2026-09-01T00:00:00+02:00"))
        XCTAssertEqual(stats.records.fastestWordsPerMinute!.value, 150, accuracy: 0.0001)
        XCTAssertEqual(stats.records.fastestWordsPerMinute?.day, t("2026-09-02T00:00:00+02:00"))
    }

    func testRecordsAreNilWithoutEligibleRows() {
        let stats = compute([row("2026-09-09T10:00:00+02:00", seconds: 3)])
        XCTAssertEqual(stats.records.longestDictationSeconds?.value, 3)
        XCTAssertNil(stats.records.mostWordsInADay)
        XCTAssertNil(stats.records.fastestWordsPerMinute)
    }
```

Note on `mostWordsInADay`: 2026-09-01 has 400 words in one dictation, 2026-09-02 has 250 across two; the biggest day is therefore 09-01 with 400. The assertion above is written accordingly.

- [ ] **Step 2: Run to verify failure**: expected failures on the new tests.

- [ ] **Step 3: Implement** (inside `compute`, replacing the placeholders)

```swift
        // Local day keys
        func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
        var perDay: [Date: (dictations: Int, words: Int)] = [:]
        for row in counting {
            let key = day(row.startedAt)
            let entry = perDay[key] ?? (0, 0)
            perDay[key] = (entry.dictations + 1, entry.words + (row.finalWordCount ?? 0))
        }

        // Heatmap: Monday of the current week, minus 51 weeks, through today.
        let today = day(now)
        let weekday = calendar.component(.weekday, from: today)        // 1 = Sunday … 7 = Saturday
        let mondayOffset = (weekday + 5) % 7                            // Monday 0 … Sunday 6
        let thisMonday = calendar.date(byAdding: .day, value: -mondayOffset, to: today)!
        let firstDay = calendar.date(byAdding: .day, value: -51 * 7, to: thisMonday)!
        var heatmapDays: [Date] = []
        var cursor = firstDay
        while cursor <= today {
            heatmapDays.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        let maxWords = heatmapDays.map { perDay[$0]?.words ?? 0 }.max() ?? 0
        let heatmap = heatmapDays.enumerated().map { index, date -> HeatmapDay in
            let entry = perDay[date] ?? (0, 0)
            let level: Int
            if entry.dictations == 0 { level = 0 }
            else if entry.words == 0 || maxWords == 0 { level = 1 }
            else {
                let ratio = Double(entry.words) / Double(maxWords)
                level = ratio <= 0.25 ? 1 : ratio <= 0.5 ? 2 : ratio <= 0.75 ? 3 : 4
            }
            return HeatmapDay(day: date, dictations: entry.dictations, words: entry.words,
                              level: level, column: index / 7, row: index % 7)
        }

        // Hour profile over the period
        var hours = Array(repeating: 0, count: 24)
        for row in inPeriod { hours[calendar.component(.hour, from: row.startedAt)] += 1 }

        // Streaks over all time
        let days = Set(perDay.keys)
        var current = 0
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            var probe: Date? = days.contains(today) ? today : (days.contains(yesterday) ? yesterday : nil)
            while let p = probe, days.contains(p) {
                current += 1
                probe = calendar.date(byAdding: .day, value: -1, to: p)
            }
        }
        var longest = 0, run = 0
        var previous: Date?
        for d in days.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == d { run += 1 } else { run = 1 }
            longest = max(longest, run)
            previous = d
        }

        // Records over all time
        let longestRow = counting.max { $0.durationSeconds < $1.durationSeconds }
        let biggestDay = perDay.filter { $0.value.words > 0 }
            .max { $0.value.words != $1.value.words ? $0.value.words < $1.value.words : $0.key > $1.key }
        let fastestRow = counting
            .filter { $0.durationSeconds >= 10 && ($0.rawWordCount ?? 0) >= 20 }
            .max { wpm($0) < wpm($1) }
        func wpm(_ r: DictationStatisticsRow) -> Double { Double(r.rawWordCount ?? 0) * 60 / r.durationSeconds }
```

(`wpm` must be declared before use; place it above the records block.) Then fill `heatmap`, `hourProfile: hours`, `streak: Streak(current: current, longest: longest)`, and

```swift
            records: Records(
                longestDictationSeconds: longestRow.map { Record(value: $0.durationSeconds, day: day($0.startedAt)) },
                mostWordsInADay: biggestDay.map { Record(value: $0.value.words, day: $0.key) },
                fastestWordsPerMinute: fastestRow.map { Record(value: wpm($0), day: day($0.startedAt)) })
```

- [ ] **Step 4: Run to verify pass**: `swift test --filter DictationStatisticsTests`, then the whole package.

- [ ] **Step 5: Report**; orchestrator commits (`feat(stats): heatmap, hour profile, streaks and records`).

---

### Task 7: `StatisticsFormatting`

**Files:**
- Create: `MurmureCore/Sources/MurmureCore/StatisticsFormatting.swift`
- Test: `MurmureCore/Tests/MurmureCoreTests/StatisticsFormattingTests.swift`

**Interfaces:**
- Produces: `public enum StatisticsFormatting` with `static func minutes(_ minutes: Double?) -> String` (`"—"` for nil; `"12 min"`, `"1h 05min"`, `"-1.5 min"` → rounds to whole minutes: `"−2 min"` uses a true minus sign U+2212), `static func wordsPerMinute(_ wpm: Double?) -> String` (`"—"`, `"142"`), `static func count(_ n: Int) -> String` (grouped with the given locale, default `Locale(identifier: "en_GB")`: `"12,345"`), `static func duration(_ seconds: Double) -> String` (`"38 s"`, `"2 min 38 s"`, `"1 h 02 min"`), `static func dash: String = "—"`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MurmureCore

final class StatisticsFormattingTests: XCTestCase {
    func testMinutesRoundToWholeMinutesAndSplitHours() {
        XCTAssertEqual(StatisticsFormatting.minutes(nil), "—")
        XCTAssertEqual(StatisticsFormatting.minutes(0), "0 min")
        XCTAssertEqual(StatisticsFormatting.minutes(12.4), "12 min")
        XCTAssertEqual(StatisticsFormatting.minutes(65), "1h 05min")
        XCTAssertEqual(StatisticsFormatting.minutes(600), "10h 00min")
        XCTAssertEqual(StatisticsFormatting.minutes(-1.5), "−2 min")
        XCTAssertEqual(StatisticsFormatting.minutes(-75), "−1h 15min")
    }

    func testWordsPerMinuteIsAWholeNumberOrADash() {
        XCTAssertEqual(StatisticsFormatting.wordsPerMinute(nil), "—")
        XCTAssertEqual(StatisticsFormatting.wordsPerMinute(141.6), "142")
    }

    func testCountsAreGrouped() {
        XCTAssertEqual(StatisticsFormatting.count(12345), "12,345")
        XCTAssertEqual(StatisticsFormatting.count(7), "7")
    }

    func testDurationsPickTheRightUnits() {
        XCTAssertEqual(StatisticsFormatting.duration(38.25), "38 s")
        XCTAssertEqual(StatisticsFormatting.duration(158), "2 min 38 s")
        XCTAssertEqual(StatisticsFormatting.duration(3720), "1 h 02 min")
    }
}
```

- [ ] **Step 2: Run to verify failure** (compile error).

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Display strings for the Home figures. Pure so the rounding rules are pinned by tests rather
/// than rediscovered in a view.
public enum StatisticsFormatting {
    public static let dash = "—"

    public static func minutes(_ minutes: Double?) -> String {
        guard let minutes else { return dash }
        let whole = Int(minutes.rounded(.toNearestOrAwayFromZero))
        let sign = whole < 0 ? "−" : ""
        let magnitude = abs(whole)
        if magnitude < 60 { return "\(sign)\(magnitude) min" }
        return "\(sign)\(magnitude / 60)h \(String(format: "%02d", magnitude % 60))min"
    }

    public static func wordsPerMinute(_ wpm: Double?) -> String {
        guard let wpm else { return dash }
        return String(Int(wpm.rounded()))
    }

    public static func count(_ n: Int, locale: Locale = Locale(identifier: "en_GB")) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min \(total % 60) s" }
        return "\(total / 3600) h \(String(format: "%02d", (total % 3600) / 60)) min"
    }
}
```

- [ ] **Step 4: Run to verify pass**.

- [ ] **Step 5: Report**; orchestrator commits (`feat(stats): display formatting`).

---

### Task 8: `WindowSection.home` and `HomeLayout`

**Files:**
- Modify: `MurmureCore/Sources/MurmureCore/WindowSection.swift`
- Create: `MurmureCore/Sources/MurmureCore/HomeLayout.swift`
- Test: the existing `WindowSection` tests (find with `grep -l "WindowSection" MurmureCore/Tests/MurmureCoreTests/*.swift`), create `HomeLayoutTests.swift`

**Interfaces:**
- Produces: `WindowSection.home` (first case, title `"Home"`, symbol `"chart.bar.xaxis"`, group `.material`), `WindowSection.fallback == .home`; `HomeLayout` constants below.

- [ ] **Step 1: Write the failing tests**

Update the pinned-order test in the WindowSection tests so the expected array starts with `.home` and the expected fallback is `.home`; add:

```swift
    func testHomeIsAMaterialSectionWithItsOwnSymbol() {
        XCTAssertEqual(WindowSection.home.title, "Home")
        XCTAssertEqual(WindowSection.home.symbolName, "chart.bar.xaxis")
        XCTAssertEqual(WindowSection.home.group, .material)
        XCTAssertEqual(WindowSection.sections(in: .material).first, .home)
        XCTAssertEqual(WindowSection.fallback, .home)
    }
```

`HomeLayoutTests.swift`:

```swift
import XCTest
@testable import MurmureCore

final class HomeLayoutTests: XCTestCase {
    func testConstantsArePinned() {
        XCTAssertEqual(HomeLayout.panePadding, 16)
        XCTAssertEqual(HomeLayout.contentMaxWidth, 920)
        XCTAssertEqual(HomeLayout.cardCornerRadius, 12)
        XCTAssertEqual(HomeLayout.cardPadding, 16)
        XCTAssertEqual(HomeLayout.gridSpacing, 12)
        XCTAssertEqual(HomeLayout.figureFontSize, 30)
        XCTAssertEqual(HomeLayout.heatmapCellSize, 11)
        XCTAssertEqual(HomeLayout.heatmapCellGap, 3)
        XCTAssertEqual(HomeLayout.heatBrightness, [0.35, 0.55, 0.75, 1.0])
    }
}
```

- [ ] **Step 2: Run to verify failure**.

- [ ] **Step 3: Implement**

`WindowSection.swift`: add `case home` before `case history`; `fallback = .home`; `title` → `"Home"`; `symbolName` → `"chart.bar.xaxis"`; `group` → include `.home` in the `.material` line. Read the doc comments in the file and keep them accurate (the sidebar-order comment).

`HomeLayout.swift`:

```swift
import CoreGraphics

/// Layout constants of the Home pane. Pinned by `HomeLayoutTests` so a drift is a deliberate act.
public enum HomeLayout {
    /// Outer padding of the pane; the other panes use the same 16 pt as a literal.
    public static let panePadding: CGFloat = 16
    public static let contentMaxWidth: CGFloat = 920
    public static let cardCornerRadius: CGFloat = 12
    public static let cardPadding: CGFloat = 16
    public static let gridSpacing: CGFloat = 12
    public static let figureFontSize: CGFloat = 30
    public static let heatmapCellSize: CGFloat = 11
    public static let heatmapCellGap: CGFloat = 3
    /// Brightness of the accent hue for heatmap levels 1…4; level 0 uses the hairline role.
    public static let heatBrightness: [Double] = [0.35, 0.55, 0.75, 1.0]
}
```

- [ ] **Step 4: Run to verify pass**: `swift test --filter "WindowSection|HomeLayout"`, then the whole package (`WindowRestoration` tests may reference the fallback: fix expectations, not behaviour).

- [ ] **Step 5: Report**; orchestrator commits (`feat(window): Home section first, HomeLayout`).

---

### Task 9: app pane — `HomePaneModel`, `HomePaneView`, cards, wiring

**Files:**
- Create: `Murmure/HomePaneModel.swift`, `Murmure/HomePaneView.swift`, `Murmure/HomeCards.swift`
- Modify: `Murmure/MainWindowView.swift` (add `@ObservedObject var home: HomePaneModel` next to `history`; add `case .home: HomePaneView(model: home)` to `pane`), `Murmure/MurmureApp.swift` (construct `HomePaneModel(store:settings:)` exactly where `HistoryPaneModel(` is constructed and pass it to `MainWindowView`; grep `HistoryPaneModel(` and `MainWindowView(` to find both places).

**Interfaces:**
- Consumes: `HistoryStore.statisticsRows()`, `DictationStatistics.compute`, `StatisticsPeriod`, `StatisticsFormatting`, `HomeLayout`, `AppSettings.typingWordsPerMinute/homeStatisticsPeriod`, `AppState.historyRevision`, `Color(role:)`, `WindowRole`, `NotchAppearance.accentHue/accentSaturation`.

- [ ] **Step 1: `HomePaneModel.swift`**

```swift
import Foundation
import MurmureCore
import os

/// Thin: fetches the text-free projection, computes off the main actor, publishes. Every rule is
/// in `DictationStatistics`; this file only decides when to recompute.
@MainActor
final class HomePaneModel: ObservableObject {
    @Published private(set) var statistics: DictationStatistics?
    @Published var period: StatisticsPeriod {
        didSet { if oldValue != period { settings.homeStatisticsPeriod = period; reload() } }
    }
    @Published var typingWordsPerMinute: Int {
        didSet { if oldValue != typingWordsPerMinute { settings.typingWordsPerMinute = typingWordsPerMinute; reload() } }
    }

    private let store: HistoryStore?
    private let settings: AppSettings
    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "home")
    private var generation = 0

    init(store: HistoryStore?, settings: AppSettings) {
        self.store = store
        self.settings = settings
        self.period = settings.homeStatisticsPeriod
        self.typingWordsPerMinute = settings.typingWordsPerMinute
    }

    func reload() {
        guard let store else { statistics = nil; return }
        generation += 1
        let expected = generation
        let period = period
        let typing = typingWordsPerMinute
        Task.detached(priority: .userInitiated) { [log] in
            let result: DictationStatistics?
            do {
                let rows = try store.statisticsRows()
                result = DictationStatistics.compute(rows: rows, period: period, now: Date(),
                                                     calendar: .autoupdatingCurrent,
                                                     typingWordsPerMinute: typing)
            } catch {
                log.error("statistics not computed: \(error.localizedDescription, privacy: .public)")
                result = nil
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == expected else { return }
                self.statistics = result
            }
        }
    }
}
```

The `Logger` subsystem string matches the one the other pane models use (`com.louiscourcier.Murmure`).

- [ ] **Step 2: `HomeCards.swift`**

```swift
import AppKit
import Charts
import MurmureCore
import SwiftUI

struct HomeCard<Content: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(role: .primaryText))
                Spacer()
                if let caption {
                    Text(caption).font(.system(size: 11)).foregroundStyle(Color(role: .secondaryText))
                }
            }
            content
        }
        .padding(HomeLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeLayout.cardCornerRadius, style: .continuous)
                .fill(Color(role: .cardBackground))
                .overlay(RoundedRectangle(cornerRadius: HomeLayout.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color(role: .hairline), lineWidth: 1)))
    }
}

struct StatCard: View {
    let label: String
    let value: String
    var footnote: String? = nil
    var accessory: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Color(role: .secondaryText))
                Spacer()
                accessory
            }
            Text(value)
                .font(.system(size: HomeLayout.figureFontSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(role: .primaryText))
                .contentTransition(.numericText())
            if let footnote {
                Text(footnote).font(.system(size: 11)).foregroundStyle(Color(role: .secondaryText))
            }
        }
        .padding(HomeLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeLayout.cardCornerRadius, style: .continuous)
                .fill(Color(role: .cardBackground))
                .overlay(RoundedRectangle(cornerRadius: HomeLayout.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color(role: .hairline), lineWidth: 1)))
    }
}

enum HeatStyle {
    static func color(level: Int) -> Color {
        guard level > 0 else { return Color(role: .hairline) }
        let brightness = HomeLayout.heatBrightness[min(level, HomeLayout.heatBrightness.count) - 1]
        return Color(hue: NotchAppearance.accentHue, saturation: NotchAppearance.accentSaturation,
                     brightness: brightness)
    }
}

struct HeatmapCard: View {
    let days: [DictationStatistics.HeatmapDay]
    let dictations: Int

    private var monthLabels: [(column: Int, text: String)] {
        // Label a column when its first day is the first Monday that falls within a month's first week.
        var seen = Set<Int>()
        var labels: [(Int, String)] = []
        let formatter = DateFormatter(); formatter.dateFormat = "MMM"
        for day in days where day.row == 0 {
            let month = Calendar.autoupdatingCurrent.component(.month, from: day.day)
            let dayOfMonth = Calendar.autoupdatingCurrent.component(.day, from: day.day)
            if dayOfMonth <= 7, !seen.contains(month) {
                seen.insert(month); labels.append((day.column, formatter.string(from: day.day)))
            }
        }
        return labels
    }

    var body: some View {
        HomeCard(title: "Activity", caption: "Last 52 weeks · \(StatisticsFormatting.count(dictations)) dictations") {
            Chart(days, id: \.day) { day in
                RectangleMark(
                    xStart: .value("Week", day.column), xEnd: .value("Week", day.column + 1),
                    yStart: .value("Day", 6 - day.row), yEnd: .value("Day", 7 - day.row))
                .foregroundStyle(HeatStyle.color(level: day.level))
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: monthLabels.map(\.column)) { value in
                    if let column = value.as(Int.self), let label = monthLabels.first(where: { $0.column == column }) {
                        AxisValueLabel { Text(label.text).font(.system(size: 10)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: [6.5, 4.5, 2.5]) { value in
                    AxisValueLabel {
                        Text(value.as(Double.self) == 6.5 ? "Mon" : value.as(Double.self) == 4.5 ? "Wed" : "Fri")
                            .font(.system(size: 10))
                    }
                }
            }
            .chartXScale(domain: 0...52)
            .chartYScale(domain: 0...7)
            .chartLegend(.hidden)
            .frame(height: 7 * (HomeLayout.heatmapCellSize + HomeLayout.heatmapCellGap) + 24)
            .chartPlotStyle { $0.padding(.zero) }
        }
    }
}
```

The `RectangleMark` cells fill their slot; to leave the visual gap, apply `.cornerRadius(2)` and set the plot frame so each slot is `cellSize + gap` wide; if the gap is not visible, wrap each mark in `RectangleMark(...).offset(...)` is not available, so instead draw with `xStart/xEnd` narrowed: `xStart: .value("Week", Double(day.column) + 0.1), xEnd: .value("Week", Double(day.column) + 0.9)` and likewise for y. Use that form.

```swift
struct HourProfileCard: View {
    let hours: [Int]
    var body: some View {
        HomeCard(title: "When you dictate", caption: nil) {
            Chart(Array(hours.enumerated()), id: \.offset) { hour, count in
                BarMark(x: .value("Hour", hour), y: .value("Dictations", count))
                    .foregroundStyle(HeatStyle.color(level: count == 0 ? 0 : 3))
                    .cornerRadius(2)
            }
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { v in AxisValueLabel { Text("\(v.as(Int.self) ?? 0)h").font(.system(size: 10)) } } }
            .chartYAxis(.hidden)
            .frame(height: 96)
        }
    }
}

struct StreakCard: View {
    let streak: DictationStatistics.Streak
    var body: some View {
        HomeCard(title: "Streak", caption: "All time") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "flame").foregroundStyle(HeatStyle.color(level: streak.current > 0 ? 4 : 0))
                Text("\(streak.current)").font(.system(size: HomeLayout.figureFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit().contentTransition(.numericText())
                Text(streak.current == 1 ? "day" : "days").foregroundStyle(Color(role: .secondaryText))
            }
            Text("Longest: \(streak.longest) \(streak.longest == 1 ? "day" : "days")")
                .font(.system(size: 12)).foregroundStyle(Color(role: .secondaryText))
        }
    }
}

struct RecordsCard: View {
    let records: DictationStatistics.Records
    private static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f }()

    var body: some View {
        HomeCard(title: "Records", caption: "All time") {
            row("Longest dictation",
                records.longestDictationSeconds.map { StatisticsFormatting.duration($0.value) },
                records.longestDictationSeconds?.day)
            row("Biggest day",
                records.mostWordsInADay.map { "\(StatisticsFormatting.count($0.value)) words" },
                records.mostWordsInADay?.day)
            row("Fastest",
                records.fastestWordsPerMinute.map { "\(StatisticsFormatting.wordsPerMinute($0.value)) wpm" },
                records.fastestWordsPerMinute?.day)
        }
    }

    private func row(_ label: String, _ value: String?, _ day: Date?) -> some View {
        HStack {
            Text(label).foregroundStyle(Color(role: .secondaryText))
            Spacer()
            Text(value ?? StatisticsFormatting.dash).monospacedDigit().foregroundStyle(Color(role: .primaryText))
            if let day {
                Text(Self.dayFormatter.string(from: day)).font(.system(size: 11)).foregroundStyle(Color(role: .secondaryText))
                    .frame(width: 96, alignment: .trailing)
            }
        }
        .font(.system(size: 12))
    }
}

struct TopApplicationsCard: View {
    let applications: [DictationStatistics.Application]
    var body: some View {
        HomeCard(title: "Top applications", caption: nil) {
            if applications.isEmpty {
                Text(StatisticsFormatting.dash).foregroundStyle(Color(role: .secondaryText))
            }
            let maxCount = applications.first?.dictations ?? 1
            ForEach(applications, id: \.bundleID) { app in
                HStack(spacing: 8) {
                    Image(nsImage: Self.icon(for: app.bundleID)).resizable().frame(width: 18, height: 18)
                    Text(app.name).font(.system(size: 12)).foregroundStyle(Color(role: .primaryText)).lineLimit(1)
                    Spacer(minLength: 8)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(HeatStyle.color(level: 3))
                            .frame(width: proxy.size.width * CGFloat(app.dictations) / CGFloat(maxCount))
                    }
                    .frame(width: 120, height: 6)
                    Text(StatisticsFormatting.count(app.dictations)).font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(Color(role: .secondaryText)).frame(width: 48, alignment: .trailing)
                }
            }
        }
    }

    /// The app's icon if it is installed, else a generic one. Read-only lookup, no launch.
    private static func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
```

- [ ] **Step 3: `HomePaneView.swift`**

```swift
import MurmureCore
import SwiftUI

struct HomePaneView: View {
    @ObservedObject var model: HomePaneModel
    @EnvironmentObject private var appState: AppState
    @State private var showsTypingPopover = false

    var body: some View {
        Group {
            if let stats = model.statistics, stats.hasAnyDictation {
                ScrollView {
                    VStack(alignment: .leading, spacing: HomeLayout.gridSpacing) {
                        header
                        figures(stats)
                        HeatmapCard(days: stats.heatmap, dictations: stats.heatmap.reduce(0) { $0 + $1.dictations })
                        HStack(alignment: .top, spacing: HomeLayout.gridSpacing) {
                            HourProfileCard(hours: stats.hourProfile)
                            StreakCard(streak: stats.streak)
                        }
                        HStack(alignment: .top, spacing: HomeLayout.gridSpacing) {
                            RecordsCard(records: stats.records)
                            TopApplicationsCard(applications: stats.topApplications)
                        }
                    }
                    .frame(maxWidth: HomeLayout.contentMaxWidth)
                    .padding(HomeLayout.panePadding)
                    .frame(maxWidth: .infinity)
                }
            } else if model.statistics != nil {
                ContentUnavailableView("No dictation yet", systemImage: "waveform",
                                       description: Text("Press your shortcut and speak. Your statistics will appear here."))
            } else {
                Color.clear
            }
        }
        .background(Color(role: .paneBackground))
        .onAppear { model.reload() }
        .onChange(of: appState.historyRevision) { _, _ in model.reload() }
    }

    private var header: some View {
        HStack {
            Text("Home").font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(role: .primaryText))
            Spacer()
            Picker("Period", selection: $model.period) {
                ForEach(StatisticsPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
        }
    }

    private func figures(_ stats: DictationStatistics) -> some View {
        HStack(alignment: .top, spacing: HomeLayout.gridSpacing) {
            StatCard(label: "Average WPM", value: StatisticsFormatting.wordsPerMinute(stats.averageWordsPerMinute))
            StatCard(label: "Words", value: StatisticsFormatting.count(stats.words), footnote: wordsFootnote(stats))
            StatCard(label: "Applications", value: StatisticsFormatting.count(stats.applicationCount))
            StatCard(label: "Time saved", value: StatisticsFormatting.minutes(stats.timeSavedMinutes),
                     footnote: "vs typing at \(model.typingWordsPerMinute) wpm",
                     accessory: AnyView(typingGear))
        }
    }

    private func wordsFootnote(_ stats: DictationStatistics) -> String? {
        guard let since = stats.wordCountsSince else { return nil }
        let start = stats.period.start(now: Date(), calendar: .autoupdatingCurrent)
        guard start == nil || start! < since else { return nil }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return "counted since \(f.string(from: since))"
    }

    private var typingGear: some View {
        Button { showsTypingPopover.toggle() } label: {
            Image(systemName: "gearshape").font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(role: .secondaryText))
        .popover(isPresented: $showsTypingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Typing speed used for the comparison").font(.system(size: 12, weight: .semibold))
                HStack {
                    Slider(value: Binding(get: { Double(model.typingWordsPerMinute) },
                                          set: { model.typingWordsPerMinute = Int($0.rounded()) }),
                           in: Double(AppSettings.typingWordsPerMinuteRange.lowerBound)...Double(AppSettings.typingWordsPerMinuteRange.upperBound),
                           step: 5)
                    Stepper("\(model.typingWordsPerMinute) wpm", value: $model.typingWordsPerMinute,
                            in: AppSettings.typingWordsPerMinuteRange, step: 5).monospacedDigit()
                }
                Text("Time saved = time to type the words at this speed, minus time spent speaking.")
                    .font(.system(size: 11)).foregroundStyle(Color(role: .secondaryText))
            }
            .padding(14)
            .frame(width: 340)
        }
    }
}
```

- [ ] **Step 4: Wire** `MainWindowView` (property + `case .home: HomePaneView(model: home)`) and `MurmureApp` (construct `HomePaneModel(store: <the same store handed to HistoryPaneModel>, settings: <the AppSettings instance>)`, pass as `home:`).

- [ ] **Step 5: Build**

Run from the repo root: `xcodegen generate && xcodebuild -project Murmure.xcodeproj -scheme Murmure -configuration Debug -derivedDataPath .build/xcode build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. Paste that line in the report. Fix compile errors in your own files; if the error is in a file you did not touch, report it, do not "fix" it.

- [ ] **Step 6: Report** with every file touched; orchestrator commits (`feat(home): statistics pane`).

---

### Task 10: docs

**Files:**
- Modify: `docs/plans/2026-09-backlog.md` (add `## 9. Home statistics pane — CLOSED` following the shape of §8: what shipped, what is measured, what is deliberately not shipped: delta raw/refined, equivalences, rollup table), `docs/design/ui-design-notes.md` (a Home section describing the card grid, period rule, heatmap rule, the typing-baseline popover, the empty state).

- [ ] **Step 1: Write both sections** (British English, no emoji, no owner data).
- [ ] **Step 2: Run the whole package once more**: `cd MurmureCore && swift test` — report the totals line verbatim.
- [ ] **Step 3: Report**; orchestrator commits (`docs: Home statistics pane`).

---

## Orchestrator steps after Task 10 (not for implementers)

1. `verifier` review of the full diff against the spec; re-run one mutation (e.g. flip the `>= 10` guard) to confirm a test goes red.
2. Install: `scripts/install.sh` quits the running Murmure; warn Louis, run it, relaunch with `open "$HOME/Applications/Murmure.app"`.
3. Push with the account dance (`gh auth switch --user Loulouleloup1`, push `feat/murmure-v1` and `feat/murmure-v1:main`, restore `LouisCourcier`).
4. Ask Louis for the eye-gate: Home opens first; figures match a hand count on a few visible rows; the gear changes Time saved live; the heatmap shows the right weekday for a known dictation; the empty state is not shown when data exists.
