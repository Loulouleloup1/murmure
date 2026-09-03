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

Stage 3 -- `n01s`, `n03s`:
  The reversed curve is FLAT (86, 88, 87, 88 repairs at N=3, 10, 20, 30), so size buys
  nothing once the order is right, and what the forward arms lose is specifically
  whatever term sits FIRST: `Claude Code` repairs 11-17 times when first and 55-58 when
  not, and `WeeFin` repairs 0 of 10 when first and 10 of 10 when not.

  The tokenizer says why, and it is not about position at all. `tokencount` on the two
  prompts, which differ by one leading space:

      "Claude Code, Trucost, ..."   ->  C | la | ude | " Code" | , | " Tru" | cost
      " Claude Code, Trucost, ..."  ->  " Cla" | ude | " Code" | , | " Tru" | cost

  Written first, a term is cut into character fragments (`C`, `la`, `ude`) that never
  occur in running speech, where every word arrives with a leading space. Written
  anywhere else it gets ` Cla` -- the same id it has in the reversed arms that work.
  The leading space also costs one token LESS (11 against 12).

  So these two arms are the forward order with ONE leading space added and nothing else
  changed. Prediction, stated before running so it can fail: `n01s` lifts `Claude Code`
  from 17 to roughly 55, and `n03s` reaches the repairs of the 103-token `n30r` at 11
  tokens. If it holds, the feature needs no ordering rule in its interface -- it needs
  one character in its prompt builder.

Stage 4 -- `n03rs`, `n10rs`:
  Stage 3 held: one leading space took `Claude Code` from 17 repairs to 50 while
  SHRINKING the prompt from 5 tokens to 4. But it did not close the gap entirely --
  `n03r`, where the term is last, still reaches 58. So two effects coexist, one large
  (the tokenisation of the first item) and one small (proximity to the audio), and no
  arm so far has both: `n03s` has the space but wastes the last slot, `n03r` has the
  slot but pays the tokenisation on `WeeFin`, which it repairs 0 times out of 10.

  These arms have both -- a leading space AND the most-mangled term last. `n10rs` is
  the same at a realistic list size. This is the prompt the feature would actually
  build, so it is the one that has to be measured rather than extrapolated.

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
    # Stage 3. One leading space, nothing else changed.
    "n01s": " " + prompt_string(ORDER[:1]),
    "n03s": " " + prompt_string(ORDER[:3]),
    # Stage 4. Both effects at once: the leading space AND the mangled terms last.
    "n03rs": " " + prompt_string(list(reversed(ORDER[:3]))),
    "n10rs": " " + prompt_string(list(reversed(ORDER[:10]))),
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
