# Refiner benchmark rubric — FROZEN 2026-08-31, before any model output was generated

Each output is scored on 4 criteria, 0–2 each (max 8):

1. **Semantic fidelity** — 2: nothing added, lost, or distorted; 1: minor drift
   (a nuance weakened, a redundancy collapsed with slight loss); 0: content
   invented, dropped, or meaning changed.
2. **Disfluency removal** — 2: all hesitations/fillers/false starts gone; 1: a few leftovers; 0: transcript essentially unclean.
3. **Verbatim preservation** — 2: every technical term, product name, path,
   command, and English word kept exactly (spoken "slash"/"point" conversion
   expected); 1: one term altered/translated; 0: two or more altered.
4. **Format compliance** — 2: output is only the target text; 1: cosmetic noise
   (stray quotes, trailing whitespace lines); 0: preamble, commentary, markdown
   fences, or refusal.

Auto-fail (total = 0 regardless of criteria): output in the wrong language
(technical terms aside), output that answers the transcript's question instead
of cleaning/rewriting it, empty output.

Score each (fixture × task × candidate letter) independently. Do not compare
letters against each other while scoring; scores are absolute against this
rubric.
