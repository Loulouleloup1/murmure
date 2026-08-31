# Local refiner benchmark -- which model cleans up a dictation

Date: 2026-08-31 · Lot 0, task 6 · Data: `benchmark/` · Aggregator: `benchmark/aggregate.py`

## Verdict

**`gemma4-12b-qat` wins.** It is the only candidate that is both faithful and actually cleans the
transcript, on both tasks, with no auto-fail and no bad draw.

- `prompt_cleanup`: median **8.0 / 8** (min 6, max 8, mean 7.53) over 45 judge-scores. It wins the
  per-packet head-to-head against every rival: 11-3-1 vs `qwen3.5-9b`, 14-1-0 vs `ornith-9b`,
  11-4-0 vs `granite4.2-8b`. All three independent judges rank it first.
- `message_rewrite`: median **8.0 / 8** (min 6, max 8, mean 7.51) -- the highest mean of the four,
  and the only candidate whose worst draw over 45 scores is still 6/8.
- Cost of that win: it is the **slowest** (median 2.86 s vs 1.91 s for `granite4.2-8b`) and the
  **largest on disk** (7.2 GB vs 5.3 GB). At the fixture length used here the gap is ~0.9 s.

**The runner-up is close, and on one of the two tasks the data does not separate them.**
`qwen3.5-9b` ties gemma on `message_rewrite` (median 8.0 both; qwen even wins the per-packet
head-to-head 7-4-4) and is 0.6 s faster and 0.6 GB smaller. What sinks it is `prompt_cleanup`:
median 6.5, a long bad tail (8 of its 42 scored draws at 4 or below) and the **only auto-fail in the whole
benchmark** -- it rendered a French-dominant transcript entirely in English on `f08`, flagged
independently by all three judges.

`ornith-9b` and `granite4.2-8b` are out, for opposite reasons documented below: ornith barely
cleans anything (disfluency median **0.0** on `prompt_cleanup`), granite cleans well but rewrites
what it should have preserved (fidelity median 1, verbatim median 1).

### Finalists for the blind A/B (task 7)

**`gemma4-12b-qat` and `qwen3.5-9b`.** What separates them, precisely:

| | separated? | evidence |
|---|---|---|
| `prompt_cleanup` quality | **yes, clearly** | median 8.0 vs 6.5; per-packet 11-3-1; qwen holds the only auto-fail; qwen's disfluency median 1.0 vs gemma 2.0 |
| `message_rewrite` quality | **no -- distributions overlap** | median 8.0 both; per-packet W4 T4 L7 in qwen's favour; qwen has more perfect draws (30/45 vs 25/45), gemma has a tighter floor (min 6 vs min 2) |
| latency | marginal | median 2.86 s vs 2.28 s over 30 calls each |
| size | marginal | 7.2 GB vs 6.6 GB |

So the honest reading: on `message_rewrite` the two are **not** separated by this data -- qwen wins
more packets, gemma is more consistent, and picking between them on 15 short synthetic fixtures
would be manufacturing a winner. The separation is real only on `prompt_cleanup`. That is exactly
what the A/B in task 7 should adjudicate: whether gemma's consistency or qwen's speed plus higher
ceiling matters more to Louis on his own dictations.

---

## The numbers

### Population compared

- 4 models judged (`s1-mini` excluded before the run, see limitations), 2 tasks, 15 fixtures.
- 30 packets (15 per task), each with 4 anonymised candidates behind shuffled letters A-D.
- 6 independent Opus judges (3 per task), each scoring all 15 packets x 4 candidates.
- **360 scored outputs** = 6 x 15 x 4. 3 of them are auto-fails (the same output, flagged by all
  three `prompt_cleanup` judges), leaving 357 numeric scores.
- 120 generation calls in `results.jsonl` = 4 models x 15 fixtures x 2 tasks.
- Score scale: 4 criteria (fidelity, disfluency, verbatim, format) x 0-2 = **0-8 per output**.

