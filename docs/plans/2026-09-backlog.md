# What is left, 2026-09-02 (updated 2026-09-04)

Everything below is already argued somewhere — in a plan, a doc comment, or a spec section. This
file exists because it was **argued in prose and never listed**, so the honest answer to "what is
left?" took a grep. One page, ordered, each item pointing at where it is actually specified.

The loop works today: ⌥Space (or whatever you have rebound it to), record, transcribe, refine,
paste, Escape to abandon a recording, plus History and the retention purge.

---

## 1. Vocabulary — CLOSED 2026-09-03 / 2026-09-04 (`80702d2`, `5776133`)

Both halves exist. `VocabularyStore` persists the list, `Transcriber` carries an `initialPrompt`
seam, and the pane shows **two headed sections** rather than one list:

- **Words to recognise** — a bare term, no replacement. It reaches the recogniser's prompt so the
  model leans toward it when hesitating, and nothing else. This is the half that answers `PR` vs
  `paire`: you cannot rewrite every `paire`, but you can tell the recogniser the word exists.
- **Corrections** — `term → replacement`. Biases the prompt *and* rewrites the output afterwards.

The distinction was already in the format (`replacement == nil`), so **no migration and no format
change**: the two sections are a reading of what was already stored. The arrow glyph now appears
only under Corrections — its presence on every row was the reason the first kind looked absent.

The measured rules (`docs/benchmarks/2026-09-vocabulary-prompt.md`, 2 289 decodes over 109 real
dictations) are enforced in code, not documented as advice:

- **The prompt starts with a space.** Without it the tokenizer cuts the first entry into character
  fragments (`C`, `la`, `ude`) that never occur in speech. One character takes `Claude Code` from
  17 repairs out of 60 to 50, and costs one token LESS.
- **The first slot is sacrificial**, so it holds filler and the most-corrected terms go LAST. The
  order derives itself from the correction counts; the user learns no rule.
- **Cap around 20 terms / 70 tokens**, under the 111-token WhisperKit budget. Overflow is discarded
  from the FRONT with no error — a 35-term list ordered wrong repaired 0 of 106 where the same
  words repaired 75.
- **A long list buys nothing**: 3 well-placed terms repair 86, 30 repair 88.

**No fine-tuning**, recorded so it is not re-proposed as an oversight: the only pairs available are
raw transcript → the model's *own* output, which is not a human correction.

## 2. Four empty settings panes — CLOSED 2026-09-03 (`7bf06e9`)

`Modes`, `Models`, `General` and `Advanced` render. The `default:` arm of `pane` is **gone**: a
seventh section now fails to compile until someone decides what it shows, which is the only
mechanism that can catch an unconnected pane -- the app target has no test bundle, so no test can.
Proven mechanically, not asserted: removing one case made the build fail with `switch must be
exhaustive`.

Settings are no longer edited as JSON by hand. `scripts/set-refiner.sh` keeps its reason to exist
(the three correlated fields), but the Modes editor now refuses the same combinations `Mode`
already refused, at typing time rather than at dictation time.

**Three settings were removed rather than shipped**, because they were wired to nothing and a
control that lies is worse than a control that is absent -- nothing signals it, not an error, not a
warning, not a red test:

- `simulateKeypresses`, both the per-mode switch and the global one. `PasteInserter.insert()` always
  posts ⌘V. The field stays in `Mode` and in the modes JSON -- no file becomes invalid -- and the
  switches come back when the typing path is actually written. It could not be written in that
  session: it requires posting key events, which would reach whatever Louis had in front of him.
- The microphone picker. `AudioRecorder` takes `engine.inputNode` and nothing else. Replaced by a
  read-only line reporting the system input, which is what Murmure actually follows.

Louis chose removal on both, 2026-09-03.

## 3. `stt.language` is hardcoded — CLOSED 2026-09-03 (`80702d2`)

`WhisperKitEngine.transcribe` builds `DecodingOptions` per call and honours `Mode.stt.language`.
Blast radius when it shipped was nil: both `prompt.json` and `voice.json` declare `"fr"`.

## 4. A mode's context and its speech model — CLOSED 2026-09-04 (`06115c4`)

Two things a mode declared but that never left the JSON.

**Context now reaches the refiner.** `RefinementRequest` assembles the system turn: the mode's
instructions, then a preamble stating the sections are background and **not text to rewrite**, then
the captured sections (selected text via AX, clipboard, frontmost application). Capture happens at
recording start, beside the target window and the active mode, so what is refined is the context
that existed when you spoke. Capped at 12 288 characters, derived from Ollama's context budget
rather than guessed. Under `api: .s1` the context toggles render **disabled with a reason** — that
API takes no system turn, and a control that lies is worse than one that is absent.

