"""Is one arm reproducible against itself?

This has to run before any q4-versus-f16 difference is read as a quantisation
effect. Both arms are sent `temperature: 0` and a fixed seed, so in principle a
re-run reproduces the byte string -- but "in principle" is what this project has
been bitten by before. If q4 does not reproduce itself, then a q4/f16 difference
is indistinguishable from the noise floor and the whole comparison collapses to
"the two arms are the same".

Method: replay the same arm over the same fixtures, in a fresh process against a
freshly loaded model, and count byte-identical outputs against the recorded run.
Same wire, same order.

Writes `results-v4-determinism.local.jsonl` (real dictations -- gitignored).
"""

from __future__ import annotations

import argparse
import json
import pathlib
import time

from v4_quant import ARMS, generate, load_jsonl, unload_everything

BASE = pathlib.Path(__file__).parent
OUT = BASE / "results-v4-determinism.local.jsonl"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--arm", default="q4", choices=sorted(ARMS))
    args = parser.parse_args()

    recorded = {
        (r["arm"], r["fixture_id"]): r["output"]
        for r in load_jsonl(BASE / "results-v4-quant.local.jsonl")
    }
    fixtures = load_jsonl(BASE / "fixtures.jsonl") + load_jsonl(
        BASE / "fixtures-franglais.local.jsonl"
    )

    unload_everything()
    time.sleep(2)
    model_id = ARMS[args.arm]["model_id"]
    generate(model_id, "bonjour, ceci est un warm-up.")

    same = differ = 0
    drifted: list[str] = []
    with OUT.open("w") as out:
        for f in fixtures:
            r = generate(model_id, f["raw"])
            was = recorded[(args.arm, f["id"])]
            identical = r["output"] == was
            same += identical
            differ += not identical
            if not identical:
                drifted.append(f["id"])
            out.write(
                json.dumps(
                    {
                        "arm": args.arm,
                        "fixture_id": f["id"],
                        "identical_to_first_run": identical,
                        **r,
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )
            out.flush()
    unload_everything()
    print(f"arm={args.arm}  reproduced {same}/{same + differ} outputs byte-for-byte")
    if drifted:
        print("  not reproduced:", drifted)


if __name__ == "__main__":
    main()
