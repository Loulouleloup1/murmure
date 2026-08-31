"""Aggregate blind judgments into per-model scores + machine metrics.

Reads the blind judgments (`judgments/*.jsonl`), de-anonymises them through
`letter_mapping.json`, and joins the result with the machine metrics measured in
`results.jsonl` and the on-disk sizes declared in `models.json`.

Two deliberate choices, both doctrine:
- scores are reported as a DISTRIBUTION (min / median / max over the three
  independent judges), never as a single draw;
- auto-fails are counted SEPARATELY, never folded into the score as a 0 — a
  zero would silently drag the median of an otherwise good candidate.

Anything missing (a judge file, a packet, a letter, a `size_gb`, a perf row)
raises. Silently skipping would misstate the compared population.
"""

from __future__ import annotations

import json
import pathlib
import statistics
from collections import defaultdict

BASE = pathlib.Path(__file__).parent
CRITERIA = ("fidelity", "disfluency", "verbatim", "format")
TASKS = ("prompt_cleanup", "message_rewrite")
JUDGES = (1, 2, 3)


def load_jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def _load_sizes() -> dict[str, float]:
    """On-disk size per model. `models.json` ships `size_gb` -- assert, never default."""
    sizes: dict[str, float] = {}
    for entry in json.loads((BASE / "models.json").read_text()):
        name = entry.get("name")
        if "size_gb" not in entry:
            raise KeyError(f"models.json entry {name!r} has no 'size_gb' key")
        sizes[name] = float(entry["size_gb"])
    return sizes


def _packets_by_task(mapping: dict[str, dict[str, str]]) -> dict[str, set[str]]:
    by_task: dict[str, set[str]] = defaultdict(set)
    for packet_id in mapping:
        task, _, fixture = packet_id.partition("/")
        if task not in TASKS or not fixture:
            raise ValueError(f"letter_mapping.json: unexpected packet_id {packet_id!r}")
        by_task[task].add(packet_id)
    missing = [t for t in TASKS if t not in by_task]
    if missing:
        raise ValueError(f"letter_mapping.json covers no packet for task(s) {missing}")
    return by_task


def _collect_judgments(mapping: dict[str, dict[str, str]]) -> dict:
    """De-anonymise every judgment. Raises on any missing judge, packet or letter."""
    expected = _packets_by_task(mapping)
    on_disk = {p.name for p in (BASE / "judgments").glob("*.jsonl")}
    wanted = {f"{task}_judge{j}.jsonl" for task in TASKS for j in JUDGES}
    if missing_files := sorted(wanted - on_disk):
        raise FileNotFoundError(f"missing judgment file(s): {missing_files}")
    if extra_files := sorted(on_disk - wanted):
        raise ValueError(f"unexpected judgment file(s) in judgments/: {extra_files}")

    totals: dict[tuple[str, str], list[int]] = defaultdict(list)
    by_judge: dict[tuple[str, str, int], list[int]] = defaultdict(list)
    per_criterion: dict[tuple[str, str], dict[str, list[int]]] = defaultdict(
        lambda: defaultdict(list)
    )
    autofails: dict[tuple[str, str], int] = defaultdict(int)
    autofail_detail: list[tuple[str, str, str, int]] = []

    for task in TASKS:
        for judge in JUDGES:
            path = BASE / "judgments" / f"{task}_judge{judge}.jsonl"
            rows = load_jsonl(path)
            seen: set[str] = set()
            for row in rows:
                packet_id = row["packet_id"]
                if packet_id not in mapping:
                    raise KeyError(
                        f"{path.name}: packet {packet_id!r} absent from letter_mapping"
                    )
                if not packet_id.startswith(f"{task}/"):
                    raise ValueError(
                        f"{path.name}: packet {packet_id!r} belongs to another task"
                    )
                if packet_id in seen:
                    raise ValueError(f"{path.name}: packet {packet_id!r} judged twice")
                seen.add(packet_id)

                letters = mapping[packet_id]
                if set(row["scores"]) != set(letters):
                    raise ValueError(
                        f"{path.name}/{packet_id}: judged letters {sorted(row['scores'])} "
                        f"!= mapped letters {sorted(letters)}"
                    )
                for letter, score in row["scores"].items():
                    model = letters[letter]
                    if score["autofail"]:
                        autofails[task, model] += 1
                        autofail_detail.append((task, packet_id, letter, judge))
                        continue
                    total = sum(int(score[c]) for c in CRITERIA)
                    totals[task, model].append(total)
                    by_judge[task, model, judge].append(total)
                    for criterion in CRITERIA:
                        per_criterion[task, model][criterion].append(
                            int(score[criterion])
                        )
            if missing_packets := sorted(expected[task] - seen):
                raise ValueError(f"{path.name}: unjudged packet(s) {missing_packets}")

    return {
        "totals": totals,
        "by_judge": by_judge,
        "per_criterion": per_criterion,
        "autofails": autofails,
        "autofail_detail": autofail_detail,
        "n_packets": {t: len(expected[t]) for t in TASKS},
    }


