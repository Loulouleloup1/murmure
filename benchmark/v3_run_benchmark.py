"""Benchmark v3 -- generation phase, under a memory admissibility constraint.

What changes from v2 (`run_benchmark_v2.py`), and why:

  * Three models only, chosen by resident footprint rather than by score:
    `s1-mini` (1.5 GB resident), `gemma4-e2b-qat` (4.7 GB), `gemma4-12b-qat`
    (8.7 GB, the high reference we are pricing rather than a candidate).
  * The prompt arm is aimed at *shortness*. The production instruction is 202
    words; v3 asks whether that helps or hurts a model small enough to fit a
    16 GB machine, so it adds an 83-word, a 33-word and a 103-word French
    variant.
  * `s1-mini` gets four control-line variants instead of one. The probe
    (`v3_probe_s1.py`) found that `[Styling: semi-casual]` is what suppresses
    capitalisation -- v2 attributed that to the model and post-processed around
    it. Dropping the styling key restores capitalisation from the model itself.
  * The real dictations are generated on for every model, not just the 12B, so
    the latency-versus-length curve exists for the small models too (v2
    limitation 3).
  * The recapitalisation pass is fixed. v2's `_PLAIN_WORD` rejected any first
    token carrying glued punctuation (`'alors,'`), so it silently did nothing on
    7 outputs out of 15; the report had to publish a `format` score that measured
    our bug. See `recapitalise` below.

Writes `results-v3.jsonl`, which carries real-dictation outputs and is therefore
gitignored (ruling R12).
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
OUT_PATH = BASE / "results-v3.jsonl"
CHAT_ENDPOINT = "http://localhost:11434/api/chat"
GENERATE_ENDPOINT = "http://localhost:11434/api/generate"
RUNTIME = "ollama-0.33.2"
SEED = 20260901
OPTIONS = {"temperature": 0, "seed": SEED, "num_predict": 2048, "num_ctx": 8192}

MODELS = {
    "s1-mini": {
        "model_id": "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M",
        "api": "generate_raw",
        "disk_gb": 0.48,
        "resident_gb": 1.55,
    },
    "gemma4-e2b-qat": {
        "model_id": "gemma4:e2b-it-qat",
        "api": "chat",
        "disk_gb": 4.3,
        "resident_gb": 4.66,
    },
    "gemma4-12b-qat": {
        "model_id": "gemma4:12b-it-qat",
        "api": "chat",
        "disk_gb": 7.2,
        "resident_gb": 8.69,
    },
}

# Chat prompts, ordered by length. `cleanup_A` is what Murmure ships today
# (`~/Library/Application Support/Murmure/modes/prompt.json`, 202 words).
CHAT_PROMPTS = {
    "cleanup_A": BASE / "prompts" / "prompt_cleanup_A.txt",
    "cleanup_S60": BASE / "prompts" / "v3_cleanup_S60.txt",
    "cleanup_S25": BASE / "prompts" / "v3_cleanup_S25.txt",
    "cleanup_FR60": BASE / "prompts" / "v3_cleanup_FR60.txt",
}

V2_SYSTEM = (
    "You are a text normalizer for speech-to-text transcripts. The input begins "
    "with a control line specifying the styling, structure, and context settings; "
    "clean the transcript to match those settings and output only the cleaned text."
)

# (system, control line). Probed in `v3_probe_s1.py` on f01/f04/f08/f12.
S1_VARIANTS = {
    # v2's exact setup. Kept as the anchor so v3 numbers are comparable.
    "s1_v2": (V2_SYSTEM, "[Styling: semi-casual] [Structure: prose] [Context: general]"),
    # The probe winner: dropping `Styling` restores capitalisation and, on the
    # code-switched fixture, keeps the French clauses in French.
    "s1_ctx": (None, "[Context: general]"),
    # No steering at all -- the purest form of "this model was built for the task".
    "s1_naked": (None, None),
    # v2 warned that `formal` corrupts facts; it was never measured at scale.
    "s1_formal": (None, "[Styling: formal] [Structure: prose] [Context: general]"),
}

# Recapitalisation. v2's version captured the whole first token (`[^\s]+`) and
# tested it against `^[a-zà-öø-ÿ']+$`, so a token with glued punctuation
# (`'alors,'`) failed the test and stayed lowercase -- 7 of 15 outputs. Here the
# trailing punctuation is stripped before the test, and only the leading letter
# is touched. `config.yaml`, `p90`, `tests/unit` and `WhisperKitConfig` still
# fail `_PLAIN_WORD` and are still left alone.
_PLAIN_WORD = re.compile(r"^[a-zà-öø-ÿ']+$")
_SENTENCE_START = re.compile(r"(^|(?<=[.!?])\s+|(?<=\n))(\S+)")
_TRAILING_PUNCT = re.compile(r"[,.;:!?…»)\]\"']+$")
_FINAL_PUNCT = re.compile(r"[.!?…:»\"')\]]\s*$")


def recapitalise(text: str) -> tuple[str, list[str]]:
    touched: list[str] = []

    def _fix(m: re.Match[str]) -> str:
        lead, token = m.group(1), m.group(2)
        core = _TRAILING_PUNCT.sub("", token)
        if core and _PLAIN_WORD.match(core):
            touched.append(core)
            return lead + token[0].upper() + token[1:]
        return lead + token

    return _SENTENCE_START.sub(_fix, text), touched


def add_final_punctuation(text: str) -> tuple[str, bool]:
    """v2 measured 13 s1-mini outputs out of 15 ending with no punctuation at
    all, and the judges flagged it. A trailing full stop is a deterministic fix,
    but it is OUR edit, so it is flagged per row rather than folded in silently."""
    if not text or _FINAL_PUNCT.search(text):
        return text, False
    return text + ".", True


def load_jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def _post(endpoint: str, payload: dict) -> tuple[dict, float]:
    t0 = time.monotonic()
    resp = requests.post(endpoint, json=payload, timeout=900)
    resp.raise_for_status()
    return resp.json(), time.monotonic() - t0


def _metrics(output: str, data: dict, latency: float) -> dict:
    completion = data.get("eval_count", 0)
    return {
        "output": output,
        "latency_s": round(latency, 3),
        "completion_tokens": completion,
        "prompt_tokens": data.get("prompt_eval_count", 0),
        "load_ms": round(data.get("load_duration", 0) / 1e6, 1),
        "tokens_per_s": round(completion / latency, 2) if latency > 0 else 0.0,
        "done_reason": data.get("done_reason", ""),
    }


def run_chat(model_id: str, system: str, raw_text: str) -> dict:
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
            "options": OPTIONS,
        },
    )
    return _metrics(data["message"]["content"].strip(), data, latency)


def run_s1(model_id: str, variant: str, raw_text: str) -> dict:
    system, control = S1_VARIANTS[variant]
    parts = []
    if system:
        parts.append(f"<|im_start|>system\n{system}<|im_end|>\n")
    user = f"{control}\n{raw_text}" if control else raw_text
    parts.append(f"<|im_start|>user\n{user}<|im_end|>\n")
    parts.append("<|im_start|>assistant\n<think>\n\n</think>\n\n")
    data, latency = _post(
        GENERATE_ENDPOINT,
        {
            "model": model_id,
            "prompt": "".join(parts),
            "raw": True,
            "stream": False,
            "options": {**OPTIONS, "stop": ["<|im_end|>", "<|im_start|>"]},
        },
    )
    model_out = data.get("response", "").strip()
    fixed, touched = recapitalise(model_out)
    fixed, added_period = add_final_punctuation(fixed)
    row = _metrics(fixed, data, latency)
    row["raw_model_output"] = model_out
    row["recapitalised_words"] = touched
    row["added_final_period"] = added_period
    return row


def build_grid() -> list[dict]:
    """Two arms.

    `prompt` -- synthetic fixtures, the judgeable and committable set. It answers
    "which instruction wins for which model", the question the brief calls the
    real work.

    `length` -- real dictations, 20 to 370 words. It answers "what does latency
    do as the dictation grows", which v2 only ever measured for the 12B. Not
    judged here; its outputs carry Louis's work content.
    """
    cells: list[dict] = []

    for variant in S1_VARIANTS:
        cells.append({"model": "s1-mini", "prompt_id": variant, "fixtures": "synthetic", "arm": "prompt"})
    for prompt_id in CHAT_PROMPTS:
        cells.append({"model": "gemma4-e2b-qat", "prompt_id": prompt_id, "fixtures": "synthetic", "arm": "prompt"})
    # The 12B is the reference we are pricing, not a candidate for a 16 GB
    # machine. It runs the production prompt plus the shortest variant, which is
    # enough to say whether prompt shortening costs the big model anything.
    for prompt_id in ("cleanup_A", "cleanup_S25"):
        cells.append({"model": "gemma4-12b-qat", "prompt_id": prompt_id, "fixtures": "synthetic", "arm": "prompt"})

    cells.append({"model": "s1-mini", "prompt_id": "s1_ctx", "fixtures": "real", "arm": "length"})
    cells.append({"model": "s1-mini", "prompt_id": "s1_v2", "fixtures": "real", "arm": "length"})
    cells.append({"model": "gemma4-e2b-qat", "prompt_id": "cleanup_A", "fixtures": "real", "arm": "length"})
    cells.append({"model": "gemma4-12b-qat", "prompt_id": "cleanup_A", "fixtures": "real", "arm": "length"})

    order = list(MODELS)
    cells.sort(key=lambda c: order.index(c["model"]))
    return cells


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    fixture_sets = {
        "synthetic": load_jsonl(BASE / "fixtures.jsonl"),
        "real": load_jsonl(BASE / "fixtures-real.local.jsonl"),
    }
    prompt_text = {k: v.read_text().strip() for k, v in CHAT_PROMPTS.items()}
    grid = build_grid()

    total = sum(len(fixture_sets[c["fixtures"]]) for c in grid)
    print(f"{len(grid)} cells / {total} generations")
    for c in grid:
        print(f"  {c['model']:16} {c['prompt_id']:14} {c['arm']:7} "
              f"{c['fixtures']:10} n={len(fixture_sets[c['fixtures']])}")
    if args.dry_run:
        return

    done = (
        {(r["model"], r["prompt_id"], r["fixture_id"]) for r in load_jsonl(OUT_PATH)}
        if OUT_PATH.exists()
        else set()
    )

    loaded: str | None = None
    with OUT_PATH.open("a") as out:
        for cell in grid:
            model = MODELS[cell["model"]]
            # Strictly sequential -- one model resident at a time. Louis's explicit
            # constraint: run together they degrade each other and the latencies
            # stop meaning anything.
            if loaded is not None and loaded != model["model_id"]:
                subprocess.run(["ollama", "stop", loaded], check=False, capture_output=True)
                time.sleep(1.5)
            loaded = model["model_id"]

            for fixture in fixture_sets[cell["fixtures"]]:
                key = (cell["model"], cell["prompt_id"], fixture["id"])
                if key in done:
                    continue
                if model["api"] == "generate_raw":
                    result = run_s1(model["model_id"], cell["prompt_id"], fixture["raw"])
                else:
                    result = run_chat(
                        model["model_id"], prompt_text[cell["prompt_id"]], fixture["raw"]
                    )
                row = {
                    "model": cell["model"],
                    "model_id": model["model_id"],
                    "disk_gb": model["disk_gb"],
                    "resident_gb": model["resident_gb"],
                    "runtime": RUNTIME,
                    "arm": cell["arm"],
                    "prompt_id": cell["prompt_id"],
                    "fixture_set": cell["fixtures"],
                    "fixture_id": fixture["id"],
                    "input_words": len(fixture["raw"].split()),
                    **result,
                }
                out.write(json.dumps(row, ensure_ascii=False) + "\n")
                out.flush()
                print(f"{cell['model']:16} {cell['prompt_id']:14} {fixture['id']:14} "
                      f"{result['latency_s']:7.2f}s {result['completion_tokens']:4d}tok "
                      f"{result['done_reason']}")
    if loaded is not None:
        subprocess.run(["ollama", "stop", loaded], check=False, capture_output=True)


if __name__ == "__main__":
    main()
