# What is left, 2026-09-02 (updated 2026-09-03)

Everything below is already argued somewhere — in a plan, a doc comment, or a spec section. This
file exists because it was **argued in prose and never listed**, so the honest answer to "what is
left?" took a grep. One page, ordered, each item pointing at where it is actually specified.

The loop works today: ⌥Space, record, transcribe, refine, paste, Escape to abandon a recording,
plus History and the retention purge. What follows is what the app still cannot do.

---

## 1. Vocabulary — the largest functional gap

**Neither half exists**: no `VocabularyStore`, no UI, and `Transcriber` has no `initialPrompt` seam.
The Vocabulary pane currently holds a temporary ⌘V probe field left over from T1's eye-gate, which
T6 deletes rather than replaces.

Already decided, so this is implementation and not design:

- **One list, `word → optional replacement`, not two** (lot 4 D13). The same entry biases the
  recogniser *and* fixes the word afterwards, so a term is taught once.
- The terms are **derived** — a word list, no sentences, no client content — which is why they
  survive the 30-day text purge that produced them. Extraction has to run **before** a row expires,
  not over whatever happens to remain (lot 4, retention section).
- **No fine-tuning.** Recorded as deliberately not built so it is not re-proposed as an oversight:
  the only pairs available are raw transcript → the model's *own* output, which is not a human
  correction, and training on it degrades rather than improves.

Now also **measured**, which turned four of the open design questions into settled ones
(`docs/benchmarks/2026-09-vocabulary-prompt.md`, 2 180 decodes over 109 real dictations):

- **The prompt must start with a space.** Without it the tokenizer cuts the first entry into
  character fragments (`C`, `la`, `ude`) that never occur in speech. One character takes
  `Claude Code` from 17 repairs out of 60 to 50, and costs one token LESS.
- **Order the list with the most-corrected terms LAST**, and never put a valuable one first:
  the first slot is sacrificial even once the space is there. The replacement half already
  counts corrections, so the order derives itself and the user learns no rule.
- **Cap the list around 20 terms / 70 tokens**, well under the 111-token budget. Beyond it the
  word toll doubles, and overflow is discarded from the FRONT with no error at all -- a
  35-term list ordered wrong repaired 0 of 106 where the same words repaired 75.
- **A long list buys nothing**: 3 well-placed terms repair 86, 30 repair 88.

Spec §5. Highest expected gain on transcription quality of anything remaining.

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

---

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
