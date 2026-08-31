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
    models = [
        m
        for m in json.loads((BASE / "models.json").read_text())
        if not m.get("excluded")
    ]
    out_path = BASE / "results.jsonl"
    done = (
        {(r["model"], r["fixture_id"], r["task"]) for r in load_jsonl(out_path)}
        if out_path.exists()
        else set()
    )
    with out_path.open("a") as out:
        for model in models:
            endpoint = model.get("endpoint", DEFAULT_ENDPOINT)
            for fixture in fixtures:
                for task, system in TASKS.items():
                    key = (model["name"], fixture["id"], task)
                    if key in done:
                        continue
                    result = run_one(
                        endpoint, model["model_id"], system, fixture["raw"]
                    )
                    row = {
                        "model": model["name"],
                        "fixture_id": fixture["id"],
                        "task": task,
                        **result,
                    }
                    out.write(json.dumps(row, ensure_ascii=False) + "\n")
                    out.flush()
                    print(
                        f"{model['name']} {fixture['id']} {task}: {result['latency_s']}s"
                    )


if __name__ == "__main__":
    main()
