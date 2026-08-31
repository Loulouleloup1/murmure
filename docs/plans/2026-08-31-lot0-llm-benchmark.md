# Lot 0 — Refiner LLM Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pick the default local refinement model for Murmure, data-driven, among 5 verified candidates.

**Architecture:** Python scripts hit Ollama's OpenAI-compatible endpoint for each model × fixture × task, record outputs + machine metrics; outputs are anonymised into packets; blind Opus-tier judges score them against a rubric frozen before any generation; an aggregation script produces the report; Louis adjudicates the top 2.

**Tech Stack:** Python 3.11+ (`requests`), Ollama (`http://localhost:11434/v1`) as the serving endpoint for all 5 candidates.

> **Amended 2026-08-31 (ruling R3, see the SDD ledger):** the plan originally used LM Studio plus an
> MLX conversion for `s1-mini`. `superwhisper/s1-mini-GGUF` turned out to be published, so all five
> candidates are Ollama-pullable and Ollama is now the single endpoint. `models.json` still carries a
> per-model `endpoint` so a mixed setup stays expressible.
> **Ruling R1:** no real dictations exist on this machine (fresh Superwhisper install, empty history),
> so all 15 fixtures are synthetic. **Ruling R2:** `google/gemma-4-12b-qat` is gated; the ungated
> Ollama tag `gemma4:12b-it-qat` is used instead.

**Spec:** `docs/specs/2026-08-31-whisper-local-design.md` (§10)

## Global Constraints

- 100% local — no cloud API calls anywhere in the benchmark.
- The rubric and judge prompt MUST be committed before `run_benchmark.py` is ever executed (frozen-before-outputs doctrine).
- Judges never see model names; the letter→model mapping lives outside the packets directory.
- Machine metrics are measured on this M4 Pro, never copied from blogs.
- All work happens in the `murmure` repo; commit after every task.
- Serving endpoint: Ollama at `http://localhost:11434/v1` (ruling R3). Model refs come from
  `benchmark/pulled.tsv`, written by `benchmark/pull_models.sh`.
- All fixtures are synthetic and tagged `"source": "synthetic"` (ruling R1).

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

- [ ] **Step 2: Add the 5 register-coverage fixtures**

Ruling R1 replaced the "dictated by Louis" fixtures with synthetic ones (no Superwhisper history exists on this machine). Append these 5 lines verbatim to `benchmark/fixtures.jsonl` — they cover the Slack/email register and the longer, more rambling dictations the first 10 do not:

```jsonl
{"id": "f11", "source": "synthetic", "raw": "euh coucou dis-moi est-ce que t'as eu le temps de regarder le le ticket sur les alertes de variation parce que du coup j'ai un doute sur le seuil enfin je veux dire est-ce qu'on le met à dix pour cent ou à vingt pour cent parce que là on en a genre huit cents à traiter et euh voilà"}
{"id": "f12", "source": "synthetic", "raw": "bonjour Marie euh donc comme convenu je vous envoie le le récapitulatif de la réunion d'hier alors on a validé trois points le premier c'est le périmètre des datasets le deuxième c'est la date de livraison qui passe au quinze septembre et le troisième euh attendez le troisième c'était sur le budget donc on reste sur l'enveloppe initiale voilà bonne journée"}
{"id": "f13", "source": "synthetic", "raw": "ok alors écoute je pense qu'on devrait euh plutôt partir sur une architecture où chaque couche est derrière un protocole parce que sinon on va se retrouver avec un truc monolithique et euh et après pour tester c'est l'enfer donc voilà mon avis c'est protocol first et on injecte les implémentations"}
{"id": "f14", "source": "synthetic", "raw": "hello team petite update sur le sujet du du connecteur donc la PR est prête elle attend juste la review de quelqu'un euh j'ai testé en dry run sur les données de prod et ça sort bien les cent trente-quatre lignes attendues donc euh si quelqu'un a cinq minutes ce serait top merci"}
{"id": "f15", "source": "synthetic", "raw": "attends non non je reprends donc le fichier il faut le mettre pas dans le dossier models mais dans le dossier recordings et euh et le nom c'est rec tiret la date en ISO avec les deux points remplacés par des tirets parce que sinon macOS il accepte pas le nom de fichier"}
```

Expected total after this step: **15 lines** in `fixtures.jsonl` (`wc -l benchmark/fixtures.jsonl`).

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

### Task 2: Verify the 5 candidates in Ollama and write models.json

