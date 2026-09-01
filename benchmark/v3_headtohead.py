"""Three-way head-to-head on the franglais-stratified real dictations.

Each model runs its own v3 winner, not a shared prompt -- comparing a model
under an instruction written for a different one measures the mismatch, not the
model. The winners:

  s1-mini        semi-casual/prose/general, temperature 0, repeat_penalty 1.1,
                 num_ctx 4096   (v3_s1_grid.py + v3_s1_params.py)
  gemma4-e2b     cleanup_FR60 -- the only prompt of the four that does not
                 translate the code-switched fixture
  gemma4-12b     cleanup_S25 -- 33 words, matches the 202-word production prompt
                 mechanically for 29 % less latency

Strictly sequential, one model resident at a time. Writes
`results-v3-headtohead.local.jsonl`: real dictations, gitignored, judging
material for the blind panel.
"""

from __future__ import annotations

import json
import pathlib
import subprocess
import time

from v3_run_benchmark import run_chat
from v3_s1_grid import build_prompt, generate

BASE = pathlib.Path(__file__).parent
OUT = BASE / "results-v3-headtohead.local.jsonl"

S1_OPTIONS = {"temperature": 0, "seed": 20260901, "num_predict": 2048,
              "num_ctx": 4096, "repeat_penalty": 1.1}
CHAT_MODELS = [
    ("gemma4-e2b-qat", "gemma4:e2b-it-qat", "cleanup_FR60", "v3_cleanup_FR60.txt"),
    ("gemma4-12b-qat", "gemma4:12b-it-qat", "cleanup_S25", "v3_cleanup_S25.txt"),
]


def main() -> None:
    fixtures = [
        json.loads(x)
        for x in (BASE / "fixtures-franglais.local.jsonl").read_text().splitlines()
        if x.strip()
    ]
    for m in ("gemma4:12b-it-qat", "gemma4:e2b-it-qat",
              "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"):
        subprocess.run(["ollama", "stop", m], check=False, capture_output=True)

    with OUT.open("w") as out:
        for f in fixtures:
            r = generate(build_prompt(f["raw"], "semi-casual", "prose", "general"), S1_OPTIONS)
            out.write(json.dumps({"model": "s1-mini", "config": "semi-casual/prose/general",
                                  "stratum": f["stratum"], "fixture_id": f["id"],
                                  "input_words": len(f["raw"].split()), **r},
                                 ensure_ascii=False) + "\n")
            out.flush()
        print("s1-mini done", flush=True)
        subprocess.run(["ollama", "stop", "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"],
                       check=False, capture_output=True)
        time.sleep(1.5)

        for name, model_id, prompt_id, prompt_file in CHAT_MODELS:
            system = (BASE / "prompts" / prompt_file).read_text().strip()
            for f in fixtures:
                r = run_chat(model_id, system, f["raw"])
                out.write(json.dumps({"model": name, "config": prompt_id,
                                      "stratum": f["stratum"], "fixture_id": f["id"],
                                      "input_words": len(f["raw"].split()), **r},
                                     ensure_ascii=False) + "\n")
                out.flush()
            print(f"{name} done", flush=True)
            subprocess.run(["ollama", "stop", model_id], check=False, capture_output=True)
            time.sleep(1.5)


if __name__ == "__main__":
    main()
