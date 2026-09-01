"""s1-mini: sampling parameters, and where `num_ctx` silently breaks.

Two questions the field grid cannot answer.

**Sampling.** On a 0.6 B model these settings weigh far more than on a 12 B. The
Ollama modelfile ships `temperature: 0.6, top_k: 20, top_p: 0.95,
repeat_penalty: 1`; the model card says `temperature: 0`. The field grid ran at
temperature 0 throughout and still produced 5 runaway generations under
`Styling: casual` -- a 44-word dictation expanded to 1 401 words with one 6-gram
repeated 108 times. `repeat_penalty: 1` (i.e. disabled) is the obvious suspect,
so it is tested directly on the fixtures that failed rather than on an average
that would hide them.

**Context.** `num_ctx` is the only real memory lever on this model (0.84 GB at
2048, 2.48 GB at 16384). The v2 lesson is that a too-small window drops input
*silently* -- the run stays green. So the sweep runs the longest real dictations
down the window sizes and checks how much of the input survives, rather than
trusting `done_reason`.

Writes `results-v3-s1params.local.jsonl` (real dictations -- gitignored).
"""

from __future__ import annotations

import json
import pathlib
import subprocess

from v3_franglais import french_sentence_rate
from v3_s1_grid import BASE_OPTIONS, build_prompt, generate

BASE = pathlib.Path(__file__).parent
OUT_PATH = BASE / "results-v3-s1params.local.jsonl"
BEST = ("semi-casual", "prose", "general")

# Sampling configurations. `card` is what the model card prescribes and what the
# field grid used; `modelfile` is what Ollama would apply if the caller passed no
# options at all -- worth knowing, since that is the trap a naive integration
# falls into.
SAMPLING = {
    "card_t0": {"temperature": 0},
    "modelfile_default": {"temperature": 0.6, "top_k": 20, "top_p": 0.95, "repeat_penalty": 1},
    "t0.3": {"temperature": 0.3},
    "t0.6": {"temperature": 0.6},
    "t0_rp1.05": {"temperature": 0, "repeat_penalty": 1.05},
    "t0_rp1.1": {"temperature": 0, "repeat_penalty": 1.1},
    "t0_rp1.2": {"temperature": 0, "repeat_penalty": 1.2},
    "t0_topk1": {"temperature": 0, "top_k": 1},
    "t0_topp0.9": {"temperature": 0, "top_p": 0.9},
}
CTX_SIZES = (512, 1024, 2048, 4096, 8192)


def load(name: str) -> list[dict]:
    return [
        json.loads(x)
        for x in (BASE / name).read_text().splitlines()
        if x.strip()
    ]


def _emit(out, row: dict) -> None:
    out.write(json.dumps(row, ensure_ascii=False) + "\n")
    out.flush()


def main() -> None:
    fixtures = load("fixtures-franglais.local.jsonl")
    # 5 per stratum keeps the sweep cheap; the runaway fixtures are added on top
    # because an average over well-behaved inputs would erase them.
    subset = [f for s in ("pure", "tech", "mixed", "heavy")
              for f in [x for x in fixtures if x["stratum"] == s][:5]]
    runaways = {"fg-mixed-02", "fg-mixed-09", "fg-tech-04"}
    subset += [f for f in fixtures if f["id"] in runaways and f not in subset]

    subprocess.run(["ollama", "stop", "gemma4:12b-it-qat"], check=False, capture_output=True)
    subprocess.run(["ollama", "stop", "gemma4:e2b-it-qat"], check=False, capture_output=True)

    with OUT_PATH.open("w") as out:
        print("== sampling sweep, semi-casual/prose/general ==")
        for name, override in SAMPLING.items():
            opts = {**BASE_OPTIONS, **override}
            for f in subset:
                r = generate(build_prompt(f["raw"], *BEST), opts)
                _emit(out, {"experiment": "sampling", "config": name, "options": override,
                            "fixture_id": f["id"], "stratum": f["stratum"],
                            "franglais_density": f["franglais_density"],
                            "input_words": len(f["raw"].split()), **r})
            print(f"  {name:20} done")

        print("== repeat_penalty rescue of Styling: casual, on the 5 runaway cells ==")
        cells = [("fg-mixed-02", "prose", "email"), ("fg-mixed-02", "lists", "general"),
                 ("fg-mixed-09", "lists", "general"), ("fg-tech-04", "lists", "email"),
                 ("fg-mixed-02", "lists", "email")]
        for fid, structure, context in cells:
            f = next(x for x in fixtures if x["id"] == fid)
            for rp in (1, 1.05, 1.1, 1.2):
                r = generate(build_prompt(f["raw"], "casual", structure, context),
                             {**BASE_OPTIONS, "repeat_penalty": rp})
                _emit(out, {"experiment": "casual_rescue", "config": f"rp{rp}",
                            "repeat_penalty": rp, "structure": structure,
                            "context": context, "fixture_id": fid,
                            "stratum": f["stratum"],
                            "franglais_density": f["franglais_density"],
                            "input_words": len(f["raw"].split()), **r})
            print(f"  casual/{structure}/{context} {fid} done")

        print("== num_ctx breakdown, longest real dictations ==")
        longest = sorted(fixtures, key=lambda f: -len(f["raw"].split()))[:4]
        for f in longest:
            for ctx in CTX_SIZES:
                r = generate(build_prompt(f["raw"], *BEST),
                             {**BASE_OPTIONS, "num_ctx": ctx})
                rate, _, _ = french_sentence_rate(r["output"])
                _emit(out, {"experiment": "num_ctx", "config": f"ctx{ctx}", "num_ctx": ctx,
                            "fixture_id": f["id"], "stratum": f["stratum"],
                            "franglais_density": f["franglais_density"],
                            "input_words": len(f["raw"].split()),
                            "fr_rate_out": round(rate, 3), **r})
            print(f"  {f['id']} ({len(f['raw'].split())} words) done")

    subprocess.run(["ollama", "stop", "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"],
                   check=False, capture_output=True)


if __name__ == "__main__":
    main()