**A mode's `stt.model` now selects the model that runs.** It previously named a model and the engine
loaded its own default regardless. `SpeechModelResolution` resolves a blank or default name to the
engine default and passes anything else through; `WhisperKitEngine` keeps one model resident, keyed
by variant, and warm-starts on an exact match. `HistoryRecord.sttModel` now records what ran, not
what was asked.

**2026-09-05: the editor shows what it sends, not just what is stored.** `RefinementPreview` renders
the exact request (`RefinementRequest`'s own assembler, shared rather than duplicated) so "What the
refiner receives" in the Modes editor can never drift from a real dictation. Each context toggle now
carries a one-line description of what/when/how, and the s1-disabled reason is a single constant
(`ContextSource`) read by both the view and its test.

## 5. Installing a model the app did not ship with — CLOSED, then generalised 2026-09-05

One field takes anything -- an `owner/repo` id, a `huggingface.co` URL, or an Ollama name -- and a
press of "Inspect" classifies it: `ModelClassifier` (`MurmureCore`) reads the repository's own
Hugging Face blob listing (`?blobs=true`) and sorts it into speech variants (a folder holding every
required bundle), `.gguf` refiner candidates (one per quantisation, tagged from the filename), both
at once (the user picks the role in the sheet), or not runnable at all (safetensors-only, with a
Hugging Face search offering GGUF conversions as "Inspect this instead" rows). An Ollama name skips
classification entirely and is pulled as typed. Install dispatches to
`WhisperKit.download(variant:downloadBase:from:)` for a speech pick or `/api/pull` for a refiner
pick, exactly as before; nothing reaches the network before a press. `SpeechModelCatalog` (the
original, `WhisperKit.fetchAvailableModels`-based listing) is deleted, not merely unused: it was
the one remaining call to `fetchAvailableModels` in the app, and that call is what silently
substitutes Argmax's own fallback table on a repository with no `config.json` — the trap
`ModelClassifier`'s own doc comment describes. Deleting the file rather than leaving it orphaned
takes that trap out of the live path entirely, rather than leaving a second, unreachable copy of it
sitting in the tree for a future call site to wire back in by accident.

`ModelInventory.removal(for:in:namedByModes:)` (speech) and its language sibling
`removal(forLanguageModel:namedByModes:)` are wired to a real Delete button behind a confirmation
`.alert` — see the item below.

## 6. The start/stop shortcut is yours to change — CLOSED 2026-09-04 (`3122f5d`)

General has a Record button. The rules live in `MurmureCore` (`HotkeyRecording`), so they are
tested: at least one of ⌃⌥⇧⌘ except a bare F1–F12, Escape refused bare or modified because
`CancelHotkey` owns it, a modifier alone reads as still pressing. `DictationController` **registers
the new combo before storing it** and reverts to the previous one on refusal, so a rejected binding
never leaves you without a shortcut.

The AppKit → Carbon modifier conversion (`KeyCombo.carbonModifierMask`) is the risky half; its eight
constants were checked by hand and the tests were mutation-proved (swapping ⌃/⌥ turns two red).

---

## 7. A mode can have its own shortcut — CLOSED 2026-09-05

`Mode.hotkey` was a dead field; it is wired now. Pressing a mode's own shortcut starts a dictation
IN THAT MODE while idle (a one-shot override of `appState.manualModeKey`, restored the moment the
recording starts) and stops the recording exactly like the global toggle while one is running.
`HotkeyManager` now holds a table of bindings, not one; `HotkeyAssignments.resolve` (`MurmureCore`,
tested, mutation-proved) settles a combo two bindings both want -- the toggle always wins, a
mode-vs-mode tie goes to the alphabetically last key -- and reports every loser as a sentence
appended to the same `appState.modeProblems` the menu already shows. The editor UI for recording a
per-mode shortcut is the next step; everything under it is already in place.

## Measured, and deliberately NOT shipped

**A logits bias on the vocabulary list** (`docs/benchmarks/2026-09-vocabulary-logits-bias.md`,
1 526 decodes over two rounds). WhisperKit's `LogitsFiltering` seam lets a term's tokens be boosted
during decoding, and on a *curated* list of long distinctive terms it is excellent: prompt + boost
repaired 110 of 114, with 0 regressions, 0 injections, no word toll and no decode-time cost.

It does not ship, and the reason is structural rather than a matter of tuning. On a **free-form**
user list, short or common-shaped terms are written into dictations where they were never spoken —
`dbt` appeared 23 times across 9 dictations that contained it 0 times at baseline. Three candidate
bridling rules were measured; all three suppress the misfires by suppressing the repairs we want,
because token length does not separate them:

```
Trucost = 2 tokens        dbt = 2 tokens, MDI = 2 tokens
esgc    = 3 tokens        Claude Code = 3 tokens, WeeFin = 3 tokens
```

Per term (the aggregate hid this — 43 vs 48 looked like a small cost):

| arm | Claude Code | Trucost | WeeFin | total |
|---|---:|---:|---:|---:|
| no bridle | 31 | 6 | 11 | 48 |
| token floor | 31 | 0 | 11 | 42 |
| strength × tokens | 31 | 1 | 11 | 43 |
| no first position, short terms | 31 | 0 | 11 | 42 |

The five "small" losses are five of `Trucost`'s six. A stress test at strength 30 confirmed a cliff
rather than a gradient: `mdi` 3 077 occurrences, median words ×2.54, decode time ×9.5.

**What would unblock it**: a criterion that is not token length. The harness is committed
(`benchmark/vocabprobe`), so the question can be reopened on evidence rather than rediscovered.

## Open

- ~~**`Mode.stt.model` holds a display name from a different namespace than the engine's variant id.**~~
  Replaced by `SpeechModelReference` (`owner/name/variant`, the Hugging Face form): `ModeStore`
  migrates an old mode file on load, `WhisperKitEngine` and the Models pane both read the one
  reference, and the mode editor's Speech/Refiner model fields are now pickers over what is
  actually installed rather than free text.
- ~~**Deleting a model does not warn when a mode still names it.**~~ CLOSED 2026-09-05. The Delete
  button on both families now calls `ModelInventory.removal`/`removal(forLanguageModel:)`, shows
  the confirmation `.alert` it computes, and only then removes the two speech directories or calls
  Ollama's own `DELETE /api/delete` (`OllamaDelete`, new, tested). **What actually ran**: the
  Ollama half of this, end to end — a real pull followed by a real `DELETE /api/delete`, confirmed
  gone from `/api/tags` (`benchmark/modelnettest`, below). The speech half — removing the variant
  folder and its `.cache` sidecar — is wired and unit-tested (`ModelInventoryTests`) but was NOT
  exercised against the real store: the shipped default's own files under
  `argmaxinc/whisperkit-coreml` were never touched, deliberately, and the confirmation `.alert`
  itself was never seen on screen, since that requires the GUI, which this session never launched.
  Both remain open for Louis to confirm by hand: open the Models pane, delete a speech model (any
  one other than the shipped default -- pressing "Add a model" against a small repository and
  installing it first gives a safe one to delete) and confirm the row, the `.alert`'s wording, and
  the removed directories all look right; separately, pull a small model through "Add a model" and
  delete it from the table, confirming Ollama's own `ollama list` no longer shows it.
- ~~**Four network paths shipped unexecuted**~~ CLOSED 2026-09-05, all four actually run
  (`benchmark/modelnettest`, gated by `MURMURE_NETWORK_TESTS=1`, one recorded pass): Hugging Face
  listing classified `argmaxinc/whisperkit-coreml` (27 speech variants), `superwhisper/s1-mini-GGUF`
  (refiner, `Q4_K_M` among the quants) and `XHToken/Spark-X2.5-4B` (not runnable, safetensors, 8 GGUF
  conversions found) — fixtures re-saved from these live responses; `openai_whisper-tiny` downloaded
  into a temp dir and deleted; `hf.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF:Q4_K_M` (491 MB) pulled,
  confirmed in `/api/tags`, then removed, none of the five pre-existing Ollama models touched; the
  `config.json`-fallback path fired for real against `tomAndJetty/whisperkit-coreml` (4 variants
  derived from its raw file listing).

## Known, argued, and deliberately not scheduled

- **The hover dashboard with Stop/Cancel** (lot 3 T5) stays blocked on `ignoresMouseEvents = true`.
  Escape shipped and supersedes its only urgent purpose.
- **`durationSeconds` comes from `Date`.** An NTP correction mid-dictation writes a wrong duration.
  A monotonic clock fixes it; T4 declined to add an unguarded fix and said so.
- ~~**Two surfaces with nothing behind them**~~ — done 2026-09-03. A database that will not open
  surfaces a named error, carried out of `DictationController` rather than logged and dropped, and
  the app still dictates: a broken archive must not cost a dictation.
- **The default branch is `main`.** The rename happened; `origin/HEAD` points at it and no
  `master` remains on the remote. A clone made before it needs
  `git fetch --prune origin && git branch -m master main && git branch -u origin/main main`.
