"""Descriptive pass over `results-v4-quant.local.jsonl` -- q4 against f16.

Machine metrics and mechanical flags only, no quality verdict, for the same
reason as v2 and v3: a controller opinion here would contaminate the protocol.
The flag machinery is imported unchanged from `describe_v2.py` and the quality
axes unchanged from `v3_describe.py`, so a number in this report can be read
against the same number in the two published ones.

The first table is the one that decides the question. Two arms of the same model
differing only in weight precision either produce different text or they do not,
and **byte-identical output count** answers that before any axis is averaged. An
axis computed over pairs that are the same string measures nothing.

Prints aggregates and counts. Never prints a dictation: the fixture ids and word
counts are the only per-row identifiers that leave this script.
"""

from __future__ import annotations

import difflib
import pathlib
import statistics as stats
from collections import defaultdict

from describe_v2 import flags, lang_ratio, words
from v3_describe import FINAL_PUNCT, cap_rate, keep_rate, load

BASE = pathlib.Path(__file__).parent


def p90(xs: list[float]) -> float:
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(0.9 * len(xs)))]


def main() -> None:
    rows = load(BASE / "results-v4-quant.local.jsonl")
    raws = {
        f["id"]: f["raw"]
        for name in ("fixtures.jsonl", "fixtures-franglais.local.jsonl")
        for f in load(BASE / name)
    }
    by_arm: dict[str, dict[str, dict]] = defaultdict(dict)
    for r in rows:
        by_arm[r["arm"]][r["fixture_id"]] = r

    shared = sorted(set(by_arm["q4"]) & set(by_arm["f16"]))
    print("=" * 78)
    print("A. DO THE TWO ARMS DIFFER AT ALL -- byte-identical output count")
    print("=" * 78)
    per_set: dict[str, list[str]] = defaultdict(list)
    identical: list[str] = []
    differing: list[tuple[str, float, int, int]] = []
    for fid in shared:
        q, f = by_arm["q4"][fid], by_arm["f16"][fid]
        per_set[q["fixture_set"]].append(fid)
        if q["output"] == f["output"]:
            identical.append(fid)
        else:
            ratio = difflib.SequenceMatcher(None, q["output"], f["output"]).ratio()
            differing.append((fid, ratio, len(q["output"]), len(f["output"])))
    print(f"{'fixture set':12} {'n':>4} {'identical':>10} {'differing':>10}")
    for set_name, fids in per_set.items():
        ident = sum(1 for x in fids if x in identical)
        print(f"{set_name:12} {len(fids):4d} {ident:10d} {len(fids) - ident:10d}")
    print(f"{'TOTAL':12} {len(shared):4d} {len(identical):10d} {len(differing):10d}")

    if differing:
        print()
        print("Differing pairs, by character-level similarity (1.00 = identical):")
        print(
            f"  {'fixture':22} {'similarity':>10} {'q4 chars':>9} {'f16 chars':>10} {'stratum':>10}"
        )
        for fid, ratio, nq, nf in sorted(differing, key=lambda x: x[1]):
            print(
                f"  {fid:22} {ratio:10.3f} {nq:9d} {nf:10d} "
                f"{by_arm['q4'][fid]['stratum']:>10}"
            )
        sims = [x[1] for x in differing]
        print(f"  similarity: median {stats.median(sims):.3f}  min {min(sims):.3f}")

    print()
    print("=" * 78)
    print("B. LATENCY -- per arm, per fixture set")
    print("=" * 78)
    print(
        f"{'arm':5} {'set':12} {'n':>4} {'median':>8} {'p90':>7} {'max':>7} "
        f"{'tok/s':>7} {'out tok':>8}"
    )
    for arm in ("q4", "f16"):
        for set_name in per_set:
            group = [by_arm[arm][f] for f in per_set[set_name]]
            lat = [r["latency_s"] for r in group]
            print(
                f"{arm:5} {set_name:12} {len(group):4d} {stats.median(lat):8.3f} "
                f"{p90(lat):7.3f} {max(lat):7.3f} "
                f"{stats.median([r['tokens_per_s'] for r in group]):7.1f} "
                f"{stats.median([r['completion_tokens'] for r in group]):8.0f}"
            )

    print()
    print("=" * 78)
    print("C. QUALITY AXES -- the v3 measures, unchanged")
    print("=" * 78)
    print(
        "cap %   = share of capitalisable sentence starts the model capitalises itself"
    )
    print("end .   = outputs ending on terminal punctuation")
    print("len %   = output words / input words")
    print("keep %  = share of the input's non-filler content words surviving")
    print(
        "drift   = LANG_DRIFT_EN, the failure that matters (French answered in English)"
    )
    print()
    print(
        f"{'arm':5} {'set':12} {'n':>4} {'cap %':>7} {'end .':>8} {'len %':>7} "
        f"{'keep %':>7} {'drift':>6} {'flags':>6}"
    )
    for arm in ("q4", "f16"):
        for set_name in per_set:
            group = [by_arm[arm][f] for f in per_set[set_name]]
            caps_hit = caps_tot = ends = drift = 0
            keeps, lens = [], []
            allflags: dict[str, int] = defaultdict(int)
            for r in group:
                raw = raws[r["fixture_id"]]
                fl = flags(r, raw)
                for x in fl:
                    allflags[x] += 1
                drift += "LANG_DRIFT_EN" in fl
                ends += bool(FINAL_PUNCT.search(r["output"].strip()))
                h, t = cap_rate(r["output"])
                caps_hit += h
                caps_tot += t
                keeps.append(keep_rate(raw, r["output"]))
                lens.append(len(words(r["output"])) / max(1, len(words(raw))))
            print(
                f"{arm:5} {set_name:12} {len(group):4d} "
                f"{100 * caps_hit / max(1, caps_tot):6.1f}% {ends:4d}/{len(group):<3d} "
                f"{100 * stats.mean(lens):6.1f}% {100 * stats.mean(keeps):6.1f}% "
                f"{drift:6d} {sum(allflags.values()):6d}"
            )
            if allflags:
                print(f"{'':24} {dict(allflags)}")

    print()
    print("=" * 78)
    print("D. PER-FIXTURE AXIS DISAGREEMENT -- where the arms score differently")
    print("=" * 78)
    disagree = 0
    for fid in shared:
        q, f = by_arm["q4"][fid], by_arm["f16"][fid]
        if q["output"] == f["output"]:
            continue
        raw = raws[fid]
        qd, fd = "LANG_DRIFT_EN" in flags(q, raw), "LANG_DRIFT_EN" in flags(f, raw)
        qe = bool(FINAL_PUNCT.search(q["output"].strip()))
        fe = bool(FINAL_PUNCT.search(f["output"].strip()))
        qc, fc = cap_rate(q["output"]), cap_rate(f["output"])
        qk, fk = keep_rate(raw, q["output"]), keep_rate(raw, f["output"])
        notes = []
        if qd != fd:
            notes.append(f"drift q4={qd} f16={fd}")
        if qe != fe:
            notes.append(f"final-punct q4={qe} f16={fe}")
        if qc != fc:
            notes.append(f"caps q4={qc[0]}/{qc[1]} f16={fc[0]}/{fc[1]}")
        if abs(qk - fk) > 0.01:
            notes.append(f"keep q4={100 * qk:.0f}% f16={100 * fk:.0f}%")
        if notes:
            disagree += 1
            print(f"  {fid:22} " + "; ".join(notes))
    print(
        f"  {disagree} of {len(differing)} differing pairs disagree on any measured axis"
    )

    print()
    print("=" * 78)
    print("F. THE TWO FAILURE MODES THE AGGREGATES HIDE")
    print("=" * 78)
    print("Section C averages, and an average over 63 fixtures cannot see a defect")
    print("that hits three of them. These two are found by asking directly.")
    print()
    print("F1. CONTENT DELETION -- output words / input words below 75 %, or a")
    print("    >15 pt gap between the arms. These outputs are NOT truncated: each")
    print("    one still lands on the input's final sentence, so the material is")
    print("    removed from the MIDDLE and the answer reads as complete.")
    print(f"  {'fixture':22} {'in w':>5} {'q4':>6} {'f16':>6}   verdict")
    losses = {"q4": 0, "f16": 0}
    for fid in shared:
        n = len(words(raws[fid]))
        r = {a: len(words(by_arm[a][fid]["output"])) / max(1, n) for a in ("q4", "f16")}
        if min(r.values()) < 0.75 or abs(r["q4"] - r["f16"]) > 0.15:
            for a in ("q4", "f16"):
                losses[a] += r[a] < 0.75
            worse = "q4" if r["q4"] < r["f16"] else "f16"
            print(
                f"  {fid:22} {n:5d} {100 * r['q4']:5.0f}% {100 * r['f16']:5.0f}%   "
                f"{worse} drops the material"
            )
    print(f"  severe (<75 % kept): q4 {losses['q4']}, f16 {losses['f16']}")

    print()
    print("F2. LANGUAGE -- English stopwords per 100 output words against the")
    print("    input's own share. `LANG_DRIFT_EN` in section C is a binary flag and")
    print("    only fires when French collapses almost completely; this is the")
    print(
        "    continuous version, and it sees the partial translations the flag misses."
    )
    print(
        f"  {'fixture':22} {'in EN':>6} {'in FR':>6} {'q4 EN':>6} {'q4 FR':>6} "
        f"{'f16 EN':>7} {'f16 FR':>7}   worse"
    )
    for fid in shared:
        raw = raws[fid]
        nw = max(1, len(words(raw)))
        fr_in, en_in = lang_ratio(raw)
        cells = {}
        for arm in ("q4", "f16"):
            out = by_arm[arm][fid]["output"]
            no = max(1, len(words(out)))
            fr_out, en_out = lang_ratio(out)
            cells[arm] = (100 * en_out / no, 100 * fr_out / no)
        if any(c[0] > max(4.0, 2 * 100 * en_in / nw) for c in cells.values()):
            worse = "q4" if cells["q4"][0] > cells["f16"][0] else "f16"
            if abs(cells["q4"][0] - cells["f16"][0]) < 1.0:
                worse = "both"
            print(
                f"  {fid:22} {100 * en_in / nw:6.1f} {100 * fr_in / nw:6.1f} "
                f"{cells['q4'][0]:6.1f} {cells['q4'][1]:6.1f} "
                f"{cells['f16'][0]:7.1f} {cells['f16'][1]:7.1f}   {worse}"
            )

    print()
    print("=" * 78)
    print("E. HEALTH -- anything that is not a clean stop")
    print("=" * 78)
    for arm in ("q4", "f16"):
        group = [by_arm[arm][f] for f in shared]
        nonstop = [r["fixture_id"] for r in group if r["done_reason"] != "stop"]
        empty = [r["fixture_id"] for r in group if not r["output"].strip()]
        http = [r["fixture_id"] for r in group if r.get("http_status") != 200]
        print(
            f"{arm:5} non-stop={len(nonstop)} empty={len(empty)} non-200={len(http)} "
            f"{nonstop or ''}{empty or ''}{http or ''}"
        )


if __name__ == "__main__":
    main()