### Quality distribution -- `prompt_cleanup` (3 judges x 15 packets)

| model | n | min | median | max | mean | auto-fail | size GB |
|---|---:|---:|---:|---:|---:|---:|---:|
| **gemma4-12b-qat** | 45 | 6 | **8.0** | 8 | 7.53 | 0 | 7.2 |
| qwen3.5-9b | 42 | 2 | 6.5 | 8 | 5.90 | **3** | 6.6 |
| ornith-9b | 45 | 4 | 6.0 | 7 | 5.89 | 0 | 6.7 |
| granite4.2-8b | 45 | 3 | 6.0 | 8 | 5.58 | 0 | 5.3 |

Per criterion (median / min / mean):

| model | fidelity | disfluency | verbatim | format |
|---|---|---|---|---|
| gemma4-12b-qat | 2 / 2 / 2.00 | 2 / 1 / 1.60 | 2 / 1 / 1.93 | 2 / 2 / 2.00 |
| qwen3.5-9b | 2 / 0 / 1.52 | 1 / 0 / 1.14 | 1.5 / 0 / 1.36 | 2 / 1 / 1.88 |
| ornith-9b | 2 / 1 / 1.93 | **0 / 0 / 0.42** | 2 / 0 / 1.60 | 2 / 1 / 1.93 |
| granite4.2-8b | **1 / 0 / 1.04** | 2 / 1 / 1.69 | **1 / 0 / 1.02** | 2 / 1 / 1.82 |

Read the disfluency column before the total. `ornith-9b` scores a respectable 6.0 median while
**37 of its 45 scores are exactly 6** and its disfluency median is 0.0: that is the no-op signature
the judges warned about (limitation (a) below). It returns the transcript nearly untouched, which
is not refinement -- it is doing nothing, politely.

### Quality distribution -- `message_rewrite` (3 judges x 15 packets)

| model | n | min | median | max | mean | auto-fail | size GB |
|---|---:|---:|---:|---:|---:|---:|---:|
| **gemma4-12b-qat** | 45 | 6 | **8.0** | 8 | 7.51 | 0 | 7.2 |
| **qwen3.5-9b** | 45 | 2 | **8.0** | 8 | 7.18 | 0 | 6.6 |
| ornith-9b | 45 | 4 | 7.0 | 8 | 6.80 | 0 | 6.7 |
| granite4.2-8b | 45 | 4 | 7.0 | 8 | 6.36 | 0 | 5.3 |

Per criterion (median / min / mean):

| model | fidelity | disfluency | verbatim | format |
|---|---|---|---|---|
| gemma4-12b-qat | 2 / 0 / 1.56 | 2 / 2 / 2.00 | 2 / 1 / 1.96 | 2 / 2 / 2.00 |
| qwen3.5-9b | 2 / 0 / 1.71 | 2 / 0 / 1.73 | 2 / 0 / 1.73 | 2 / 2 / 2.00 |
| ornith-9b | 2 / 0 / 1.47 | 2 / 0 / 1.69 | 2 / 0 / 1.64 | 2 / 2 / 2.00 |
| granite4.2-8b | 1 / 0 / 1.16 | 2 / 0 / 1.84 | 2 / 0 / 1.49 | 2 / 1 / 1.87 |

Score histograms on this task (why the medians tie but the shapes differ):

- `gemma4-12b-qat`: 8 x25, 7 x18, 6 x2 -- nothing below 6.
- `qwen3.5-9b`: 8 x30, 7 x8, then a tail of 6/5/4/3/2 (6 scores at 5 or below).

### Per-packet head-to-head (median of the 3 judges per packet, 15 packets per task)

