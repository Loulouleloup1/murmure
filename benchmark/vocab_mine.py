#!/usr/bin/env python3
"""Mine Louis's dictation corpus for near-misses of his recurring technical terms.

There is no ground truth for this corpus: we have his audio and what a recogniser
produced from it, never what he actually said. So this script does NOT claim to
find errors. It finds *candidates*: recordings whose transcript contains either
the correct spelling of a seed term or a string close enough to it to be a
plausible mangling. Deciding which is which is the re-decode's job, not this
one's.

Two sources, both read-only:
  - ~/Documents/superwhisper/recordings/*/meta.json  (rawResult / result + output.wav)
  - a COPY of ~/Library/Application Support/Murmure/murmure.sqlite (rawTranscript)

Output is one JSONL row per candidate recording, written under benchmark/ with a
`.local.jsonl` suffix so .gitignore keeps it out of the repo (ruling R12): these
transcripts are Louis's own client and internal work content.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
import unicodedata
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from pathlib import Path

SUPERWHISPER = Path.home() / "Documents" / "superwhisper" / "recordings"
MURMURE_SUPPORT = Path.home() / "Library" / "Application Support" / "Murmure"

# The seed vocabulary. The project's own terms are certain -- they are in the repo,
# in project.yml, in the plans -- and the work jargon is what recurs in his corpus.
# Each entry is `canonical spelling`; matching is done on a de-accented, lowercased,
# non-alphanumeric-stripped form so `s1-mini` and `S1 Mini` collapse together.
SEEDS = [
    # Murmure's own stack -- certain, they are in the repository.
    "Murmure",
    "Whisper",
    "WhisperKit",
    "Ollama",
    "s1-mini",
    "Claude Code",
    "Cursor",
    "Ghostty",
    "xcodegen",
    "SwiftUI",
    "Superwhisper",
    "GRDB",
    "DynamicNotchKit",
    "CoreML",
    "Xcode",
    "Swift",
    # Work jargon visible in the corpus.
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
    "Lambda",
    "DynamoDB",
    "awswrangler",
    "pytest",
    "ruff",
    "moto",
    "SQLAlchemy",
    "indicatorId",
    "datasetName",
    "MDI",
    "Urgewald",
    "Carbon4Finance",
    "ISS",
]


def fold(s: str) -> str:
    """Lowercase, de-accent, keep only alphanumerics. `S1-Mini` -> `s1mini`."""
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]", "", s.lower())


FOLDED_SEEDS = {seed: fold(seed) for seed in SEEDS}
# Seeds whose folded form is short are matched EXACTLY only: a 3-letter target
# like `dcg` or `mdi` has a high fuzzy ratio against half the French lexicon.
SHORT = {s for s, f in FOLDED_SEEDS.items() if len(f) <= 4}

NEAR_THRESHOLD = 0.74
MAX_NGRAM = 3


def word_spans(text: str) -> list[tuple[int, int, str]]:
    return [(m.start(), m.end(), m.group()) for m in re.finditer(r"[^\s]+", text)]


def candidates_in(text: str) -> dict[str, dict]:
    """Per seed: exact hits and near-miss fragments found in `text`.

    A `near` is evidence of a mangling, not proof of one: the corpus has no ground
    truth, so a fragment scoring 0.8 against `WhisperKit` may equally be a word
    Louis actually said.
    """
    spans = word_spans(text)
    out: dict[str, dict] = defaultdict(lambda: {"exact": 0, "near": []})

    for n in range(1, MAX_NGRAM + 1):
        for i in range(len(spans) - n + 1):
            frag = " ".join(w for _, _, w in spans[i : i + n])
            f = fold(frag)
            if not f or len(f) < 3:
                continue
            for seed, fs in FOLDED_SEEDS.items():
                if f == fs:
                    if n == 1 or " " in seed:
                        out[seed]["exact"] += 1
                    continue
                if seed in SHORT:
                    continue
                # Cheap length pre-filter before the O(n^2) ratio.
                if abs(len(f) - len(fs)) > max(3, len(fs) // 3):
                    continue
                r = SequenceMatcher(None, f, fs).ratio()
                if r >= NEAR_THRESHOLD:
                    out[seed]["near"].append({"fragment": frag, "ratio": round(r, 3)})
    return out


def superwhisper_rows():
    if not SUPERWHISPER.is_dir():
        return
    for d in sorted(SUPERWHISPER.iterdir()):
        meta = d / "meta.json"
        wav = d / "output.wav"
        if not meta.is_file() or not wav.is_file():
            continue
        try:
            m = json.loads(meta.read_text())
        except Exception:
            continue
        text = (m.get("rawResult") or m.get("result") or "").strip()
        if not text:
            continue
        yield {
            "source": "superwhisper",
            "id": d.name,
            "wav": str(wav),
            "engine": m.get("modelName"),
            "engine_key": m.get("modelKey"),
            "duration_ms": m.get("duration"),
            "text": text,
        }


def murmure_rows(db_copy: Path):
    if not db_copy.is_file():
        return
    con = sqlite3.connect(f"file:{db_copy}?mode=ro", uri=True)
    q = """select id, rawTranscript, audioFilename, durationSeconds, sttModel
           from dictation where rawTranscript is not null and rawTranscript <> ''"""
    for rid, text, audio, dur, model in con.execute(q):
        wav = MURMURE_SUPPORT / "recordings" / (audio or "")
        if not audio or not wav.is_file():
            continue
        yield {
            "source": "murmure",
            "id": str(rid),
            "wav": str(wav),
            "engine": model,
            "engine_key": model,
            "duration_ms": int((dur or 0) * 1000),
            "text": text.strip(),
        }


def main() -> int:
    out_path = Path(sys.argv[1])
    db_copy = Path(sys.argv[2]) if len(sys.argv) > 2 else None

    rows = list(superwhisper_rows())
    if db_copy:
        rows += list(murmure_rows(db_copy))

    exact_total: Counter = Counter()
    near_total: Counter = Counter()
    near_forms: dict[str, Counter] = defaultdict(Counter)
    kept = 0

    with out_path.open("w") as fh:
        for row in rows:
            found = candidates_in(row["text"])
            if not found:
                continue
            for seed, info in found.items():
                exact_total[seed] += info["exact"]
                near_total[seed] += len(info["near"])
                for nr in info["near"]:
                    near_forms[seed][nr["fragment"]] += 1
            kept += 1
            row["terms"] = {k: v for k, v in found.items()}
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")

    print(f"scanned {len(rows)} recordings with audio, {kept} carry a seed candidate")
    print(f"wrote {out_path}")
    print()
    print(f"{'term':<18}{'exact':>7}{'near':>7}   commonest near-miss forms")
    for seed in SEEDS:
        e, n = exact_total[seed], near_total[seed]
        if not e and not n:
            continue
        forms = ", ".join(f"{f!r}x{c}" for f, c in near_forms[seed].most_common(4))
        print(f"{seed:<18}{e:>7}{n:>7}   {forms}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
