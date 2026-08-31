"""Run the 2D (model x prompt) refiner benchmark -- generation phase only.

Differences from `run_benchmark.py` (v1), all deliberate:
  * `num_ctx` is set explicitly (v1 inherited Ollama's 2048 default).
  * `num_predict` raised 512 -> 2048 (v1's cap truncated long real dictations).
  * `temperature` 0.2 -> 0 with a fixed `seed`, for reproducible generations.
  * prompt variants A/B/C for `prompt_cleanup` in addition to the v1 baseline.
  * `s1-mini` served through `/api/generate` with `raw: true` (it returns empty
    content through `/api/chat`), plus a deterministic recapitalisation pass.

Writes to `results-v2.jsonl`. Never touches any v1 artefact.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import time

import requests

BASE = pathlib.Path(__file__).parent
OUT_PATH = BASE / "results-v2.jsonl"
CHAT_ENDPOINT = "http://localhost:11434/api/chat"
GENERATE_ENDPOINT = "http://localhost:11434/api/generate"
RUNTIME = "ollama-0.33.2"
SEED = 20260901

# Config sets. `v2` is the run config; `v1cfg` and `v2mid` exist only to measure
# what the two config fixes actually change (see the config A/B arm below).
CONFIGS = {
    "v1cfg": {"temperature": 0.2, "num_predict": 512},
    "v2mid": {"temperature": 0, "seed": SEED, "num_predict": 512},
    "v2": {"temperature": 0, "seed": SEED, "num_predict": 2048, "num_ctx": 8192},
}

PROMPTS = {
    "cleanup_baseline": BASE / "prompts" / "prompt_cleanup.txt",
    "cleanup_A": BASE / "prompts" / "prompt_cleanup_A.txt",
    "cleanup_B": BASE / "prompts" / "prompt_cleanup_B.txt",
    "cleanup_C": BASE / "prompts" / "prompt_cleanup_C.txt",
    "rewrite_baseline": BASE / "prompts" / "message_rewrite.txt",
    # s1-mini is not steerable by a system prompt (measured twice in the probe);
    # it is steered by a control line prepended to the user message.
    "s1_control": None,
}

S1_SYSTEM = (
    "You are a text normalizer for speech-to-text transcripts. The input begins "
    "with a control line specifying the styling, structure, and context settings; "
    "clean the transcript to match those settings and output only the cleaned text."
)
S1_CONTROL = "[Styling: semi-casual] [Structure: prose] [Context: general]"

# A word is recapitalised only if it looks like ordinary prose: all-lowercase,
# no digit, no path/identifier punctuation. Keeps `tests/unit`, `config.yaml`,
# `p90` and `WhisperKitConfig` untouched.
_PLAIN_WORD = re.compile(r"^[a-zà-öø-ÿ']+$")
_SENTENCE_START = re.compile(r"(^|(?<=[.!?])\s+|(?<=\n))([^\s]+)")


def recapitalise(text: str) -> tuple[str, list[str]]:
    """Deterministic sentence-start capitalisation for s1-mini (it emits none).

    Returns the fixed text plus the list of words it actually capitalised, so the
    pass stays auditable -- capitalising a lowercase technical term at a sentence
    start would be a verbatim alteration introduced by us, not by the model.
    """
    touched: list[str] = []

    def _fix(m: re.Match[str]) -> str:
        lead, word = m.group(1), m.group(2)
        if _PLAIN_WORD.match(word):
            touched.append(word)
            return lead + word[0].upper() + word[1:]
        return lead + word

    return _SENTENCE_START.sub(_fix, text), touched


def load_jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def _post(endpoint: str, payload: dict) -> tuple[dict, float]:
    t0 = time.monotonic()
    resp = requests.post(endpoint, json=payload, timeout=600)
    resp.raise_for_status()
    return resp.json(), time.monotonic() - t0


def run_chat(model_id: str, system: str, raw_text: str, options: dict) -> dict:
    data, latency = _post(
        CHAT_ENDPOINT,
        {
            "model": model_id,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": raw_text},
            ],
            "stream": False,
            "think": False,
            "options": options,
        },
    )
    return _metrics(data["message"]["content"].strip(), data, latency)


def run_s1_raw(model_id: str, raw_text: str, options: dict) -> dict:
    """s1-mini only. `/api/chat` yields empty output because Ollama parses the
    model's open `<think>` block; the raw prefix below is the only working path."""
    prompt = (
        f"<|im_start|>system\n{S1_SYSTEM}<|im_end|>\n"
        f"<|im_start|>user\n{S1_CONTROL}\n{raw_text}<|im_end|>\n"
        f"<|im_start|>assistant\n<think>\n\n</think>\n\n"
    )
    data, latency = _post(
        GENERATE_ENDPOINT,
        {
            "model": model_id,
            "prompt": prompt,
            "raw": True,
            "stream": False,
            "options": {**options, "stop": ["<|im_end|>", "<|im_start|>"]},
        },
    )
    model_out = data.get("response", "").strip()
    fixed, touched = recapitalise(model_out)
    row = _metrics(fixed, data, latency)
    row["raw_model_output"] = model_out
    row["recapitalised_words"] = touched
    return row


def _metrics(output: str, data: dict, latency: float) -> dict:
    completion = data.get("eval_count", 0)
    return {
        "output": output,
        "latency_s": round(latency, 3),
        "completion_tokens": completion,
        "prompt_tokens": data.get("prompt_eval_count", 0),
        "tokens_per_s": round(completion / latency, 2) if latency > 0 else 0.0,
        "done_reason": data.get("done_reason", ""),
    }


