#!/usr/bin/env python3
"""Build the dose-curve arms: the same experiment at six prompt sizes.

The question this exists to answer. The 35-term arm repaired 75 term occurrences and
cost ~6 % of every dictated word -- but the `unrelated` control cost almost exactly the
same (mean difference -0.82 words per file, 95 % CI [-3.89, +2.26], indistinguishable
from zero). So the toll is the price of having a prompt at all, not the price of these
words. Two possibilities remain, with opposite conclusions:

  - the toll is FIXED for any non-empty prompt  -> the recogniser half is dead whatever
    the list contains, and Vocabulary shrinks to post-hoc replacement;
  - the toll SCALES with prompt length -> there is a knee, and the feature is a small
    curated list rather than a growing one.

Both arms so far are full-budget (both truncated to 111 tokens), so the existing data
cannot separate them. Sizes 1, 3, 5, 10, 20 and the existing 35 can.

The lists are NESTED -- each is a prefix of the next -- so the marginal effect of adding
terms is readable directly rather than confounded with a change of contents.

Ordering rule, stated because it is a design choice and not a neutral one: terms are
ranked by total mentions in his corpus (correct spellings PLUS known manglings, i.e.
how often he actually says them), with the terms that are actually mangled placed
first. That models how a vocabulary really accumulates -- a user adds the words they
notice coming out wrong -- and it puts `Claude Code` alone at N=1, which is 63 of the
111 measurable file/term pairs and therefore close to a real product decision rather
than a toy arm. Terms that are frequent but never mangled (`DCG` 143 mentions, `MDI`
83) enter at N=10: a user would certainly add them, and they can only cost, never
repair, which is itself part of what the curve has to price.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from vocab_select import TERMS, prompt_string

# Ranked as described above. Every entry is drawn from the 35-term list already
# measured, so size 35 IS the existing arm and does not need re-running.
ORDER = [
    # Mangled in the corpus, most-mentioned first.
    "Claude Code",  # 98 mentions (28 correct + 70 mangled), 63 of 111 pairs
    "Trucost",  # 57 (36 + 21)
    "WeeFin",  # 28 (10 + 18)
    "Cursor",
    "Superwhisper",
    # Frequent but never mangled: pure cost, no repair available. A user adds them
    # anyway, so the curve has to carry them.
    "DCG",  # 143 mentions
    "MDI",  # 83
    "Notion",  # 29
    "Parquet",
    "Serena",
    # The remainder of the measured list, project vocabulary first.
    "Murmure",
    "WhisperKit",
    "Ollama",
    "Xcode",
    "SwiftUI",
    "Ghostty",
    "xcodegen",
    "GRDB",
    "CoreML",
    "esgc",
    "connector",
    "dbt",
    "Athena",
    "Hindsight",
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
    "Urgewald",
]

SIZES = [1, 3, 5, 10, 20]


def main() -> int:
    out = Path(sys.argv[1])
    meta = json.loads(Path(sys.argv[2]).read_text())

    missing = [t for t in ORDER if t not in TERMS]
    extra = [t for t in TERMS if t not in ORDER]
    assert not missing and not extra, (
        f"ORDER must be a permutation of TERMS: {missing} {extra}"
    )

    tasks = []
    for n in SIZES:
        prompt = prompt_string(ORDER[:n])
        for p in meta["picks"]:
            tasks.append(
                {
                    "id": f"{p['id']}#n{n:02d}",
                    "wav": p["wav"],
                    "arm": f"n{n:02d}",
                    "prompt": prompt,
                }
            )

    out.write_text(json.dumps({"tasks": tasks}, ensure_ascii=False))
    print(
        f"{len(tasks)} decodes = {len(meta['picks'])} files x {len(SIZES)} sizes -> {out}"
    )
    for n in SIZES:
        print(f"  n={n:<3} {len(prompt_string(ORDER[:n])):>5} chars  {ORDER[:n]}")
    print(f"  n=35  (the arm already measured)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
