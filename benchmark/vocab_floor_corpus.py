#!/usr/bin/env python3
"""The noise floor measured on the SAME 109 files the arms run on.

Two full baseline passes, in two separate processes, with identical options. Whatever
spread shows up here is the decoder talking to itself, and no difference between arms
is meaningful below it.

Reported per file rather than as one aggregate on purpose. A single unstable recording
in the 109 is enough to make a global "the floor is zero" misleading, so the unstable
files are named (by id) and the arms report has to exclude them or treat them apart.
"""

from __future__ import annotations

import json
import sys
from difflib import SequenceMatcher
from pathlib import Path

from vocab_report import TERMS, verdict


def load(path: Path) -> dict[str, str]:
    out = {}
    for line in path.open():
        r = json.loads(line)
        if not r.get("error"):
            out[r["id"].split("#")[0]] = r["text"]
    return out


def main() -> int:
    a, b = load(Path(sys.argv[1])), load(Path(sys.argv[2]))
    shared = sorted(set(a) & set(b))

    identical = [f for f in shared if a[f] == b[f]]
    differing = [f for f in shared if a[f] != b[f]]

    print(f"files decoded in both passes: {len(shared)}")
    print(f"byte-identical across the two processes: {len(identical)}")
    print(f"differing: {len(differing)}")
    print()

    if differing:
        print(
            "UNSTABLE FILES -- the floor is NOT zero on these, and any arm difference"
        )
        print("on them has to clear their own spread before it means anything:")
        for f in differing:
            sim = SequenceMatcher(None, a[f], b[f]).ratio()
            flips = [t for t in TERMS if verdict(a[f], t) != verdict(b[f], t)]
            print(
                f"  {f}  sim={sim:.3f}  chars {len(a[f])} vs {len(b[f])}"
                + (f"  TERM VERDICT FLIPPED: {flips}" if flips else "")
            )
        print()

    # The number that actually gates the verdict: does an identical re-decode ever
    # change what a term looks like? A term-level floor above zero would mean some of
    # the arms' repairs are just the decoder wobbling.
    flips = 0
    checked = 0
    for f in shared:
        for t in TERMS:
            va, vb = verdict(a[f], t), verdict(b[f], t)
            if va == "absent" and vb == "absent":
                continue
            checked += 1
            if va != vb:
                flips += 1
    print(
        f"term-level floor: {flips} verdict flips out of {checked} (file, term) pairs "
        f"where the term is present in at least one pass"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
