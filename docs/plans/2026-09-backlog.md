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

## 5. Installing a model the app did not ship with — CLOSED 2026-09-04 (`c6e1525`)

Paste an `owner/repo` or a `huggingface.co` URL and the app lists the speech-model variants that
repo actually contains (a top-level folder holding every required bundle), then downloads one.
Refiner models come through `/api/pull` against the local Ollama, streamed as NDJSON.

Two traps found and handled rather than discovered later:

- `WhisperKit.fetchAvailableModels` **silently substitutes Argmax's fallback table** when a repo has
  no `config.json` — a plausible-looking wrong answer, worse than an empty one. `SpeechModelCatalog`
  detects the `whisperkit-coreml-fallback` sentinel and falls back to a raw file listing.
- Nothing reaches the network on `onAppear`. Every call is behind a press.

`ModelInventory.removal(for:in:namedByModes:)` says something different when a mode still names the
model you are deleting. It is decided and tested but **deliberately not wired to the delete
button** — see the open items below.

## 6. The start/stop shortcut is yours to change — CLOSED 2026-09-04 (`3122f5d`)

General has a Record button. The rules live in `MurmureCore` (`HotkeyRecording`), so they are
tested: at least one of ⌃⌥⇧⌘ except a bare F1–F12, Escape refused bare or modified because
`CancelHotkey` owns it, a modifier alone reads as still pressing. `DictationController` **registers
the new combo before storing it** and reverts to the previous one on refusal, so a rejected binding
never leaves you without a shortcut.

The AppKit → Carbon modifier conversion (`KeyCombo.carbonModifierMask`) is the risky half; its eight
constants were checked by hand and the tests were mutation-proved (swapping ⌃/⌥ turns two red).

---

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

- **`Mode.stt.model` holds a display name from a different namespace than the engine's variant id.**
  A mode declares `"large-v3-turbo"`; the installed folder is `openai_whisper-large-v3-v20240930_turbo`.
  `SpeechModelResolution` bridges the two safe cases (blank, and the default name) deliberately,
  bypassing WhisperKit's fuzzy Hub matcher — which does **not** match that folder and would have
  triggered a multi-GB re-download plus ~7 minutes of ANE compilation on the next dictation. A
  picker in the mode editor is the real fix, and it needs that namespace decided first.
- **Deleting a model does not warn when a mode still names it.** The sentence exists and is tested
  (`ModelInventory.removal(for:in:namedByModes:)`); wiring it means actuating a destructive button,
  which was not done on a machine holding real models.
- **Four network paths shipped unexecuted**: listing a Hugging Face repo, downloading a speech
  model, pulling an Ollama model, and the fallback file listing. The parsing and classification
  around each is tested against fixtures; no request was ever sent.
- **`Mode.hotkey` is a dead field.** A mode declares a per-mode shortcut that nothing reads. Either
  wire it or remove it; leaving it is the same lie as the three settings removed in §2.

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
