"""Aggregate the v2 blind judgments into per-condition scores + machine metrics.

Same doctrine as `aggregate.py` (v1), extended to four arms:

  armA -- prompt variants on gemma4-12b-qat   armC -- models on prompt_cleanup
  armB -- prompt variants on gemma4-e2b-qat   armD -- models on message_rewrite

Doctrine carried over from v1, unchanged:
- scores are reported as a DISTRIBUTION (min / median / max / mean over the three
  independent judges of the arm), never as a single draw;
- auto-fails are counted SEPARATELY, never folded into the score as a 0;
- the per-packet head-to-head is printed under BOTH auto-fail conventions,
  because the choice is load-bearing and v1 had it contested.

Added in v2, because v2 asks a cost question v1 did not:
- every condition's row carries its median latency and on-disk size, so no score
  can be read without its price;
- ranking inversions BETWEEN the two auto-fail conventions are detected and
  named, not left for the reader to spot;
- `f08` (the code-switch fixture) is reported separately: a fixture everyone
  fails equally discriminates nothing.

Anything missing (a judge file, a packet, a letter, a perf row) raises.
"""

from __future__ import annotations

import itertools
import json
import pathlib
import statistics
from collections import defaultdict

BASE = pathlib.Path(__file__).parent
CRITERIA = ("fidelity", "disfluency", "verbatim", "format")
JUDGES = (1, 2, 3)
ARMS = {
    "armA": "prompt variants -- gemma4-12b-qat (prompt_cleanup)",
    "armB": "prompt variants -- gemma4-e2b-qat (prompt_cleanup)",
    "armC": "models -- prompt_cleanup, baseline prompt",
    "armD": "models -- message_rewrite, baseline prompt",
}
HARD_FIXTURE = "f08"


def load_jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(x) for x in path.read_text().splitlines() if x.strip()]


def _perf_index() -> dict[tuple[str, str], list[dict]]:
    """(model, prompt_id) -> the 15 judged generations, v2 config, synthetic set."""
    perf: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for r in load_jsonl(BASE / "results-v2.jsonl"):
        if r["config_id"] == "v2" and r["fixture_set"] == "synthetic":
            perf[r["model"], r["prompt_id"]].append(r)
    return perf


def _condition_perf(label: str, perf: dict) -> dict:
    """Map a de-anonymised condition label back to its generation rows.

    Arm A/B labels are `model/prompt_id`; arm C/D labels are bare model names, whose
    prompt is the arm's baseline. Raises rather than defaulting: a condition scored
    but not measured would put a quality number next to a blank price.
    """
    if "/" in label:
        model, prompt_id = label.split("/", 1)
    else:
        model = label
        prompt_id = {"s1-mini": "s1_control"}.get(model)
        if prompt_id is None:
            prompt_id = (
                "cleanup_baseline"
                if (model, "cleanup_baseline") in perf
                else "rewrite_baseline"
            )
    rows = perf.get((model, prompt_id))
    if not rows:
        raise KeyError(
            f"no results-v2 rows for condition {label!r} -> {(model, prompt_id)}"
        )
    sizes = {
        m["name"]: m["size_gb"]
        for m in json.loads((BASE / "models_v2.json").read_text())
    }
    lat = sorted(r["latency_s"] for r in rows)
    return {
        "n": len(rows),
        "med_lat": statistics.median(lat),
        "p90_lat": lat[min(len(lat) - 1, int(0.9 * len(lat)))],
        "max_lat": max(lat),
        "size_gb": sizes[model],
        "model": model,
    }


