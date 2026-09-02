"""s1-mini quantised versus full precision, on the wire Murmure actually uses.

Louis's question, unprompted: the refiner behind `Prompt` mode is a 0.5 B model
and we ship it quantised to 4 bits. Is the quantisation buying anything, on a
model already this small, that is worth whatever it costs in quality?

`superwhisper/s1-mini-GGUF` publishes exactly two files, verified against the
Hugging Face manifest endpoint rather than guessed:

    Q4_K_M (= `latest`)   484.2 MB   sha256:3b41ebe2502cb   <- what ships
    F16                  1509.3 MB   sha256:0370da4f1bae1

Same license, template and params blobs on both tags -- the only difference is
the weights, so this is a clean single-variable comparison.

What makes this run different from `v3_run_benchmark.py`: there is no prompt arm
and no control-field grid. Both were settled in v3, and re-opening them here
would confound the one variable being tested. Every cell uses **production's own
wire**, read out of `OllamaS1.swift` and `modes/prompt.json` rather than
reconstructed:

    /api/generate, raw: true, the ChatML conversation with the `<think>` prefill,
    control line `[Context: general]`, temperature 0, repeat_penalty 1.1,
    seed 20260901, num_predict 2048, num_ctx 4096, truncate false.

A benchmark on different settings measures a different thing.

Strictly sequential: one arm runs to completion, the model is stopped, the runner
RSS is watched down to zero, and only then does the other arm start. Two 0.5 B
models would fit side by side, which is exactly why the discipline has to be
explicit -- the latencies stop meaning anything if they share a GPU.

Writes `results-v4-quant.local.jsonl`: carries Louis's real dictations, so it is
gitignored (ruling R12) and never committed.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import time

import requests

BASE = pathlib.Path(__file__).parent
OUT_PATH = BASE / "results-v4-quant.local.jsonl"
GENERATE = "http://localhost:11434/api/generate"
RUNTIME = "ollama-0.33.2"

ARMS = {
    "q4": {"model_id": "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M", "weights_mb": 484.2},
    "f16": {"model_id": "hf.co/superwhisper/s1-mini-GGUF:F16", "weights_mb": 1509.3},
}

# ---------------------------------------------------------------------------
# Production's wire, transcribed from MurmureCore. Any drift between these
# constants and the Swift is a bug in this file, not a setting to tune.
# ---------------------------------------------------------------------------

# `OllamaS1.systemPrompt` -- fixed by the model card, not a prompt to tune.
SYSTEM_PROMPT = (
    "You are a text normalizer for speech-to-text transcripts. The input begins with a "
    "control line specifying the styling, structure, and context settings; clean the "
    "transcript to match those settings and output only the cleaned text."
)
# `modes/prompt.json` -> `instructions`. Not v3's `[Styling: semi-casual]
# [Structure: prose] [Context: general]`: that was the grid winner, this is what
# the shipped mode sends.
CONTROL = "[Context: general]"
# `OllamaS1.stop`
STOP = ["<|im_end|>", "<|im_start|>"]
# `OllamaS1.temperature` / `.repeatPenalty` / `.seed` / `.numPredict` / `.numContext`
OPTIONS = {
    "temperature": 0.0,
    "repeat_penalty": 1.1,
    "seed": 20260901,
    "num_predict": 2048,
    "num_ctx": 4096,
    "stop": STOP,
}
# `OllamaS1.truncate` -- refuse rather than silently shorten from the front.
TRUNCATE = False


def conversation(transcript: str) -> str:
    """`OllamaS1.conversation`, newline for newline.

    Written as concatenated fragments for the same reason the Swift is: the
    template ends on two newlines and a triple-quoted literal eats the last one.
    """
    return (
        f"<|im_start|>system\n{SYSTEM_PROMPT}<|im_end|>\n"
        f"<|im_start|>user\n{CONTROL}\n{transcript}<|im_end|>\n"
        f"<|im_start|>assistant\n<think>\n\n</think>\n\n"
    )


def generate(model_id: str, transcript: str) -> dict:
    t0 = time.monotonic()
    resp = requests.post(
        GENERATE,
        json={
            "model": model_id,
            "prompt": conversation(transcript),
            "raw": True,
            "stream": False,
            "truncate": TRUNCATE,
            "options": OPTIONS,
        },
        timeout=900,
    )
    latency = time.monotonic() - t0
    if resp.status_code != 200:
        return {
            "output": "",
            "http_status": resp.status_code,
            "http_body": resp.text[:400],
            "latency_s": round(latency, 3),
            "completion_tokens": 0,
            "prompt_tokens": 0,
            "tokens_per_s": 0.0,
            "done_reason": "http_error",
        }
    data = resp.json()
    completion = data.get("eval_count", 0)
    return {
        "output": data.get("response", "").strip(),
        "http_status": 200,
        "latency_s": round(latency, 3),
        "completion_tokens": completion,
        "prompt_tokens": data.get("prompt_eval_count", 0),
        "load_ms": round(data.get("load_duration", 0) / 1e6, 1),
        "tokens_per_s": round(completion / latency, 2) if latency > 0 else 0.0,
        "done_reason": data.get("done_reason", ""),
    }


def runner_rss_bytes() -> int:
    """Summed RSS of every Ollama model-runner. Zero when none is loaded.

    Same accounting as `v3_measure_ram.py`: the Ollama app and server are
    excluded because they are resident either way, so counting them would add the
    same constant to both arms and change no comparison.
    """
    out = subprocess.run(
        ["ps", "-Ao", "rss=,command="], capture_output=True, text=True, check=True
    ).stdout
    total = 0
    for line in out.splitlines():
        rss_kb, _, command = line.strip().partition(" ")
        if rss_kb and ("llama-server" in command or "ollama runner" in command):
            total += int(rss_kb) * 1024
    return total


def unload_everything(timeout_s: float = 30.0) -> None:
    """Stop every model this project can load, then WAIT for the RSS to drop.

    `ollama stop` returns before the runner has exited. Starting the next arm on
    that optimism is how two models end up resident at once on the machine Louis
    is working on.
    """
    listed = subprocess.run(
        ["ollama", "ps"], capture_output=True, text=True, check=False
    ).stdout
    for line in listed.splitlines()[1:]:
        name = line.split()[0] if line.split() else ""
        if name:
            subprocess.run(["ollama", "stop", name], check=False, capture_output=True)
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if runner_rss_bytes() == 0:
            return
        time.sleep(0.5)
    raise RuntimeError(
        f"a runner is still resident after {timeout_s}s -- refusing to load a second model"
    )


def load_jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    fixture_sets = {
        # Synthetic, committable, and the set both published reports tabulate --
        # so the numbers here can be read against theirs.
        "synthetic": load_jsonl(BASE / "fixtures.jsonl"),
        # Real dictations, stratified by code-switching density (`v3_sample_franglais.py`).
        # This is the set that can see the failure that matters: French flipping
        # to English.
        "real": load_jsonl(BASE / "fixtures-franglais.local.jsonl"),
    }
    total = sum(len(v) for v in fixture_sets.values())
    print(f"{len(ARMS)} arms x {total} fixtures = {len(ARMS) * total} generations")
    for name, rows in fixture_sets.items():
        ws = sorted(len(r["raw"].split()) for r in rows)
        print(
            f"  {name:10} n={len(rows):3d}  words {ws[0]}-{ws[-1]} (median {ws[len(ws) // 2]})"
        )
    if args.dry_run:
        return

    done = (
        {(r["arm"], r["fixture_id"]) for r in load_jsonl(OUT_PATH)}
        if OUT_PATH.exists()
        else set()
    )

    with OUT_PATH.open("a") as out:
        for arm, spec in ARMS.items():
            unload_everything()
            time.sleep(2)
            # One untimed call so the arm's first fixture is not the one paying
            # for the model load. Cold-start cost is measured separately, on
            # purpose, by `v4_measure_ram.py`.
            generate(spec["model_id"], "bonjour, ceci est un warm-up.")

            for set_name, fixtures in fixture_sets.items():
                for fixture in fixtures:
                    if (arm, fixture["id"]) in done:
                        continue
                    result = generate(spec["model_id"], fixture["raw"])
                    row = {
                        "arm": arm,
                        "model_id": spec["model_id"],
                        "weights_mb": spec["weights_mb"],
                        "runtime": RUNTIME,
                        "control": CONTROL,
                        "num_ctx": OPTIONS["num_ctx"],
                        "fixture_set": set_name,
                        "fixture_id": fixture["id"],
                        "stratum": fixture.get("stratum", "synthetic"),
                        "input_words": len(fixture["raw"].split()),
                        **result,
                    }
                    out.write(json.dumps(row, ensure_ascii=False) + "\n")
                    out.flush()
                    print(
                        f"{arm:4} {set_name:10} {fixture['id']:22} "
                        f"{result['latency_s']:7.2f}s {result['completion_tokens']:4d}tok "
                        f"{result['done_reason']}",
                        flush=True,
                    )
            unload_everything()

    print("done -- no model left resident")


if __name__ == "__main__":
    main()