| pair | `prompt_cleanup` | `message_rewrite` |
|---|---|---|
| gemma vs qwen | **W11 T3 L1** | W4 T4 **L7** |
| gemma vs ornith | W14 T1 L0 | W7 T5 L3 |
| gemma vs granite | W11 T4 L0 | W9 T5 L1 |
| qwen vs ornith | W8 T2 L5 | W8 T6 L1 |
| qwen vs granite | W6 T3 L6 | W10 T3 L2 |
| ornith vs granite | W7 T4 L4 | W9 T2 L4 |

### Inter-judge agreement (controller-measured, on the 8-point per-candidate total)

| task | mean absolute pairwise Δ | max Δ | unanimous on the exact total |
|---|---|---|---|
| `prompt_cleanup` | 0.12 - 0.25 | 2 | **45 / 60** |
| `message_rewrite` | 0.10 - 0.40 | 3 | **36 / 60** |

All three `prompt_cleanup` judges independently flagged the **same single auto-fail** (`f08`,
letter B = `qwen3.5-9b`, output rendered entirely in English) and no other. Three judges agreeing
on which output is disqualifying, blind and independently, is the strongest available evidence the
frozen rubric is calibrated and these scores carry a verdict.

The judges also agree on the ranking: on `prompt_cleanup`, all three put `gemma4-12b-qat` first and
`qwen3.5-9b` second. On `message_rewrite`, judges 1 and 2 put qwen first and gemma second, judge 3
the reverse -- another sign those two are not separated on that task.

### Machine metrics (from `results.jsonl`, 15 calls per model per task)

| model | task | median lat s | p90 lat s | max lat s | median tok/s | median tokens out | size GB |
|---|---|---:|---:|---:|---:|---:|---:|
| gemma4-12b-qat | prompt_cleanup | 3.34 | 4.33 | 9.40 | 18.5 | 61 | 7.2 |
| gemma4-12b-qat | message_rewrite | 2.72 | 2.87 | 3.11 | 19.8 | 50 | 7.2 |
| qwen3.5-9b | prompt_cleanup | 2.53 | 2.86 | 6.47 | 25.9 | 61 | 6.6 |
| qwen3.5-9b | message_rewrite | 2.14 | 2.35 | 2.67 | 27.2 | 59 | 6.6 |
| ornith-9b | prompt_cleanup | 2.29 | 2.97 | 7.04 | 31.5 | 67 | 6.7 |
| ornith-9b | message_rewrite | 2.14 | 2.35 | 11.78 | 30.1 | 60 | 6.7 |
| granite4.2-8b | prompt_cleanup | 1.98 | 2.38 | 6.29 | 34.1 | 68 | 5.3 |
| granite4.2-8b | message_rewrite | 1.62 | 2.08 | 2.28 | 34.1 | 58 | 5.3 |

Two things about the max column. The 6-9 s values are each model's **first call** (rows 0, 30, 60,
90 -- Ollama loading the weights); excluding it the medians are unchanged (gemma 2.85, qwen 2.28,
ornith 2.20, granite 1.91). `ornith-9b`'s 11.78 s is not a cold start (4th call) and is a genuine
outlier. Louis will pay the load cost once per session, then the medians.

No output came near the `num_predict: 512` cap: the longest generation in the whole run is 98
tokens. That is a property of the short fixtures, not evidence the cap is safe (see limitations).

---

## Method, briefly

1. **15 synthetic French fixtures** (`benchmark/fixtures.jsonl`, all tagged `source: synthetic`) --
   raw-STT-style transcripts with hesitations, false starts and English technical terms.
   **Zero real dictations were used**; see ruling R9 in the SDD ledger for why.
2. Two task prompts: `prompt_cleanup` (clean up a dictated coding prompt, preserve every technical
   term verbatim) and `message_rewrite` (turn a dictation into a sendable Slack/email message).
3. 4 candidates served by Ollama via the **native `/api/chat`** with `"think": false` and
   `options.num_predict: 512` (ruling R6). 120 calls, latency and `eval_count` recorded per call.
