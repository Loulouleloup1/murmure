"""Does the longest dictation Louis has actually produced still fit in `num_ctx` 4096?

Two reasons this is here rather than assumed.

First, `OllamaS1.numContext` documents its headroom against "the longest dictation
in the whole 1 449-dictation corpus (531 words)". The corpus has since grown to
1 500 and its longest is **987 words**; ten dictations now sit above the 531 the
comment was written against. A headroom argument measured on a stale maximum is
not a headroom argument.

Second, `num_ctx` is the one lever that could buy back the extra gigabyte f16
costs -- but only if the longest input still fits underneath it. `truncate: false`
turns an overflow into a `400 exceed_context_size_error` rather than silent
front-truncation, so this script can ask the question directly: send the longest
real dictation and see whether the server answers or refuses.

Prints token counts and word counts only. Never prints a transcript.
"""

from __future__ import annotations

import glob
import json
import pathlib
import sqlite3
import time

from v4_quant import ARMS, OPTIONS, generate, unload_everything

RECORDINGS = pathlib.Path.home() / "Documents" / "superwhisper" / "recordings"
MURMURE_DB = (
    pathlib.Path.home()
    / "Library"
    / "Application Support"
    / "Murmure"
    / "murmure.sqlite"
)
PROBE_CTX = (2048, 4096)


def corpus() -> list[str]:
    """Every real dictation, from both stores. Read-only on both."""
    out: list[str] = []
    for meta in glob.glob(str(RECORDINGS / "*" / "meta.json")):
        try:
            data = json.loads(pathlib.Path(meta).read_text())
        except (json.JSONDecodeError, OSError):
            continue
        text = (data.get("rawResult") or data.get("result") or "").strip()
        if text:
            out.append(text)
    if MURMURE_DB.exists():
        # `mode=ro`: this database is Louis's live history and is never written by
        # a benchmark.
        con = sqlite3.connect(f"file:{MURMURE_DB}?mode=ro", uri=True)
        out += [
            t.strip()
            for (t,) in con.execute(
                "select rawTranscript from dictation where rawTranscript is not null"
            )
            if t and t.strip()
        ]
        con.close()
    return out


def main() -> None:
    texts = sorted(corpus(), key=lambda t: len(t.split()))
    lengths = [len(t.split()) for t in texts]
    over_531 = sum(1 for n in lengths if n > 531)
    print(
        f"corpus: {len(texts)} dictations, longest {lengths[-1]} words, "
        f"{over_531} above the 531 the Swift comment cites"
    )
    print(f"  top 5 lengths: {lengths[-5:]}")

    longest = texts[-1]
    original = OPTIONS["num_ctx"]
    try:
        for arm, spec in ARMS.items():
            for ctx in PROBE_CTX:
                unload_everything()
                time.sleep(1.5)
                OPTIONS["num_ctx"] = ctx
                r = generate(spec["model_id"], longest)
                if r["http_status"] != 200:
                    print(
                        f"{arm:4} num_ctx {ctx:>5}: REFUSED {r['http_status']} "
                        f"{r['http_body'][:120]}"
                    )
                    continue
                used = r["prompt_tokens"] + r["completion_tokens"]
                print(
                    f"{arm:4} num_ctx {ctx:>5}: {r['prompt_tokens']:5d} prompt + "
                    f"{r['completion_tokens']:4d} completion = {used:5d} / {ctx} "
                    f"({100 * used / ctx:.0f}% used)  {r['latency_s']:.2f}s  {r['done_reason']}"
                )
    finally:
        OPTIONS["num_ctx"] = original
        unload_everything()


if __name__ == "__main__":
    main()
