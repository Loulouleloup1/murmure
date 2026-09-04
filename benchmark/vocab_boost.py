#!/usr/bin/env python3
"""Build the job file for the logits-bias campaign.

Companion to `vocab_dose.py` / `vocab_order.py`, but for `WhisperKit`'s OTHER mechanism:
`LogitsFiltering`, applied at every decode step on the full token history, with no prompt
budget at all (`TextDecoder.swift:652`, `LogitsFilter.swift:8`). See
`benchmark/vocabprobe/Sources/vocabprobe/VocabularyBoostFilter.swift` for the filter itself
and `docs/benchmarks/2026-09-vocabulary-logits-bias.md` for the write-up.

Reuses the EXACT SAME 109-file selection (`jobs-arms2.local.meta.local.json`) as the whole
prior campaign, so the 106 damaged occurrences are the same ones, and the `prompt` arm
below is a byte-identical replay of `n03sf` -- the shipped `VocabularyPrompt` reference --
imported from `vocab_order.py` rather than retyped.

Arms:
  baseline        -- no prompt, no filter. Re-establishes the 106; if this does not match
                      the original campaign, the harness change broke something and
                      everything below is uninterpretable.
  prompt          -- `n03sf`, the shipped prompt (3 terms + leading space + filler).
  boost02/05/10   -- filter only, no prompt, same 3 terms as `prompt`, three strengths.
                      `firstTokenBonus` is always continuation/3, per the brief: starting a
                      term is a genuine choice, continuing one nearly always follows.
  promptboost10   -- `prompt` AND the strength-10 filter together, same 3 terms.
  boost30x10      -- strength-10 filter, 30 terms (`vocab_dose.ORDER[:30]`) -- the arm the
                      prompt cannot build (20-term / 240-char cap). No prompt.
  boostabsent10   -- strength-10 filter, terms invented to NOT occur in this corpus. The
                      injection control: every occurrence counted here is a word Louis
                      never said, appearing anyway.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from vocab_dose import ORDER
from vocab_order import ARMS as ORDER_ARMS

# The 3 terms actually measurable in this corpus (60 + 35 + 10 occurrences -- see
# `docs/benchmarks/2026-09-vocabulary-prompt.md` §9). Same set the shipped prompt carries.
BOOST_TERMS_3 = ORDER[:3]
assert BOOST_TERMS_3 == ["Claude Code", "Trucost", "WeeFin"]

# 30 terms, unordered concern (the filter has no position effect and no truncation) --
# reuses the exact list `n30`/`n30r` were built from, for direct comparability.
BOOST_TERMS_30 = ORDER[:30]

# Plausible technical-sounding names invented for this campaign. None is a real tool,
# provider or WeeFin/Murmure term Louis has ever dictated -- checked by hand against
# `vocab_select.TERMS`, `vocab_select.UNRELATED` and the tracked-term list in
# `vocab_report.TERMS`. Any appearance in the `boostabsent10` output is an injection.
ABSENT_TERMS = ["Meridian", "Obsidian", "Fenwick", "Calyx", "Vertex"]

# The shipped prompt, byte-identical to the prior campaign's best arm (`n03sf`):
# " Murmure, Claude Code, Trucost, WeeFin."
PROMPT_STRING = ORDER_ARMS["n03sf"]

# continuation, firstToken = continuation / 3 (rounded to 2 decimals for a readable id).
STRENGTHS = [2, 5, 10]


def boost(terms: list[str], continuation: float) -> dict:
    return {
        "terms": terms,
        "continuationBonus": continuation,
        "firstTokenBonus": round(continuation / 3, 4),
    }


def build_arms() -> dict[str, dict]:
    arms = {
        "baseline": {"prompt": None, "boost": None},
        "prompt": {"prompt": PROMPT_STRING, "boost": None},
    }
    for c in STRENGTHS:
        arms[f"boost{c:02d}"] = {"prompt": None, "boost": boost(BOOST_TERMS_3, c)}
    best = STRENGTHS[-1]
    arms[f"promptboost{best:02d}"] = {
        "prompt": PROMPT_STRING,
        "boost": boost(BOOST_TERMS_3, best),
    }
    arms[f"boost30x{best:02d}"] = {"prompt": None, "boost": boost(BOOST_TERMS_30, best)}
    arms[f"boostabsent{best:02d}"] = {
        "prompt": None,
        "boost": boost(ABSENT_TERMS, best),
    }
    return arms


def main() -> int:
    out = Path(sys.argv[1])
    meta_in = Path(sys.argv[2])
    meta = json.loads(meta_in.read_text())
    arms = build_arms()

    tasks = [
        {
            "id": f"{p['id']}#{arm}",
            "wav": p["wav"],
            "arm": arm,
            "prompt": spec["prompt"],
            "boost": spec["boost"],
        }
        for p in meta["picks"]
        for arm, spec in arms.items()
    ]

    out.write_text(json.dumps({"tasks": tasks}, ensure_ascii=False))
    meta_path = out.with_suffix(".meta.local.json")
    meta_path.write_text(
        json.dumps({"picks": meta["picks"], "arms": arms}, ensure_ascii=False, indent=1)
    )

    print(
        f"{len(tasks)} decodes = {len(meta['picks'])} files x {len(arms)} arms -> {out}"
    )
    for arm, spec in arms.items():
        if spec["boost"]:
            b = spec["boost"]
            print(
                f"  {arm:<14} boost terms={len(b['terms']):<3} "
                f"cont={b['continuationBonus']:<5} first={b['firstTokenBonus']:<6}"
                f"{'  + prompt' if spec['prompt'] else ''}"
            )
        else:
            print(
                f"  {arm:<14} prompt only"
                if spec["prompt"]
                else f"  {arm:<14} baseline"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
