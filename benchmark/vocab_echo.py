#!/usr/bin/env python3
"""Measure prompt-echo directly, instead of caveating it.

The problem this closes: in the `terms` arm, a term absent from the baseline that
appears once its spelling is in the prompt might be a genuine recovery, or might be the
decoder simply repeating a word it was shown. With no ground truth the `terms` arm
alone cannot separate them.

The `unrelated` arm can, because its 35 French nouns are words Louis almost certainly
did not say in these 109 recordings. Their null expectation is zero, so any appearance
is echo, observed rather than inferred.

The design is a symmetric 2x2, which is what makes it a measurement and not a guess.
Each word list is counted in the arm that DOES prompt it and in the arm that does NOT:

                       word list = technical terms   word list = French nouns
    arm `terms`        prompted   <- effect          not prompted <- control
    arm `unrelated`    not prompted <- control       prompted   <- echo

A word appearing only when it is in the prompt is echo. A word appearing at the same
rate either way is ordinary decoder variation and nothing to do with prompting.

Also reports the reverse direction, which a presence scan alone would miss: a prompt
word REPLACING something Louis did say. That does not show up as an appearance, so it
is caught as a sharp whole-transcript similarity drop against the baseline.
"""

from __future__ import annotations

import json
import re
import statistics
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from vocab_report import fold, similarity
from vocab_select import TERMS as TECH_TERMS
from vocab_select import UNRELATED

# Only single-word entries are scannable this way; a multi-word term like `Claude Code`
# is already covered by the per-term verdicts.
TECH_WORDS = sorted({t for t in TECH_TERMS if " " not in t})
NOUN_WORDS = sorted(UNRELATED)


def present(text: str, word: str) -> bool:
    return re.search(rf"\b{re.escape(fold(word))}\b", fold(text)) is not None


def load(path: Path) -> dict[str, dict[str, str]]:
    by_file: dict[str, dict[str, str]] = {}
    for line in path.open():
        r = json.loads(line)
        if r.get("error"):
            continue
        fid, arm = r["id"].split("#")
        by_file.setdefault(fid, {})[arm] = r["text"]
    return by_file


def scan(
    files: dict[str, dict[str, str]], arm: str, words: list[str]
) -> tuple[int, Counter]:
    """How many (file, word) pairs gained `word` in `arm` that the baseline lacked."""
    gained: Counter = Counter()
    n = 0
    for fid, arms in files.items():
        if "baseline" not in arms or arm not in arms:
            continue
        for w in words:
            if not present(arms["baseline"], w) and present(arms[arm], w):
                gained[w] += 1
                n += 1
    return n, gained


def main() -> int:
    files = load(Path(sys.argv[1]))
    for extra in sys.argv[2:]:
        for fid, arms in load(Path(extra)).items():
            files.setdefault(fid, {}).update(arms)

    usable = {f: a for f, a in files.items() if "baseline" in a}
    print(f"files with a baseline and at least one arm: {len(usable)}")
    print()

    print("PROMPT ECHO -- words gained over the baseline, by arm and word list")
    print("A word list should only gain words in the arm that puts it in the prompt.")
    print(f"{'':<14}{'technical terms':>20}{'French nouns':>20}")
    for arm in ("terms", "unrelated", "overflow"):
        if not any(arm in a for a in usable.values()):
            continue
        nt, gt = scan(usable, arm, TECH_WORDS)
        nn, gn = scan(usable, arm, NOUN_WORDS)
        mark_t = "prompted" if arm in ("terms", "overflow") else "control"
        mark_n = "prompted" if arm in ("unrelated", "overflow") else "control"
        print(f"  {arm:<12}{nt:>10} ({mark_t}){nn:>10} ({mark_n})")
        if gn:
            print(
                f"      nouns gained: {', '.join(f'{w}x{c}' for w, c in gn.most_common(8))}"
            )
        if gt:
            print(
                f"      terms gained: {', '.join(f'{w}x{c}' for w, c in gt.most_common(8))}"
            )

    print()
    print("ECHO RATE -- French nouns gained per file in the arm that prompts them.")
    print(
        "This is the number that lets `appeared` in the terms arm be read rather than"
    )
    print(
        "only distrusted: at zero, an appearance is much more likely a real recovery."
    )
    if any("unrelated" in a for a in usable.values()):
        n, _ = scan(usable, "unrelated", NOUN_WORDS)
        d = sum(1 for a in usable.values() if "unrelated" in a)
        print(
            f"  {n} gained across {d} files = {n / d:.3f} per file "
            f"({len(NOUN_WORDS)} nouns offered in every prompt)"
        )

    print()
    print("REVERSE DIRECTION -- a prompt word REPLACING what was said shows up as a")
    print("similarity drop, not as an appearance. Files furthest from their baseline:")
    for arm in ("terms", "unrelated", "overflow"):
        rows = [
            (similarity(a["baseline"], a[arm]), f, len(a["baseline"]), len(a[arm]))
            for f, a in usable.items()
            if arm in a
        ]
        if not rows:
            continue
        rows.sort()
        med = statistics.median(r[0] for r in rows)
        below = sum(1 for r in rows if r[0] < 0.95)
        print(f"  {arm:<12} median sim {med:.3f}   {below}/{len(rows)} below 0.95")
        for sim, f, lb, la in rows[:5]:
            print(f"      {f}  sim={sim:.3f}  chars {lb} -> {la}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
