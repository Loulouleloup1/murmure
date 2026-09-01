"""Probe s1-mini's control line before freezing the v3 grid.

v2 established the transport (`/api/generate` with `raw: true`; `/api/chat`
returns empty because Ollama parses the model's open `<think>` block) and one
working control line. It never explored the control line itself, and it never
asked whether the generic system prompt in front of it helps or hurts a model
that was trained for exactly this task.

Output goes to `probe-s1.local.jsonl` (gitignored) because it may run on real
fixtures.
"""

from __future__ import annotations

import json
import pathlib
import sys
import time

import requests

BASE = pathlib.Path(__file__).parent
GENERATE = "http://localhost:11434/api/generate"
MODEL = "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"
OPTIONS = {"temperature": 0, "seed": 20260901, "num_predict": 2048, "num_ctx": 8192}

V2_SYSTEM = (
    "You are a text normalizer for speech-to-text transcripts. The input begins "
    "with a control line specifying the styling, structure, and context settings; "
    "clean the transcript to match those settings and output only the cleaned text."
)

# Each variant is (system_or_None, control_line_or_None).
VARIANTS = {
    # v2's exact setup -- the anchor.
    "v2repro": (V2_SYSTEM, "[Styling: semi-casual] [Structure: prose] [Context: general]"),
    # No system at all: does the purpose-built model need the explanation?
    "bare": (None, "[Styling: semi-casual] [Structure: prose] [Context: general]"),
    # No control line either: what is the model's default behaviour?
    "naked": (None, None),
    # Control line only, with a context that names the actual domain.
    "ctx_tech": (
        None,
        "[Styling: semi-casual] [Structure: prose] "
        "[Context: French dictation with English technical terms, file paths and commands]",
    ),
    # Does the model honour an extra, non-schema control key?
    "ctx_lang": (
        None,
        "[Styling: semi-casual] [Structure: prose] [Context: general] [Language: French]",
    ),
    # Styling axis. v2 warns `formal` corrupts facts; check `casual` and `default`.
    "styling_casual": (None, "[Styling: casual] [Structure: prose] [Context: general]"),
    "styling_default": (None, "[Styling: default] [Structure: prose] [Context: general]"),
    # Structure axis.
    "struct_para": (None, "[Styling: semi-casual] [Structure: paragraphs] [Context: general]"),
    # Can a plain instruction be appended to the control line?
    "ctrl_plus": (
        None,
        "[Styling: semi-casual] [Structure: prose] [Context: general]\n"
        "Capitalise every sentence and end every sentence with punctuation. "
        "Keep the text in French. Remove hesitations and fillers.",
    ),
}


def call(system: str | None, control: str | None, raw_text: str) -> dict:
    parts = []
    if system:
        parts.append(f"<|im_start|>system\n{system}<|im_end|>\n")
    user = f"{control}\n{raw_text}" if control else raw_text
    parts.append(f"<|im_start|>user\n{user}<|im_end|>\n")
    parts.append("<|im_start|>assistant\n<think>\n\n</think>\n\n")
    t0 = time.monotonic()
    resp = requests.post(
        GENERATE,
        json={
            "model": MODEL,
            "prompt": "".join(parts),
            "raw": True,
            "stream": False,
            "options": {**OPTIONS, "stop": ["<|im_end|>", "<|im_start|>"]},
        },
        timeout=600,
    )
    resp.raise_for_status()
    data = resp.json()
    return {
        "output": data.get("response", "").strip(),
        "latency_s": round(time.monotonic() - t0, 3),
        "completion_tokens": data.get("eval_count", 0),
        "done_reason": data.get("done_reason", ""),
    }


def main() -> None:
    fixtures = [
        json.loads(line)
        for line in (BASE / "fixtures.jsonl").read_text().splitlines()
        if line.strip()
    ]
    picked = [f for f in fixtures if f["id"] in {"f01", "f04", "f08", "f12"}]
    out_path = BASE / "probe-s1.local.jsonl"
    with out_path.open("w") as out:
        for name, (system, control) in VARIANTS.items():
            for fixture in picked:
                row = {"variant": name, "fixture_id": fixture["id"], **call(system, control, fixture["raw"])}
                out.write(json.dumps(row, ensure_ascii=False) + "\n")
                out.flush()
                print(f"{name:16} {fixture['id']} {row['latency_s']:5.2f}s "
                      f"{row['completion_tokens']:3d}tok  {row['output'][:90]!r}",
                      file=sys.stderr)


if __name__ == "__main__":
    main()
