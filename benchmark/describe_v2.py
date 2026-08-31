"""Descriptive pass over `results-v2.jsonl` -- machine metrics and mechanical
anomaly flags only. Deliberately says nothing about quality: that is the blind
judges' job, and a controller opinion here would contaminate the protocol.
"""

from __future__ import annotations

import json
import pathlib
import re
import statistics as stats
import unicodedata
from collections import defaultdict

BASE = pathlib.Path(__file__).parent

# Mechanical, model-agnostic flags. None of them is a quality verdict.
PREAMBLE = re.compile(
    r"^\s*(voici|here is|here's|bien s[uû]r|sure[,!]|d'accord|okay[,:]|the cleaned|"
    r"transcription (nettoy|corrig)|texte (nettoy|corrig)|je vais |i will )",
    re.I,
)
FENCE = re.compile(r"```|^\s*[\"'«].*[\"'»]\s*$", re.S)
# Ratio of ASCII-only words as a crude language-drift signal (French loses accents
# and function words when a model translates). Compared per fixture, not absolute.
FR_STOPWORDS = {
    "le",
    "la",
    "les",
    "de",
    "des",
    "du",
    "et",
    "que",
    "qui",
    "dans",
    "pour",
    "je",
    "tu",
    "il",
    "on",
    "est",
    "pas",
    "un",
    "une",
    "ce",
    "sur",
    "avec",
}
EN_STOPWORDS = {
    "the",
    "of",
    "and",
    "to",
    "in",
    "is",
    "that",
    "it",
    "you",
    "for",
    "with",
    "this",
    "are",
    "was",
    "we",
    "on",
    "have",
    "be",
    "at",
    "not",
    "should",
}


def load(path: pathlib.Path) -> list[dict]:
    return [json.loads(x) for x in path.read_text().splitlines() if x.strip()]


def words(text: str) -> list[str]:
    return re.findall(r"[\w'À-ÿ-]+", text.lower())


def lang_ratio(text: str) -> tuple[int, int]:
    w = words(text)
    return sum(x in FR_STOPWORDS for x in w), sum(x in EN_STOPWORDS for x in w)


