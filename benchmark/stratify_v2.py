"""Stratified post-hoc read of the prompt arms: few-shot gain, or few-shot contamination?

The `cleanup_B` and `cleanup_C` variants ship three worked examples. Two of the
three demonstrate operations that some fixtures also carry -- a dictated symbol
("slash", "point" + extension) and an abandoned false start ("non attends").
`cleanup_baseline` and `cleanup_A` have no examples at all. So a win for B or C
could mean "few-shot helps" or only "few-shot helps when the example resembles
the input", which are very different claims for production.

This script partitions the 15 fixtures on a criterion fixed from the CONTENT OF
THE EXAMPLES ALONE -- never from the scores -- and reports the variant-minus-
baseline gap on each stratum separately.

It also reports the baseline's remaining headroom per stratum, because that is
what makes the two arms readable: on `gemma4-12b-qat` the "near" stratum is at
the ceiling (baseline already 8.0 on 4 of 5 fixtures), so no contamination
advantage could show there even if one existed. A stratum with no headroom
yields an inconclusive test, not a negative one, and the report must not read
the second as the first.
"""

from __future__ import annotations

import json
import pathlib
import re
import statistics
from collections import defaultdict

BASE = pathlib.Path(__file__).parent
CRITERIA = ("fidelity", "disfluency", "verbatim", "format")
JUDGES = (1, 2, 3)
BASELINE = "cleanup_baseline"
VARIANTS = ("cleanup_A", "cleanup_B", "cleanup_C")
ARMS = {"armA": "gemma4-12b-qat", "armB": "gemma4-e2b-qat"}
MAX_SCORE = 8

# The two operations the few-shot examples actually demonstrate. Fixed from
# `prompts/prompt_cleanup_B.txt`, before looking at any score.
SYMBOL = re.compile(r"\bslash\b|\bpoint\b\s+(?:yaml|yml|py|json|txt|js|md|csv)\b", re.I)
FALSE_START = re.compile(
    r"non attends|attends non|enfin non|je me suis tromp|je reprends|non non", re.I
)


def load_jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(x) for x in path.read_text().splitlines() if x.strip()]


def stratify() -> dict[str, str]:
    strata: dict[str, str] = {}
    for f in load_jsonl(BASE / "fixtures.jsonl"):
        hit = SYMBOL.search(f["raw"]) or FALSE_START.search(f["raw"])
        strata[f["id"]] = "near" if hit else "far"
    return strata


def per_fixture(arm: str, mapping: dict) -> dict[tuple[str, str], dict]:
    """(variant, fixture) -> the three judge totals, plus that cell's auto-fails."""
    cells: dict[tuple[str, str], dict] = defaultdict(
        lambda: {"totals": [], "autofails": 0}
    )
    for judge in JUDGES:
        for row in load_jsonl(BASE / "judgments_v2" / f"{arm}_judge{judge}.jsonl"):
            fixture = row["packet_id"].split("/", 1)[1]
            for letter, score in row["scores"].items():
                variant = mapping[row["packet_id"]][letter].split("/")[-1]
                cell = cells[variant, fixture]
                if score["autofail"]:
                    cell["autofails"] += 1
                else:
                    cell["totals"].append(sum(int(score[c]) for c in CRITERIA))
    return cells


def cell_score(cell: dict, rule: str) -> float | None:
    totals = list(cell["totals"]) + ([0] * cell["autofails"] if rule == "zero" else [])
    return statistics.median(totals) if totals else None


def main() -> None:
    mapping = json.loads((BASE / "letter_mapping_v2.json").read_text())
    strata = stratify()
    near = sorted(f for f, s in strata.items() if s == "near")
    far = sorted(f for f, s in strata.items() if s == "far")
    print(
        "=== strata (criterion fixed from the few-shot examples, not from scores) ==="
    )
    print(f"  near (n={len(near)}): {near}")
    print(f"  far  (n={len(far)}): {far}")

    for arm, model in ARMS.items():
        cells = per_fixture(arm, mapping)
        print(
            f"\n{'=' * 88}\n{arm} -- {model}: variant minus baseline, per stratum\n{'=' * 88}"
        )
        for rule in ("excluded", "zero"):
            print(f"  [auto-fail rule: {rule}]")
            print(
                f"    {'variant':<12}{'stratum':<9}{'n':>3}{'variant':>10}{'baseline':>10}"
                f"{'gap':>8}   W-T-L"
            )
            for variant in VARIANTS:
                for label, fixtures in (("near", near), ("far", far)):
                    pairs = [
                        (
                            cell_score(cells[variant, f], rule),
                            cell_score(cells[BASELINE, f], rule),
                        )
                        for f in fixtures
                    ]
                    pairs = [
                        (a, b) for a, b in pairs if a is not None and b is not None
                    ]
                    if not pairs:
                        continue
                    a = statistics.fmean(x for x, _ in pairs)
                    b = statistics.fmean(y for _, y in pairs)
                    w = sum(x > y for x, y in pairs)
                    t = sum(x == y for x, y in pairs)
                    losses = sum(x < y for x, y in pairs)
                    print(
                        f"    {variant:<12}{label:<9}{len(pairs):>3}{a:>10.2f}{b:>10.2f}"
                        f"{a - b:>+8.2f}   {w}-{t}-{losses}"
                    )
                print()

        # Headroom: a saturated stratum cannot express a contamination advantage.
        print(
            "  baseline headroom per stratum (an inconclusive test is not a negative one):"
        )
        for label, fixtures in (("near", near), ("far", far)):
            vals = [
                cell_score(cells[BASELINE, f], "excluded")
                for f in fixtures
                if cell_score(cells[BASELINE, f], "excluded") is not None
            ]
            at_ceiling = sum(v >= MAX_SCORE for v in vals)
            print(
                f"    {label:<9} mean {statistics.fmean(vals):.2f} | headroom "
                f"{MAX_SCORE - statistics.fmean(vals):.2f} pt | {at_ceiling}/{len(vals)} "
                f"fixtures already at {MAX_SCORE}.0"
            )


if __name__ == "__main__":
    main()