def _collect_perf() -> dict[tuple[str, str], dict[str, list[float]]]:
    perf: dict[tuple[str, str], dict[str, list[float]]] = defaultdict(
        lambda: {"latencies": [], "tps": []}
    )
    for row in load_jsonl(BASE / "results.jsonl"):
        key = (row["task"], row["model"])
        perf[key]["latencies"].append(float(row["latency_s"]))
        perf[key]["tps"].append(float(row["tokens_per_s"]))
    return perf


def _rank(totals: dict[tuple[str, str], list[int]], task: str) -> list[str]:
    """Models of one task, best first. Median is the verdict; mean breaks ties only."""
    models = [m for (t, m) in totals if t == task]
    return sorted(
        models,
        key=lambda m: (
            -statistics.median(totals[task, m]),
            -statistics.fmean(totals[task, m]),
            m,
        ),
    )


def _print_task_table(agg: dict, task: str, sizes: dict[str, float]) -> None:
    totals, per_criterion, autofails = (
        agg["totals"],
        agg["per_criterion"],
        agg["autofails"],
    )
    print(
        f"\n=== {task} -- score distribution over 3 judges x {agg['n_packets'][task]} packets ==="
    )
    header = (
        f"{'model':<15} {'n':>4} {'min':>4} {'med':>5} {'max':>4} {'mean':>5} "
        f"{'autofail':>8} {'size_gb':>7}"
    )
    print(header)
    for model in _rank(totals, task):
        scored = totals[task, model]
        if model not in sizes:
            raise KeyError(f"model {model!r} judged but absent from models.json")
        print(
            f"{model:<15} {len(scored):>4} {min(scored):>4} "
            f"{statistics.median(scored):>5.1f} {max(scored):>4} "
            f"{statistics.fmean(scored):>5.2f} {autofails[task, model]:>8} {sizes[model]:>7.1f}"
        )
        for criterion in CRITERIA:
            vals = per_criterion[task, model][criterion]
            print(
                f"    {criterion:<12} med={statistics.median(vals):>3.1f} "
                f"min={min(vals)} max={max(vals)} mean={statistics.fmean(vals):.2f}"
            )


def _print_judge_agreement(agg: dict, task: str) -> None:
    print(f"\n--- {task}: per-judge ranking (median total per model) ---")
    print(f"{'model':<15} " + " ".join(f"{'judge' + str(j):>8}" for j in JUDGES))
    for model in _rank(agg["totals"], task):
        cells = []
        for judge in JUDGES:
            vals = agg["by_judge"][task, model, judge]
            cells.append(f"{statistics.median(vals):>8.1f}" if vals else f"{'-':>8}")
        print(f"{model:<15} " + " ".join(cells))
    for judge in JUDGES:
        order = sorted(
            [m for (t, m) in agg["totals"] if t == task],
            key=lambda m: (
                -statistics.median(agg["by_judge"][task, m, judge] or [0]),
                -statistics.fmean(agg["by_judge"][task, m, judge] or [0]),
                m,
            ),
        )
        print(f"    judge{judge} top-2: {order[0]}, {order[1]}")


def _print_perf(perf: dict, agg: dict, sizes: dict[str, float]) -> None:
    print("\n=== machine metrics (from results.jsonl) ===")
    print(
        f"{'model':<15} {'task':<15} {'n':>3} {'med_lat_s':>9} {'max_lat_s':>9} "
        f"{'med_tps':>8} {'size_gb':>7}"
    )
    for task in TASKS:
        for model in _rank(agg["totals"], task):
            if (task, model) not in perf:
                raise KeyError(
                    f"no results.jsonl row for model {model!r} on task {task!r}"
                )
            lat = perf[task, model]["latencies"]
            tps = perf[task, model]["tps"]
            print(
                f"{model:<15} {task:<15} {len(lat):>3} {statistics.median(lat):>9.2f} "
                f"{max(lat):>9.2f} {statistics.median(tps):>8.1f} {sizes[model]:>7.1f}"
            )


def main() -> None:
    mapping = json.loads((BASE / "letter_mapping.json").read_text())
    sizes = _load_sizes()
    agg = _collect_judgments(mapping)
    perf = _collect_perf()

    n_scores = sum(len(v) for v in agg["totals"].values()) + sum(
        agg["autofails"].values()
    )
    models = sorted({m for (_, m) in agg["totals"]})
    print("=== population ===")
    print(f"models judged : {len(models)} ({', '.join(models)})")
    print(f"packets       : {sum(agg['n_packets'].values())} ({agg['n_packets']})")
    print(
        f"judges        : {len(TASKS) * len(JUDGES)} ({len(JUDGES)} independent per task)"
    )
    print(f"scored outputs: {n_scores} (auto-fails: {sum(agg['autofails'].values())})")

    for task in TASKS:
        _print_task_table(agg, task, sizes)
        _print_judge_agreement(agg, task)

    if agg["autofail_detail"]:
        print("\n=== auto-fails (excluded from the score distribution) ===")
        for task, packet_id, letter, judge in sorted(agg["autofail_detail"]):
            print(
                f"    {packet_id} letter {letter} = {mapping[packet_id][letter]} (judge{judge})"
            )

    _print_perf(perf, agg, sizes)


if __name__ == "__main__":
    main()
