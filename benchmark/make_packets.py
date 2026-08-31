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
            mapping[packet_id] = {
                letter: row["model"] for letter, row in zip(letters, rows)
            }
            lines.append(
                json.dumps(
                    {
                        "packet_id": packet_id,
                        "raw": fixtures[fid]["raw"],
                        "task_prompt": task_prompt,
                        "candidates": {
                            letter: row["output"] for letter, row in zip(letters, rows)
                        },
                    },
                    ensure_ascii=False,
                )
            )
        (BASE / "packets" / f"{task}.jsonl").write_text("\n".join(lines) + "\n")
    (BASE / "letter_mapping.json").write_text(
        json.dumps(mapping, indent=2, ensure_ascii=False)
    )
    print(f"packets written; {len(mapping)} packets total")


if __name__ == "__main__":
    main()
