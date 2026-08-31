"""Re-measure the benchmark winner on REAL, long dictations.

Ruling R10: the 15 synthetic fixtures are median 46 words, so the benchmark only
ever measured short input. Two risks were left untested -- latency at real length,
and silent truncation, because `num_predict: 512` caps the completion. This script
closes both on the real corpus (ruling R12 allows local-only use).

Truncation is detected two ways: `done_reason == "length"` straight from Ollama,
and `eval_count` landing on the cap. Reads a git-ignored fixture file and writes a
git-ignored results file -- the transcripts never enter the repo.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics

from run_benchmark import DEFAULT_ENDPOINT, TASKS, load_jsonl

import requests

BASE = pathlib.Path(__file__).parent
NUM_PREDICT = 512


def run_one(endpoint: str, model_id: str, system: str, raw: str) -> dict:
    """Same call shape as the benchmark, but keeping the fields that reveal truncation."""
    import time

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
            "options": {"temperature": 0.2, "num_predict": NUM_PREDICT},
        },
        timeout=600,
    )
    resp.raise_for_status()
    data = resp.json()
    latency = time.monotonic() - t0
    eval_count = data.get("eval_count", 0)
    return {
        "output": data["message"]["content"].strip(),
        "latency_s": round(latency, 3),
        "completion_tokens": eval_count,
        "prompt_tokens": data.get("prompt_eval_count", 0),
        "done_reason": data.get("done_reason", ""),
        "truncated": data.get("done_reason") == "length" or eval_count >= NUM_PREDICT,
        "tokens_per_s": round(eval_count / latency, 2) if latency > 0 else 0.0,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="gemma4:12b-it-qat")
    parser.add_argument("--name", default="gemma4-12b-qat")
    parser.add_argument("--task", default="prompt_cleanup", choices=sorted(TASKS))
    args = parser.parse_args()

    fixtures = load_jsonl(BASE / "fixtures-real.local.jsonl")
    out_path = BASE / f"results-longform.local.jsonl"
    done = (
        {(r["model"], r["fixture_id"], r["task"]) for r in load_jsonl(out_path)}
        if out_path.exists()
        else set()
    )
    system = TASKS[args.task]
    with out_path.open("a") as out:
        for fixture in fixtures:
            key = (args.name, fixture["id"], args.task)
            if key in done:
                continue
            result = run_one(DEFAULT_ENDPOINT, args.model, system, fixture["raw"])
            row = {
                "model": args.name,
                "fixture_id": fixture["id"],
                "band": fixture["band"],
                "task": args.task,
                "input_words": len(fixture["raw"].split()),
                **result,
            }
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
            out.flush()
            # Counts only, never the transcript or the output.
            print(
                f"{fixture['id']:<16} in={row['input_words']:>4}w "
                f"{result['latency_s']:>6.2f}s out={result['completion_tokens']:>4}tok "
                f"{'TRUNCATED' if result['truncated'] else ''}"
            )

    rows = load_jsonl(out_path)
    print(f"\n== {args.name} / {args.task} on {len(rows)} real fixtures ==")
    for band in ("short", "medium", "long", "verylong"):
        band_rows = [r for r in rows if r["band"] == band]
        if not band_rows:
            continue
        lat = [r["latency_s"] for r in band_rows]
        print(
            f"{band:<9} n={len(band_rows)} "
            f"words {min(r['input_words'] for r in band_rows)}-{max(r['input_words'] for r in band_rows)} "
            f"latency med {statistics.median(lat):.2f}s max {max(lat):.2f}s "
            f"truncated {sum(r['truncated'] for r in band_rows)}"
        )
    print(f"TOTAL truncated: {sum(r['truncated'] for r in rows)}/{len(rows)}")


if __name__ == "__main__":
    main()