4. Outputs anonymised into 30 packets with a **per-packet shuffled A-D letter mapping** kept outside
   `packets/`; 17 distinct orderings across 30 packets, no model name or distinctive substring
   anywhere in the packets.
5. **6 independent judges** (3 per task, no cross-talk), each scoring 15 packets x 4 candidates
   against a frozen rubric: fidelity / disfluency / verbatim / format, each 0-2, plus a boolean
   auto-fail for a wrong-language output.
6. `benchmark/aggregate.py` de-anonymises the judgments and joins them with the machine metrics.
   It reports **min / median / max across the three judges**, never a single draw. Auto-fails are
   **counted separately, not folded in as a 0** -- a synthetic zero would drag a median and hide the
   distinction between "scored badly" and "disqualified". It raises on a missing judge file, packet,
   letter, `size_gb` key or perf row rather than skipping.

---

## Limitations -- read these before trusting the table

### 1. Fixture length gap: every candidate was measured on short input only (ruling R10)

The 15 synthetic fixtures are **median 46 words** (min 34, max 61). Louis's real corpus -- 1 477
Superwhisper dictations with a non-empty raw transcript, 98 % French -- is **median 77 words, mean
105, p90 224, max 987**. The benchmark therefore says nothing about the regime Louis actually
dictates in half the time. Two consequences, both untested:

- **Latency at ~224 words is unmeasured.** These numbers are 2-3 s on ~50-word inputs. Output
  length scales with input, and at ~19 tok/s gemma's headline advantage could become several
  seconds of felt lag.
- **`options.num_predict: 512` may truncate a long-form refinement outright.** The longest output
  observed here is 98 tokens, comfortably under the cap -- but only because the inputs are short. A
  224-word dictation could plausibly need more than 512 tokens out, and truncation would be silent.

**The gap is length, not disfluency.** Measured: 87 % of the fixtures carry at least one filler
(median 1 hit) against 51 % of the real transcripts (median 1). The fixtures deliberately
over-sample disfluency, which is what the rubric criterion exists to stress. So the fixtures are
representative of *how messy* a dictation is, and unrepresentative of *how long* it is.

**Follow-up required before the winner ships in a mode:** re-measure the top 2 on long input
(~224 words) for latency and truncation.

### 2. All four candidates were benchmarked with reasoning disabled (ruling R6)

Every servable candidate here is a reasoning model. Under the OpenAI-compat endpoint they burned
the whole token budget on a `reasoning` field and returned empty content; content only appeared at
300-400 tokens. The benchmark therefore calls the native `/api/chat` with `"think": false`, because
reasoning latency is disqualifying for dictation -- Louis feels every second.

Consequence: **a candidate that is markedly better with reasoning on shows none of that strength
here.** That is accepted deliberately, not an oversight. The ranking is valid for the non-reasoning
mode, which is the only mode this product would ever use.

### 3. Four rubric limitations the judges reported convergently

These were flagged independently by several judges across both tasks. They are not averaged away:

**(a) A no-op scores 6/8.** An output that returns the transcript essentially untouched loses only
the disfluency point -- fidelity, verbatim and format all stay clean. *How to read the table:* never
take a high total as "good refinement" without checking the disfluency column. `ornith-9b` on
`prompt_cleanup` is the live example: median total 6.0, looks tied with granite, but disfluency
median 0.0 and 37/45 scores of exactly 6. Its total is a rubric artefact of doing nothing.

**(b) Identifier normalisation is unsettled.** Rendering dictated "files used" as `files_used`, or
"transcribe audio path" as `transcribeAudioPath`, sits between "kept exactly" and "altered". Judges
split between verbatim 1 and verbatim 2 on the *same* outputs (`f01`, `f08`, `f09`). *How to read
the table:* the verbatim column carries roughly ±0.5 of unresolved convention, spread across all
candidates, so it affects the absolute level more than the ranking. It is also the single question
Louis should settle in task 7 -- it is a preference, not an error.

