# What is left, 2026-09-02

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

## 2. Four empty settings panes

`Modes`, `Models`, `General` and `Advanced` render `Color.clear` — literally nothing
(`MainWindowView.swift`, the `default` arm of `pane`). The frame, the sidebar, the palette and the
window restoration are all built; only the contents are missing.

The consequence, and the reason this is on the list at all: **every setting is edited as JSON by
hand today** — the hotkey, the model, a mode's instructions. `scripts/set-refiner.sh` exists
precisely because three of those fields are correlated and editing one alone produces a mode that
still validates and silently inserts the raw transcript.

Lot 4 T7 (Modes), T8 (Models/General/Advanced), T9 (empty and broken states). Sidebar order and the
section-by-section content are already settled in that plan.

## 3. `stt.language` is hardcoded

`WhisperKitEngine` decodes with `DecodingOptions(language: "fr")` at a module constant, so
**`Mode.stt.language` and `Mode.stt.model` are parsed, validated, stored and then ignored**. A mode
saying `"language": "en"` transcribes French, silently. The code already knows: the engine carries a
comment owing this a per-mode seam.

Low priority only because Louis dictates in French. It is a defect, not a missing feature: the
config lies about what it controls. Fixing it is also what T6 needs, since `initialPrompt` travels
the same seam.

---

## Known, argued, and deliberately not scheduled

- **The hover dashboard with Stop/Cancel** (lot 3 T5) stays blocked on `ignoresMouseEvents = true`.
  Escape shipped and supersedes its only urgent purpose.
- **`durationSeconds` comes from `Date`.** An NTP correction mid-dictation writes a wrong duration.
  A monotonic clock fixes it; T4 declined to add an unguarded fix and said so.
- **Two surfaces with nothing behind them**: a corrupt database is named as an error no screen
  shows, and a row that failed to write is silent. The dictation itself still succeeds, which is the
  right priority — but the archive is then quietly incomplete. Lot 4 T9.
- **The default branch is `main`.** The rename happened; `origin/HEAD` points at it and no
  `master` remains on the remote. A clone made before it needs
  `git fetch --prune origin && git branch -m master main && git branch -u origin/main main`.
