"""Run the v2 blind judges as independent headless `claude -p` processes.

12 judges = 4 arms x 3. Each judge is a SEPARATE process with no shared context,
started from an empty working directory so that even a stray tool call cannot
reach `letter_mapping_v2.json` or `results-v2.jsonl`. The judge receives only:
the frozen `judge_prompt.txt`, the frozen `rubric.md`, and its arm's 15 packets.

Two protocol details:
- The three judges of an arm get the SAME instructions (as in v1) but the
  packets in a DIFFERENT order (per-judge seed), so any ordering or fatigue
  effect is not shared across the three -- which is what makes their agreement
  informative rather than a common artefact.
- Output is validated before it is written: every packet judged exactly once,
  the judged letters matching the packet's letters, all four criteria present
  and in 0-2. A judge whose output fails validation is re-run (up to RETRIES);
  a partial file is never written.
"""

from __future__ import annotations

import concurrent.futures as futures
import json
import pathlib
import random
import subprocess
import sys
import tempfile

BASE = pathlib.Path(__file__).parent
ARMS = ("armA", "armB", "armC", "armD")
JUDGES = (1, 2, 3)
CRITERIA = ("fidelity", "disfluency", "verbatim", "format")
RETRIES = 2
MODEL = "opus"


def load_jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(x) for x in path.read_text().splitlines() if x.strip()]


def build_prompt(packets: list[dict]) -> str:
    parts = [
        (BASE / "judge_prompt.txt").read_text(),
        "\n--- RUBRIC (frozen) ---\n",
        (BASE / "rubric.md").read_text(),
        f"\n--- {len(packets)} PACKETS TO SCORE ---\n",
    ]
    for p in packets:
        parts.append(
            f"\n### PACKET {p['packet_id']}\n\n"
            f"TASK PROMPT GIVEN TO THE CANDIDATES:\n{p['task_prompt']}\n"
            f"RAW DICTATED TRANSCRIPT:\n{p['raw']}\n\nCANDIDATE OUTPUTS:\n"
        )
        for letter, text in p["candidates"].items():
            parts.append(f"[{letter}]\n{text}\n")
    parts.append(
        f"\nScore all {len(packets)} packets. Output exactly {len(packets)} JSON "
        "objects, one per line, in any order, and nothing else."
    )
    return "".join(parts)


def parse_and_validate(stdout: str, packets: list[dict]) -> list[dict]:
    expected = {p["packet_id"]: set(p["candidates"]) for p in packets}
    rows: list[dict] = []
    seen: set[str] = set()
    for line in stdout.splitlines():
        line = line.strip().strip("`")
        if not line.startswith("{"):
            continue
        row = json.loads(line)
        pid = row["packet_id"]
        if pid not in expected:
            raise ValueError(f"unknown packet {pid!r}")
        if pid in seen:
            raise ValueError(f"packet {pid!r} judged twice")
        seen.add(pid)
        if set(row["scores"]) != expected[pid]:
            raise ValueError(
                f"{pid}: letters {sorted(row['scores'])} != {sorted(expected[pid])}"
            )
        for letter, score in row["scores"].items():
            if not isinstance(score.get("autofail"), bool):
                raise ValueError(f"{pid}/{letter}: missing boolean 'autofail'")
            for c in CRITERIA:
                if int(score[c]) not in (0, 1, 2):
                    raise ValueError(f"{pid}/{letter}: {c}={score[c]!r} out of 0-2")
        rows.append(row)
    if missing := sorted(set(expected) - seen):
        raise ValueError(f"unjudged packet(s): {missing}")
    return rows


def run_judge(arm: str, judge: int) -> str:
    packets = load_jsonl(BASE / "packets_v2" / f"{arm}.jsonl")
    # Deterministic seed: `hash()` on a str is salted per process (PYTHONHASHSEED),
    # which would make the packet order irreproducible across runs.
    random.Random(f"{arm}-{judge}-20260901").shuffle(packets)
    prompt = build_prompt(packets)
    out_path = BASE / "judgments_v2" / f"{arm}_judge{judge}.jsonl"
    last: Exception | None = None
    for attempt in range(1, RETRIES + 2):
        with tempfile.TemporaryDirectory() as jail:
            proc = subprocess.run(
                ["claude", "-p", "--model", MODEL],
                input=prompt,
                capture_output=True,
                text=True,
                cwd=jail,
                timeout=1800,
            )
        try:
            if proc.returncode != 0:
                raise ValueError(
                    f"claude exited {proc.returncode}: {proc.stderr[:300]}"
                )
            rows = parse_and_validate(proc.stdout, packets)
        except Exception as exc:  # noqa: BLE001 -- retried, then surfaced verbatim
            last = exc
            print(f"  {arm} judge{judge} attempt {attempt} rejected: {exc}", flush=True)
            continue
        out_path.write_text(
            "\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n"
        )
        return f"{arm} judge{judge}: OK ({len(rows)} packets, attempt {attempt})"
    raise RuntimeError(
        f"{arm} judge{judge} failed after {RETRIES + 1} attempts: {last}"
    )


def main() -> None:
    (BASE / "judgments_v2").mkdir(exist_ok=True)
    jobs = [(a, j) for a in ARMS for j in JUDGES]
    errors: list[str] = []
    with futures.ThreadPoolExecutor(max_workers=4) as pool:
        pending = {pool.submit(run_judge, a, j): (a, j) for a, j in jobs}
        for fut in futures.as_completed(pending):
            arm, judge = pending[fut]
            try:
                print(fut.result(), flush=True)
            except Exception as exc:  # noqa: BLE001 -- collected, reported at the end
                errors.append(f"{arm} judge{judge}: {exc}")
                print(f"FAILED {arm} judge{judge}: {exc}", flush=True)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        sys.exit(1)
    print("all 12 judges complete")


if __name__ == "__main__":
    main()