The controller already ran `benchmark/pull_models.sh` (committed), which pulled each candidate with tag fallbacks and recorded the resolved refs in `benchmark/pulled.tsv` (successes, `name<TAB>ref`) and `benchmark/failed.tsv` (candidates where every fallback failed). This task verifies what actually landed and turns it into `models.json`.

**Files:**
- Create: `benchmark/models.json`
- Read: `benchmark/pulled.tsv`, `benchmark/failed.tsv`, `benchmark/pull.log`

**Interfaces:**
- Produces: `benchmark/models.json` — consumed by `run_benchmark.py` (Task 3) and `aggregate.py` (Task 6). Schema, one object per candidate:
  `{"name": "s1-mini", "model_id": "<exact ollama ref>", "endpoint": "http://localhost:11434/api/chat", "size_gb": <float>, "excluded": "<reason>"}` — `excluded` present ONLY for candidates that are not benchmarked; `size_gb` from `ollama list`.

> **Amended 2026-08-31 (rulings R6/R7, see the SDD ledger).** Two corrections to this task's output:
> 1. `endpoint` is Ollama's **native** `http://localhost:11434/api/chat`, not the OpenAI-compatible
>    `/v1/chat/completions`. All four servable candidates are reasoning models that emit a `reasoning`
>    field before `content`; the native API accepts `"think": false`, which the compat endpoint does
>    not, and it returns `eval_count` for exact token counts. Verified on `qwen3.5:9b`: clean content
>    in 5.9 s, `thinking: null`, `eval_count: 40`.
> 2. `s1-mini`'s `excluded` reason is its **language scope**, not the empty-output symptom: its model
>    card states v1 "covers English only", that it "is not a chat model and will not follow general
>    instructions", and that it is steered by a control line at the top of the input. The fixtures are
>    French. Record it as: `"excluded": "English-only (v1 model card); fixtures and Louis's dictation
>    are French. Not a chat model — steered by a control line, not a system prompt."`

- [ ] **Step 1: Read what the pull produced**

```bash
cat benchmark/pulled.tsv benchmark/failed.tsv; ollama list
```
The five `name` values are: `s1-mini`, `ornith-9b`, `gemma4-12b-qat`, `qwen3.5-9b`, `granite4.2-8b`.

- [ ] **Step 2: Smoke-test every pulled model through the OpenAI-compatible endpoint**

For each `name<TAB>ref` line in `pulled.tsv`:

```bash
curl -s --max-time 120 http://localhost:11434/api/chat -H 'Content-Type: application/json' \
  -d '{"model": "<ref>", "stream": false, "think": false,
       "messages": [{"role": "user", "content": "Réponds uniquement: ok"}],
       "options": {"num_predict": 512}}' | python3 -m json.tool
```
Expected: HTTP 200 with a non-empty `message.content` and `thinking: null`. A model that returns an error, empty content, or times out after 120 s counts as NOT servable. **Use the native `/api/chat`, not `/v1/chat/completions`** (ruling R6): every candidate is a reasoning model, and only the native API accepts `"think": false` — on the compat endpoint they burn the whole budget on a reasoning field and return empty content, which reads as a dead model when it is not one. Keep `num_predict` generous for the same reason.

- [ ] **Step 3: Retry any failed candidate once, then record it honestly**

