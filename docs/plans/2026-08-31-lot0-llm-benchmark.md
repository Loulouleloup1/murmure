# Lot 0 — Refiner LLM Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pick the default local refinement model for Murmure, data-driven, among 5 verified candidates.

**Architecture:** Python scripts hit LM Studio's OpenAI-compatible endpoint for each model × fixture × task, record outputs + machine metrics; outputs are anonymised into packets; blind Opus-tier judges score them against a rubric frozen before any generation; an aggregation script produces the report; Louis adjudicates the top 2.

**Tech Stack:** Python 3.11+ (`requests`), LM Studio (`lms` CLI) as the single serving endpoint, `mlx_lm` for the one model without GGUF.

**Spec:** `docs/specs/2026-08-31-whisper-local-design.md` (§10)

## Global Constraints

- 100% local — no cloud API calls anywhere in the benchmark.
- The rubric and judge prompt MUST be committed before `run_benchmark.py` is ever executed (frozen-before-outputs doctrine).
- Judges never see model names; the letter→model mapping lives outside the packets directory.
- Machine metrics are measured on this M4 Pro, never copied from blogs.
- All work happens in the `murmure` repo; commit after every task.
- ~35 GB of model downloads — check disk space (`df -h /`) before Task 2.

---

### Task 1: Benchmark scaffolding — fixtures, prompts, rubric (frozen)

**Files:**
- Create: `benchmark/fixtures.jsonl`
- Create: `benchmark/prompts/prompt_cleanup.txt`
- Create: `benchmark/prompts/message_rewrite.txt`
- Create: `benchmark/rubric.md`
- Create: `benchmark/judge_prompt.txt`

**Interfaces:**
- Produces: `fixtures.jsonl` — one JSON object per line: `{"id": "f01", "source": "synthetic"|"real", "raw": "<raw transcript>"}`. Consumed by `run_benchmark.py` (Task 3).
- Produces: the two prompt files — consumed verbatim as the system prompt by `run_benchmark.py`.

- [ ] **Step 1: Write the 10 synthetic fixtures**

