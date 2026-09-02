#!/usr/bin/env python3
"""Read the probe's JSONL and report the noise floor, then the arms.

Two modes, and the order matters: `floor` establishes how much the decoder moves when
NOTHING moves, and no number the `arms` mode prints means anything until that is known.
Murmure has been burned by exactly this before (commit adb86be: a 0.488 similarity read
as audio contamination turned out to be the model's own instability, the same bytes
returning 484, 484, 372 and 484 characters across four runs).

Prints counts, ratios and term outcomes. It never prints a transcript: the corpus is
Louis's client and internal work content.
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

# One entry per measured term: the spelling that counts as right, and the forms that
# count as a specific mangling. Anything else is "absent".
#
# The mangled patterns list forms produced by BOTH models. The `small`-only forms came
# from `vocab_mine.py`; the rest (`wifin`, `trou cost`, `trocos`, `super swiper`) were
# produced by `large-v3-turbo` itself and were found by `vocab_headroom.py` on the
# baseline pass. Scoring the arms against `small`'s vocabulary of errors alone would
# have miscounted our own model's failures as "the term is simply absent".
TERMS = {
    "Claude Code": (
        r"\bclaude[ -]?code\b",
        r"\b(cloud ?code|clou de code|cloude code|claudecode)\b",
    ),
    "WeeFin": (
        r"\bweefin\b",
        r"\b(wefin|wefinn|wefine|wifine|wee fine|we fine|wifin)\b",
    ),
    "Trucost": (
        r"\btrucost\b",
        r"\b(true ?cost|trop ?coste?|tru ?coste|trou ?cost|trocos|trocost)\b",
    ),
    "Cursor": (r"\bcursor\b", r"\b(curesor|keursor)\b"),
    "Superwhisper": (
        r"\bsuperwhisper\b",
        r"\b(superspiber|superwisper|super whisper|super swiper)\b",
    ),
}


def fold(s: str) -> str:
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9 ]", " ", s.lower())).strip()


def similarity(a: str, b: str) -> float:
    return SequenceMatcher(None, fold(a), fold(b)).ratio()


def load(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.open() if line.strip()]


def verdict(text: str, term: str) -> str:
    """`right`, `mangled` or `absent` -- what this decode did with one term."""
    right, wrong = TERMS[term]
    low = fold(text)
    if re.search(right, low):
        return "right"
    if re.search(wrong, low):
        return "mangled"
    return "absent"


def report_floor(rows: list[dict]) -> None:
    by_file: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        by_file[r["id"].split("#")[0]].append(r)

    print("NOISE FLOOR -- identical file, identical options, repeated decodes")
    print(
        f"{'file':<12}{'n':>3}{'audio s':>9}{'distinct':>10}{'chars':>18}"
        f"{'min pairwise sim':>18}{'median sim':>12}"
    )
    all_min = []
    for fid, group in sorted(by_file.items(), key=lambda kv: kv[1][0]["audioSeconds"]):
        texts = [r["text"] for r in group]
        lens = sorted(len(t) for t in texts)
        sims = [
            similarity(texts[i], texts[j])
            for i in range(len(texts))
            for j in range(i + 1, len(texts))
        ]
        distinct = len(set(texts))
        all_min.append(min(sims))
        span = f"{lens[0]}-{lens[-1]}"
        print(
            f"{fid:<12}{len(group):>3}{group[0]['audioSeconds']:>9.1f}"
            f"{distinct:>4}/{len(group):<5}{span:>18}"
            f"{min(sims):>18.3f}{statistics.median(sims):>12.3f}"
        )

    print()
    print(f"worst pairwise similarity anywhere in the floor: {min(all_min):.3f}")

    print()
    print("Per-term stability across identical repeats:")
    for term in TERMS:
        flips = 0
        seen = 0
        for fid, group in by_file.items():
            vs = {verdict(r["text"], term) for r in group}
            if vs == {"absent"}:
                continue
            seen += 1
            if len(vs) > 1:
                flips += 1
        if seen:
            print(
                f"  {term:<14} present in {seen} file(s); "
                f"verdict changed across repeats in {flips}"
            )


def report_arms(rows: list[dict], meta: dict) -> None:
    picks = {p["id"]: p for p in meta["picks"]}
    by_file: dict[str, dict[str, dict]] = defaultdict(dict)
    for r in rows:
        fid, arm = r["id"].split("#")
        by_file[fid][arm] = r

    arms = ["baseline", "terms", "unrelated", "overflow"]

    print("PROMPT TOKEN COST")
    for arm in arms:
        sample = next(
            (r for g in by_file.values() for a, r in g.items() if a == arm), None
        )
        if sample:
            print(
                f"  {arm:<12} {sample['promptTokenCount']:>4} tokens encoded, "
                f"{sample['promptTokensKept']:>4} kept by the decoder "
                f"(budget 111)"
            )

    print()
    print("LATENCY (decode seconds per audio second)")
    for arm in arms:
        rates = [
            g[arm]["decodeSeconds"] / max(g[arm]["decodedSeconds"], 0.01)
            for g in by_file.values()
            if arm in g and g[arm]["decodedSeconds"]
        ]
        if rates:
            print(
                f"  {arm:<12} median {statistics.median(rates):.4f}  "
                f"mean {statistics.mean(rates):.4f}  n={len(rates)}"
            )

    print()
    print("TERM OUTCOMES -- baseline verdict vs each prompt arm")
    print("  `repaired` is the only unambiguous win: the baseline produced a KNOWN")
    print("  mangling and the arm produced the correct spelling. `appeared` is scored")
    print("  apart from it on purpose -- a term absent from the baseline that shows up")
    print("  once its spelling is in the prompt may be a repair, but it may equally be")
    print(
        "  the decoder echoing a prompt word, and this corpus cannot tell them apart."
    )
    for arm in ("terms", "unrelated", "overflow"):
        table: Counter = Counter()
        per_term: dict[str, Counter] = defaultdict(Counter)
        for fid, g in by_file.items():
            if "baseline" not in g or arm not in g:
                continue
            pick = picks.get(fid, {})
            relevant = set(pick.get("mangled", {})) | set(pick.get("correct", {}))
            for term in relevant:
                b, a = (
                    verdict(g["baseline"]["text"], term),
                    verdict(g[arm]["text"], term),
                )
                k = {
                    ("mangled", "right"): "repaired",
                    ("absent", "right"): "appeared",
                    ("right", "mangled"): "NEWLY MANGLED",
                    ("right", "absent"): "LOST",
                    ("right", "right"): "kept right",
                    ("mangled", "mangled"): "still mangled",
                    ("absent", "absent"): "still absent",
                    ("mangled", "absent"): "mangled -> absent",
                    ("absent", "mangled"): "absent -> mangled",
                }[(b, a)]
                table[k] += 1
                per_term[term][k] += 1
        print(f"\n  arm = {arm}")
        for k in (
            "repaired",
            "appeared",
            "NEWLY MANGLED",
            "LOST",
            "kept right",
            "still mangled",
            "still absent",
            "mangled -> absent",
            "absent -> mangled",
        ):
            print(f"    {k:<20}{table[k]:>5}")
        for term, c in sorted(per_term.items()):
            print(
                f"      {term:<14}"
                + "  ".join(f"{k}={v}" for k, v in sorted(c.items()))
            )

    print()
    print("UNCLASSIFIED -- arm output matching NEITHER the correct spelling nor any")
    print(
        "known-wrong form. This bucket exists because scoring on the ABSENCE of known"
    )
    print(
        "manglings would let a novel mangling introduced by the prompt read as a fix."
    )
    print(
        "Scoring is positive (the correct literal spelling must be present), so a novel"
    )
    print(
        "mangling lands here instead -- but if this bucket is large, the pattern set is"
    )
    print("not describing the data and every number above needs re-reading first.")
    from vocab_headroom import near_forms

    for arm in ("baseline", "terms", "unrelated", "overflow"):
        forms: Counter = Counter()
        n = 0
        for fid, g in by_file.items():
            if arm not in g:
                continue
            pick = picks.get(fid, {})
            for term in set(pick.get("mangled", {})) | set(pick.get("correct", {})):
                if verdict(g[arm]["text"], term) == "absent":
                    n += 1
                    for frag in near_forms(g[arm]["text"], term):
                        forms[f"{term}: {frag}"] += 1
        top = ", ".join(f"{f!r}x{c}" for f, c in forms.most_common(6))
        print(f"  {arm:<12} {n:>4} unclassified (file, term) pairs   {top}")

    print()
    print("REST OF THE TRANSCRIPT -- similarity to baseline, whole text")
    for arm in ("terms", "unrelated"):
        sims = [
            similarity(g["baseline"]["text"], g[arm]["text"])
            for g in by_file.values()
            if "baseline" in g and arm in g
        ]
        lens_b = [
            len(g["baseline"]["text"]) for g in by_file.values() if "baseline" in g
        ]
        lens_a = [len(g[arm]["text"]) for g in by_file.values() if arm in g]
        print(
            f"  {arm:<12} median sim {statistics.median(sims):.3f}  "
            f"min {min(sims):.3f}  "
            f"n below 0.90: {sum(1 for s in sims if s < 0.90)}/{len(sims)}  "
            f"total chars {sum(lens_b)} -> {sum(lens_a)}"
        )


def main() -> int:
    kind, path = sys.argv[1], Path(sys.argv[2])
    rows = [r for r in load(path) if not r.get("error")]
    errors = [r for r in load(path) if r.get("error")]
    if errors:
        print(f"{len(errors)} decode(s) failed")
    if kind == "floor":
        report_floor(rows)
    else:
        meta = json.loads(Path(sys.argv[3]).read_text())
        report_arms(rows, meta)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
