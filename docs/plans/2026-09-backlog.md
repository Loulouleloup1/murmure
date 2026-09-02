# What is left, 2026-09-02

Everything below is already argued somewhere — in a plan, a doc comment, or a spec section. This
file exists because it was **argued in prose and never listed**, so the honest answer to "what is
left?" took a grep. One page, ordered, each item pointing at where it is actually specified.

The loop works today: ⌥Space, record, transcribe, refine, paste, plus History and the retention
purge. What follows is what the app still cannot do.

---

## In flight

**Cancel gets a caller.** `DictationSession.cancel()` writes a `.cancelled` row, is tested, and had
no caller — a started dictation could not be abandoned. Escape while recording, registered only for
the length of the recording so it is not stolen from the rest of macOS. Resolves the open question
in `2026-09-lot4-app-window.md` §"For T9".

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
  Escape supersedes its only urgent purpose.
- **`durationSeconds` comes from `Date`.** An NTP correction mid-dictation writes a wrong duration.
  A monotonic clock fixes it; T4 declined to add an unguarded fix and said so.
- **Two surfaces with nothing behind them**: a corrupt database is named as an error no screen
  shows, and a row that failed to write is silent. The dictation itself still succeeds, which is the
  right priority — but the archive is then quietly incomplete. Lot 4 T9.
- **`master` has not been renamed to `main`.** Offered and held, because a rename mid-clone on the
  second Mac breaks it.