Create `benchmark/fixtures.jsonl` with exactly these 10 lines (they simulate Louis's real dictation style — French with disfluencies, false starts, and English technical terms that MUST survive refinement verbatim):

```jsonl
{"id": "f01", "source": "synthetic", "raw": "alors euh je voudrais que tu regardes le fichier euh le connecteur trucost là et que tu vérifies que le les files used sont bien un sous-ensemble de file description parce que sinon ça ça crash avec un KeyError au runtime"}
{"id": "f02", "source": "synthetic", "raw": "ok donc lance les tests unitaires sur le module de tagging enfin non attends d'abord fais un git fetch origin et ensuite tu lances pytest sur tests slash unit et tu me dis combien passent"}
{"id": "f03", "source": "synthetic", "raw": "salut euh est-ce que tu peux regarder la PR trente et un quand t'as un moment y a un truc bizarre sur le double scaling des valeurs dans l'export Excel je crois que c'est le fill review work sheet qui multiplie par cent une deuxième fois"}
{"id": "f04", "source": "synthetic", "raw": "bonjour donc suite à notre échange de la semaine dernière euh je reviens vers vous concernant le dictionnaire de données du provider on a identifié douze indicateurs livrés dans les fichiers mais absents du dictionnaire est-ce que vous pourriez nous confirmer si c'est voulu ou pas merci d'avance"}
{"id": "f05", "source": "synthetic", "raw": "je veux que tu fasses trois choses premièrement tu crées une branche feat slash notch ui deuxièmement tu ajoutes la dépendance DynamicNotchKit dans le project point yml et troisièmement tu vérifies que ça build avec xcodebuild"}
{"id": "f06", "source": "synthetic", "raw": "donc pour le mode meeting non attends je me suis trompé pour le mode prompt il faut que le LLM garde les termes techniques verbatim genre Hindsight Serena le DCG tout ça et qu'il enlève juste les hésitations sans réécrire le fond"}
{"id": "f07", "source": "synthetic", "raw": "euh oui alors je disais que le le pipeline il fait la capture audio puis la transcription puis la la reformulation et enfin l'insertion et je veux que chaque couche soit derrière un protocol pour qu'on puisse swapper les implémentations tu vois le genre euh une interface TranscriptionEngine quoi"}
{"id": "f08", "source": "synthetic", "raw": "can you euh check the the WhisperKit README because je suis pas sûr que l'API transcribe audio path elle existe encore dans la version zéro neuf il faut peut-être passer par un WhisperKitConfig maintenant"}
{"id": "f09", "source": "synthetic", "raw": "le fichier de config il est dans tilde slash Library slash Application Support slash Murmure slash modes et chaque mode c'est un JSON avec le champ key le champ instructions et les toggles de contexte donc selected text clipboard et app context"}
{"id": "f10", "source": "synthetic", "raw": "hey euh petite question est-ce que quelqu'un sait pourquoi le run de vendredi soir a produit zéro lignes pour le provider MSCI alors que le bucket S3 contient bien les fichiers d'input j'ai regardé les logs CloudWatch mais euh y a rien d'évident"}
```

- [ ] **Step 2: Collect the 5 real fixtures (USER INPUT REQUIRED — blocking)**

Ask Louis to dictate 5 real prompts/messages with Superwhisper in **Voice mode** (raw transcription, no AI) and paste the raw transcripts. Append them to `benchmark/fixtures.jsonl` as `{"id": "f11".."f15", "source": "real", "raw": "..."}`.

If Louis is not available, proceed with f01–f10 and leave a `TODO(real-fixtures)` marker ONLY in the commit message (never in the file); the benchmark is re-runnable cheaply once f11–f15 land.

- [ ] **Step 3: Write the two task prompts**

`benchmark/prompts/prompt_cleanup.txt` (exact content — this is also the future *Prompt* mode instruction, keep them in sync):

```
You clean up dictated text. The input is a raw speech-to-text transcript in French, often mixed with English technical terms.

Rules:
- Remove hesitations (euh, hum), filler words (alors, donc, du coup, genre, tu vois, quoi) when they carry no meaning, repeated words, and false starts (keep only the corrected version when the speaker corrects themselves, e.g. "non attends" patterns).
- Add proper punctuation, capitalisation, and paragraph breaks.
- Keep EVERY technical term, product name, file path, command, and English word EXACTLY as dictated. Never translate them. Never "fix" them.
- Never rewrite, summarise, expand, or reorder the meaning. The output must say exactly what the speaker said, minus the noise.
- Convert spoken symbols: "slash" → "/", "point" → "." when clearly part of a path, file name, or URL.
- Output ONLY the cleaned text. No preamble, no quotes, no markdown fences, no commentary.
```

`benchmark/prompts/message_rewrite.txt` (exact content — future *Message* mode instruction):

```
You turn dictated text into a short Slack message. The input is a raw speech-to-text transcript in French, often mixed with English technical terms.

Rules:
- Rewrite as a concise, informal-professional Slack message in French (tutoiement).
- Remove all hesitations, fillers, and false starts.
- Keep every technical term, product name, path, and English word exactly as dictated — never translate them.
- Keep the original intent and ALL factual content (numbers, names, questions). Do not add greetings or sign-offs the speaker did not say.
- Output ONLY the message text. No preamble, no quotes, no markdown fences, no commentary.
```

- [ ] **Step 4: Write the frozen rubric**

`benchmark/rubric.md` (exact content):

```markdown
# Refiner benchmark rubric — FROZEN 2026-08-31, before any model output was generated

Each output is scored on 4 criteria, 0–2 each (max 8):

1. **Semantic fidelity** — 2: nothing added, lost, or distorted; 1: minor drift
   (a nuance weakened, a redundancy collapsed with slight loss); 0: content
   invented, dropped, or meaning changed.
2. **Disfluency removal** — 2: all hesitations/fillers/false starts gone; 1: a
   few leftovers; 0: transcript essentially unclean.
3. **Verbatim preservation** — 2: every technical term, product name, path,
   command, and English word kept exactly (spoken "slash"/"point" conversion
   expected); 1: one term altered/translated; 0: two or more altered.
4. **Format compliance** — 2: output is only the target text; 1: cosmetic noise
   (stray quotes, trailing whitespace lines); 0: preamble, commentary, markdown
   fences, or refusal.

Auto-fail (total = 0 regardless of criteria): output in the wrong language
(technical terms aside), output that answers the transcript's question instead
of cleaning/rewriting it, empty output.

Score each (fixture × task × candidate letter) independently. Do not compare
letters against each other while scoring; scores are absolute against this
rubric.
```

- [ ] **Step 5: Write the judge prompt**

`benchmark/judge_prompt.txt` (exact content):

```
You are a blind judge for a text-refinement benchmark. You will receive packets.
Each packet contains: the raw dictated transcript, the task prompt that was
given to the candidates, and N candidate outputs labelled A, B, C, ...

You do not know which model produced which output, and you must not guess or
let style similarity influence you. Score each output independently against
the rubric provided below. Output STRICT JSON, one object per packet:

{"packet_id": "...", "scores": {"A": {"fidelity": 0-2, "disfluency": 0-2, "verbatim": 0-2, "format": 0-2, "autofail": false, "note": "<one short sentence>"}, "B": {...}}}

No other text outside the JSON objects.
```

- [ ] **Step 6: Commit**

```bash
git add benchmark/
git commit -m "feat(benchmark): fixtures, task prompts, frozen rubric and judge prompt"
```

---

### Task 2: Load the 5 candidates into LM Studio

**Files:**
- Create: `benchmark/models.json`

**Interfaces:**
- Produces: `benchmark/models.json` — consumed by `run_benchmark.py`. Schema:
  `[{"name": "s1-mini", "model_id": "<id as served by lms>", "ram_gb": <float from lms ps>, "disk_gb": <float>}, ...]`
- LM Studio server running on `http://localhost:1234/v1` with each model loadable by `model_id`.

- [ ] **Step 1: Check tooling and disk**

```bash
lms --version && df -h / && python3 --version
```
Expected: lms CLI present (LM Studio is installed), ≥ 50 GB free. If `lms` is missing: `~/.lmstudio/bin/lms bootstrap` or ask Louis to open LM Studio once.

- [ ] **Step 2: Download the three GGUF-ready / hub-listed candidates**

```bash
lms get ornith-ai/Ornith-1.5-9B-GGUF   # pick Q4_K_M when prompted
lms get qwen3.5-9b                      # pick the Q4_K_M community GGUF or MLX 4-bit
lms get granite-4.2-8b                  # pick Q4_K_M
```
For each, if `lms get` finds no match, search the hub name variants with `lms get <name> --yes=false` interactively; as a fallback download the GGUF with `huggingface-cli download <community-gguf-repo>` into `~/.lmstudio/models/`. Record the exact ids shown by `lms ls` afterwards.

- [ ] **Step 3: gemma-4-12b-qat (gated — USER INPUT REQUIRED once)**

Ask Louis to run `huggingface-cli login` and accept the Gemma licence on the `google/gemma-4-12b-qat` model page. Then:

```bash
lms get google/gemma-4-12b-qat || huggingface-cli download google/gemma-4-12b-qat --local-dir ~/.lmstudio/models/google/gemma-4-12b-qat
```
If the QAT repo ships safetensors only (no GGUF), use the MLX route of Step 4 for it as well.

- [ ] **Step 4: s1-mini (no GGUF — convert to MLX)**

```bash
python3 -m venv benchmark/.venv && source benchmark/.venv/bin/activate
pip install mlx-lm requests
mlx_lm.convert --hf-path superwhisper/s1-mini --mlx-path ~/.lmstudio/models/mlx/s1-mini-4bit -q
```
LM Studio serves MLX models placed under its models directory; confirm it appears in `lms ls`.

- [ ] **Step 5: Smoke-test each model and fill models.json**

For each of the 5 ids from `lms ls`:

```bash
lms load "<model_id>" && curl -s http://localhost:1234/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model": "<model_id>", "messages": [{"role": "user", "content": "Réponds uniquement: ok"}], "max_tokens": 5}' | python3 -m json.tool
lms ps   # note the RAM footprint
lms unload --all
```
Expected: a JSON completion containing "ok"-ish text. Fill `benchmark/models.json` with the 5 entries (measured `ram_gb` from `lms ps`, `disk_gb` from `lms ls`). A model that cannot be served after both routes (GGUF + MLX) is recorded in models.json with `"excluded": "<reason>"` and reported — never silently dropped.

- [ ] **Step 6: Commit**

```bash
git add benchmark/models.json
git commit -m "feat(benchmark): candidate models resolved and smoke-tested in LM Studio"
```

---

### Task 3: Generation runner

**Files:**
- Create: `benchmark/run_benchmark.py`
- Create (output, committed): `benchmark/results.jsonl`

**Interfaces:**
- Consumes: `fixtures.jsonl`, `models.json`, `prompts/*.txt`.
- Produces: `results.jsonl` — one line per (model × fixture × task):
  `{"model": str, "fixture_id": str, "task": "prompt_cleanup"|"message_rewrite", "output": str, "latency_s": float, "completion_tokens": int, "tokens_per_s": float}`. Consumed by `make_packets.py` and `aggregate.py`.

- [ ] **Step 1: Write the runner**

`benchmark/run_benchmark.py`:

```python
"""Run every candidate model over every fixture x task via LM Studio."""
from __future__ import annotations

import json
import pathlib
import subprocess
import time

import requests

BASE = pathlib.Path(__file__).parent
ENDPOINT = "http://localhost:1234/v1/chat/completions"
TASKS = {
    "prompt_cleanup": (BASE / "prompts" / "prompt_cleanup.txt").read_text(),
    "message_rewrite": (BASE / "prompts" / "message_rewrite.txt").read_text(),
}


def load_jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def run_one(model_id: str, system: str, raw: str) -> dict:
    t0 = time.monotonic()
    resp = requests.post(
        ENDPOINT,
        json={
            "model": model_id,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": raw},
            ],
            "temperature": 0.2,
            "max_tokens": 1024,
        },
        timeout=300,
    )
    resp.raise_for_status()
    data = resp.json()
    latency = time.monotonic() - t0
    completion_tokens = data.get("usage", {}).get("completion_tokens", 0)
    return {
        "output": data["choices"][0]["message"]["content"].strip(),
        "latency_s": round(latency, 3),
        "completion_tokens": completion_tokens,
        "tokens_per_s": round(completion_tokens / latency, 2) if latency > 0 else 0.0,
    }


def main() -> None:
    fixtures = load_jsonl(BASE / "fixtures.jsonl")
    models = [m for m in json.loads((BASE / "models.json").read_text()) if not m.get("excluded")]
    out_path = BASE / "results.jsonl"
    done = {(r["model"], r["fixture_id"], r["task"]) for r in load_jsonl(out_path)} if out_path.exists() else set()
    with out_path.open("a") as out:
        for model in models:
            subprocess.run(["lms", "unload", "--all"], check=True)
            subprocess.run(["lms", "load", model["model_id"]], check=True)
            for fixture in fixtures:
                for task, system in TASKS.items():
                    key = (model["name"], fixture["id"], task)
                    if key in done:
                        continue
                    result = run_one(model["model_id"], system, fixture["raw"])
                    row = {"model": model["name"], "fixture_id": fixture["id"], "task": task, **result}
                    out.write(json.dumps(row, ensure_ascii=False) + "\n")
                    out.flush()
                    print(f"{model['name']} {fixture['id']} {task}: {result['latency_s']}s")
    subprocess.run(["lms", "unload", "--all"], check=True)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run it**

```bash
source benchmark/.venv/bin/activate && python3 benchmark/run_benchmark.py
```
Expected: 5 models × 15 fixtures × 2 tasks = **150 lines** in `results.jsonl` (or n_models × n_fixtures × 2 if a model was excluded / real fixtures pending — verify the count matches the population and STATE the compared population; an empty or short file is a failure, not a pass).

```bash
wc -l benchmark/results.jsonl
```

- [ ] **Step 3: Commit**

```bash
git add benchmark/run_benchmark.py benchmark/results.jsonl
git commit -m "feat(benchmark): generation runner + raw results (N=<actual count>)"
```

---

### Task 4: Anonymised judge packets

**Files:**
- Create: `benchmark/make_packets.py`
- Create (output): `benchmark/packets/prompt_cleanup.jsonl`, `benchmark/packets/message_rewrite.jsonl`
- Create (output, NOT in packets/): `benchmark/letter_mapping.json`

**Interfaces:**
- Consumes: `results.jsonl`, `fixtures.jsonl`, `prompts/*.txt`.
- Produces: packets — one line per fixture:
  `{"packet_id": "prompt_cleanup/f01", "raw": str, "task_prompt": str, "candidates": {"A": str, "B": str, ...}}`.
  `letter_mapping.json`: `{"packet_id": {"A": "model-name", ...}}` — judges must NEVER receive this file.

- [ ] **Step 1: Write the packet builder**

`benchmark/make_packets.py`:

```python
"""Build anonymised, per-fixture judge packets from results.jsonl."""
from __future__ import annotations

import json
import pathlib
import random
import string

BASE = pathlib.Path(__file__).parent
random.seed(20260831)  # reproducible shuffle; seed value is arbitrary but fixed


def load_jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def main() -> None:
    results = load_jsonl(BASE / "results.jsonl")
    fixtures = {f["id"]: f for f in load_jsonl(BASE / "fixtures.jsonl")}
    (BASE / "packets").mkdir(exist_ok=True)
    mapping: dict[str, dict[str, str]] = {}
    for task in ("prompt_cleanup", "message_rewrite"):
        task_prompt = (BASE / "prompts" / f"{task}.txt").read_text()
        lines = []
        fixture_ids = sorted({r["fixture_id"] for r in results if r["task"] == task})
        for fid in fixture_ids:
            rows = [r for r in results if r["task"] == task and r["fixture_id"] == fid]
            random.shuffle(rows)
            letters = string.ascii_uppercase[: len(rows)]
            packet_id = f"{task}/{fid}"
            mapping[packet_id] = {letter: row["model"] for letter, row in zip(letters, rows)}
            lines.append(json.dumps({
                "packet_id": packet_id,
                "raw": fixtures[fid]["raw"],
                "task_prompt": task_prompt,
                "candidates": {letter: row["output"] for letter, row in zip(letters, rows)},
            }, ensure_ascii=False))
        (BASE / "packets" / f"{task}.jsonl").write_text("\n".join(lines) + "\n")
    (BASE / "letter_mapping.json").write_text(json.dumps(mapping, indent=2, ensure_ascii=False))
    print(f"packets written; {len(mapping)} packets total")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run and verify**

```bash
python3 benchmark/make_packets.py && wc -l benchmark/packets/*.jsonl
```
Expected: 15 packets per task file (matching fixture count). Spot-check one packet: letters differ across packets (shuffle worked), no model name appears anywhere in `packets/`:

```bash
grep -il "s1-mini\|ornith\|gemma\|qwen\|granite" benchmark/packets/ -r
```
Expected: no matches.

- [ ] **Step 3: Commit**

```bash
git add benchmark/make_packets.py benchmark/packets/ benchmark/letter_mapping.json
git commit -m "feat(benchmark): anonymised judge packets + secret letter mapping"
```

---

### Task 5: Blind judging (ORCHESTRATOR-EXECUTED — not an implementer subagent task)

**Files:**
- Create (output): `benchmark/judgments/<task>_judge<1-3>.jsonl` (6 files)

**Interfaces:**
- Consumes: `packets/*.jsonl`, `judge_prompt.txt`, `rubric.md`.
- Produces: judgment files — same JSON schema as defined in `judge_prompt.txt`. Consumed by `aggregate.py`.

- [ ] **Step 1: Dispatch 3 independent Opus-tier judges per task (6 subagents total)**

The orchestrating session dispatches each judge with: `judge_prompt.txt` + `rubric.md` + one full packet file — and NOTHING else (no mapping, no model list, no spec, fresh context). Model tier: **opus, explicitly set** (review tier is never degraded). Save each judge's JSON-lines output verbatim to `benchmark/judgments/<task>_judge<n>.jsonl`.

- [ ] **Step 2: Validate judgment files**

```bash
python3 - <<'EOF'
import json, pathlib
for p in sorted(pathlib.Path("benchmark/judgments").glob("*.jsonl")):
    rows = [json.loads(line) for line in p.read_text().splitlines() if line.strip()]
    assert all("packet_id" in r and "scores" in r for r in rows), p
    print(p.name, len(rows), "packets")
EOF
```
Expected: 6 files × 15 packets, every packet scored, every letter present.

- [ ] **Step 3: Commit**

```bash
git add benchmark/judgments/
git commit -m "feat(benchmark): blind judgments, 3 opus judges per task"
```

---

### Task 6: Aggregation and report

**Files:**
- Create: `benchmark/aggregate.py`
- Create (output): `docs/benchmarks/2026-08-refiner-benchmark.md`

**Interfaces:**
- Consumes: `judgments/*.jsonl`, `letter_mapping.json`, `results.jsonl`, `models.json`.
- Produces: the report — per-model score distribution (min/median/max across judges, per doctrine: never a single-draw verdict), machine metrics, top-2 recommendation.

- [ ] **Step 1: Write the aggregator**

`benchmark/aggregate.py`:

```python
"""Aggregate blind judgments into per-model scores + machine metrics."""
from __future__ import annotations

import json
import pathlib
import statistics
from collections import defaultdict

BASE = pathlib.Path(__file__).parent
CRITERIA = ("fidelity", "disfluency", "verbatim", "format")


def load_jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def main() -> None:
    mapping = json.loads((BASE / "letter_mapping.json").read_text())
    # per model: list of per-judge total scores (one entry per judgment of one output)
    totals: dict[str, list[int]] = defaultdict(list)
    per_criterion: dict[str, dict[str, list[int]]] = defaultdict(lambda: defaultdict(list))
    autofails: dict[str, int] = defaultdict(int)
    for jf in sorted((BASE / "judgments").glob("*.jsonl")):
        for row in load_jsonl(jf):
            letters = mapping[row["packet_id"]]
            for letter, s in row["scores"].items():
                model = letters[letter]
                if s.get("autofail"):
                    totals[model].append(0)
                    autofails[model] += 1
                    continue
                total = sum(int(s[c]) for c in CRITERIA)
                totals[model].append(total)
                for c in CRITERIA:
                    per_criterion[model][c].append(int(s[c]))

    perf: dict[str, dict[str, float]] = defaultdict(dict)
    for r in load_jsonl(BASE / "results.jsonl"):
        perf[r["model"]].setdefault("latencies", []).append(r["latency_s"])
        perf[r["model"]].setdefault("tps", []).append(r["tokens_per_s"])

    ram = {m["name"]: m.get("ram_gb") for m in json.loads((BASE / "models.json").read_text())}

    print(f"{'model':<14} {'n':>4} {'min':>4} {'med':>4} {'max':>4} {'autofail':>8} {'med_lat_s':>9} {'med_tps':>8} {'ram_gb':>6}")
    for model in sorted(totals, key=lambda m: -statistics.median(totals[m])):
        t = totals[model]
        lat = statistics.median(perf[model]["latencies"]) if model in perf else float("nan")
        tps = statistics.median(perf[model]["tps"]) if model in perf else float("nan")
        print(f"{model:<14} {len(t):>4} {min(t):>4} {statistics.median(t):>4} {max(t):>4} "
              f"{autofails[model]:>8} {lat:>9.2f} {tps:>8.1f} {ram.get(model) or 0:>6.1f}")
        for c in CRITERIA:
            vals = per_criterion[model][c]
            if vals:
                print(f"    {c:<12} med={statistics.median(vals)} min={min(vals)}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run it and write the report**

```bash
python3 benchmark/aggregate.py | tee /tmp/agg.txt
```

Write `docs/benchmarks/2026-08-refiner-benchmark.md` containing: the aggregate table verbatim, the compared population ("N judgments = 6 judges × 15 packets × 5 candidates = 450 scored outputs" — with the ACTUAL numbers), judge-agreement note (do the 3 judges rank the same top 2 per task? disagreements listed), machine metrics table, and a **top-2 recommendation with rationale**. State explicitly which fixtures were synthetic vs real.

- [ ] **Step 3: Commit**

```bash
git add benchmark/aggregate.py docs/benchmarks/2026-08-refiner-benchmark.md
git commit -m "feat(benchmark): aggregation + benchmark report"
```

---

### Task 7: Louis adjudicates the top 2 (USER STEP) and the default lands in the spec

**Files:**
- Modify: `docs/specs/2026-08-31-whisper-local-design.md` (§10 winner + §5 default mode JSON)
- Modify: `docs/benchmarks/2026-08-refiner-benchmark.md` (final decision section)

- [ ] **Step 1: Blind A/B for Louis**

Build a small text file with 5 fixtures (mix synthetic/real), each showing raw + the two finalists' outputs labelled X/Y (order shuffled per fixture, mapping kept aside). Louis picks X or Y per fixture.

- [ ] **Step 2: Record the decision**

Append a "Final decision" section to the report (winner, Louis's picks, date). Update the spec: §10 "Winner: <model>" and §5 example mode JSON `"model": "<winner id>"`.

- [ ] **Step 3: Commit**

```bash
git add docs/
git commit -m "docs(benchmark): final refiner decision — <winner>"
```
