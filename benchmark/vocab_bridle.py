#!/usr/bin/env python3
"""Build the job file for the bridling-rule campaign (round 2 of the logits-bias work).

Companion to `vocab_boost.py`, same corpus, same 3 repair terms, but the question this
round asks is the opposite one: `boost30x10` in the first round showed the filter
injecting `dbt` -- a term Louis never said even once at baseline -- into 9 of 109 files,
23 times, whenever the filter carried 30 terms at strength 10. The control arm in that
round (`boostabsent10`) could not have caught this: its 5 invented candidates were all
long, phonetically distinctive words, exactly the shape that does NOT misfire. This round
puts deliberately short, real jargon terms IN the boosted list on purpose, and tests
three candidate rules meant to make a boost safe to point at a free-form vocabulary
list.

Reuses the SAME 109-file selection as the whole campaign (`jobs-arms2.local.meta.local.json`
via `jobs-boost.local.meta.local.json`, which just carries it through). `baseline` is NOT
re-decoded here -- it is deterministic (no prompt, no filter) and was already shown to
reproduce byte-for-byte across the first round's harness change
(`2026-09-vocabulary-logits-bias.md` §1); this report pulls it from
`results-boost.local.jsonl` instead of paying for 109 more identical decodes.

Boosted term list, same across all 4 arms below (only the STRENGTH assigned to each term
changes per arm) -- `tokencount` on each, with the leading space `VocabularyBoostFilter`
actually uses:

    Claude Code   3 tokens   known repair term (60 damaged occurrences)
    Trucost       2 tokens   known repair term (35)
    WeeFin        3 tokens   known repair term (10)
    PR            1 token    Louis's own example of a short, phonetically ambiguous term
    dbt           2 tokens   confirmed 100% injection at strength 10 / 30 terms (9/9 new)
    MDI           2 tokens   partial injection (2/7 files newly show it, the rest already
                             had it at baseline -- MDI is real vocabulary Louis says a lot)
    esgc          3 tokens   same token count as Claude Code/WeeFin, still shows 1 real
                             injection at strength 10/30 terms -- the case that breaks a
                             pure token-count floor

Note that `Trucost` (2 tokens, wanted) and `dbt`/`MDI` (2 tokens, unwanted) are the SAME
length, and `esgc` (3 tokens, unwanted) is the SAME length as `Claude Code`/`WeeFin`
(wanted). A rule keyed on token count alone cannot separate these -- that is the point of
including them together in one arm.

Arms:
  noBridle       -- uniform continuation=10, firstToken=10/3 for all 7 terms. The current
                     shipped mechanism, unmodified, extended onto this exact term set (so
                     PR's number under plain boosting is measured directly, which no prior
                     arm did).
  floorFilter    -- token-count floor at N=3: only `Claude Code`, `WeeFin`, `esgc` keep any
                     bonus; `Trucost`, `PR`, `dbt`, `MDI` get 0/0 (i.e. behave exactly like
                     baseline). Demonstrates the floor's failure mode: it cannot admit
                     `Trucost` while excluding `esgc`, because `Trucost` (2) < `esgc` (3).
  noFirstToken   -- firstTokenBonus=0 for all 7 terms, continuationBonus=10 unchanged. For
                     a 1-token term (`PR`) this is a structural zero: `matched` can never
                     exceed 0, so the only branch reachable is the one now worth nothing.
                     Cheapest candidate to test -- no new Swift beyond what round 1 shipped
                     would have needed, just a different number in the job file.
  scaledByTokens -- continuation_i = 10 * clamp((tokenCount_i - 1) / 2, 0, 1), first_i =
                     continuation_i / 3. PR -> 0 (1 token), Trucost/dbt/MDI -> 5 (2 tokens,
                     half strength), Claude Code/WeeFin/esgc -> 10 (3+ tokens, unchanged).
                     Same floor-shaped blind spot as `floorFilter` on `esgc`, but softer on
                     the 2-token terms instead of an all-or-nothing cut.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

BOOST_TERMS = ["Claude Code", "Trucost", "WeeFin", "PR", "dbt", "MDI", "esgc"]

# Measured by `tokencount` on ` <term>` (leading space, no trailing punctuation --
# matches exactly what `VocabularyBoostFilter`/`main.swift` encodes).
TOKEN_COUNTS = {
    "Claude Code": 3,
    "Trucost": 2,
    "WeeFin": 3,
    "PR": 1,
    "dbt": 2,
    "MDI": 2,
    "esgc": 3,
}

BASE_STRENGTH = 10.0


def term_spec(term: str, continuation: float) -> dict:
    return {
        "term": term,
        "continuationBonus": continuation,
        "firstTokenBonus": round(continuation / 3, 4),
    }


def arm_no_bridle() -> list[dict]:
    return [term_spec(t, BASE_STRENGTH) for t in BOOST_TERMS]


def arm_floor(n: int) -> list[dict]:
    return [
        term_spec(t, BASE_STRENGTH if TOKEN_COUNTS[t] >= n else 0.0)
        for t in BOOST_TERMS
    ]


def arm_no_first_token() -> list[dict]:
    return [
        {"term": t, "continuationBonus": BASE_STRENGTH, "firstTokenBonus": 0.0}
        for t in BOOST_TERMS
    ]


def arm_scaled() -> list[dict]:
    specs = []
    for t in BOOST_TERMS:
        scale = max(0.0, min(1.0, (TOKEN_COUNTS[t] - 1) / 2))
        specs.append(term_spec(t, round(BASE_STRENGTH * scale, 4)))
    return specs


def build_arms() -> dict[str, list[dict]]:
    return {
        "noBridle": arm_no_bridle(),
        "floorFilter": arm_floor(3),
        "noFirstToken": arm_no_first_token(),
        "scaledByTokens": arm_scaled(),
    }


def main() -> int:
    out = Path(sys.argv[1])
    meta_in = Path(sys.argv[2])
    meta = json.loads(meta_in.read_text())
    arms = build_arms()

    tasks = [
        {
            "id": f"{p['id']}#{arm}",
            "wav": p["wav"],
            "arm": arm,
            "prompt": None,
            "boost": spec,
        }
        for p in meta["picks"]
        for arm, spec in arms.items()
    ]

    out.write_text(json.dumps({"tasks": tasks}, ensure_ascii=False))
    meta_path = out.with_suffix(".meta.local.json")
    meta_path.write_text(
        json.dumps(
            {"picks": meta["picks"], "arms": arms, "tokenCounts": TOKEN_COUNTS},
            ensure_ascii=False,
            indent=1,
        )
    )

    print(
        f"{len(tasks)} decodes = {len(meta['picks'])} files x {len(arms)} arms -> {out}"
    )
    for arm, spec in arms.items():
        print(
            f"  {arm:<15}"
            + " ".join(f"{s['term']}={s['continuationBonus']:g}" for s in spec)
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
