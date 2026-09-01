"""Sample real dictations stratified by franglais density.

The question this exists to answer is Louis's, in his words: s1-mini gives him
French when his sentence is all-French and flips to English when the sentence is
heavily franglais. Nothing in the project measures that, and a length-stratified
sample (`sample_real_fixtures.py`) cannot: length and code-switching are
independent axes.

Writes `fixtures-franglais.local.jsonl` -- real work content, gitignored, never
committed (ruling R12). Prints counts and band edges only, never a transcript.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import random
import statistics

from v3_franglais import counts, franglais_density, tech_share

RECORDINGS = pathlib.Path.home() / "Documents" / "superwhisper" / "recordings"
OUT = pathlib.Path(__file__).parent / "fixtures-franglais.local.jsonl"

# Strata, set from the corpus rather than guessed. The first pass used
# [0, .05) / [.05, .15) / [.15, .30) / [.30, 1] and found 0 dictations in the top
# band and 2 in the third: Louis's real speech is French grammar with English
# technical nouns, not English grammar. So the axis splits in two --
# `franglais_density` (English *grammar*) and `tech_share` (technical nouns) --
# and the bands below are the quartiles that actually exist in his data.
#
# `synthetic_f08` is not sampled here: it is added by the runner from
# `fixtures.jsonl` as an explicit out-of-distribution control, because the one
# fixture that breaks every model (density 0.33) is above anything in 1 447 real
# dictations and must not be read as representative.
STRATA = [
    # label, predicate on (franglais_density, tech_share), how many
    ("pure", lambda fg, tech: fg == 0 and tech <= 0.01, 12),
    ("tech", lambda fg, tech: fg == 0 and tech >= 0.03, 12),
    ("mixed", lambda fg, tech: 0 < fg < 0.06, 12),
    ("heavy", lambda fg, tech: fg >= 0.06, 12),
]
MIN_WORDS = 15
MIN_FUNCTION_WORDS = 6  # below this, the density estimate is noise


def load_corpus() -> list[str]:
    out = []
    for meta in RECORDINGS.glob("*/meta.json"):
        try:
            data = json.loads(meta.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        raw = (data.get("rawResult") or "").strip()
        if raw and data.get("languageSelected") == "fr":
            out.append(raw)
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=20260901)
    parser.add_argument("--describe-only", action="store_true")
    args = parser.parse_args()

    corpus = load_corpus()
    scored = []
    for text in corpus:
        fr, en, tech, total = counts(text)
        if total < MIN_WORDS or fr + en < MIN_FUNCTION_WORDS:
            continue
        scored.append((franglais_density(text), tech / total, text))

    densities = [d for d, _, _ in scored]
    print(f"corpus: {len(corpus)} French dictations, {len(scored)} eligible "
          f"(>= {MIN_WORDS} words and >= {MIN_FUNCTION_WORDS} function words)")
    print(f"franglais density (English grammar): median "
          f"{statistics.median(densities):.3f}, p95 "
          f"{sorted(densities)[int(0.95 * len(densities))]:.3f}, max {max(densities):.3f}")
    techs = [t for _, t, _ in scored]
    print(f"tech share (technical nouns):        median "
          f"{statistics.median(techs):.3f}, p95 "
          f"{sorted(techs)[int(0.95 * len(techs))]:.3f}, max {max(techs):.3f}")
    for label, pred, _ in STRATA:
        pool = [x for x in scored if pred(x[0], x[1])]
        print(f"  {label:9} n={len(pool):4d} "
              f"({100 * len(pool) / len(scored):4.1f}% of the eligible corpus)")
    if args.describe_only:
        return

    rng = random.Random(args.seed)
    rows = []
    for label, pred, want in STRATA:
        pool = [x for x in scored if pred(x[0], x[1])]
        if len(pool) < want:
            raise SystemExit(f"stratum {label}: {len(pool)} available, {want} needed")
        for i, (fg, tech, text) in enumerate(rng.sample(pool, want), start=1):
            rows.append({
                "id": f"fg-{label}-{i:02d}",
                "source": "real",
                "stratum": label,
                "franglais_density": round(fg, 4),
                "tech_share": round(tech, 4),
                "raw": text,
            })
    OUT.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    print(f"\n{len(rows)} fixtures -> {OUT.name}")
    for label, _, _ in STRATA:
        band = [r for r in rows if r["stratum"] == label]
        words = [len(r["raw"].split()) for r in band]
        print(f"  {label:9} n={len(band)} words {min(words)}-{max(words)} "
              f"fg {min(r['franglais_density'] for r in band):.3f}-"
              f"{max(r['franglais_density'] for r in band):.3f} "
              f"tech {min(r['tech_share'] for r in band):.3f}-"
              f"{max(r['tech_share'] for r in band):.3f}")


if __name__ == "__main__":
    main()