def flags(row: dict, raw: str) -> list[str]:
    out = row["output"]
    f: list[str] = []
    if not out.strip():
        f.append("EMPTY")
    if row.get("done_reason") == "length":
        f.append("TRUNCATED")
    if PREAMBLE.search(out):
        f.append("PREAMBLE")
    if "```" in out:
        f.append("FENCE")
    if out.strip() == raw.strip():
        f.append("NOOP_EXACT")
    fr_in, en_in = lang_ratio(raw)
    fr_out, en_out = lang_ratio(out)
    # Drift is a *relative* move: the input's own language mix is the reference.
    if fr_in >= 3 and fr_out <= max(1, fr_in // 4) and en_out > fr_out:
        f.append("LANG_DRIFT_EN")
    if en_in >= 3 and en_out <= max(1, en_in // 4) and fr_out > en_out:
        f.append("LANG_DRIFT_FR")
    if len(words(out)) < 0.5 * len(words(raw)):
        f.append("SHORT<50%")
    if len(words(out)) > 1.6 * len(words(raw)):
        f.append("LONG>160%")
    if " " in out or " " in out:
        f.append("FR_TYPO")
    return f


def pct(xs: list[float], q: float) -> float:
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


def main() -> None:
    rows = load(BASE / "results-v2.jsonl")
    fixtures = {
        f["id"]: f
        for f in load(BASE / "fixtures.jsonl")
        + load(BASE / "fixtures-real.local.jsonl")
    }

    print("=" * 78)
    print("A. LATENCY & LENGTH  (runtime: ollama-0.33.2, one model resident at a time)")
    print("=" * 78)
    print(
        f"{'model':16}{'prompt':18}{'task':16}{'cfg':6}{'set':10}"
        f"{'n':>3}{'med s':>8}{'p90 s':>8}{'max s':>8}{'tok/s':>8}{'med tok':>9}"
    )
    groups: dict[tuple, list[dict]] = defaultdict(list)
    for r in rows:
        groups[
            (r["model"], r["prompt_id"], r["task"], r["config_id"], r["fixture_set"])
        ].append(r)
    for key in sorted(groups):
        g = groups[key]
        lat = [x["latency_s"] for x in g]
        print(
            f"{key[0]:16}{key[1]:18}{key[2]:16}{key[3]:6}{key[4]:10}{len(g):>3}"
            f"{stats.median(lat):>8.2f}{pct(lat, 0.9):>8.2f}{max(lat):>8.2f}"
            f"{stats.median(x['tokens_per_s'] for x in g):>8.1f}"
            f"{stats.median(x['completion_tokens'] for x in g):>9.0f}"
        )

    print()
    print("=" * 78)
    print("B. MECHANICAL FLAGS  (not quality judgements -- see describe_v2.py)")
    print("=" * 78)
    tally: dict[tuple, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    detail: list[str] = []
    for r in rows:
        f = flags(r, fixtures[r["fixture_id"]]["raw"])
        key = (r["model"], r["prompt_id"], r["config_id"])
        tally[key]["n"] += 1
        for name in f:
            tally[key][name] += 1
            detail.append(
                f"  {name:14} {r['model']:16}{r['prompt_id']:18}"
                f"{r['config_id']:6}{r['fixture_id']}"
            )
    for key in sorted(tally):
        t = tally[key]
        hits = {k: v for k, v in t.items() if k != "n"}
        print(f"{key[0]:16}{key[1]:18}{key[2]:6}n={t['n']:<4}{hits or '-'}")
    print("\nper-generation detail:")
    for line in sorted(detail):
        print(line)

    print()
    print("=" * 78)
    print("C. CONFIG A/B  (same model, same prompt, same fixtures)")
    print("=" * 78)
    for fset in ("synthetic", "real_long"):
        byc = {
            c: {
                x["fixture_id"]: x
                for x in rows
                if x["config_id"] == c
                and x["fixture_set"] == fset
                and x["model"] == "gemma4-12b-qat"
                and x["prompt_id"] == "cleanup_baseline"
            }
            for c in ("v1cfg", "v2mid", "v2")
        }
        for a, b, label in (
            ("v1cfg", "v2mid", "temperature 0.2 -> 0 (+seed), caps unchanged"),
            ("v2mid", "v2", "num_predict 512->2048, num_ctx unset->8192"),
        ):
            ids = sorted(set(byc[a]) & set(byc[b]))
            if not ids:
                continue
            identical = sum(byc[a][i]["output"] == byc[b][i]["output"] for i in ids)
            trunc_a = sum(byc[a][i]["done_reason"] == "length" for i in ids)
            trunc_b = sum(byc[b][i]["done_reason"] == "length" for i in ids)
            dl = stats.median(
                byc[b][i]["latency_s"] - byc[a][i]["latency_s"] for i in ids
            )
            print(
                f"[{fset}] {a} -> {b}  ({label})\n"
                f"    byte-identical outputs: {identical}/{len(ids)}"
                f" | truncated: {trunc_a} -> {trunc_b}"
                f" | median latency delta: {dl:+.2f} s"
            )
            for i in ids:
                if byc[a][i]["output"] != byc[b][i]["output"]:
                    print(
                        f"      {i}: {byc[a][i]['completion_tokens']} tok"
                        f" ({byc[a][i]['done_reason']}) -> "
                        f"{byc[b][i]['completion_tokens']} tok"
                        f" ({byc[b][i]['done_reason']})"
                    )
        print()

    print("=" * 78)
    print("D. FRENCH TYPOGRAPHY EMISSION  (variant C's distinguishing rule)")
    print("=" * 78)
    for key in sorted(groups):
        g = groups[key]
        nnbsp = sum(x["output"].count(" ") for x in g)
        nbsp = sum(x["output"].count(" ") for x in g)
        guill = sum(x["output"].count("«") for x in g)
        if nnbsp or nbsp or guill:
            print(
                f"{key[0]:16}{key[1]:18}{key[3]:6} U+202F x{nnbsp:<4}"
                f" U+00A0 x{nbsp:<4} « x{guill}"
            )
    print("(absent groups emitted none)")

    print()
    print("=" * 78)
    print(
        "E. s1-mini RECAPITALISATION PASS  (artefact introduced by us, not the model)"
    )
    print("=" * 78)
    for r in rows:
        if r["model"] != "s1-mini":
            continue
        w = r.get("recapitalised_words", [])
        print(f"  {r['fixture_id']}: {len(w)} word(s) -> {w}")

    print()
    print(f"total rows: {len(rows)}")
    print(
        "non-ASCII control chars in outputs: "
        + str(
            sum(
                1
                for r in rows
                for ch in r["output"]
                if unicodedata.category(ch) == "Cc" and ch not in "\n\t"
            )
        )
    )


if __name__ == "__main__":
    main()
