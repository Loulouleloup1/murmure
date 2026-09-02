#!/usr/bin/env python3
"""Separate ORDER from SIZE, and re-decode one arm to check that it replicates.

The dose curve came back non-monotonic in a way size alone cannot explain: `terms`
(35 words, original order) repaired `Claude Code` 55 times out of 60, while `n30`
(30 of the same words, frequency order) repaired it 12 times. Two stages.

Stage 1 -- `termsB` and `n30r`:
  - `termsB` re-decodes the EXACT `terms` prompt. The noise floor so far was measured
    WITHOUT a prompt (0/111 verdict flips), so prompt-conditioned stability had never
    been measured at all. Result: 76 repairs against 75, and 2 verdict flips on 112
    (file, term) pairs. The arms are reproducible; the ordering difference is real.
  - `n30r` is `n30` REVERSED -- same 30 words, same 103 tokens, no truncation, but the
    repairable terms move from the far end of the prompt to the end adjacent to the
    audio. Result: 88 repairs against 36. Position dominates.

Stage 2 -- `n03r`, `n10r`, `n20r`:
  The reversed dose curve. `n30r` buys its 88 repairs at -8.7 words per file, where the
  short forward arms cost -2.9. If putting the mangled terms LAST is what matters, a
  short reversed list should reach the same repairs at a third of the toll, and the
  product answer is "a small list, most-important last" rather than "a long one".

Usage:  vocab_order.py <out.json> <meta.json> [arm ...]
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from vocab_dose import ORDER
from vocab_select import TERMS, prompt_string

ARMS = {
    "termsB": prompt_string(TERMS),
    "n30r": prompt_string(list(reversed(ORDER[:30]))),
    "n03r": prompt_string(list(reversed(ORDER[:3]))),
    "n10r": prompt_string(list(reversed(ORDER[:10]))),
    "n20r": prompt_string(list(reversed(ORDER[:20]))),
}


def main() -> int:
    out = Path(sys.argv[1])
    meta = json.loads(Path(sys.argv[2]).read_text())
    wanted = sys.argv[3:] or list(ARMS)

    tasks = [
        {"id": f"{p['id']}#{arm}", "wav": p["wav"], "arm": arm, "prompt": ARMS[arm]}
        for arm in wanted
        for p in meta["picks"]
    ]
    out.write_text(json.dumps({"tasks": tasks}, ensure_ascii=False))
    print(f"{len(tasks)} decodes = {len(meta['picks'])} files x {len(wanted)} arms -> {out}")
    for arm in wanted:
        print(f"  {arm:<8}{len(ARMS[arm]):>5} chars  {ARMS[arm][:70]}...")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
