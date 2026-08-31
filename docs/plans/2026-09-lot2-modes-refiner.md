# Lot 2 — Modes & LLM refinement

Follows lot 1 (dictation core, validated 2026-08-31 by real use) and lot 0 (refiner benchmark,
`docs/benchmarks/2026-08-refiner-benchmark.md` + `2026-09-refiner-benchmark-v2.md`).

## What this lot delivers

A dictation is currently: hotkey → record → Whisper → paste. This lot inserts the mode between the
hotkey and the paste: **which model transcribes, in which language, with which instructions, refined
by which LLM, into which application**.

Spec: §5 (Modes), §4 (Coordinator), §9 (Error handling). Out of scope here and stated so: notch UI
(lot 3), history and vocabulary (lot 4), file/YouTube (lot 5).

## Decisions taken before starting, with their evidence

| Decision | Evidence | Where it can be revisited |
|---|---|---|
| Default refiner `gemma4-12b-qat` | v2 benchmark: unanimous across 3 judges, **fidelity mean 1.98 / min 1 and 0 auto-fails**, against 1.52 / **min 0** and 3 auto-fails for the 4.3 GB model. A fidelity of 0 means content was deleted — the one failure a user cannot see happen. | `llm.model` per mode |
| Ollama options pinned: `temperature 0`, `seed`, `num_predict 2048`, `num_ctx 8192` | Measured: at the defaults, `num_predict 512` truncates a 370-word dictation mid-sentence and `num_ctx` 2048 silently drops input past ~600 words. Both are production-only bugs — the benchmark fixtures are too short to expose them. | never (they are floors, not preferences) |
| `stt.language` defaults to `"fr"`, not `"auto"` | Whole real corpus (1 449 dictations): `detectLanguage: true` re-evaluates per window, produced 9 non-Latin transcripts plus unseen Spanish switches, and accounted for every case where Superwhisper beat us. Pinning removed 100 % of them. Louis dictates French with English technical terms, never full English. | `stt.language` per mode — this lot builds exactly that seam |
| No few-shot in the shipped prompt | The v2 few-shot advantage did not survive stratification: it appears only on fixtures resembling the examples (+0.40 near / −0.11 far, measured where headroom exists). Unproven, so not shipped. | a later prompt lot, with out-of-distribution examples |
| Refiner prompts start from `benchmark/prompts/*.txt` | They are what the 765 blind scores were produced against. Any edit invalidates that evidence and must be re-measured. | — |

**Open, and deliberately not blocking:** the 12B takes **19.0 s median** on a 260-370 word dictation
(3.17 s on a short one); the 4.3 GB model takes 4.58 s and 0.81 s. Louis has been asked whether 19 s
is acceptable. His answer changes one field's default value — `llm.model` — and nothing structural,
which is why this lot proceeds. If he says no, the answer is a second mode, not a rewrite.

## Tasks

1. **`Mode` model + store** (core) — the JSON shape of spec §5, load/save from
   `~/Library/Application Support/Murmure/modes/<key>.json`, the four built-ins created on first
   launch, validation with a named error per invalid field. A malformed mode file must not take the
   app down: it is reported and skipped, and the default mode still works.
2. **Ollama client** (app) — native `/api/chat` with `think: false` and the pinned options above.
   Must distinguish, as separate reported outcomes: Ollama not running, model not pulled, timeout,
   and a well-formed refusal. Ruling L7 applies — no failure mechanism without a consumer.
3. **Refiner step** (core) — raw transcript → refined text, behind a protocol so it is testable
   without Ollama. Carries the **no-op guard**: an output identical to the input is the documented
   failure mode of a too-small model, and the only remedy the literature offers is caller-side
   detection. Flag it, do not silently accept it.
4. **Mode selection** — manual (menu bar for now) plus `autoActivate` by frontmost bundle id,
   resolved at recording start, with a deterministic tie-break when two modes claim one app.
5. **Wire into `DictationSession`** — the mode chooses the language, the instructions and the
   refiner; `Voice` (no LLM) stays the default and must remain byte-identical to today's behaviour.
   That equivalence is a test, not an assumption.

## Acceptance

Unit tests in `MurmureCore` (the app target has no test bundle — this is why the logic lives in the
core). Plus one gate only Louis can pass: dictate through `Voice` and confirm nothing changed, then
through `Prompt` and confirm the refinement is worth its latency on his real work.
