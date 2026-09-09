# What is left, 2026-09-02 (updated 2026-09-05)

Everything below is already argued somewhere — in a plan, a doc comment, or a spec section. This
file exists because it was **argued in prose and never listed**, so the honest answer to "what is
left?" took a grep. One page, ordered, each item pointing at where it is actually specified.

The loop works today: ⌥Space (or whatever you have rebound it to), record, transcribe, refine,
paste, Escape to abandon a recording, plus History and the retention purge.

**Landed since the last full pass, not yet each its own line below:** a Dock-tile click reopens the
window even though Murmure has no Dock icon by default (`AppDelegate.applicationShouldHandleReopen`,
routed to `WindowController`); a hotkey may be a single modifier tapped alone (Right ⌥, say) and not
only a combination requiring ⌃⌥⇧⌘ (`HotkeyRecordingSession`, `KeyCombo.leftHandModifierWarning` for
the one left-hand key that warrants a warning) -- both folded into §6/§7's own prose already, named
here only so a header-level grep finds them. Vocabulary UI, the Hugging Face namespace fields and add/delete of any model, the editor's
transparency blocks, and the per-mode shortcut are each already their own CLOSED section below
(§1; §5 and its own "Open" addendum; §4's 2026-09-05 addendum; §7).

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
appended to the same `appState.modeProblems` the menu already shows.

Editor UI landed 2026-09-05: `ModesPaneView`'s Shortcut row, between Language and Speech model --
Record/Clear over the same `HotkeyRecordingSession` General uses for the toggle, live conflict
feedback (`HotkeyAssignments.resolve`) shown under the row before Save. A hand-edited mode hotkey
the recorder would refuse (Escape, a bare key) is refused rather than registered, and reported in
the menu the same way a conflict is. A per-mode registration that fails outright -- typically a
modifier-only combo attempted without Accessibility granted -- is reported there too, instead of
only logged.

---

## 8. Drafting a mode with help — CLOSED 2026-09-05

**What.** A "Draft with help" button beside "+ New mode" opens a sheet: a model picker, a
user/assistant conversation, and a "Use this draft" button. Talking to a local Ollama model turns a
description ("a mode for short Slack messages, French, tutoiement, no emoji") into a fenced JSON
mode; "Use this draft" closes the sheet and opens the SAME editor a hand-made mode goes through,
prefilled (`ModeDraft(creating:)`) -- the person still reviews every field, the preview, and Save
gating exactly as before. No new save path exists: `ModeStore.save` is the only writer there has
ever been.

**Model gating.** The picker only ever offers chat-capable Ollama models (`ChatModelFilter`,
`MurmureCore`, tested against the five models installed while this was built): the s1-mini model is
excluded because it is driven through `/api/generate` with a hand-written conversation and never
reads a system turn at all, and the two embedding models are excluded because they answer with a
vector, never with text. Defaults to `gemma4:12b-it-qat` when installed, else the first chat-capable
model. The endpoint is always the loopback Ollama root (`OllamaEndpoint.isLoopback`); the sheet
probes nothing of its own on appear -- it reuses whatever `ModesPaneModel` already loaded for its
own pickers.

**Nothing saved by the AI.** The model's reply is read by `ModeDraftExtraction.extract(from:...)`
(`MurmureCore`, tested, four mutations proved red across the two review rounds -- see the session's
own report), which finds the LAST fenced ```json block, decodes it with a schema that mirrors
`Mode`'s own but tolerates a missing `"key"` (derived from `"name"` via
`Mode.availableKey(basedOn:avoiding:)`, the same call the editor's own presets use, when the model
takes the system prompt's own word that omitting it is fine), refuses a stray key -- top-level OR
nested inside `stt`/`llm`/`context` -- rather than silently dropping it, always discards any
`"hotkey"` the reply names rather than merely warning about it (the prompt says never invent one; a
saved, invented combo registers a real global shortcut), runs `Mode.validate()`, and checks whether
the two model references it names are actually installed -- surfaced as a sentence under the reply
itself now, in the editor's own "(not installed)" wording, not only carried on the candidate and
read by nothing. A key colliding with an existing mode is refused by name. A decoding failure names
the field it failed on (`"missing field \"instructions\""`) for that sentence, rather than a raw
`Swift.DecodingError` dump -- the dump itself is not discarded, only kept out of the caption: it
reaches Murmure's unified log instead. Every refusal is a sentence shown under the reply -- never a
save, ever.

**Offline.** The system prompt (`ModeDraftSystemPrompt`) is built from `Mode`'s own `Codable`
shape via `ModeStore.encoder` and from the app's own constants (`ModeSymbol.library`, the shipped
`Mode.voice`/`Mode.prompt`), never a hand-typed second description that could drift. The
conversation's character budget (`ModeDraftingConversation.characterBudget`) reuses
`RefinementRequest.characterCap`'s own derivation from `OllamaChat.numContext`/`numPredict` rather
than inventing a number, and now also SUBTRACTS the built system prompt's own length from that
ceiling -- caught at review: with every installed model listed by name that prompt runs to several
thousand characters, and left unaccounted for, a long conversation could fill the WHOLE derived
budget with history and overshoot `num_ctx` once the system prompt was added back in, which Ollama
resolves by silently dropping context from the front -- the system prompt itself, not the most
recent turn. The oldest turns are still dropped first when the (now correctly sized) budget is
exceeded, with a notice. Streaming is a new, minimal wire type (`ModeDraftChat`, `MurmureCore` +
`ModeDraftChatClient`, `Murmure`) rather than a reuse of the refiner's own
`OllamaChat`/`OllamaClient`: that pair hardcodes `stream: false` and exactly one system + one user
turn, the shape a REFINEMENT needs and not an open-ended, streamed conversation. Ollama's own final
streamed line can carry a reply's last fragment of text AND `"done": true` together; `ModeDraftChat`
reads both off that one line now, rather than the `done` half alone with the text silently dropped.
The loopback-or-fallback endpoint rule the sheet's own network call resolves against
(`OllamaEndpoint.loopbackRoot(preferring:)`) was moved into `MurmureCore` and tested there for the
non-loopback fallback -- it used to live as a private computed property on `ModesPaneModel`, which
has no test bundle to prove that fallback in.

**Verified twice, for real** (`benchmark/modedraftconvo`, gated `MURMURE_NETWORK_TESTS=1`): the
assembled system prompt plus "Un mode pour dicter des messages Slack courts, en français,
tutoiement, sans emoji", sent non-streaming to `gemma4:e2b-it-qat` (the small, 4.3 GB model, not the
12b one). Both runs answered on the FIRST turn with a fenced JSON block that extracted and validated
cleanly -- no prompt iteration was needed either time. Both runs also did the same thing worth
naming precisely because it was not asked for: the system prompt tells the model to ask ONE
clarifying question and stop there when unsure, OR answer with a block -- as an either/or across
turns. What it actually did, both times, was ask the clarifying question (which speech model to
use) AND emit the block, together, in the SAME turn. That is an observed model behaviour, not the
instructed one; the extractor does not care (a fenced block is a fenced block regardless of what
prose sits beside it), so it costs nothing here, but it is not what the prompt's closing paragraph
describes.

The first run surfaced a real bug: the model copied `"com.apple.Terminal"` into `autoActivate`
straight out of the system prompt's own schema EXAMPLE, and because `useDraftedMode` lands on the
Basic screen -- where Auto-activate is not shown -- an unreviewed save of that candidate would have
silently made this mode take over dictation the instant Terminal was frontmost. Fixed by encoding
the schema example with `autoActivate: []` instead of a populated one. The second run, on the same
prompt otherwise, came back with `autoActivate: []` -- the copy stopped. The reply is saved verbatim
as `MurmureCore/Tests/MurmureCoreTests/Fixtures/mode-draft-reply-gemma4-e2b.txt` (replacing the
first run's capture) with offline tests over it, including one pinning the empty `autoActivate`
specifically so this regression cannot come back unnoticed.

---

## 9. Home statistics pane — CLOSED 2026-09-09

**What.** A Home pane, first in the sidebar and the fallback both a fresh install and an
unrecognised stored section land on (`WindowSection.home`, `WindowSection.fallback`), showing what
a person gets out of dictating: average WPM, total words, distinct applications and time saved
against a typing baseline for a chosen period (7 days, 30 days, 12 months, all time), a 52-week
activity heatmap, an hour-of-day profile, current and longest streaks, personal records, and the
top five applications. Full design in `docs/specs/2026-09-09-home-statistics-design.md`.

**Files.** `MurmureCore/Sources/MurmureCore/`: `DictationStatisticsRow.swift` (the text-free
projection), `DictationStatistics.swift` (the one pure `compute` function -- figures, heatmap, hour
profile, streaks, records), `StatisticsPeriod.swift`, `StatisticsFormatting.swift` (display
strings, pinned rounding), `HomeLayout.swift` (layout constants, pinned by `HomeLayoutTests`),
`WordCount.swift`. `Murmure/`: `HomePaneModel.swift` (thin -- loads on appear and on
`historyRevision`, computes off the main actor, publishes), `HomePaneView.swift`,
`HomeCards.swift`. `HistoryStore.swift` carries the migration and `statisticsRows()`.

**The v3 migration.** `v3-wordCounts` adds two nullable integer columns to `dictation`
(`rawWordCount`, `finalWordCount`) with a plain `ALTER TABLE ADD COLUMN` -- no FTS rebuild, the
counts are not searchable text. A one-off backfill runs inside the same migration transaction:
every row whose text is still present gets its counts computed and stored; a row already purged of
text keeps null counts and simply contributes no words (it still contributes duration and
dictation count). A migration runs exactly once, so the backfill is idempotent by construction, and
because only the last 30 days of rows still carry text at all, the one-off cost at first launch is
a fraction of a second.

**Counting rules.** Only `inserted` and `copiedToClipboard` rows count; failures, cancels and
"nothing heard" are excluded from every figure though still visible in History. Words: sum of
`finalWordCount` (null counts contribute zero) -- `refinedText` if present, else `correctedText`,
else `rawTranscript`. Average WPM is a weighted average (total raw words over total spoken
minutes), never a mean of per-row speeds, and a dash when spoken time is zero. Time saved is
`finalWordCount / typingWPM − durationSeconds / 60` summed over rows with a final count, may be
negative, and rows without a final count are excluded rather than dragging the figure down with
duration alone. The heatmap always covers the last 52 weeks ending today regardless of the period
picker; streaks and records are always all-time; the four figures and top applications follow the
picker. The screen says so next to each card.

**What is measured.** The MurmureCore package total after this lot: 1366 tests, 0 failures.

**What is deliberately not shipped.** The raw-versus-refined delta widget (would need the diff
stored before purge -- it is not); "equivalent to N novels" lines; weekly recaps and badges; a
rollup table (unneeded while rows survive purge; revisit if row deletion is ever added); a hover
tooltip on the heatmap in V1.

## 10. Modes editor v2 — CLOSED 2026-09-10

**What.** Voice becomes protected (`Mode.isProtected`, name and symbol locked, no refiner section,
still configurable speech model/language/shortcut/Advanced); Prompt is seeded once and stays
deletable (a `.seeded` marker in `modes/` stops it being recreated); a refiner is mandatory for
every non-protected mode (`ModeValidationError.refinerRequired`), a legacy refiner-off file still
loads and gets a notice instead; the Custom preset ships with the refiner already on. Full design
in `docs/specs/2026-09-09-modes-editor-v2-design.md`.

**Files.** `MurmureCore/Sources/MurmureCore/`: `Mode.swift` (`isProtected`,
`editorValidationError(original:)`, `ModeValidationError.protectedField`/`.refinerRequired`,
`Mode.LLM.API.title`/`.defaultModel`/`.defaultInstructions`/`.accepts(modelName:)`,
`Mode.switching(to:)`), `HardwareProfile.swift`, `ModelFit.swift` (both new), `ModeSymbol.swift`
(`isStageDefault(_:for:)`), `ModesLayout.swift` (`cardSpacing`), `ModeStore.swift` (once-only
Prompt seeding, the protection guard on `delete`), `ModeEditing.swift` (`ModePreset.all` drops
Voice). `Murmure/`: `ModesPaneModel.swift` (`hardware`, `fit(forRefiner:)`, `refinerChoices(for:)`,
`recommendedRefiner(for:)`, `canDeleteDraft`, the kind-switch state machine), `ModesPaneView.swift`
(two `HomeCard`s -- Identity, Refiner -- the single icon list, the hardware-fit badges, the
protected-Voice lock row, the no-refiner notice, Context as `.help()` tooltips, the collapsed
"What the refiner receives" disclosure).

**Refiner kinds.** The API picker reads as a *kind* segmented control: "Superwhisper S1
(fixed-format cleanup)" / "General model (Gemma, Llama, …)". Switching kind resets model and
instructions to that kind's defaults, confirming first only when the instructions had been edited.
`.chat`'s default instructions are a prose cleanup prompt, distinct from S1's control-fields-only
line; the Custom preset ships the same prose text.

**Hardware-aware badges, refiner models only.** `HardwareProfile` (physical memory, chip name) and
`ModelFit.classify(modelBytes:memoryBytes:)` (`.recommended` ≤ 45 % of memory, `.tight` ≤ 70 %,
else `.tooLarge`) drive a caption per row of the Refiner model picker -- "Recommended for this
Mac" / "Tight on this Mac" / "Too large for this Mac". The speech-model picker carries none in
this lot: the speech listing does not know sizes yet (spec §5/§6).

**What is measured.** The MurmureCore package total after this lot: 1392 tests, 0 failures.

**Open / eye-gate.** None of the following blocked closing the lot; all four need Louis's eye on
the running app, not a test:
- The kind segmented control's two long titles at the picker's minimum window width (720 pt) may
  truncate rather than wrap.
- The "Default" caption under the stage-default icon tile got `.fixedSize()` against a 22 pt grid
  column in the review fix round; whether it still visually fits was not checked by launching the
  app.
- Moving Context's three descriptions from printed text to `.help()` tooltips is a design call
  (discoverability vs a cleaner row) that reads right on paper but wants a look before it is
  called final.
- The speech-model picker's missing badge is a deliberate gap, not an oversight, but it stays open
  until the speech listing carries sizes and a follow-up gives it one too.

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

- **The next chantier is Transcripts** (YouTube/X video transcription and local file transcription)
  -- see `docs/specs/2026-09-09-transcripts-design.md`.
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
- **`keycap(_:)` is drawn twice, once in `GeneralPaneView` and once in `ModesPaneView`.** Both
  panes render a shortcut as chips the identical way (design notes §2), but the two views were
  built by different lots at different times and neither shares a common parent view module a
  small SwiftUI helper could live in without one importing the other. Left duplicated rather than
  factored out now; worth a shared `ChipRow` view the day a third pane needs the same chips.
