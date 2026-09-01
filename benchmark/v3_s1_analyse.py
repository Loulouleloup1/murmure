"""Read the s1-mini control-field grid and answer the one question that decides.

Louis's report, which this exists to confirm or refute: s1-mini gives him French
when his sentence is all-French and flips to English when the sentence is heavily
franglais. The headline number is therefore the share of outputs that stay
entirely French, cut by input franglais density and by control-field combination.

An output counts as **fully French** when every sentence of it that carries any
function word at all classifies French (`v3_franglais.french_sentence_rate`
== 1.0). Sentences made only of identifiers are neutral and ignored -- a line
that reads `WhisperKitConfig.transcribe(audioPath)` is not evidence either way.

The input side is measured with the same function, so a fixture that already
contains an English clause is not counted against the model.
"""

from __future__ import annotations

import json
import pathlib
import statistics as stats
from collections import defaultdict

from v3_franglais import french_sentence_rate

BASE = pathlib.Path(__file__).parent
STRATA = ("pure", "tech", "mixed", "heavy", "ood_synthetic")


def load() -> tuple[list[dict], dict[str, str]]:
    rows = [
        json.loads(x)
        for x in (BASE / "results-v3-s1grid.local.jsonl").read_text().splitlines()
        if x.strip()
    ]
    raws = {
        f["id"]: f["raw"]
        for name in ("fixtures-franglais.local.jsonl", "fixtures.jsonl")
        for f in (json.loads(x) for x in (BASE / name).read_text().splitlines() if x.strip())
    }
    return rows, raws


def main() -> None:
    rows, raws = load()
    for r in rows:
        rate_out, fr_out, en_out = french_sentence_rate(r["output"])
        rate_in, _, en_in = french_sentence_rate(raws[r["fixture_id"]])
        r["_fr_rate_out"] = rate_out
        r["_fr_rate_in"] = rate_in
        # A switch is judged relative to the input: a fixture that already had an
        # English clause cannot be charged to the model for keeping it.
        r["_fully_french"] = rate_out >= rate_in
        r["_en_sentences"] = en_out
        r["_en_sentences_in"] = en_in
        r["_combo"] = f"{r['styling']}/{r['structure']}/{r['context']}"

    print("=" * 92)
    print("A. INPUT PROFILE -- what each stratum actually is")
    print("=" * 92)
    print(f"{'stratum':15}{'n':>4}{'fg density':>12}{'tech share':>12}{'words':>14}"
          f"{'FR sentence rate of the INPUT':>32}")
    for s in STRATA:
        g = [r for r in rows if r["stratum"] == s]
        if not g:
            continue
        seen = {r["fixture_id"]: r for r in g}.values()
        print(f"{s:15}{len(seen):>4}"
              f"{stats.mean([r['franglais_density'] for r in seen]):>12.3f}"
              f"{stats.mean([r['tech_share'] for r in seen]):>12.3f}"
              f"{min(r['input_words'] for r in seen):>7d}-"
              f"{max(r['input_words'] for r in seen):<6d}"
              f"{stats.mean([r['_fr_rate_in'] for r in seen]):>28.1%}")

    print()
    print("=" * 92)
    print("B. THE HEADLINE -- % of outputs that stay fully French, by stratum")
    print("=" * 92)
    print(f"{'combination':30}" + "".join(f"{s:>13}" for s in STRATA) + f"{'real avg':>11}")
    scored = []
    for combo in sorted({r["_combo"] for r in rows}):
        cells, real = [], []
        for s in STRATA:
            g = [r for r in rows if r["_combo"] == combo and r["stratum"] == s]
            rate = stats.mean([r["_fully_french"] for r in g]) if g else float("nan")
            cells.append(rate)
            if s != "ood_synthetic":
                real.extend(r["_fully_french"] for r in g)
        avg = stats.mean(real)
        scored.append((avg, combo, cells))
        print(f"{combo:30}" + "".join(f"{c:>12.0%} " for c in cells) + f"{avg:>10.0%}")

    print()
    print("=" * 92)
    print("C. RANKING on real strata, with the cost columns")
    print("=" * 92)
    print(f"{'combination':30}{'FR kept':>9}{'lat med':>9}{'p90':>7}{'out/in words':>14}"
          f"{'empty':>7}{'non-stop':>9}")
    for avg, combo, _ in sorted(scored, reverse=True):
        g = [r for r in rows if r["_combo"] == combo and r["stratum"] != "ood_synthetic"]
        lat = sorted(r["latency_s"] for r in g)
        ratio = stats.mean([
            len(r["output"].split()) / max(1, r["input_words"]) for r in g
        ])
        print(f"{combo:30}{avg:>8.0%}{stats.median(lat):>9.2f}"
              f"{lat[int(0.9 * len(lat))]:>7.2f}{ratio:>13.0%}"
              f"{sum(1 for r in g if not r['output'].strip()):>7d}"
              f"{sum(1 for r in g if r['done_reason'] != 'stop'):>9d}")

    print()
    print("=" * 92)
    print("D. MARGINAL EFFECT of each field, averaged over the other two")
    print("=" * 92)
    for field in ("styling", "structure", "context"):
        print(f"  {field}:")
        for value in sorted({r[field] for r in rows}):
            g = [r for r in rows if r[field] == value and r["stratum"] != "ood_synthetic"]
            ood = [r for r in rows if r[field] == value and r["stratum"] == "ood_synthetic"]
            print(f"    {value:14} FR kept {stats.mean([r['_fully_french'] for r in g]):>6.0%}"
                  f"   (out-of-distribution f08: {stats.mean([r['_fully_french'] for r in ood]):.0%})"
                  f"   lat med {stats.median([r['latency_s'] for r in g]):.2f}s"
                  f"   out/in {stats.mean([len(r['output'].split()) / max(1, r['input_words']) for r in g]):.0%}")

    print()
    print("=" * 92)
    print("E. IS THERE A THRESHOLD? failures against the fixture's own density")
    print("=" * 92)
    best = max(scored)[1]
    print(f"  (best combination: {best})")
    per_fixture = defaultdict(list)
    for r in rows:
        if r["_combo"] == best:
            per_fixture[r["fixture_id"]].append(r)
    fails = sorted(
        (r[0] for r in per_fixture.values() if not r[0]["_fully_french"]),
        key=lambda r: -r["franglais_density"],
    )
    oks = [r[0] for r in per_fixture.values() if r[0]["_fully_french"]]
    print(f"  fixtures kept fully French: {len(oks)}/{len(per_fixture)}")
    if fails:
        print(f"  failures, by input density (fg = English grammar, tech = technical nouns):")
        for r in fails:
            print(f"    {r['fixture_id']:18} fg={r['franglais_density']:.3f} "
                  f"tech={r['tech_share']:.3f} words={r['input_words']:4d} "
                  f"-> {r['_en_sentences']} English sentence(s) out")
    print()
    print("  All-combination view: failure rate by density band")
    bands = [(0.0, 0.001, "fg = 0"), (0.001, 0.03, "0 < fg < .03"),
             (0.03, 0.06, ".03-.06"), (0.06, 0.12, ".06-.12"),
             (0.12, 0.25, ".12-.25"), (0.25, 1.01, "> .25 (OOD)")]
    for lo, hi, label in bands:
        g = [r for r in rows if lo <= r["franglais_density"] < hi]
        if not g:
            continue
        n_fix = len({r["fixture_id"] for r in g})
        print(f"    {label:14} {n_fix:2d} fixtures x16 combos = {len(g):4d} gen  "
              f"-> fully French {stats.mean([r['_fully_french'] for r in g]):.0%}")


if __name__ == "__main__":
    main()
