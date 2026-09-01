"""Descriptive pass over `results-v3.jsonl`.

Machine metrics and mechanical flags only -- no quality verdict, for the same
reason as v2: the blind judges decide that, and a controller opinion here would
contaminate the protocol. The flag machinery is imported from `describe_v2.py`
unchanged so the two reports are directly comparable.

What v3 adds, all of it forced by the memory constraint:
  * a resident-footprint column alongside every latency,
  * a latency-versus-input-length regression per model, because a 46-word median
    says nothing about the 370-word dictations Louis actually produces,
  * two `s1-mini`-specific counters -- how often the model capitalises on its own
    and how often it ends a sentence -- so the `format` number stops measuring
    our post-processing (v2 limitation 4).
"""

from __future__ import annotations

import json
import pathlib
import re
import statistics as stats
from collections import defaultdict

from describe_v2 import flags, words

BASE = pathlib.Path(__file__).parent

# Unambiguous hesitation tokens. `alors` / `donc` are excluded on purpose: they
# are legitimate connectives as often as they are filler, so counting them would
# penalise a correct output.
HESITATION = re.compile(r"\b(euh+|heu+|hum+|ben|bah)\b", re.I)
SENTENCE_START = re.compile(r"(?:^|(?<=[.!?])\s+|(?<=\n))(\S+)")
FINAL_PUNCT = re.compile(r"[.!?…»\"')\]]\s*$")
PLAIN = re.compile(r"^[a-zà-öø-ÿ']+$", re.I)
TRAIL = re.compile(r"[,.;:!?…»)\]\"']+$")


def load(path: pathlib.Path) -> list[dict]:
    return [json.loads(x) for x in path.read_text().splitlines() if x.strip()]


def cap_rate(text: str) -> tuple[int, int]:
    """(capitalised sentence starts, capitalisable sentence starts).

    Only ordinary prose words count as capitalisable: `tests/unit` or `p90` at a
    sentence start is not a missing capital.
    """
    total = hit = 0
    for token in SENTENCE_START.findall(text):
        core = TRAIL.sub("", token)
        if not core or not PLAIN.match(core):
            continue
        total += 1
        hit += core[0].isupper()
    return hit, total


def keep_rate(raw: str, out: str) -> float:
    """Share of the input's non-filler content words that survive into the output.

    A crude verbatim proxy: translation and paraphrase both push it down, while
    legitimate filler deletion barely moves it because fillers are excluded.
    """
    src = [w for w in words(raw) if not HESITATION.fullmatch(w)]
    if not src:
        return 1.0
    dst = set(words(out))
    return sum(w in dst for w in src) / len(src)


def slope(xs: list[float], ys: list[float]) -> tuple[float, float]:
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    den = sum((x - mx) ** 2 for x in xs)
    a = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den else 0.0
    return a, my - a * mx


def p90(xs: list[float]) -> float:
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(0.9 * len(xs)))]