def collect(mapping: dict) -> dict:
    packets_by_arm: dict[str, set[str]] = defaultdict(set)
    for pid in mapping:
        packets_by_arm[pid.split("/", 1)[0]].add(pid)

    totals: dict[tuple[str, str], list[int]] = defaultdict(list)
    by_judge: dict[tuple[str, str, int], list[int]] = defaultdict(list)
    per_criterion: dict[tuple[str, str], dict[str, list[int]]] = defaultdict(
        lambda: defaultdict(list)
    )
    autofails: dict[tuple[str, str], int] = defaultdict(int)
    autofail_detail: list[tuple] = []
    per_packet: dict[tuple[str, str, str], dict] = defaultdict(
        lambda: {"totals": [], "autofails": 0}
    )
    # packet -> letter -> judge -> total, for the inter-judge agreement pass.
    raw: dict[str, dict[str, dict[int, int | None]]] = defaultdict(
        lambda: defaultdict(dict)
    )

    for arm in ARMS:
        for judge in JUDGES:
            path = BASE / "judgments_v2" / f"{arm}_judge{judge}.jsonl"
            if not path.exists():
                raise FileNotFoundError(f"missing judgment file: {path.name}")
            seen: set[str] = set()
            for row in load_jsonl(path):
                pid = row["packet_id"]
                if pid not in mapping or not pid.startswith(f"{arm}/"):
                    raise KeyError(f"{path.name}: bad packet {pid!r}")
                if pid in seen:
                    raise ValueError(f"{path.name}: packet {pid!r} judged twice")
                seen.add(pid)
                letters = mapping[pid]
                if set(row["scores"]) != set(letters):
                    raise ValueError(f"{path.name}/{pid}: letter set mismatch")
                for letter, score in row["scores"].items():
                    cond = letters[letter]
                    if score["autofail"]:
                        autofails[arm, cond] += 1
                        autofail_detail.append(
                            (arm, pid, letter, cond, judge, score.get("note", ""))
                        )
                        per_packet[arm, cond, pid]["autofails"] += 1
                        raw[pid][letter][judge] = None
                        continue
                    total = sum(int(score[c]) for c in CRITERIA)
                    totals[arm, cond].append(total)
                    per_packet[arm, cond, pid]["totals"].append(total)
                    by_judge[arm, cond, judge].append(total)
                    raw[pid][letter][judge] = total
                    for c in CRITERIA:
                        per_criterion[arm, cond][c].append(int(score[c]))
            if missing := sorted(packets_by_arm[arm] - seen):
                raise ValueError(f"{path.name}: unjudged packet(s) {missing}")

    return {
        "totals": totals,
        "by_judge": by_judge,
        "per_criterion": per_criterion,
        "autofails": autofails,
        "autofail_detail": autofail_detail,
        "per_packet": per_packet,
        "packets": {a: sorted(packets_by_arm[a]) for a in ARMS},
        "raw": raw,
    }


def _conditions(agg: dict, arm: str) -> list[str]:
    return sorted({c for (a, c) in agg["totals"] if a == arm})


def _rank(agg: dict, arm: str, rule: str = "excluded") -> list[str]:
    """Best first. Median is the verdict; mean breaks ties only (v1 convention)."""

    def key(cond: str) -> tuple:
        vals = list(agg["totals"][arm, cond])
        if rule == "zero":
            vals += [0] * agg["autofails"][arm, cond]
        if not vals:
            return (0.0, 0.0, cond)
        return (-statistics.median(vals), -statistics.fmean(vals), cond)

    return sorted(_conditions(agg, arm), key=key)


def _p(xs: list[int], q: float) -> float:
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


def print_arm(agg: dict, arm: str, perf: dict) -> None:
    print(
        f"\n{'=' * 100}\n=== {arm}: {ARMS[arm]} -- 3 judges x 15 packets\n{'=' * 100}"
    )
    print(
        f"{'condition':<34}{'n':>4}{'min':>5}{'p10':>5}{'med':>6}{'max':>5}{'mean':>6}"
        f"{'AF':>4}{'med_s':>8}{'p90_s':>7}{'GB':>6}"
    )
    for cond in _rank(agg, arm):
        s = agg["totals"][arm, cond]
        pf = _condition_perf(cond, perf)
        print(
            f"{cond:<34}{len(s):>4}{min(s):>5}{_p(s, 0.1):>5}{statistics.median(s):>6.1f}"
            f"{max(s):>5}{statistics.fmean(s):>6.2f}{agg['autofails'][arm, cond]:>4}"
            f"{pf['med_lat']:>8.2f}{pf['p90_lat']:>7.2f}{pf['size_gb']:>6.1f}"
        )
        hist = {v: s.count(v) for v in sorted(set(s), reverse=True)}
        print(f"{'':<4}histogram {hist}")
        for c in CRITERIA:
            v = agg["per_criterion"][arm, cond][c]
            print(
                f"{'':<8}{c:<12} med={statistics.median(v):>3.1f} min={min(v)} "
                f"max={max(v)} mean={statistics.fmean(v):.2f}"
            )


def print_judges(agg: dict, arm: str) -> None:
    print(f"\n--- {arm}: per-judge median, and each judge's own ranking ---")
    print(f"{'condition':<34}" + "".join(f"{'judge' + str(j):>9}" for j in JUDGES))
    for cond in _rank(agg, arm):
        cells = "".join(
            f"{statistics.median(agg['by_judge'][arm, cond, j]):>9.1f}"
            if agg["by_judge"][arm, cond, j]
            else f"{'-':>9}"
            for j in JUDGES
        )
        print(f"{cond:<34}{cells}")
    for j in JUDGES:
        order = sorted(
            _conditions(agg, arm),
            key=lambda c: (
                -statistics.median(agg["by_judge"][arm, c, j] or [0]),
                -statistics.fmean(agg["by_judge"][arm, c, j] or [0]),
                c,
            ),
        )
        print(f"    judge{j} order: {' > '.join(order)}")

    # Agreement on the raw per-output total, the same statistic v1 reported.
    deltas: list[int] = []
    unanimous = comparable = 0
    for pid in agg["packets"][arm]:
        for letter, per_judge in agg["raw"][pid].items():
            vals = [v for v in per_judge.values() if v is not None]
            if len(vals) < 2:
                continue
            comparable += 1
            if len(set(vals)) == 1 and len(vals) == len(JUDGES):
                unanimous += 1
            deltas += [abs(a - b) for a, b in itertools.combinations(vals, 2)]
    print(
        f"    agreement: mean |delta| {statistics.fmean(deltas):.2f}, max {max(deltas)}, "
        f"unanimous on the exact total {unanimous}/{comparable} outputs"
    )