def build_grid(models: dict) -> list[dict]:
    """The reduced grid. Each cell = (model, prompt, task, fixture set, config)."""
    cells: list[dict] = []

    def add(model: str, prompt_id: str, task: str, fixtures: str, config_id: str):
        cells.append(
            {
                "model": model,
                "prompt_id": prompt_id,
                "task": task,
                "fixtures": fixtures,
                "config_id": config_id,
            }
        )

    prompt_arm = ["gemma4-12b-qat", "gemma4-e2b-qat"]
    all_four = [*prompt_arm, "qwen3.5-4b", "qwen3.5-2b-q8"]

    # Arm 0 -- config A/B: what do the two harness fixes actually change?
    #   v1cfg -> v2mid isolates temperature; v2mid -> v2 isolates the two caps.
    add("gemma4-12b-qat", "cleanup_baseline", "prompt_cleanup", "synthetic", "v1cfg")
    add("gemma4-12b-qat", "cleanup_baseline", "prompt_cleanup", "synthetic", "v2mid")
    # (the v2 cell of the same triple is produced by arm 1 below -- no duplicate)
    # Long-form check: the caps can only bind on real long dictations.
    add("gemma4-12b-qat", "cleanup_baseline", "prompt_cleanup", "real_long", "v2mid")
    add("gemma4-12b-qat", "cleanup_baseline", "prompt_cleanup", "real_long", "v2")

    # Arm 1 -- prompt dimension, full 2x4 factorial on the two gemma sizes.
    for model in prompt_arm:
        for prompt_id in ("cleanup_baseline", "cleanup_A", "cleanup_B", "cleanup_C"):
            add(model, prompt_id, "prompt_cleanup", "synthetic", "v2")

    # Arm 2 -- model dimension at the baseline prompt, both tasks.
    for model in ("qwen3.5-4b", "qwen3.5-2b-q8"):
        add(model, "cleanup_baseline", "prompt_cleanup", "synthetic", "v2")
    for model in all_four:
        add(model, "rewrite_baseline", "message_rewrite", "synthetic", "v2")

    # Arm 3 -- s1-mini, prompt_cleanup only (it cannot do message_rewrite).
    add("s1-mini", "s1_control", "prompt_cleanup", "synthetic", "v2")

    order = {m["name"]: i for i, m in enumerate(models.values())}
    cells.sort(key=lambda c: order[c["model"]])
    return cells


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    models = {m["name"]: m for m in json.loads((BASE / "models_v2.json").read_text())}
    fixture_sets = {
        "synthetic": load_jsonl(BASE / "fixtures.jsonl"),
        "real_long": [
            f
            for f in load_jsonl(BASE / "fixtures-real.local.jsonl")
            if len(f["raw"].split()) >= 260
        ],
    }
    prompt_text = {
        k: (v.read_text() if v is not None else S1_CONTROL) for k, v in PROMPTS.items()
    }
    grid = build_grid(models)

    total = sum(len(fixture_sets[c["fixtures"]]) for c in grid)
    print(f"{len(grid)} cells / {total} generations")
    for c in grid:
        n = len(fixture_sets[c["fixtures"]])
        print(
            f"  {c['model']:18} {c['prompt_id']:18} {c['task']:16} "
            f"{c['fixtures']:10} {c['config_id']:6} n={n}"
        )
    if args.dry_run:
        return

    done = (
        {
            (r["model"], r["prompt_id"], r["task"], r["fixture_id"], r["config_id"])
            for r in load_jsonl(OUT_PATH)
        }
        if OUT_PATH.exists()
        else set()
    )

    loaded: str | None = None
    with OUT_PATH.open("a") as out:
        for cell in grid:
            model = models[cell["model"]]
            # Strictly sequential: one model resident at a time, so latencies mean
            # something. Louis's explicit constraint.
            if loaded is not None and loaded != model["model_id"]:
                subprocess.run(["ollama", "stop", loaded], check=False)
                time.sleep(1)
            loaded = model["model_id"]

            options = dict(CONFIGS[cell["config_id"]])
            system = prompt_text[cell["prompt_id"]]
            for fixture in fixture_sets[cell["fixtures"]]:
                key = (
                    cell["model"],
                    cell["prompt_id"],
                    cell["task"],
                    fixture["id"],
                    cell["config_id"],
                )
                if key in done:
                    continue
                if model.get("api") == "generate_raw":
                    result = run_s1_raw(model["model_id"], fixture["raw"], options)
                else:
                    result = run_chat(
                        model["model_id"], system, fixture["raw"], options
                    )
                row = {
                    "model": cell["model"],
                    "model_id": model["model_id"],
                    "size_gb": model["size_gb"],
                    "runtime": RUNTIME,
                    "prompt_id": cell["prompt_id"],
                    "task": cell["task"],
                    "config_id": cell["config_id"],
                    "fixture_set": cell["fixtures"],
                    "fixture_id": fixture["id"],
                    "input_words": len(fixture["raw"].split()),
                    **result,
                }
                out.write(json.dumps(row, ensure_ascii=False) + "\n")
                out.flush()
                print(
                    f"{cell['model']} {cell['prompt_id']} {cell['config_id']} "
                    f"{fixture['id']}: {result['latency_s']}s "
                    f"({result['completion_tokens']} tok, {result['done_reason']})"
                )
    if loaded is not None:
        subprocess.run(["ollama", "stop", loaded], check=False)


if __name__ == "__main__":
    main()
