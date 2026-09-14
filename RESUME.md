# Murmure — where the work stands (2026-09-14)

Everything is committed on `feat/murmure-v1` and mirrored on `main` (both at `4afc2fa`, pushed
2026-09-10). Nothing is in flight. The installed app at `~/Applications/Murmure.app` is that same
commit. `cd MurmureCore && swift test` passes 1392 tests; `xcodebuild` reports `BUILD SUCCEEDED`.

This file is the single entry point for whoever picks the project up, human or assistant. The
detailed record lives in `docs/` (map at the end).

## 1. What Murmure does today

Hold the hotkey (⌥Space by default, rebindable, a lone modifier allowed), speak, release: Whisper
`large-v3-turbo` transcribes on the Neural Engine, the mode's refiner (a local Ollama model) cleans
the text, and it is pasted into the frontmost app. A notch card (or a floating panel on a Mac
without a notch) shows the state; Escape abandons a recording. Everything runs on the machine.

The application window has seven sidebar sections: **Home** (statistics: WPM, words, time saved,
52-week heatmap, hour profile, streaks, records, top apps), **History** (with retention purge),
**Modes**, **Vocabulary**, **Models** (install/delete speech and refiner models, Hugging Face and
Ollama), **General** (shortcut, launch at login, sounds), **Advanced**.

Modes, as shipped by the "Modes editor v2" lot (2026-09-10):

- **Voice** is the protected built-in: fixed key, name and icon, no refiner, cannot be deleted.
  Speech model, language, shortcut and Advanced remain editable.
- **Prompt** is a deletable example, seeded once (`modes/.seeded` marker) and never reseeded.
- Every other mode **must** have a refiner of one of two kinds: **Superwhisper S1** (fixed-format
  cleanup, no free prompt, `[Context: …]` control line) or a **general model** (Gemma, Llama…, free
  prose instructions). Switching kind resets model and instructions, with a confirmation only if the
  prompt was edited.
- Refiner models carry a memory-fit badge computed from the Mac's physical memory and chip
  (`HardwareProfile`, `ModelFit`: ≤ 45 % recommended, ≤ 70 % tight, else too large). New modes land
  on the largest recommended installed model.

## 2. Lots delivered

| Lot | State | Where it is argued |
|---|---|---|
| 0 refiner benchmark | closed | `docs/benchmarks/2026-08-refiner-benchmark.md`, `2026-09-refiner-benchmark-v2.md`, `2026-09-refiner-quantisation.md` |
| 1 core dictation | closed 2026-08-31 | `docs/plans/2026-08-31-lot1-core-dictation.md` |
| 2 modes + refinement | closed | `docs/plans/2026-09-lot2-modes-refiner.md` |
| 3 notch UI | closed | `docs/plans/2026-09-lot3-notch-ui.md` |
| 4 app window | closed | `docs/plans/2026-09-lot4-app-window.md` |
| Backlog §1–§8 (vocabulary, panes, shortcuts, models, drafting a mode) | closed 2026-09-03 → 05 | `docs/plans/2026-09-backlog.md` |
| Home statistics | closed 2026-09-09 | spec `docs/specs/2026-09-09-home-statistics-design.md`, plan `docs/plans/2026-09-09-home-statistics.md` |
| Modes editor v2 | closed 2026-09-10 | spec `docs/specs/2026-09-09-modes-editor-v2-design.md`, plan `docs/plans/2026-09-09-modes-editor-v2.md`, backlog §10 |

Measured and deliberately **not** shipped: the vocabulary logits bias
(`docs/benchmarks/2026-09-vocabulary-logits-bias.md`) and the structured prompt mode
(`docs/benchmarks/2026-09-prompt-mode-structure.md`). Known limits that are argued and not
scheduled: backlog, last section.

## 3. What has not been checked by eye

The last two lots were verified by unit tests and the build only. Nobody has looked at the running
app since. To confirm, in this order:

1. Home: figures match a hand count of recent dictations; the gear changes "Time saved" live;
   the heatmap puts days on the right weekday; the empty state shows only without data.
2. Home hovers (heatmap cells, hour bars, top-app rows): fix `d5f4f6f` was never seen running.
3. Modes, Voice: name and icon locked, no Refiner card, no Delete button, Advanced still reachable.
4. Modes, Prompt: delete it, relaunch, it must not come back; the button reads "Delete…", not
   "Reset…".
5. Modes editor: two cards (Identity, Refiner); icon grid without duplicate, the "Default" caption
   fits under the tile; kind switch asks for confirmation only when the prompt was edited, and
   re-selecting the current kind does nothing; memory badges on refiner rows.
6. At the 720 pt minimum window width, the two segment titles of the kind picker may truncate.
7. Design call to confirm: the Context toggles' descriptions moved into tooltips.
8. Models pane (open since 2026-09-05): delete a speech model other than the shipped default and
   check the confirmation alert and the removed directories.

