"""Build the anonymised v2 judge packets from `results-v2.jsonl`.

Four independent judge panels ("arms"), 15 packets each, 60 packets total:

  armA -- prompt variants on gemma4-12b-qat  (4 candidates: baseline, A, B, C)
  armB -- prompt variants on gemma4-e2b-qat  (4 candidates: baseline, A, B, C)
  armC -- models on prompt_cleanup           (5 candidates)
  armD -- models on message_rewrite          (4 candidates)

Blinding rules enforced here, not by convention:
- letters are shuffled per packet with a seed distinct from v1's;
- the letter -> condition mapping is written OUTSIDE `packets_v2/`;
- packet ids carry an opaque arm label, never a model or prompt name;
- the packets are scanned for any candidate/model/prompt substring before being
  written, and the script raises if one leaks.

On the arms A and B the four candidates ARE four different prompts, so the real
prompt cannot go in the packet: a neutral brief stating the intent shared by the
four variants is used instead (`prompts/neutral_cleanup_brief.txt`). Arms C and
D keep the real task prompt, exactly as v1 did.

Nothing here touches the v1 artefacts (`results.jsonl`, `packets/`,
`letter_mapping.json`, `judgments/`).
"""

from __future__ import annotations

import json
import pathlib
import random
import string

BASE = pathlib.Path(__file__).parent
SEED = 20260901  # distinct from v1's 20260831 so the two shuffles are independent

# (arm, task, [(condition_label, model, prompt_id)]) -- condition_label is what the
# de-anonymised aggregate reports; it never appears in a packet.
ARMS: dict[str, dict] = {
    "armA": {
        "task": "prompt_cleanup",
        "brief": "neutral",
        "conditions": [
            ("gemma4-12b-qat/cleanup_baseline", "gemma4-12b-qat", "cleanup_baseline"),
            ("gemma4-12b-qat/cleanup_A", "gemma4-12b-qat", "cleanup_A"),
            ("gemma4-12b-qat/cleanup_B", "gemma4-12b-qat", "cleanup_B"),
            ("gemma4-12b-qat/cleanup_C", "gemma4-12b-qat", "cleanup_C"),
        ],
    },
    "armB": {
        "task": "prompt_cleanup",
        "brief": "neutral",
        "conditions": [
            ("gemma4-e2b-qat/cleanup_baseline", "gemma4-e2b-qat", "cleanup_baseline"),
            ("gemma4-e2b-qat/cleanup_A", "gemma4-e2b-qat", "cleanup_A"),
            ("gemma4-e2b-qat/cleanup_B", "gemma4-e2b-qat", "cleanup_B"),
            ("gemma4-e2b-qat/cleanup_C", "gemma4-e2b-qat", "cleanup_C"),
        ],
    },
    "armC": {
        "task": "prompt_cleanup",
        "brief": "prompt_cleanup.txt",
        "conditions": [
            ("gemma4-12b-qat", "gemma4-12b-qat", "cleanup_baseline"),
            ("gemma4-e2b-qat", "gemma4-e2b-qat", "cleanup_baseline"),
            ("qwen3.5-4b", "qwen3.5-4b", "cleanup_baseline"),
            ("qwen3.5-2b-q8", "qwen3.5-2b-q8", "cleanup_baseline"),
            ("s1-mini", "s1-mini", "s1_control"),
        ],
    },
    "armD": {
        "task": "message_rewrite",
        "brief": "message_rewrite.txt",
        "conditions": [
            ("gemma4-12b-qat", "gemma4-12b-qat", "rewrite_baseline"),
            ("gemma4-e2b-qat", "gemma4-e2b-qat", "rewrite_baseline"),
            ("qwen3.5-4b", "qwen3.5-4b", "rewrite_baseline"),
            ("qwen3.5-2b-q8", "qwen3.5-2b-q8", "rewrite_baseline"),
        ],
    },
}

# Substrings that must never appear inside a packet file. Checked after writing.
FORBIDDEN = (
    "gemma",
    "qwen",
    "s1-mini",
    "s1_control",
    "cleanup_A",
    "cleanup_B",
    "cleanup_C",
    "cleanup_baseline",
    "rewrite_baseline",
    "latency",
    "size_gb",
    "ollama",
)


def load_jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(x) for x in path.read_text().splitlines() if x.strip()]


def main() -> None:
    rows = load_jsonl(BASE / "results-v2.jsonl")
    fixtures = {f["id"]: f for f in load_jsonl(BASE / "fixtures.jsonl")}
    # Only the v2 config on the synthetic set is judged: v1cfg/v2mid exist solely
    # for the config A/B in describe_v2, and real_long was never judged.
    index = {
        (r["model"], r["prompt_id"], r["fixture_id"]): r
        for r in rows
        if r["config_id"] == "v2" and r["fixture_set"] == "synthetic"
    }
    fixture_ids = sorted(fixtures)

    rng = random.Random(SEED)
    out_dir = BASE / "packets_v2"
    out_dir.mkdir(exist_ok=True)
    mapping: dict[str, dict[str, str]] = {}

    for arm, spec in ARMS.items():
        brief = (
            (BASE / "prompts" / "neutral_cleanup_brief.txt").read_text()
            if spec["brief"] == "neutral"
            else (BASE / "prompts" / spec["brief"]).read_text()
        )
        lines: list[str] = []
        for fid in fixture_ids:
            cells = []
            for label, model, prompt_id in spec["conditions"]:
                key = (model, prompt_id, fid)
                if key not in index:
                    raise KeyError(f"{arm}/{fid}: no results-v2 row for {key}")
                cells.append((label, index[key]["output"]))
            rng.shuffle(cells)
            letters = string.ascii_uppercase[: len(cells)]
            packet_id = f"{arm}/{fid}"
            mapping[packet_id] = {
                letter: label for letter, (label, _) in zip(letters, cells)
            }
            lines.append(
                json.dumps(
                    {
                        "packet_id": packet_id,
                        "raw": fixtures[fid]["raw"],
                        "task_prompt": brief,
                        "candidates": {
                            letter: text for letter, (_, text) in zip(letters, cells)
                        },
                    },
                    ensure_ascii=False,
                )
            )
        path = out_dir / f"{arm}.jsonl"
        path.write_text("\n".join(lines) + "\n")

        blob = path.read_text().lower()
        if leaked := [s for s in FORBIDDEN if s.lower() in blob]:
            raise ValueError(f"{path.name}: identifying substring(s) leaked: {leaked}")

    (BASE / "letter_mapping_v2.json").write_text(
        json.dumps(mapping, indent=2, ensure_ascii=False)
    )

    # Shuffle diversity: a mapping that repeats the same ordering everywhere would
    # let a judge learn the position of a condition across packets.
    for arm in ARMS:
        orderings = {
            tuple(mapping[p][x] for x in sorted(mapping[p]))
            for p in mapping
            if p.startswith(f"{arm}/")
        }
        print(f"{arm}: 15 packets, {len(orderings)} distinct letter orderings")
    print(f"{len(mapping)} packets written to packets_v2/ ; no forbidden substring")


if __name__ == "__main__":
    main()