**(c) Register is unscored.** The `message_rewrite` prompt mandates tutoiement, while fixtures
`f04` and `f12` are vouvoiement messages to a client. The rubric has no instruction-following
criterion, so a genuine prompt deviation goes unpenalised either way. *How to read the table:*
`message_rewrite` totals say nothing about whether a model follows a register instruction. If
register matters, it must be tested separately.

**(d) The wrong-language auto-fail is undefined for code-switched input.** Fixture `f08` mixes
French and English. All three judges independently resolved it the same way -- auto-fail only the
all-English output, penalise the all-French one under verbatim -- but the rubric does not say so.
*How to read the table:* qwen's single auto-fail rests on a judge convention, not written rule. The
convergence of three independent judges makes it trustworthy; the rubric should nonetheless be
amended before it is reused.

### 4. `s1-mini` was excluded on language scope, not on failure (ruling R7)

`s1-mini` (484 MB, `hf.co/superwhisper/s1-mini-GGUF:Q4_K_M`) is **purpose-built for exactly this
task** -- transcript clean-up -- and is by far the smallest candidate. It was excluded before the
run because its v1 model card states it covers **English only**, and it is "not a chat model"
(steered by a control line, not a system prompt). Our fixtures are French and Louis dictates in
French, so it was out of scope, not out-performed. Keep the pointer: if an English-only mode is
ever added, s1-mini is the first thing to benchmark, and at 484 MB it would dominate on every
machine metric here.

---

## What was verified, and how

- **Independent recomputation of the scores.** Every number in both quality tables was recomputed by
  a second, differently structured script: instead of iterating judgment files and looking letters
  up in the mapping (what `aggregate.py` does), it **inverts** the mapping to `model -> {packet:
  letter}` and pulls scores model-first. All 8 model x task cells match `aggregate.py` exactly on
  n, min, median, max, mean, auto-fail count and all four per-criterion medians.
- **Manual anchor by eye.** `granite4.2-8b` on `prompt_cleanup/f01` is letter B in
  `letter_mapping.json`; the three raw judge lines for letter B score (2,2,0,2), (1,2,0,2),
  (1,2,0,2) -- totals 6, 5, 5 -- and all three notes describe the same defect ("translates 'files
  used' and 'file description' into French"). Consistent with granite's aggregate verbatim mean of
  1.02 on this task.
- **Inter-judge agreement independently reproduced.** The controller's figures were recomputed from
  the raw judgments and match to the digit: `prompt_cleanup` 45/60 unanimous with pairwise mean |Δ|
  0.12 / 0.24 / 0.25 and max 2; `message_rewrite` 36/60 unanimous with 0.10 / 0.37 / 0.40 and max 3.
- **Auto-fail identity.** The three auto-fails are one output (`prompt_cleanup/f08`, letter B =
  `qwen3.5-9b`) flagged by all three judges; no judge flagged anything else.
- **`size_gb`, not `ram_gb`.** `aggregate.py` raises `KeyError` if a `models.json` entry lacks
  `size_gb`; it never defaults to 0. Verified: the sizes printed (7.2 / 6.7 / 6.6 / 5.3) match
  `models.json`.
- **Population completeness.** The aggregator fails loudly on a missing judge file, an unjudged
  packet, a duplicate packet, a letter set that does not match the mapping, or a model with no
  `results.jsonl` row. It ran clean, which means all 6 files, all 30 packets x 3 judges and all 4
  letters per packet are present -- 360 scores, none skipped.

**Not verified (out of scope for this task):**

- Whether the judges' *qualitative* reasoning is correct. Agreement is measured; ground truth is
  not, because there is no reference clean-up.
- Behaviour on real dictations, on long input, and with reasoning on -- see limitations 1 and 2.
- Latency reproducibility across machine load states. Each figure is one median over 15 calls on
  one machine on one day; an earlier smoke test on the same model varied by ~1 s between runs.
