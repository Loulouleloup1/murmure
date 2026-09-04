#!/usr/bin/env python3
"""Build one more round-2 bridling arm: the same 7-term list as `vocab_bridle.py`, at a
strength never tested before (`continuationBonus=30`, `firstTokenBonus=10`), uniform
across all terms, no bridle at all.

This was meant as a stress test of `PR` specifically -- does the one term that showed
zero injection at strength 10 (`vocab_bridle.py`'s `noBridle` arm) start misfiring at a
higher strength? The result was not a clean answer to that question: at strength 30 the
decoder itself collapses for every term in the filter, not just `PR` (median word count
2.5x the baseline, similarity 0.016, decode time 1.97s -> 18.8s median). See
`docs/benchmarks/2026-09-vocabulary-logits-bias.md`, round 2 §3.

Usage:  vocab_bridle_strength.py <out.json> <meta.json>
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from vocab_bridle import BOOST_TERMS, term_spec

STRENGTH = 30.0
ARM_NAME = "noBridle30"


def main() -> int:
    out = Path(sys.argv[1])
    meta = json.loads(Path(sys.argv[2]).read_text())
    spec = [term_spec(t, STRENGTH) for t in BOOST_TERMS]

    tasks = [
        {
            "id": f"{p['id']}#{ARM_NAME}",
            "wav": p["wav"],
            "arm": ARM_NAME,
            "prompt": None,
            "boost": spec,
        }
        for p in meta["picks"]
    ]
    out.write_text(json.dumps({"tasks": tasks}, ensure_ascii=False))
    meta_path = out.with_suffix(".meta.local.json")
    meta_path.write_text(
        json.dumps(
            {"picks": meta["picks"], "arms": {ARM_NAME: spec}},
            ensure_ascii=False,
            indent=1,
        )
    )
    print(f"{len(tasks)} decodes -> {out}")
    print(
        f"  {ARM_NAME:<15}"
        + " ".join(f"{s['term']}={s['continuationBonus']:g}" for s in spec)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
