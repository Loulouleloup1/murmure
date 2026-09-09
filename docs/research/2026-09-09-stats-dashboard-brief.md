---
type: research
source: web
confidence: medium
as-of: 2026-09-09
repos: [murmure]
---

# Dictation-app stats dashboards — research brief

## Actionable bullets
1. Copy Wispr Flow's shape, not its numbers: WPM + percentile, total-words counter with a %-change badge, a Sun–Sat contribution heatmap, current/longest streak, and an app-usage bar chart — all computable from Murmure's existing fields (docs.wisprflow.ai, 2026 usage-tab article).
2. Anchor "time saved" on a stated, adjustable typing baseline (40 WPM is the most common default; Voibe's calculator ladder is 40/60/80) versus measured *speaking* WPM from Murmure's own timestamps — never a fixed industry number — and label the assumption on-screen to avoid the credibility hit Wispr Flow took over its 200-220 WPM claim (Reddit-driven CTO apology, referenced in 2026 reviews).
3. Build the heatmap with Swift Charts `RectangleMark` (iOS 16+/macOS 13+); Artem Novichkov's 2026 write-up and `VIkill33/SwiftUI-ContributionChart` (GitHub, MIT-style) are directly reusable references.
4. Persist a lightweight `daily_stats` rollup (date, count, totalWords, totalDuration, byMode, byLanguage) updated on every insert and on purge, so 30-day history deletion never erodes long-term stats — this is a standard sync/aggregate pattern, not something any of these apps document publicly, so treat it as an inferred design, not a cited one.
5. Skip vanity/gamification that reviewers flag as noise (aggressive nagging, unverifiable "words = book" claims without basis) — keep milestones honest and opt-in, not push notifications.

## (a) Inventory: what each app shows

| App | Metrics shown | Presentation | Source |
|---|---|---|---|
| Superwhisper | Avg WPM, words this week, time saved (home row); CLI `stats`: total recordings, words, time spent, avg WPM | Compact stat row at top of home view; separate CLI command | superwhisper.com/blog/cli-mcp; superwhisper.com/words-per-minute-test (2026) |
| Wispr Flow | WPM + percentile vs other users, total words dictated (+desktop/mobile split, %-change badge), "corrections by Flow" (filler words removed, dictionary/snippet substitutions), app-usage bar chart, daily/weekly streak, Sun–Sat contribution heatmap, shareable milestone cards ("equivalent to N books/tweets") | Dedicated "Usage" tab; Hub Home stats card also shows streak+WPM+words | docs.wisprflow.ai "Your Usage tab" (2026) |
| VoiceInk | No confirmed dedicated stats dashboard found; open-source (GPL v3, 4,300+ GitHub stars); reviewers note the interface is "a little confusing" and wish transcriptions were reachable from the dashboard | — | tryvoiceink.com; getvoibe.com VoiceInk review (2026) |
| MacWhisper | No dedicated cumulative-stats dashboard found in reviews; focus is per-file transcript export (CSV/docx/PDF/MD/HTML) and search-within-transcript | — | macwhisper.com; 30-day review, lumevoice.com (2026) |
| Aqua Voice | Proprietary Avalon model, 97.3% on "AISpeak" benchmark; no stats-dashboard detail surfaced | — | aquavoice.com/vs (2026) |
| Typeless | Rewrites rather than transcribes verbatim (cleans filler/tone before insertion); 4,000 words/week free cap — no dashboard detail found | — | tryvoiceink.com/best-typeless-alternatives |
| Willow Voice / Monologue | Word-count free-tier caps (2,000/mo, 1,000/mo) mentioned; no stats-dashboard detail found | — | aquavoice.com/vs/monologue |
| Third-party (community) | `crarau/superwhisper-analysis` (GitHub): daily/weekly/monthly stats, char counts, time-saved calc from SQLite export; `cathrynlavery/wispr-flow-recap`: HTML recaps from local SQLite DB | Confirms both apps store enough local history for rich offline analytics | GitHub repo descriptions (2026) |

## (b) Metric/widget shortlist (interest ÷ cost)

| # | Idea | Data needed | Cost | Notes |
|---|---|---|---|---|
| 1 | Spoken WPM (per-session + rolling avg) | transcript word count, audio duration (existing) | trivial | direct Wispr/Superwhisper parity |
| 2 | Words-this-week/month counter with delta badge | daily aggregate | trivial | needs the rollup table (§c) |
| 3 | Contribution heatmap (busiest day/hour) | timestamp only | low | RectangleMark, see §d |
| 4 | Mode split (donut/bar) | mode field (existing) | trivial | |
| 5 | Language split | language field (existing) | trivial | |
| 6 | Streak (current/longest) | daily aggregate | low | derive from rollup, no new capture |
| 7 | "Equivalent to N pages/novels" (≈250 words/page, ≈90k words/novel) | cumulative words | trivial | be explicit this is illustrative, not "time saved" |
| 8 | Filler/edit delta (raw vs refined word-count or char diff) | raw + refined text — must be diffed **before** 30-day purge, then only the delta count persisted | medium (new persisted field) | genuinely novel vs competitors; none of the apps above expose a raw/refined diff metric |
| 9 | Personal records (longest dictation, fastest WPM, longest streak) | duration, WPM per session | low | derive at purge-time from the rollup |
| 10 | Model latency trend (processing latency by model over time) | latency, model fields (existing) | low, engineering-facing widget | closer to a debug pane than a "fun" one — maybe a secondary tab |

Ranked highest-interest/lowest-cost: 1, 3, 6, 7 first; 8 is the standout differentiator but requires a new persisted field computed pre-purge.

## (c) Aggregate-table pattern
Standard approach across privacy-conscious apps that purge raw history (inferred from general mobile-analytics practice; not documented by any app above — flagged as inference, not citation):
- A `daily_stats` row per calendar day: `date`, `dictationCount`, `totalWords`, `totalDurationSeconds`, `totalCharacters`, counts-by-mode (dict/map), counts-by-language, `longestDurationSeconds`, `maxWpm`. No transcript text, ever.
- **On insert**: upsert today's row, incrementing counters (avoids waiting for a purge to know today's totals).
- **On purge** (30-day / 3-day audio job): before deleting a raw record, ensure its day's aggregate already reflects it (idempotent upsert-on-insert makes purge a pure "delete raw rows" step — no recomputation needed if step 1 is correct).
- Streak/heatmap/personal-records widgets read only this table, so they remain valid indefinitely with a bounded, small (~365 rows/year) footprint.