For every candidate in `failed.tsv`, or that failed the Step 2 smoke test, try ONE alternative ref (search `ollama list` naming variants, or `ollama pull hf.co/<repo>:<quant>` using a quant visible on the HF repo's file list). If it still fails, put it in `models.json` with an `"excluded": "<one-line reason, e.g. no GGUF quant pullable>"` key. **Never silently drop a candidate** — an excluded entry is a reported result, a missing entry is a lie about the compared population.

- [ ] **Step 4: Write models.json**

Fill `benchmark/models.json` with one object per candidate (all five present, excluded ones included), `size_gb` read from `ollama list`, `endpoint` set to `http://localhost:11434/api/chat` for every servable model (ruling R6 — the native chat API, see the amendment note above).

- [ ] **Step 5: Verify the file parses and covers all five**

```bash
python3 -c "
import json
m = json.load(open('benchmark/models.json'))
names = {x['name'] for x in m}
assert names == {'s1-mini','ornith-9b','gemma4-12b-qat','qwen3.5-9b','granite4.2-8b'}, names
servable = [x for x in m if not x.get('excluded')]
print(f'{len(servable)}/5 servable:', [x['name'] for x in servable])
"
```
Expected: prints the servable count and names, no assertion error.

- [ ] **Step 6: Commit**

```bash
git add benchmark/models.json benchmark/pulled.tsv benchmark/failed.tsv
git commit -m "feat(benchmark): candidate models resolved and smoke-tested in Ollama"
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
"""Run every candidate model over every fixture x task via Ollama's native chat API."""
from __future__ import annotations

import json
import pathlib
import time

import requests

BASE = pathlib.Path(__file__).parent
DEFAULT_ENDPOINT = "http://localhost:11434/api/chat"
TASKS = {
    "prompt_cleanup": (BASE / "prompts" / "prompt_cleanup.txt").read_text(),
    "message_rewrite": (BASE / "prompts" / "message_rewrite.txt").read_text(),
}


def load_jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def run_one(endpoint: str, model_id: str, system: str, raw: str) -> dict:
    """One refinement call. think=False keeps reasoning models from spending the
    budget on a reasoning field — and keeps the measured latency representative."""
    t0 = time.monotonic()
    resp = requests.post(
        endpoint,
        json={
            "model": model_id,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": raw},
            ],
            "stream": False,
            "think": False,
            "options": {"temperature": 0.2, "num_predict": 512},
        },
        timeout=300,
    )
    resp.raise_for_status()
    data = resp.json()
    latency = time.monotonic() - t0
    completion_tokens = data.get("eval_count", 0)
    return {
        "output": data["message"]["content"].strip(),
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
            endpoint = model.get("endpoint", DEFAULT_ENDPOINT)
            for fixture in fixtures:
                for task, system in TASKS.items():
                    key = (model["name"], fixture["id"], task)
                    if key in done:
                        continue
                    result = run_one(endpoint, model["model_id"], system, fixture["raw"])
                    row = {"model": model["name"], "fixture_id": fixture["id"], "task": task, **result}
                    out.write(json.dumps(row, ensure_ascii=False) + "\n")
                    out.flush()
                    print(f"{model['name']} {fixture['id']} {task}: {result['latency_s']}s")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run it**

```bash
python3 -m venv benchmark/.venv && source benchmark/.venv/bin/activate && pip install -q requests
python3 benchmark/run_benchmark.py
```
Expected: n_servable_models × 15 fixtures × 2 tasks lines in `results.jsonl`. With s1-mini excluded (ruling R7) that is 4 × 15 × 2 = **120 lines**. Compute the expected number from `models.json` (excluding `excluded` entries) and `fixtures.jsonl`, then assert it:

```bash
python3 -c "
import json
models=[m for m in json.load(open('benchmark/models.json')) if not m.get('excluded')]
fixtures=[l for l in open('benchmark/fixtures.jsonl') if l.strip()]
rows=[json.loads(l) for l in open('benchmark/results.jsonl') if l.strip()]
expected=len(models)*len(fixtures)*2
print(f'{len(rows)} rows / {expected} expected ({len(models)} models x {len(fixtures)} fixtures x 2 tasks)')
assert len(rows)==expected, 'population mismatch'
empty=[(r['model'],r['fixture_id'],r['task']) for r in rows if not r['output'].strip()]
print('empty outputs:', len(empty), empty[:5])
"
```
STATE the compared population in the commit message; an empty or short file is a failure, not a pass. **Empty outputs are a red flag, not a result**: if any appear, report them and do not treat the run as complete — they mean the model spent its budget on reasoning despite `think:false`, and that model needs `num_predict` raised before its rows are usable. Ollama loads each model on first request and unloads it on its own — no explicit load/unload calls.

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

    # models.json ships `size_gb` (on-disk size from `ollama list`) — NOT `ram_gb`.
    size = {m["name"]: m.get("size_gb") for m in json.loads((BASE / "models.json").read_text())}

    print(f"{'model':<14} {'n':>4} {'min':>4} {'med':>4} {'max':>4} {'autofail':>8} {'med_lat_s':>9} {'med_tps':>8} {'size_gb':>7}")
    for model in sorted(totals, key=lambda m: -statistics.median(totals[m])):
        t = totals[model]
        lat = statistics.median(perf[model]["latencies"]) if model in perf else float("nan")
        tps = statistics.median(perf[model]["tps"]) if model in perf else float("nan")
        print(f"{model:<14} {len(t):>4} {min(t):>4} {statistics.median(t):>4} {max(t):>4} "
              f"{autofails[model]:>8} {lat:>9.2f} {tps:>8.1f} {size.get(model) or 0:>7.1f}")
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
