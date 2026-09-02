"""Resident footprint and load cost of s1-mini at Q4_K_M versus F16.

The prior this exists to test: v3 measured s1-mini at 1.07 GB resident at
`num_ctx` 4096, and noted that the KV cache dominates because the weights are so
small. If that holds, full-precision weights add about a gigabyte of the wrong
half of that sum -- and quantisation would be buying memory nobody needed. This
script is what turns that sentence from a plausible inference into a number.

Method, inherited from `v3_measure_ram.py` and kept identical so the two runs are
comparable:

  * RSS is **sampled continuously at 50 ms**, and the figure reported is the peak
    over the window, never a single reading. A single sample taken when the
    response lands catches the process mid-load and under-reports -- that trap is
    already recorded in this repo and this script does not fall into it.
  * The warm peak is read after **two** requests have completed under the
    sampler, not one, so the reading is of a settled model rather than of one
    still faulting pages in.
  * `ollama ps` is captured alongside as Ollama's own accounting of the same
    thing; the two disagree and the report says so rather than picking one.
  * Only the model-runner processes are counted. The Ollama app and server are
    resident whether or not a model is.

Caveat, same as v3: "cold" means cold after an `ollama stop`, so the GGUF is
still in the OS page cache. A true boot-cold start is slower and needs root to
measure. The gap between the arms is still meaningful -- the f16 file is 3.1x
the bytes to move either way.

Writes `ram-v4-quant.json`. Not gitignored, deliberately: it carries no
dictation, only timings and byte counts.
"""

from __future__ import annotations

import json
import pathlib
import statistics
import threading
import time

from v4_quant import ARMS, generate, load_jsonl, runner_rss_bytes, unload_everything

BASE = pathlib.Path(__file__).parent
COLD_ROUNDS = 4
WARM_ROUNDS = 7
# The sweep is run on the f16 arm only. `num_ctx` was already swept on q4 in v3
# (0.84 / 1.07 / 1.54 / 2.48 GB at 2048 / 4096 / 8192 / 16384); what is unknown
# is whether the lever still has the same throw once the weights are 3.1x bigger.
SWEEP_CTX = (2048, 4096, 8192)


class Sampler(threading.Thread):
    """Peak-RSS sampler at 50 ms. See the module docstring for why a peak."""

    def __init__(self) -> None:
        super().__init__(daemon=True)
        self.samples: list[int] = []
        self._stop = threading.Event()

    def run(self) -> None:
        while not self._stop.is_set():
            self.samples.append(runner_rss_bytes())
            time.sleep(0.05)

    def stop(self) -> int:
        self._stop.set()
        self.join(timeout=2)
        return max(self.samples) if self.samples else 0


def ollama_ps() -> list[str]:
    import subprocess

    out = subprocess.run(
        ["ollama", "ps"], capture_output=True, text=True, check=False
    ).stdout
    return [line.strip() for line in out.splitlines()[1:] if line.strip()]


def measure(arm: str, model_id: str, short: str, long_text: str) -> dict:
    unload_everything()
    time.sleep(2)

    # Cold rounds. Each one is a full stop -> load -> single request, so the
    # latency includes the model load; the sampler runs across the whole of it so
    # the first-load high-water mark is caught.
    cold_latencies: list[float] = []
    cold_peak = 0
    for i in range(COLD_ROUNDS):
        if i > 0:
            unload_everything()
            time.sleep(2)
        sampler = Sampler()
        sampler.start()
        r = generate(model_id, short)
        peak = sampler.stop()
        cold_latencies.append(r["latency_s"])
        cold_peak = max(cold_peak, peak)
        if i == 0:
            first_cold_load_ms = r.get("load_ms", 0.0)

    warm = [generate(model_id, short)["latency_s"] for _ in range(WARM_ROUNDS)]

    # Two requests under the sampler before the peak is read.
    sampler = Sampler()
    sampler.start()
    generate(model_id, short)
    generate(model_id, short)
    warm_peak = sampler.stop()
    settled = runner_rss_bytes()

    # The longest dictation in the corpus, to see the footprint under a full
    # window rather than under a 46-word one.
    sampler = Sampler()
    sampler.start()
    long_result = generate(model_id, long_text)
    long_peak = sampler.stop()

    row = {
        "arm": arm,
        "model_id": model_id,
        "weights_mb": ARMS[arm]["weights_mb"],
        "num_ctx": 4096,
        "ollama_ps": ollama_ps(),
        "peak_rss_first_load_gb": round(cold_peak / 1e9, 3),
        "peak_rss_warm_gb": round(warm_peak / 1e9, 3),
        "settled_rss_gb": round(settled / 1e9, 3),
        "peak_rss_longest_dictation_gb": round(long_peak / 1e9, 3),
        "longest_dictation_words": len(long_text.split()),
        "longest_prompt_tokens": long_result["prompt_tokens"],
        "longest_completion_tokens": long_result["completion_tokens"],
        "first_cold_load_ms": first_cold_load_ms,
        "cold_latency_s": [round(x, 3) for x in cold_latencies],
        "cold_latency_median_s": round(statistics.median(cold_latencies), 3),
        "cold_latency_max_s": round(max(cold_latencies), 3),
        "warm_latency_s": [round(x, 3) for x in warm],
        "warm_latency_median_s": round(statistics.median(warm), 3),
    }
    unload_everything()
    return row


def sweep(arm: str, model_id: str, short: str) -> list[dict]:
    from v4_quant import OPTIONS

    original = OPTIONS["num_ctx"]
    out = []
    try:
        for ctx in SWEEP_CTX:
            unload_everything()
            time.sleep(2)
            OPTIONS["num_ctx"] = ctx
            sampler = Sampler()
            sampler.start()
            generate(model_id, short)
            generate(model_id, short)
            peak = sampler.stop()
            out.append(
                {
                    "arm": arm,
                    "num_ctx": ctx,
                    "rss_gb": round(peak / 1e9, 3),
                    "ollama_ps": ollama_ps(),
                }
            )
            print(f"  {arm} num_ctx {ctx:>5}: {peak / 1e9:.2f} GB", flush=True)
            unload_everything()
    finally:
        OPTIONS["num_ctx"] = original
    return out


def main() -> None:
    fixtures = load_jsonl(BASE / "fixtures.jsonl")
    short = next(f for f in fixtures if f["id"] == "f02")["raw"]
    real = load_jsonl(BASE / "fixtures-franglais.local.jsonl")
    longest = max(real, key=lambda f: len(f["raw"].split()))["raw"]

    unload_everything()
    print(f"idle runner RSS: {runner_rss_bytes() / 1e9:.3f} GB (expected 0.000)")

    results = []
    for arm, spec in ARMS.items():
        row = measure(arm, spec["model_id"], short, longest)
        results.append(row)
        print(json.dumps(row, ensure_ascii=False, indent=2), flush=True)

    print("\nnum_ctx sweep (f16):")
    sweeps = sweep("f16", ARMS["f16"]["model_id"], short)

    (BASE / "ram-v4-quant.json").write_text(
        json.dumps(
            {"arms": results, "f16_ctx_sweep": sweeps}, ensure_ascii=False, indent=2
        )
    )
    unload_everything()


if __name__ == "__main__":
    main()
