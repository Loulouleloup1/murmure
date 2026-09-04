#!/usr/bin/env python3
"""Build the round-2 `noFirstTokenShort` arm: the literal wording of the brief's third
candidate rule -- "first-token bonus removed for SHORT terms", not for every term in the
filter. `vocab_bridle.py`'s `noFirstToken` arm tested the stricter, global version (bonus
removed everywhere); this one removes it only below the same 3-token floor used by
`floorFilter`, keeping `Claude Code`/`WeeFin`/`esgc` fully intact.

Result (see `docs/benchmarks/2026-09-vocabulary-logits-bias.md`, round 2 §2): identical
to `floorFilter` term for term. `Trucost` still drops from 6 repairs to 0 even though it
keeps its full `continuationBonus` -- the bonus that drives repair is the same one that
drives risk, and `Trucost` is exactly as short (2 tokens) as `dbt`/`MDI`.

Usage:  vocab_bridle_short.py <out.json> <meta.json>
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from vocab_bridle import BASE_STRENGTH, BOOST_TERMS, TOKEN_COUNTS

FLOOR = 3
ARM_NAME = "noFirstTokenShort"


def build_spec() -> list[dict]:
    spec = []
    for t in BOOST_TERMS:
        first = 0.0 if TOKEN_COUNTS[t] < FLOOR else round(BASE_STRENGTH / 3, 4)
        spec.append(
            {"term": t, "continuationBonus": BASE_STRENGTH, "firstTokenBonus": first}
        )
    return spec


def main() -> int:
    out = Path(sys.argv[1])
    meta = json.loads(Path(sys.argv[2]).read_text())
    spec = build_spec()

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
        f"  {ARM_NAME:<20}"
        + " ".join(
            f"{s['term']}={s['firstTokenBonus']:g}/{s['continuationBonus']:g}"
            for s in spec
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