## 4. Next chantier: Transcripts

Spec, validated with Louis on 2026-09-09: `docs/specs/2026-09-09-transcripts-design.md`. Paste a
YouTube or X URL, or drop an audio/video file, and get a timestamped transcript in its own pane and
tables, produced with the already-loaded turbo model. Research and spike reports:
`docs/research/2026-09-09-*`, harness `benchmark/longform/`.

No implementation plan exists yet. The sequence is:

1. Write the plan for **T1** (spec §2 and §7): `Subprocess`, `YtDlpProgress`, `YtDlpFailure`,
   `ExternalTools` (download of the pinned `yt-dlp_macos` release into `bin/` after a consent
   sheet, SHA-256 recorded, `--version` check, 24 h `-U` update), settings keys. Tests listed in
   spec §5, none of them touching the network.
2. Implement T1 task by task, each task reviewed, then **T2** (job model, pipeline, audio
   extraction, long-form transcription, migration v4, `TranscriptStore`, dictation suspended while
   a job transcribes) and **T3** (`WindowSection.transcripts`, pane, export, failure actions).
3. Real end-to-end run described in spec §5, then Louis's eye-gate on the consent sheet, progress,
   detail view, export and the suspension message.

Open items are listed in spec §8 (Deno pinning, automatic retry after a yt-dlp update).

## 5. How the project is worked on

- **Rules live in `MurmureCore`** (SwiftPM, XCTest); `Murmure/` is wiring and views and has no
  test bundle. Every store takes its directory as a parameter, so tests use temp directories and
  never write into `~/Library/Application Support/Murmure/`.
- Verify with `cd MurmureCore && swift test`, then
  `xcodegen generate && xcodebuild -project Murmure.xcodeproj -scheme Murmure -configuration Debug -derivedDataPath .build/xcode build CODE_SIGNING_ALLOWED=NO`.
- Install with `scripts/install.sh` (signs with the keychain identity, **quits the running
  Murmure and does not relaunch it**: `open "$HOME/Applications/Murmure.app"` afterwards).
  `scripts/doctor.sh` is the read-only diagnostic.
- Each lot went spec → plan → one task at a time, each task implemented against failing tests
  first and reviewed before the next started, then a whole-branch review before install and push.
  Every ruling is written where it applies (spec addendum, backlog section, doc comment), so
  "why is it like this?" is answered by grep, not memory.
- Commits are small and per task; nothing is squashed. Default branch is `main`; work happens on
  `feat/murmure-v1` and both are pushed to the same commit.

## 6. Constraints that must hold, whoever is at the keyboard

- **Louis's dictations are private work content.** `~/Documents/superwhisper/recordings/`,
  `~/Library/Application Support/Murmure/recordings/` and `murmure.sqlite` may be read locally for
  fixtures and tests, never committed (see `.gitignore`), never quoted in reports beyond short
  fragments. The screenshots under `docs/design/superwhisper-*/` are git-ignored commercial UI and
  some show his real text.
- Models run **one at a time**; loading a model occupies the Neural Engine, so warn before a run
  that does. Never clear the ANE cache. Never delete his Ollama models
  (`hf.co/superwhisper/s1-mini-GGUF:Q4_K_M`, `gemma4:e2b-it-qat`, `gemma4:12b-it-qat`,
  `nomic-embed-text`, `mxbai-embed-large`); use `gemma4:e2b-it-qat` for LLM tests and `ollama rm`
  anything pulled for a test.
- An assistant sharing the live desktop must not launch the GUI, click through the UI, post key
  events, trigger permission dialogs, use the microphone or touch `NSPasteboard.general`. Shipped
  code may; nothing an agent runs may.
- Never call `SMAppService.register()` or `NSWorkspace.open` during development. In
  `~/Library/Preferences`, never touch `com.louiscourcier.Murmure.plist`.
- The GitHub repository is private. Louis has two `gh` accounts; pushes require
  `gh auth switch --user Loulouleloup1`, then push `feat/murmure-v1` and `feat/murmure-v1:main`,
  then `gh auth switch --user LouisCourcier` again.

## 7. Documentation map

- `README.md` — install on another Mac, models, permissions, memory, where data lives, developing.
- `docs/specs/` — the three design specs (2026-08-31 whisper-local, Home statistics, Modes editor
  v2) and the Transcripts spec that is next.
- `docs/plans/` — one plan per lot, plus `2026-09-backlog.md` (what is left, what was refused and
  why).
- `docs/design/ui-design-notes.md` — the visual system, measured; one "shipped" section per UI lot.
- `docs/benchmarks/` — every measurement that decided something.
- `docs/research/` — the Transcripts research and spike reports.
- `benchmark/` — the harnesses behind the benchmarks (Python and small SwiftPM probes).
