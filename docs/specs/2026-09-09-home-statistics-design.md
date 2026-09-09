# Murmure — Home statistics pane (design spec)

Date: 2026-09-09
Status: validated section-by-section with Louis during brainstorming (approaches, then the four
sections below); written for implementation planning. One lot.
Companion research: `docs/research/2026-09-09-preparation-youtube-and-stats.md` and
`docs/research/2026-09-09-stats-dashboard-brief.md`.

## 1. Purpose

A first screen that shows what the user gets out of dictating: how much they speak, how fast, into
which apps, how much typing time it replaces, and a few honest, fun facts (activity heatmap, streaks,
personal records). Superwhisper's Home is the reference shape (period picker, four figures);
Wispr Flow's Usage tab is the reference for the heatmap and streaks. Nothing leaves the machine, no
notifications, no nagging.

Not in scope: the "raw versus refined" delta widget, "equivalent to N novels" lines, weekly
recaps, badges, onboarding checklist, changelog card. Full-text search of history stays out of
scope as decided earlier.

## 2. Data

### 2.1 Word counts on the dictation row

Migration `v3-wordCounts` on table `dictation`, two nullable integer columns:

- `rawWordCount`: words in `rawTranscript`.
- `finalWordCount`: words in the text that actually went to the target application, i.e.
  `refinedText` if present, else `correctedText`, else `rawTranscript`.

Plain `ALTER TABLE ADD COLUMN`; no FTS rebuild (the counts are not searchable text). `HistoryRecord`
gains the two `Int?` properties; the round-trip tests in `HistoryStoreTests` cover them.

Rows are written with both counts at archive time (`DictationSession.archive`). A one-off
backfill runs inside the `v3-wordCounts` migration itself, in the same transaction as the
`ALTER TABLE`: every row whose text is still present gets its counts computed and stored; rows
already purged of text keep null counts and simply do not contribute words (they still contribute
duration and dictation count). A migration runs exactly once, so the backfill is idempotent by
construction. Only rows of the last 30 days still carry text, so the one-off cost at first launch
is a fraction of a second.

### 2.2 `WordCount`

Pure function in MurmureCore: split on Unicode whitespace and newlines, count the tokens that
contain at least one letter or digit. Consequences, pinned by tests: `l'affaire` is one word,
`--` or `…` alone is zero, `dbt` is one, `2026` is one, a number with a thin space is two. It is
deliberately simple and language-agnostic; it is not a linguistic tokenizer.

### 2.3 Typing baseline setting

`AppSettings.typingWordsPerMinute: Int`, key `typingWordsPerMinute`, default 40, clamped to
20…120 on read and on write. Used only by the time-saved figure.

## 3. Computation

### 3.1 One projection, one pure function

`HistoryStore.statisticsRows()` returns a light projection of every row, no text columns:
`startedAt`, `durationSeconds`, `outcome`, `rawWordCount`, `finalWordCount`, `targetBundleID`,
`targetAppName`, `modeName`. At the current volume (a few thousand rows) this is a few hundred
kilobytes and takes milliseconds; SQL aggregation was rejected because day boundaries depend on the
local calendar and time zone, which SQLite's `date()` does not know.

`DictationStatistics.compute(rows:, period:, calendar:, now:, typingWordsPerMinute:)` is a pure
function in MurmureCore returning a `DictationStatistics` value. All tests use a fixed `now` and an
explicit calendar and time zone.

### 3.2 Which rows count

Only successful dictations count: `outcome` is `inserted` or `copiedToClipboard`. Failures, cancels
and "nothing heard" are excluded from every figure (they are still visible in History).

### 3.3 Periods

`StatisticsPeriod`: `last7Days`, `last30Days`, `last12Months`, `allTime`. The period applies to the
four figures and to the top applications. The heatmap always covers the last 52 weeks ending today,
and streaks and records are always computed over all time; the screen says so next to them.

### 3.4 Definitions

- Dictations: count of counting rows in the period.
- Total words: sum of `finalWordCount` (null counts contribute zero). Word counts exist only for
  rows archived after the migration and for rows whose text was still present at backfill time, so
  all-time words undercount older dictations; the caption on the Words card says "since <date of
  the migration>" when the period reaches before it.
- Spoken time: sum of `durationSeconds`.
- Average WPM: total `rawWordCount` divided by total spoken minutes, over rows that have a raw count
  (weighted average, never a mean of per-row speeds). Undefined when spoken time is zero: shown as
  a dash.
- Applications: distinct non-null `targetBundleID` count, plus the top five by dictation count with
  `targetAppName` and count.
- Time saved: sum over rows that have a final count of `finalWordCount / typingWPM −
  durationSeconds / 60`, in minutes. May be negative and is shown negative if so. Rows without a
  final count are excluded (counting their duration alone would drag the figure down for every row
  purged of text before the migration).
