"""s1-mini: the full control-field grid, against franglais density.

This is the experiment the v3 brief asks for. Three things make it different
from every earlier run in this project:

1. **The official template, verbatim.** The fixed system prompt is part of the
   trained format and v2 omitted analysing it; every cell here uses
   `SYSTEM_PROMPT` + `[Styling: ...] [Structure: ...] [Context: ...]` exactly as
   the model card specifies. The off-template variants v3 probed first
   (no system prompt, partial control line) are dropped: they produced nicer
   capitalisation but they are not what the model was trained on, so any verdict
   built on them would be a verdict about a misuse.

2. **All 16 field combinations**, not the one that was picked by intuition in
   v2. The card states every combination is trained, so each is a distinct
   operating mode rather than a cosmetic variation. `Structure` is
   {prose, lists} and `Context` is {general, email} -- not the {prose,
   paragraphs} / {general, ...} values v3 guessed at during probing.

3. **Fixtures stratified by franglais density**, from Louis's own corpus
   (`v3_sample_franglais.py`), because the question is not "is it good" but "at
   what level of code-switching does it flip to English". `f08` rides along as an
   explicit out-of-distribution control: at density 0.294 it is above all 1 447
   real dictations, so it must never be averaged in with them.

There is no prompt arm here, deliberately. The model card is explicit that
s1-mini does not follow general instructions, and the v3 probe confirmed it --
an instruction appended to the control line came back echoed in the output. The
control fields are the whole interface.

Writes `results-v3-s1grid.local.jsonl` (real dictations -- gitignored).
"""

from __future__ import annotations

import argparse
import itertools
import json
import pathlib
import subprocess
import time

import requests

BASE = pathlib.Path(__file__).parent
OUT_PATH = BASE / "results-v3-s1grid.local.jsonl"
GENERATE = "http://localhost:11434/api/generate"
MODEL = "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"

SYSTEM_PROMPT = (
    "You are a text normalizer for speech-to-text transcripts. "
    "The input begins with a control line specifying the styling, structure, "
    "and context settings; clean the transcript to match those settings and "
    "output only the cleaned text."
)
STYLING = ("casual", "semi-casual", "semi-formal", "formal")
STRUCTURE = ("prose", "lists")
CONTEXT = ("general", "email")

BASE_OPTIONS = {"temperature": 0, "seed": 20260901, "num_predict": 2048, "num_ctx": 8192}


def build_prompt(transcript: str, styling: str, structure: str, context: str) -> str:
    control = f"[Styling: {styling}] [Structure: {structure}] [Context: {context}]"
    return (
        f"<|im_start|>system\n{SYSTEM_PROMPT}<|im_end|>\n"
        f"<|im_start|>user\n{control}\n{transcript}<|im_end|>\n"
        f"<|im_start|>assistant\n<think>\n\n</think>\n\n"
    )


def generate(prompt: str, options: dict) -> dict:
    t0 = time.monotonic()
    resp = requests.post(
        GENERATE,
        json={
            "model": MODEL,
            "prompt": prompt,
            "raw": True,
            "stream": False,
            "options": {**options, "stop": ["<|im_end|>", "<|im_start|>"]},
        },
        timeout=900,
    )
    resp.raise_for_status()
    latency = time.monotonic() - t0
    data = resp.json()
    completion = data.get("eval_count", 0)
    return {
        "output": data.get("response", "").strip(),
        "latency_s": round(latency, 3),
        "completion_tokens": completion,
        "prompt_tokens": data.get("prompt_eval_count", 0),
        "tokens_per_s": round(completion / latency, 2) if latency > 0 else 0.0,
        "done_reason": data.get("done_reason", ""),
    }


def load_fixtures() -> list[dict]:
    rows = [
        json.loads(line)
        for line in (BASE / "fixtures-franglais.local.jsonl").read_text().splitlines()
        if line.strip()
    ]
    f08 = next(
        json.loads(line)
        for line in (BASE / "fixtures.jsonl").read_text().splitlines()
        if line.strip() and json.loads(line)["id"] == "f08"
    )
    rows.append({**f08, "stratum": "ood_synthetic", "franglais_density": 0.294,
                 "tech_share": 0.029})
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    fixtures = load_fixtures()
    combos = list(itertools.product(STYLING, STRUCTURE, CONTEXT))
    print(f"{len(combos)} field combinations x {len(fixtures)} fixtures "
          f"= {len(combos) * len(fixtures)} generations")
    for stratum in ("pure", "tech", "mixed", "heavy", "ood_synthetic"):
        n = sum(1 for f in fixtures if f["stratum"] == stratum)
        print(f"  {stratum:14} n={n}")
    if args.dry_run:
        return

    done = set()
    if OUT_PATH.exists():
        for line in OUT_PATH.read_text().splitlines():
            if line.strip():
                r = json.loads(line)
                done.add((r["styling"], r["structure"], r["context"], r["fixture_id"]))

    # Only s1-mini is ever resident during this script; nothing else is touched.
    subprocess.run(["ollama", "stop", "gemma4:12b-it-qat"], check=False, capture_output=True)
    subprocess.run(["ollama", "stop", "gemma4:e2b-it-qat"], check=False, capture_output=True)

    with OUT_PATH.open("a") as out:
        for styling, structure, context in combos:
            t_cell = time.monotonic()
            for fixture in fixtures:
                key = (styling, structure, context, fixture["id"])
                if key in done:
                    continue
                result = generate(
                    build_prompt(fixture["raw"], styling, structure, context),
                    BASE_OPTIONS,
                )
                out.write(json.dumps({
                    "model": "s1-mini",
                    "styling": styling,
                    "structure": structure,
                    "context": context,
                    "stratum": fixture["stratum"],
                    "fixture_id": fixture["id"],
                    "franglais_density": fixture["franglais_density"],
                    "tech_share": fixture["tech_share"],
                    "input_words": len(fixture["raw"].split()),
                    **BASE_OPTIONS,
                    **result,
                }, ensure_ascii=False) + "\n")
                out.flush()
            print(f"{styling:12} {structure:6} {context:8} "
                  f"done in {time.monotonic() - t_cell:5.1f}s", flush=True)
    subprocess.run(["ollama", "stop", MODEL], check=False, capture_output=True)


if __name__ == "__main__":
    main()
