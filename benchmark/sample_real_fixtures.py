"""Sample real dictation transcripts into a LOCAL-ONLY fixture file.

Reads ~/Documents/superwhisper/recordings/*/meta.json and writes
benchmark/fixtures-real.local.jsonl, which .gitignore keeps out of git: the
transcripts are Louis's real work content and must never enter the repo history
(ruling R12). The sample is stratified by length, because the whole point is to
cover the long-form range the 15 synthetic fixtures miss -- they are median 46
words, the real corpus is median 77 with a p90 of 224 (ruling R10).
"""

from __future__ import annotations

import argparse
import json
import pathlib
import random

RECORDINGS = pathlib.Path.home() / "Documents" / "superwhisper" / "recordings"
OUT = pathlib.Path(__file__).parent / "fixtures-real.local.jsonl"

# (label, min_words, max_words, how_many) -- the top band is what the synthetic
# fixtures never reach, so it is deliberately over-sampled.
BANDS = [
    ("short", 20, 60, 4),
    ("medium", 61, 120, 4),
    ("long", 121, 250, 5),
    ("verylong", 251, 10_000, 4),
]


def _load() -> list[tuple[int, str]]:
    """Every non-empty raw transcript, as (word_count, text)."""
    out = []
    for meta in RECORDINGS.glob("*/meta.json"):
        try:
            data = json.loads(meta.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        raw = (data.get("rawResult") or "").strip()
        if raw and data.get("languageSelected") == "fr":
            out.append((len(raw.split()), raw))
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=20260831)
    args = parser.parse_args()

    corpus = _load()
    if not corpus:
        raise SystemExit(f"no transcripts found under {RECORDINGS}")
    rng = random.Random(args.seed)

    rows = []
    for label, lo, hi, count in BANDS:
        pool = [t for wc, t in corpus if lo <= wc <= hi]
        if len(pool) < count:
            raise SystemExit(f"band {label}: only {len(pool)} transcripts, need {count}")
        for i, text in enumerate(rng.sample(pool, count), start=1):
            rows.append({"id": f"r-{label}-{i:02d}", "source": "real", "band": label, "raw": text})

    OUT.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    # Deliberately print counts only -- never the transcripts themselves.
    print(f"{len(rows)} fixtures -> {OUT.name} (corpus: {len(corpus)} French transcripts)")
    for label, lo, hi, _ in BANDS:
        band = [len(r["raw"].split()) for r in rows if r["band"] == label]
        print(f"  {label:<9} n={len(band)} words {min(band)}-{max(band)}")


if __name__ == "__main__":
    main()