def _packet_score(cell: dict, rule: str) -> float | None:
    vals = list(cell["totals"])
    if rule == "zero":
        vals += [0] * cell["autofails"]
    return statistics.median(vals) if vals else None


def print_head_to_head(agg: dict, arm: str) -> None:
    print(f"\n--- {arm}: per-packet head-to-head (W-T-L for the left condition) ---")
    print(f"{'pair':<62}{'AF excluded':>16}{'AF = 0':>14}")
    conds = _conditions(agg, arm)
    for left, right in itertools.combinations(conds, 2):
        cells = {}
        for rule in ("excluded", "zero"):
            w = t = losses = 0
            for pid in agg["packets"][arm]:
                a = _packet_score(agg["per_packet"][arm, left, pid], rule)
                b = _packet_score(agg["per_packet"][arm, right, pid], rule)
                if a is None or b is None:
                    continue
                w, t, losses = (
                    (w + 1, t, losses)
                    if a > b
                    else (w, t, losses + 1)
                    if a < b
                    else (w, t + 1, losses)
                )
            cells[rule] = (w, t, losses)
        e, z = cells["excluded"], cells["zero"]
        flag = "" if e == z else "  <- rule changes the record"
        print(
            f"{left + ' vs ' + right:<62}{f'{e[0]}-{e[1]}-{e[2]}':>16}{f'{z[0]}-{z[1]}-{z[2]}':>14}{flag}"
        )
    r_exc, r_zero = _rank(agg, arm, "excluded"), _rank(agg, arm, "zero")
    if r_exc != r_zero:
        print(
            f"    RANKING INVERSION between conventions:\n      excluded: {r_exc}\n      zero    : {r_zero}"
        )
    else:
        print("    ranking identical under both auto-fail conventions")


def print_hard_fixture(agg: dict) -> None:
    print(
        f"\n{'=' * 100}\n=== {HARD_FIXTURE}: does the code-switch fixture discriminate, or saturate?\n{'=' * 100}"
    )
    print(
        f"{'arm':<6}{'condition':<34}{'f08 med':>9}{'arm med (all 15)':>19}{'delta':>8}{'AF on f08':>11}"
    )
    for arm in ARMS:
        for cond in _rank(agg, arm):
            cell = agg["per_packet"][arm, cond, f"{arm}/{HARD_FIXTURE}"]
            here = statistics.median(cell["totals"]) if cell["totals"] else float("nan")
            overall = statistics.median(agg["totals"][arm, cond])
            print(
                f"{arm:<6}{cond:<34}{here:>9.1f}{overall:>19.1f}{here - overall:>8.1f}"
                f"{cell['autofails']:>11}"
            )
        f08_scores = [
            s
            for cond in _conditions(agg, arm)
            for s in agg["per_packet"][arm, cond, f"{arm}/{HARD_FIXTURE}"]["totals"]
        ]
        spread = max(f08_scores) - min(f08_scores) if f08_scores else 0
        print(
            f"       -> {arm} spread on f08: {spread} points (min {min(f08_scores)}, max {max(f08_scores)})"
        )


def main() -> None:
    mapping = json.loads((BASE / "letter_mapping_v2.json").read_text())
    perf = _perf_index()
    agg = collect(mapping)

    n_scores = sum(len(v) for v in agg["totals"].values()) + sum(
        agg["autofails"].values()
    )
    print("=== population ===")
    print(
        f"arms          : {len(ARMS)} x 3 independent judges = {len(ARMS) * 3} judges"
    )
    print(f"packets       : {len(mapping)} (15 per arm)")
    print(f"scored outputs: {n_scores} (auto-fails: {sum(agg['autofails'].values())})")

    for arm in ARMS:
        print_arm(agg, arm, perf)
        print_judges(agg, arm)
        print_head_to_head(agg, arm)

    if agg["autofail_detail"]:
        print(
            f"\n{'=' * 100}\n=== auto-fails (excluded from the distributions above)\n{'=' * 100}"
        )
        for arm, pid, letter, cond, judge, note in sorted(agg["autofail_detail"]):
            print(f"  {pid} letter {letter} = {cond} (judge{judge}): {note}")

    print_hard_fixture(agg)


if __name__ == "__main__":
    main()