def main() -> None:
    rows = load(BASE / "results-v3.jsonl")
    raws = {
        f["id"]: f["raw"]
        for name in ("fixtures.jsonl", "fixtures-real.local.jsonl")
        for f in load(BASE / name)
    }
    ram = {r["model"]: r for r in json.loads((BASE / "ram-v3.json").read_text())}
    cold6 = json.loads((BASE / "ram-v3-cold6.json").read_text())
    sweep = json.loads((BASE / "ram-v3-ctxsweep.json").read_text())

    print("=" * 78)
    print("A. ADMISSIBILITY -- resident footprint and cold/warm latency")
    print("=" * 78)
    print(f"{'model':16} {'disk':>7} {'ollama ps':>10} {'peak RSS':>9} "
          f"{'cold s':>7} {'1st cold':>9} {'warm s':>7}")
    for name, r in ram.items():
        disk = next(x["disk_gb"] for x in rows if x["model"] == name)
        c = cold6[name]
        # `cold s` is the steady-state cold start: model unloaded, GGUF still in
        # the OS page cache. `1st cold` is the first stop-then-load of a series,
        # i.e. page cache cold too -- consistently ~2x, and the honest number for
        # a 16 GB machine where the page cache does get evicted.
        print(f"{name:16} {disk:6.2f}G {r['ollama_ps'][0]['size']:>10} "
              f"{r['peak_rss_warm_gb']:8.2f}G {c['median']:7.2f} {c['max']:9.2f} "
              f"{r['warm_latency_median_s']:7.2f}")
        print(f"{'':16} cold rounds: {c['cold']}")

    print()
    print("Resident RSS by context window -- `num_ctx` is a real lever on s1-mini")
    print("(KV cache dwarfs its 0.48 GB of weights) and a no-op on gemma.")
    by_model: dict[str, list[str]] = defaultdict(list)
    for s in sweep:
        by_model[s["model"]].append(f"{s['num_ctx']:>5}: {s['rss_gb']:.2f}G")
    for name, cells in by_model.items():
        print(f"  {name:16} " + "   ".join(cells))

    print()
    print("=" * 78)
    print("B. PROMPT ARM -- synthetic fixtures (n=15), machine metrics")
    print("=" * 78)
    print(f"{'model':16} {'prompt':14} {'lat med':>8} {'p90':>6} {'tok/s':>7} "
          f"{'in tok':>7} {'out tok':>8}")
    for key, group in _grouped(rows, "prompt"):
        lat = [r["latency_s"] for r in group]
        print(f"{key[0]:16} {key[1]:14} {stats.median(lat):8.2f} {p90(lat):6.2f} "
              f"{stats.median([r['tokens_per_s'] for r in group]):7.1f} "
              f"{stats.median([r['prompt_tokens'] for r in group]):7.0f} "
              f"{stats.median([r['completion_tokens'] for r in group]):8.0f}")

    print()
    print("=" * 78)
    print("C. PROMPT ARM -- mechanical signals (NOT a quality verdict)")
    print("=" * 78)
    print(f"{'model':16} {'prompt':14} {'flags':>6} {'noop':>5} {'drift':>6} "
          f"{'euh left':>9} {'cap %':>7} {'end .':>6} {'keep %':>7} {'len %':>6}")
    for key, group in _grouped(rows, "prompt"):
        allflags = defaultdict(int)
        noop = drift = hes = ends = 0
        caps_hit = caps_tot = 0
        keeps, lens = [], []
        for r in group:
            raw = raws[r["fixture_id"]]
            for f in flags(r, raw):
                allflags[f] += 1
            noop += r["output"].strip() == raw.strip()
            drift += any("LANG_DRIFT" in f for f in flags(r, raw))
            # Count on the model's own text, not on our post-processed one.
            model_text = r.get("raw_model_output", r["output"])
            hes += len(HESITATION.findall(model_text))
            ends += bool(FINAL_PUNCT.search(model_text.strip()))
            h, t = cap_rate(model_text)
            caps_hit += h
            caps_tot += t
            keeps.append(keep_rate(raw, r["output"]))
            lens.append(len(words(r["output"])) / max(1, len(words(raw))))
        print(f"{key[0]:16} {key[1]:14} {sum(allflags.values()):6d} {noop:5d} "
              f"{drift:6d} {hes:9d} "
              f"{100 * caps_hit / max(1, caps_tot):6.0f}% {ends:3d}/15 "
              f"{100 * stats.mean(keeps):6.1f}% {100 * stats.mean(lens):5.0f}%")
        if allflags:
            print(f"{'':32} {dict(allflags)}")

    print()
    print("=" * 78)
    print("D. POST-PROCESSING FOOTPRINT (s1-mini) -- how much of `format` is ours")
    print("=" * 78)
    for key, group in _grouped(rows, "prompt"):
        if key[0] != "s1-mini":
            continue
        touched = sum(1 for r in group if r.get("recapitalised_words"))
        periods = sum(1 for r in group if r.get("added_final_period"))
        nwords = sum(len(r.get("recapitalised_words", [])) for r in group)
        print(f"{key[1]:14} recapitalised {touched:2d}/15 outputs "
              f"({nwords} words), added a final period on {periods:2d}/15")

    print()
    print("=" * 78)
    print("E. LENGTH ARM -- real dictations, latency vs input length")
    print("=" * 78)
    print(f"{'model':16} {'prompt':14} {'20-60w':>8} {'96-107w':>9} {'121-172w':>10} "
          f"{'260-370w':>10} {'s/100 words':>12}")
    for key, group in _grouped(rows, "length"):
        bands = defaultdict(list)
        for r in group:
            n = r["input_words"]
            band = "short" if n < 70 else "medium" if n < 115 else "long" if n < 200 else "verylong"
            bands[band].append(r["latency_s"])
        a, b = slope([r["input_words"] for r in group], [r["latency_s"] for r in group])
        cells = [f"{stats.median(bands[x]):8.2f}" if bands[x] else f"{'--':>8}"
                 for x in ("short", "medium", "long", "verylong")]
        print(f"{key[0]:16} {key[1]:14} {cells[0]} {cells[1]:>9} {cells[2]:>10} "
              f"{cells[3]:>10} {100 * a:11.2f}s  (intercept {b:.2f}s)")

    print()
    print("=" * 78)
    print("F. LENGTH ARM -- mechanical flags on real dictations")
    print("=" * 78)
    for key, group in _grouped(rows, "length"):
        allflags = defaultdict(int)
        for r in group:
            for f in flags(r, raws[r["fixture_id"]]):
                allflags[f] += 1
        trunc = sum(1 for r in group if r["done_reason"] != "stop")
        print(f"{key[0]:16} {key[1]:14} n={len(group):2d} non-stop={trunc} "
              f"{dict(allflags) or '{}'}")


def _grouped(rows: list[dict], arm: str):
    groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for r in rows:
        if r["arm"] == arm:
            groups[(r["model"], r["prompt_id"])].append(r)
    return sorted(groups.items(), key=lambda kv: (kv[0][0], kv[0][1]))


if __name__ == "__main__":
    main()
