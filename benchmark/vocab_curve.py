#!/usr/bin/env python3
"""One table over every prompt arm measured, read from all the result files at once.

`vocab_report.py` scores the four original arms against their job metadata. This
prints the whole campaign on one line per arm -- repairs per term, word toll as a
percentage of the baseline, similarity, and regressions -- because the conclusion is
a COMPARISON between arms and no single file holds them all.

It never prints a transcript: the corpus is Louis's client and internal work content.
"""

from __future__ import annotations

import json
import statistics
import sys
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from vocab_report import TERMS, fold, verdict

RESULTS = [
    "results-vocab-all.local.jsonl",
    "results-vocab-dose2.local.jsonl",
    "results-vocab-dose3.local.jsonl",
    "results-vocab-dose4.local.jsonl",
    "results-vocab-dose5.local.jsonl",
    "results-vocab-dose6.local.jsonl",
    "results-vocab-dose7.local.jsonl",
]

# Reading order, not alphabetical: forward arms, then the same reversed, then the same
# with a leading space, then both, then the truncation and control arms.
ORDER = [
    "n01", "n03", "n05", "n10", "n20", "n30",
    "n03r", "n10r", "n20r", "n30r",
    "n01s", "n03s",
    "n03rs", "n10rs", "n03sf",
    "terms", "termsB", "n35f", "unrelated", "overflow",
]


def main() -> int:
    here = Path(__file__).parent
    rows = []
    for name in RESULTS:
        path = here / name
        if not path.is_file():
            continue
        rows += [json.loads(x) for x in path.read_text().splitlines() if x.strip()]
    rows = [r for r in rows if not r.get("error")]

    meta = json.loads((here / "jobs-arms2.local.meta.local.json").read_text())
    picks = {p["id"]: p for p in meta["picks"]}

    by: dict[str, dict[str, dict]] = defaultdict(dict)
    for r in rows:
        fid, arm = r["id"].split("#")
        by[fid][arm] = r

    base = statistics.mean(len(g["baseline"]["text"].split()) for g in by.values())
    # How many (file, term) pairs the baseline actually got wrong: the ceiling.
    ceiling: Counter = Counter()
    for fid, g in by.items():
        pick = picks.get(fid, {})
        for t in set(pick.get("mangled", {})) | set(pick.get("correct", {})):
            if verdict(g["baseline"]["text"], t) == "mangled":
                ceiling[t] += 1
    short = {"Claude Code": "CC", "Trucost": "TC", "WeeFin": "WF"}
    measured = [t for t in TERMS if ceiling[t]]

    print(f"baseline: {base:.1f} words/file, {sum(ceiling.values())} repairable pairs "
          + "(" + ", ".join(f"{short.get(t, t)} {ceiling[t]}" for t in measured) + ")")
    print()
    head = f"{'arm':<9}{'enc':>5}{'kept':>5}"
    head += "".join(f"{short.get(t, t):>5}" for t in measured)
    print(head + f"{'total':>7}{'words':>8}{'sim':>7}{'regr':>6}")

    for arm in ORDER:
        sample = next((g[arm] for g in by.values() if arm in g), None)
        if sample is None:
            continue
        c: Counter = Counter()
        deltas, sims, regressions = [], [], 0
        for fid, g in by.items():
            if arm not in g or "baseline" not in g:
                continue
            pick = picks.get(fid, {})
            for t in set(pick.get("mangled", {})) | set(pick.get("correct", {})):
                before = verdict(g["baseline"]["text"], t)
                after = verdict(g[arm]["text"], t)
                if before == "mangled" and after == "right":
                    c[t] += 1
                if before == "right" and after != "right":
                    regressions += 1
            deltas.append(
                len(g[arm]["text"].split()) - len(g["baseline"]["text"].split())
            )
            sims.append(
                SequenceMatcher(
                    None, fold(g["baseline"]["text"]), fold(g[arm]["text"])
                ).ratio()
            )
        toll = 100 * statistics.mean(deltas) / base
        print(
            f"{arm:<9}{sample['promptTokenCount']:>5}{sample['promptTokensKept']:>5}"
            + "".join(f"{c[t]:>5}" for t in measured)
            + f"{sum(c.values()):>7}{toll:>7.1f}%"
            + f"{statistics.median(sims):>7.3f}{regressions:>6}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
