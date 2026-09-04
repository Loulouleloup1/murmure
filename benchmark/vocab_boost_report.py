#!/usr/bin/env python3
"""Report the logits-bias campaign: one table over every arm in `results-boost.local.jsonl`.

Companion to `vocab_curve.py`, same shape, different mechanism. Scoring is the SAME
`vocab_report.TERMS`/`verdict` used by the whole prior campaign, so `repairs` here means
exactly what it meant there: the baseline produced a KNOWN mangling and the arm produced
the correct spelling.

Adds one thing the prompt campaign never needed: an INJECTION count for the
`boostabsent*` control -- terms invented to not occur anywhere in this corpus, counted by
plain substring search (not the `verdict` machinery, which only knows about the 5 tracked
terms) across every file that arm ran on, not just the 106 damaged occurrences.

It never prints a transcript: the corpus is Louis's client and internal work content.
"""

from __future__ import annotations

import json
import re
import statistics
import sys
import unicodedata
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from vocab_boost import ABSENT_TERMS
from vocab_report import TERMS, fold, verdict

SHORT = {
    "Claude Code": "CC",
    "Trucost": "TC",
    "WeeFin": "WF",
    "Cursor": "CU",
    "Superwhisper": "SW",
}


def load(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.open() if line.strip()]


def word_re(term: str) -> re.Pattern:
    return re.compile(r"\b" + re.escape(fold(term)) + r"\b")


def main() -> int:
    here = Path(__file__).parent
    results_path = (
        Path(sys.argv[1]) if len(sys.argv) > 1 else here / "results-boost.local.jsonl"
    )
    meta_path = (
        Path(sys.argv[2])
        if len(sys.argv) > 2
        else here / "jobs-boost.local.meta.local.json"
    )

    rows = load(results_path)
    errors = [r for r in rows if r.get("error")]
    rows = [r for r in rows if not r.get("error")]
    if errors:
        print(f"{len(errors)} decode(s) failed")
        for e in errors[:5]:
            print(f"  {e['id']}: {e['error']}")

    meta = json.loads(meta_path.read_text())
    picks = {p["id"]: p for p in meta["picks"]}
    order = list(meta["arms"])

    by: dict[str, dict[str, dict]] = defaultdict(dict)
    for r in rows:
        fid, arm = r["id"].split("#")
        by[fid][arm] = r

    base_words = statistics.mean(
        len(g["baseline"]["text"].split()) for g in by.values() if "baseline" in g
    )

    ceiling: Counter = Counter()
    for fid, g in by.items():
        if "baseline" not in g:
            continue
        pick = picks.get(fid, {})
        for t in set(pick.get("mangled", {})) | set(pick.get("correct", {})):
            if verdict(g["baseline"]["text"], t) == "mangled":
                ceiling[t] += 1
    measured = [t for t in TERMS if ceiling[t]]

    print(
        f"baseline: {base_words:.1f} words/file, {sum(ceiling.values())} repairable pairs ("
        + ", ".join(f"{SHORT.get(t, t)} {ceiling[t]}" for t in measured)
        + ")"
    )
    print()

    head = f"{'arm':<15}" + "".join(f"{SHORT.get(t, t):>5}" for t in measured)
    print(
        head
        + f"{'total':>7}{'words':>8}{'sim':>7}{'regr':>6}{'decodeS':>9}{'filterS':>9}"
    )

    for arm in order:
        sample = next((g[arm] for g in by.values() if arm in g), None)
        if sample is None:
            continue
        c: Counter = Counter()
        deltas, sims, decode_s, filter_s, regressions = [], [], [], [], 0
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
            decode_s.append(g[arm]["decodeSeconds"])
            filter_s.append(g[arm].get("filterSeconds", 0.0))
        toll = 100 * statistics.mean(deltas) / base_words
        print(
            f"{arm:<15}"
            + "".join(f"{c[t]:>5}" for t in measured)
            + f"{sum(c.values()):>7}{toll:>7.1f}%"
            + f"{statistics.median(sims):>7.3f}{regressions:>6}"
            + f"{statistics.median(decode_s):>9.3f}{statistics.median(filter_s):>9.4f}"
        )

    print()
    print("INJECTION CONTROL -- terms invented to occur nowhere in this corpus")
    print(f"  candidates: {', '.join(ABSENT_TERMS)}")
    print(
        "  a RAW hit only means the word is present in the arm's output; an INJECTION is"
        " a raw hit that was NOT already in the baseline transcript for that same file --"
        " one candidate here (Obsidian, a real note-taking app) turned out to already be"
        " in Louis's baseline vocabulary, so raw hits alone would have overstated the risk."
    )
    patterns = {t: word_re(t) for t in ABSENT_TERMS}
    for arm in order:
        if not meta["arms"][arm]["boost"]:
            continue
        boosted_terms = set(meta["arms"][arm]["boost"]["terms"])
        if not (boosted_terms & set(ABSENT_TERMS)):
            continue
        raw: Counter = Counter()
        injected: Counter = Counter()
        n_files = 0
        for fid, g in by.items():
            if arm not in g or "baseline" not in g:
                continue
            n_files += 1
            low = fold(g[arm]["text"])
            base_low = fold(g["baseline"]["text"])
            for t, pat in patterns.items():
                if pat.search(low):
                    raw[t] += 1
                    if not pat.search(base_low):
                        injected[t] += 1
        print(
            f"  {arm:<15} {sum(raw.values())} raw hit(s), "
            f"{sum(injected.values())} true injection(s) across {n_files} files"
        )
        for t in ABSENT_TERMS:
            if raw[t]:
                print(f"      {t:<12}raw={raw[t]:<3}injected={injected[t]}")
        if not sum(raw.values()):
            print("      none")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
