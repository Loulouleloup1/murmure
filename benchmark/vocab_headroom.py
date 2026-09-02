#!/usr/bin/env python3
"""What Murmure's OWN model does with the terms Superwhisper mangled.

This runs before any prompt comparison, and it can end the experiment on its own. The
candidate set was selected on Superwhisper transcripts, and Superwhisper's model key
for 1 410 of those 1 469 recordings is `small` -- three model sizes below Murmure's
`large-v3-turbo`. If the larger model already spells the terms correctly, there is no
headroom for a prompt to recover and the honest answer is "nothing to fix here", not
"the prompt did not help".

For each file where Superwhisper saw a term (right or wrong), it reports what our
baseline produced: the correct spelling, a mangling we already know the shape of, or
something else. `something else` is the interesting bucket -- it is where our model
invents a form the curated patterns do not cover -- so its fragments are surfaced,
short and de-contextualised, to be folded back into the patterns.

Prints no transcripts. Fragments are capped at three words.
"""

from __future__ import annotations

import json
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from pathlib import Path

from vocab_report import TERMS, fold


def near_forms(text: str, term: str, threshold: float = 0.62) -> list[str]:
    """Word n-grams in `text` that look like `term` without matching either pattern.

    Deliberately a lower threshold than the miner's: here we already know the file is
    about this term, so the prior is much stronger and the false-positive cost lower.
    """
    target = re.sub(r"[^a-z0-9]", "", fold(term))
    words = fold(text).split()
    hits = []
    for n in (1, 2, 3):
        for i in range(len(words) - n + 1):
            frag = " ".join(words[i : i + n])
            f = frag.replace(" ", "")
            if not f or abs(len(f) - len(target)) > max(3, len(target) // 2):
                continue
            if SequenceMatcher(None, f, target).ratio() >= threshold:
                hits.append(frag)
    return hits


def main() -> int:
    results = Path(sys.argv[1])
    meta = json.loads(Path(sys.argv[2]).read_text())
    picks = {p["id"]: p for p in meta["picks"]}

    rows = {}
    for line in results.open():
        r = json.loads(line)
        if not r.get("error"):
            rows[r["id"].split("#")[0]] = r["text"]

    print("HEADROOM -- what large-v3-turbo does where small got it wrong (or right)")
    print()
    buckets: dict[str, Counter] = defaultdict(Counter)
    unknown_forms: dict[str, Counter] = defaultdict(Counter)

    for fid, pick in picks.items():
        text = rows.get(fid)
        if text is None:
            continue
        for term in set(pick["mangled"]) | set(pick["correct"]):
            sw = "sw-wrong" if term in pick["mangled"] else "sw-right"
            right, wrong = TERMS[term]
            low = fold(text)
            if re.search(right, low):
                ours = "we-right"
            elif re.search(wrong, low):
                ours = "we-mangled"
            else:
                ours = "we-absent"
                for frag in near_forms(text, term):
                    unknown_forms[term][frag] += 1
            buckets[term][(sw, ours)] += 1

    for term in sorted(buckets):
        print(f"## {term}")
        total = sum(buckets[term].values())
        for (sw, ours), n in sorted(buckets[term].items()):
            print(f"   {sw:<10} -> {ours:<12} {n:>4}  ({n / total:.0%})")
        if unknown_forms[term]:
            forms = ", ".join(
                f"{f!r}x{c}" for f, c in unknown_forms[term].most_common(8)
            )
            print(f"   fragments in the we-absent files: {forms}")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
