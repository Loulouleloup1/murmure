"""Resident memory + cold/warm latency, one model at a time.

The v3 brief promotes memory from a footnote to an admissibility constraint: a
model that cannot coexist with the rest of a 16 GB machine is out whatever its
score. Disk size is not that number -- `gemma4:12b-it-qat` is a 7.2 GB file that
Ollama reports as 7.9 GB loaded at `num_ctx: 8192`, because the KV cache is
sized by the context window, not by the weights.

So this script measures three things per model, with only that model resident:
  * `ollama ps` loaded size (weights + KV cache, as Ollama accounts it),
  * the actual RSS of the `llama-server` process serving it, sampled at 50 ms
    while a request is in flight (peak, not a single reading),
  * cold latency (first request after `ollama stop`) and warm latency.

Caveat recorded here rather than in the report only: "cold" means cold *after an
`ollama stop`*, so the GGUF is still in the OS page cache. A true boot-cold start
would be slower. Purging the page cache needs root and this session does not
have it.

Writes `ram-v3.json` (gitignored -- it carries no dictation, but it is a
regenerated measurement artefact, not evidence to commit).
"""

from __future__ import annotations

import json
import pathlib
import statistics
import subprocess
import threading
import time

import requests

BASE = pathlib.Path(__file__).parent
CHAT = "http://localhost:11434/api/chat"
GENERATE = "http://localhost:11434/api/generate"
OPTIONS = {"temperature": 0, "seed": 20260901, "num_predict": 2048, "num_ctx": 8192}

MODELS = [
    ("s1-mini", "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M", "generate_raw"),
    ("gemma4-e2b-qat", "gemma4:e2b-it-qat", "chat"),
    ("gemma4-12b-qat", "gemma4:12b-it-qat", "chat"),
]

SYSTEM = (BASE / "prompts" / "prompt_cleanup_A.txt").read_text()
COLD_ROUNDS = 3


def _runner_rss_bytes() -> int:
    """Summed RSS of every Ollama model-runner process. Zero when none is loaded.

    The Ollama app and its server are excluded: they are resident whether or not
    a model is, so counting them would inflate every model by the same ~75 MB and
    make no model look better or worse. The runner is the per-model cost.
    """
    out = subprocess.run(
        ["ps", "-Ao", "rss=,command="], capture_output=True, text=True, check=True
    ).stdout
    total = 0
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        rss_kb, _, command = line.partition(" ")
        if "llama-server" in command or "ollama runner" in command:
            total += int(rss_kb) * 1024
    return total


def _ollama_ps() -> list[dict]:
    out = subprocess.run(["ollama", "ps"], capture_output=True, text=True, check=False).stdout
    rows = []
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 4:
            rows.append({"name": parts[0], "size": " ".join(parts[2:4]), "raw": line.strip()})
    return rows


class _Sampler(threading.Thread):
    """Peak-RSS sampler. A single reading after the response lands can miss the
    transient high-water mark during prompt eval."""

    def __init__(self) -> None:
        super().__init__(daemon=True)
        self.samples: list[int] = []
        self._stop = threading.Event()

    def run(self) -> None:
        while not self._stop.is_set():
            self.samples.append(_runner_rss_bytes())
            time.sleep(0.05)

    def stop(self) -> int:
        self._stop.set()
        self.join(timeout=2)
        return max(self.samples) if self.samples else 0


def _call(model_id: str, api: str, text: str) -> float:
    t0 = time.monotonic()
    if api == "generate_raw":
        payload = {
            "model": model_id,
            "prompt": (
                f"<|im_start|>user\n[Context: general]\n{text}<|im_end|>\n"
                f"<|im_start|>assistant\n<think>\n\n</think>\n\n"
            ),
            "raw": True,
            "stream": False,
            "options": {**OPTIONS, "stop": ["<|im_end|>", "<|im_start|>"]},
        }
        endpoint = GENERATE
    else:
        payload = {
            "model": model_id,
            "messages": [
                {"role": "system", "content": SYSTEM},
                {"role": "user", "content": text},
            ],
            "stream": False,
            "think": False,
            "options": OPTIONS,
        }
        endpoint = CHAT
    resp = requests.post(endpoint, json=payload, timeout=900)
    resp.raise_for_status()
    return time.monotonic() - t0


def _stop_all() -> None:
    for _, model_id, _ in MODELS:
        subprocess.run(["ollama", "stop", model_id], check=False, capture_output=True)
    for _ in range(40):
        if _runner_rss_bytes() == 0:
            return
        time.sleep(0.5)


def main() -> None:
    fixtures = [
        json.loads(line)
        for line in (BASE / "fixtures.jsonl").read_text().splitlines()
        if line.strip()
    ]
    short = next(f for f in fixtures if f["id"] == "f02")["raw"]

    _stop_all()
    idle_rss = _runner_rss_bytes()
    print(f"idle runner RSS: {idle_rss / 1e9:.3f} GB")

    results = []
    for name, model_id, api in MODELS:
        _stop_all()
        time.sleep(2)

        cold_latencies = []
        for i in range(COLD_ROUNDS):
            if i > 0:
                _stop_all()
                time.sleep(2)
            sampler = _Sampler()
            sampler.start()
            cold_latencies.append(_call(model_id, api, short))
            peak = sampler.stop()
            if i == 0:
                cold_peak, cold_ps = peak, _ollama_ps()

        warm = [_call(model_id, api, short) for _ in range(7)]

        sampler = _Sampler()
        sampler.start()
        _call(model_id, api, short)
        warm_peak = sampler.stop()
        settled = _runner_rss_bytes()
        ps_rows = _ollama_ps()

        row = {
            "model": name,
            "model_id": model_id,
            "num_ctx": OPTIONS["num_ctx"],
            "idle_runner_rss_gb": round(idle_rss / 1e9, 3),
            "peak_rss_first_load_gb": round(cold_peak / 1e9, 3),
            "peak_rss_warm_gb": round(warm_peak / 1e9, 3),
            "settled_rss_gb": round(settled / 1e9, 3),
            "ollama_ps": ps_rows,
            "ollama_ps_at_cold": cold_ps,
            "cold_latency_s": [round(x, 3) for x in cold_latencies],
            "cold_latency_median_s": round(statistics.median(cold_latencies), 3),
            "warm_latency_s": [round(x, 3) for x in warm],
            "warm_latency_median_s": round(statistics.median(warm), 3),
        }
        results.append(row)
        print(json.dumps(row, ensure_ascii=False, indent=2))
        _stop_all()

    (BASE / "ram-v3.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
