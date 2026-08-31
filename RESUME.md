# Murmure — where the work stands

Paused 2026-08-31 for a terminal restart (Louis granted macOS permissions that only take effect in a
fresh terminal). Everything below is committed on branch `feat/murmure-v1`. Nothing is in flight.

## How to resume

Open a session in `/Users/louiscourcier/Documents/Perso/murmure` and continue the
subagent-driven-development loop. The two ledgers hold the full state and every ruling made so far:

- `.superpowers/sdd/2026-08-31-lot0-llm-benchmark/progress.md`
- `.superpowers/sdd/2026-08-31-lot1-core-dictation/progress.md`

Task briefs for every remaining task are already generated in those same directories.

## Lot 0 — refiner benchmark

| Task | State |
|---|---|
| 1 fixtures, prompts, frozen rubric, judge prompt | **complete**, review clean |
| 2 candidate models + `models.json` | **complete**, review clean (1 fix round) |
| 3 generation runner + `results.jsonl` | **complete** (120 rows), review NOT yet dispatched |
| 4 anonymised judge packets | not started — brief ready |
| 5 blind judging (orchestrator-executed, 3 opus judges per task) | not started |
| 6 aggregation + report | not started — brief regenerated after the `size_gb` fix |
| 7 Louis adjudicates the top 2 | not started — **needs Louis** |

Machine metrics, measured on this M4 Pro over all 120 calls (reasoning disabled, `think: false`):

| model | n | median latency | median tok/s | empty outputs |
|---|---|---|---|---|
| granite4.2-8b | 30 | 1.91 s | 34.1 | 0 |
| ornith-9b | 30 | 2.21 s | 30.3 | 0 |
| qwen3.5-9b | 30 | 2.28 s | 26.3 | 0 |
| gemma4-12b-qat | 30 | 2.86 s | 19.0 | 0 |

Quality is NOT decided by these numbers — the blind judges (task 5) and Louis (task 7) decide that.
Models ran strictly one at a time; only one is ever resident in memory.

## Lot 1 — core dictation walking skeleton

| Task | State |
|---|---|
| 1 scaffolding (XcodeGen app + `MurmureCore` package) | **implemented** (65ed6c7), review package generated, reviewer NOT dispatched |
| 2 `WavWriter` | not started — brief ready |
| 3 `AudioRecorder` | not started — brief ready |
| 4 global hotkey | not started — brief ready |
| 5 WhisperKit engine | not started — brief ready |
| 6 paste inserter | not started — brief ready |
| 7 `DictationSession` + wiring | not started — brief ready |

Build verified: `swift test` 1/1, `xcodebuild` BUILD SUCCEEDED, menu-bar app launches with no Dock
icon. Toolchain: Xcode 26.6, Swift 6.3.3, XcodeGen 2.46.0, WhisperKit pinned `from: "1.1.0"`.

## First things to do after the restart

1. **Re-try the local UI capture.** It was blocked because the terminal had no Screen Recording
   permission (`screencapture` → "could not create image from display"). If that grant is now
   active, capture the installed Superwhisper window-by-window and fold what you learn into
   `docs/design/ui-design-notes.md` — which currently describes the *documented* UI, from 74
   screenshots pulled off their docs site. Steps are in `docs/design/README.md`.
2. Dispatch the pending reviews: lot 0 task 3, lot 1 task 1.
3. Continue both loops.

## What still needs Louis

- **Lot 0 task 7**: a blind A/B between the two finalists, 5 fixtures, X vs Y. Ten minutes.
- **Optional, improves the benchmark**: dictate 5 real prompts in Superwhisper's Voice mode and paste
  the raw transcripts. All 15 current fixtures are synthetic — there was no dictation history on this
  machine to mine. `run_benchmark.py` is resume-safe, so adding them regenerates only the new rows.
- **Lot 1 task 7's final gate**: dictating for real into TextEdit and into Claude Code.