## (d) SwiftUI building blocks
- **Swift Charts** (macOS 13+): `BarMark`/`LineMark` for weekly words and latency trends; `RectangleMark` with `xStart/xEnd/yStart/yEnd` for the heatmap, mapping ISO week → x, weekday → y, colour via `foregroundStyle` gradient scale (artemnovichkov.com, 2026). `chartScrollableAxes` lets a long history scroll horizontally without cramming all weeks on screen.
- **Open-source references**: `VIkill33/SwiftUI-ContributionChart` (Swift Package, GitHub-style heatmap, iOS/macOS/watchOS) and `metrue/ContributionChart` — both directly reusable as SwiftPM dependencies; verify licence file before vendoring (not confirmed in search results — check on add).
- **Animated counters**: `Text` + `.contentTransition(.numericText())` (iOS 17/macOS 14+) gives a free "odometer" roll animation for word/streak counters — no library needed.
- **Empty states**: `ContentUnavailableView` (iOS 17/macOS 14+) for "no dictations yet" / "not enough data for a streak".
- **Card layout**: `matchedGeometryEffect` for a tap-to-expand card (e.g., tapping the heatmap card expands to a detail view) is the idiomatic "cards that grow" pattern; keep it optional polish, not core.

## Contradictions
- **Superwhisper's "time saved" metric vs the general typing-baseline literature**: Superwhisper's home view shows "time saved" but no source specifies which typing WPM baseline it assumes (superwhisper.com/blog/cli-mcp, 2026, silent on the formula) whereas third-party calculators (Voibe, weesperneonflow.ai) default to 40 WPM. **Verdict: ouverte** — no source discloses Superwhisper's exact formula; ask nobody (external, closed-source calculation) — Murmure should simply pick and label its own baseline rather than reverse-engineer theirs.
- **Wispr Flow's marketed dictation speed (200-220 WPM) vs its own documented average-WPM metric**: the Usage-tab doc (docs.wisprflow.ai, 2026) frames WPM as a personal, percentile-ranked measurement, while marketing claims 200-220 WPM sparked user scepticism per review coverage (zackproser.com/eesel.ai style reviews, 2026, "cannot think or speak that fast"). **Verdict: résolue** by the Usage tab itself — the *in-app* metric is measured per-user, not a marketing headline; the contradiction is between marketing copy and the product's own honest instrumentation. Lesson for Murmure: only ever surface the measured number, never a marketing ceiling.
- No contradiction found between Wispr Flow's documented heatmap/streak feature set and the community `wispr-flow-recap` tool's description — both agree the local SQLite store holds enough per-dictation history to support daily/weekly/monthly recaps.

## Gaps
- No confirmed public detail on VoiceInk's or MacWhisper's actual stats-dashboard screens (screenshots not retrievable via web search alone) — would need App Store screenshots or a hands-on install, out of scope for web-only research.
- No official statement from Superwhisper or Wispr Flow on their exact "time saved" formula (WPM baseline, rounding, whether pauses/silence are excluded) — only third-party calculator conventions (40/60/80 WPM ladder) were found.
- No licence text was fetched for `VIkill33/SwiftUI-ContributionChart` or `metrue/ContributionChart` — confirm on the repo page before vendoring.
- Weekly recap **email** specifically (as opposed to in-app Usage tab) was not confirmed for Wispr Flow in this pass — only the in-app tab and share-cards were documented.

## Sources écartées
- Notion, Slack, Gmail, S3, Serena/code — explicitly out of scope (web research only, personal project, no company sources).
- Context7 — not used; no library/API version-pinning question arose (Swift Charts is a first-party Apple framework, covered via WebFetch/WebSearch instead).
- last30days skill — not invoked; the question needed cited documentation/reviews rather than a last-30-days social-sentiment sweep.