- Heatmap: for each day from the Monday of the week 51 weeks ago through today (358 to 364 days,
  52 week columns), the number of dictations and the sum of final words. Cells are bucketed into five
  intensity levels: 0 without dictation, 1 with dictations but no counted words, else quartiles of
  words relative to the busiest day in the heatmap window.
- Hour profile: dictations per local hour of day, 0…23, over the selected period.
- Current streak: number of consecutive local days with at least one dictation, ending today or
  yesterday (a streak survives a day that has not had a dictation yet). Longest streak: over all time.
- Records, all time: longest dictation (`durationSeconds`, date), most words in a single day (words,
  date), fastest dictation in WPM among rows with `durationSeconds ≥ 10` and `rawWordCount ≥ 20`
  (WPM, date). Absent records are shown as a dash.

## 4. Screen

### 4.1 Sidebar

`WindowSection.home` is added first in the enum (sidebar order is enum order), title "Home", a
coloured `.material` tile, symbol `chart.bar.xaxis` or the nearest SF Symbol with the same reading.
`WindowSection.fallback` becomes `.home`, so a fresh install and an unrecognised stored section open
on Home; the existing restoration of the last visited section is unchanged. Both exhaustive
switches (`WindowSection` and `MainWindowView.pane`) gain the new case.

### 4.2 Layout

`HomeLayout` in MurmureCore holds the constants (card corner radius, grid spacing, figure font
size, heatmap cell size and gap), pinned by `HomeLayoutTests`. The pane is a vertical scroll of
cards on `Color(role: .paneBackground)`, cards on `Color(role: .cardBackground)` with the hairline.

Top row: pane title on the left, period picker on the right (a segmented control: 7 days,
30 days, 12 months, All time). The choice persists in `AppSettings` under `homeStatisticsPeriod`.

Row 1, four `StatCard`s: Average WPM, Words, Applications, Time saved. Big figure with
`.contentTransition(.numericText())`, small label under it. The Time saved card carries a small
gear button opening a popover: "Typing speed used for the comparison", a stepper and slider bound
to `typingWordsPerMinute`, and the sentence "Time saved = time to type the words at this speed,
minus time spent speaking". Time is formatted as `Xh Ymin` or `Y min`, negative values with a
leading minus.

Row 2, heatmap card, full width: 52 columns × 7 rows of `RectangleMark` in Swift Charts, Monday at
the top, month initials along the bottom axis, five levels of the accent hue from `NotchAppearance`
(lightest for zero). Caption: "Last 52 weeks · N dictations". No hover tooltip in V1.

Row 3, two cards side by side: Hour profile (24 `BarMark`s, local hours, caption "When you
dictate"), and Streak (current streak with `flame` SF Symbol, longest streak underneath, caption
"All time").

Row 4, two cards: Records (three rows: longest dictation, biggest day, fastest, each with value and
date, caption "All time"), and Top applications (up to five rows: app icon from
`NSWorkspace.shared.icon(forFile:)` resolved through `urlForApplication(withBundleIdentifier:)`,
name, count, a thin proportional bar).

Empty state: when no counting row exists in the whole table, the pane shows a single
`ContentUnavailableView` ("No dictation yet", "Press your shortcut and speak. Your statistics will
appear here."). When the period has no rows but all time does, the four figures show zero or a
dash and the other cards keep their all-time content.

### 4.3 Refresh

`HomePaneModel` (app target, thin) loads on appear and on `appState.historyRevision` change; it
calls `statisticsRows()` on the store and `DictationStatistics.compute` off the main actor, then
publishes the value. No timer.

## 5. Verification

MurmureCore tests, XCTest, one file per type:

- `WordCountTests`: the cases in 2.2.
- `DictationStatisticsTests`: fixtures with fixed dates around midnight and a non-UTC time zone;
  period boundaries inclusive of today; excluded outcomes; weighted WPM versus mean; negative time
  saved; null counts; heatmap length 364 and level bucketing; hour profile; streak alive when
  yesterday has a dictation and today none, broken when two days are missing; longest streak across
  a gap; record guards (a 5-second row with 30 words is not the fastest).
- `HistoryStoreTests`: v3 round-trip of the two columns; a v2 database opens and migrates; backfill
  fills counts only where text exists and is idempotent; `statisticsRows()` carries no text.
- `AppSettingsTests`: default 40, clamping, period persistence.
- `HomeLayoutTests`: constants pinned.

App target: `xcodebuild` must print `BUILD SUCCEEDED`. The pane itself is verified by Louis's
eye-gate: Home opens first, figures match a hand count on a few visible rows, the gear changes the
time-saved value live, the heatmap shows the right weekday for a known dictation.

## 6. Out of scope, noted

Raw-versus-refined delta (would need the diff stored before purge), search, notifications, sharing
cards, a rollup table (unneeded while rows survive purge; revisit if row deletion is ever added).
