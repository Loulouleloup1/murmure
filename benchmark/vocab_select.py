#!/usr/bin/env python3
"""Pick the recordings the prompt experiment runs on, and emit the probe's job files.

The corpus has no ground truth, so selection is deliberately conservative. A file is
kept only when its existing transcript carries an **unambiguous** mangling of a seed
term -- a string that is not a French or English word and cannot plausibly be what
Louis said (`Cloud Code`, `Wefin`, `TrueCost`) -- or the seed spelled correctly, which
serves as the newly-broken control.

The fuzzy miner in `vocab_mine.py` is what found these forms; it is not what selects
on them. Its output is 80 % ordinary French (`parce que` scores 0.79 against
`Parquet`, `sera` scores 0.75 against `Serena`), which is exactly why the literal
patterns below were curated by hand from its report rather than used as a threshold.

Note what these transcripts are and are NOT: they come from Superwhisper, whose model
key for 1 410 of the 1 469 recordings is `small`. That is a much weaker model than
Murmure's `large-v3-turbo`. A mangling here is evidence that Louis SAID the term, not
evidence that Murmure gets it wrong -- establishing that is the baseline arm's job.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

SUPERWHISPER = Path.home() / "Documents" / "superwhisper" / "recordings"

# Curated by hand from vocab_mine.py's report. Each pattern matches only forms that
# are not words in either language, so a hit means the recogniser invented something.
MANGLED = {
    "Claude Code": r"\b(cloud ?code|clou de code|cloude code)\b",
    "WeeFin": r"\b(wefin|weefin|wefinn|wefine|wifine|wee fine)\b",
    "Trucost": r"\b(true ?cost|trop coste|tru ?coste)\b",
    "Cursor": r"\b(curesor|keursor)\b",
    "Superwhisper": r"\b(superspiber|superwisper)\b",
}

# The same terms spelled correctly. A file here is one where the weaker model already
# succeeded, which makes it the control for "does the prompt break what worked".
CORRECT = {
    "Claude Code": r"\bclaude code\b",
    "WeeFin": r"\bweefin\b",
    "Trucost": r"\btrucost\b",
    "Cursor": r"\bcursor\b",
    "Superwhisper": r"\bsuperwhisper\b",
}

# The prompt arms. `terms` is the realistic vocabulary Louis would actually type into
# the pane. `unrelated` is the dose control: the same shape and roughly the same token
# cost, none of it relevant to his audio. If it helps as much as `terms`, the effect is
# prompt-presence and not vocabulary.
TERMS = [
    "Murmure",
    "WhisperKit",
    "Ollama",
    "Claude Code",
    "Cursor",
    "Ghostty",
    "xcodegen",
    "SwiftUI",
    "Xcode",
    "Superwhisper",
    "GRDB",
    "CoreML",
    "WeeFin",
    "esgc",
    "DCG",
    "connector",
    "dbt",
    "Athena",
    "Hindsight",
    "Serena",
    "Trucost",
    "Parquet",
    "Notion",
    "Streamlit",
    "Playwright",
    "Terraform",
    "DynamoDB",
    "awswrangler",
    "pytest",
    "ruff",
    "SQLAlchemy",
    "indicatorId",
    "datasetName",
    "MDI",
    "Urgewald",
]

UNRELATED = [
    "Bordeaux",
    "clavecin",
    "Patagonie",
    "orthopédie",
    "brouette",
    "Valparaiso",
    "sarrasin",
    "Kilimandjaro",
    "hautbois",
    "poulailler",
    "Reykjavik",
    "cardamome",
    "Trombone",
    "Andalousie",
    "girofle",
    "escabeau",
    "Tasmanie",
    "marjolaine",
    "Ouagadougou",
    "cerf-volant",
    "Ardèche",
    "châtaigne",
    "Melbourne",
    "luzerne",
    "Copenhague",
    "sabot",
    "Zanzibar",
    "quenouille",
    "Bruges",
    "tapioca",
    "Novgorod",
    "églantine",
    "Sumatra",
    "goéland",
    "Wallonie",
]


def prompt_string(terms: list[str]) -> str:
    """The vocabulary as one string for the tokenizer.

    A comma-separated list rather than a sentence: a sentence would put French
    grammar in the conditioning context as well as the words, and the word list is
    what is being measured.
    """
    return ", ".join(terms) + "."


def corpus():
    for d in sorted(SUPERWHISPER.iterdir()):
        meta, wav = d / "meta.json", d / "output.wav"
        if not meta.is_file() or not wav.is_file():
            continue
        try:
            m = json.loads(meta.read_text())
        except Exception:
            continue
        text = (m.get("rawResult") or m.get("result") or "").strip()
        if text:
            yield (
                d.name,
                str(wav),
                m.get("duration", 0) / 1000.0,
                m.get("modelKey"),
                text,
            )


def select(max_seconds: float | None):
    kept = []
    for name, wav, dur, key, text in corpus():
        low = text.lower()
        mangled = {t: len(re.findall(p, low)) for t, p in MANGLED.items()}
        correct = {t: len(re.findall(p, low)) for t, p in CORRECT.items()}
        mangled = {k: v for k, v in mangled.items() if v}
        correct = {k: v for k, v in correct.items() if v}
        if not mangled and not correct:
            continue
        if max_seconds and dur > max_seconds:
            continue
        kept.append(
            {
                "id": name,
                "wav": wav,
                "seconds": round(dur, 1),
                "engine_key": key,
                "mangled": mangled,
                "correct": correct,
            }
        )
    return kept


def main() -> int:
    which = sys.argv[1]
    out = Path(sys.argv[2])

    if which == "noisefloor":
        # Five files spanning the duration range, decoded repeatedly with IDENTICAL
        # options. Nothing varies but the process's own temperature fallback, so the
        # spread here is the floor every later difference has to clear.
        repeats = int(sys.argv[3]) if len(sys.argv) > 3 else 6
        pool = sorted(select(max_seconds=180), key=lambda r: r["seconds"])
        picks = [pool[int(len(pool) * q)] for q in (0.05, 0.3, 0.5, 0.7, 0.92)]
        tasks = [
            {"id": f"{p['id']}#r{i}", "wav": p["wav"], "arm": "floor", "prompt": None}
            for p in picks
            for i in range(repeats)
        ]
        meta = {"picks": picks, "repeats": repeats}
    elif which == "arms":
        max_seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 180.0
        picks = select(max_seconds=max_seconds)
        arms = {
            "baseline": None,
            "terms": prompt_string(TERMS),
            "unrelated": prompt_string(UNRELATED),
        }
        tasks = [
            {"id": f"{p['id']}#{arm}", "wav": p["wav"], "arm": arm, "prompt": prompt}
            for p in picks
            for arm, prompt in arms.items()
        ]
        meta = {"picks": picks, "arms": {k: v for k, v in arms.items()}}
    else:
        raise SystemExit(f"unknown job kind {which!r}")

    out.write_text(json.dumps({"tasks": tasks}, ensure_ascii=False))
    meta_path = out.with_suffix(".meta.local.json")
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=1))

    total = sum(p["seconds"] for p in meta["picks"])
    print(f"{len(meta['picks'])} recordings, {total / 60:.1f} min of audio")
    print(f"{len(tasks)} decodes -> {out}")
    print(f"selection metadata -> {meta_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
