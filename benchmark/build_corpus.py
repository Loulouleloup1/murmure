"""Build the prompt-mode corpus: Louis's real agent dictations.

Two sources, both local, never committed:
  - murmure.sqlite: 17 rows, every one dictated in `prompt` mode into Ghostty/Cursor/Slack.
  - superwhisper 2026-08-31: the day before, same working context (dictating to Claude Code).

Stratified by length, because length is what the structuring task is sensitive to: a 60-character
acknowledgement has nothing to structure and is the strongest invention bait there is, while a
1000-character dictation is where structuring earns its seconds.
"""
import glob, json, os, sqlite3

OUT = "benchmark/fixtures-promptmode.local.jsonl"
rows = []

db = os.path.expanduser("~/Library/Application Support/Murmure/murmure.sqlite")
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
for rid, app, raw in con.execute(
    "select id, targetAppName, rawTranscript from dictation "
    "where rawTranscript is not null and length(rawTranscript) >= 40 order by id"
):
    rows.append({"id": f"mur-{rid:02d}", "source": "murmure-prompt-mode", "app": app,
                 "raw": raw.strip()})
con.close()

for p in sorted(glob.glob(os.path.expanduser("~/Documents/superwhisper/recordings/*/meta.json"))):
    try:
        m = json.load(open(p))
    except Exception:
        continue
    t = (m.get("result") or m.get("rawResult") or "").strip()
    d = m.get("datetime", "")
    if t and len(t) >= 40 and d.startswith("2026-08-31"):
        rows.append({"id": f"sw-{os.path.basename(os.path.dirname(p))}", "source": "superwhisper",
                     "app": "claude-code", "raw": t})

for r in rows:
    n = len(r["raw"])
    r["chars"] = n
    r["stratum"] = "short" if n < 150 else ("medium" if n < 500 else "long")

with open(OUT, "w") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")

from collections import Counter
print("total:", len(rows))
print("strata:", Counter(r["stratum"] for r in rows))
print("source:", Counter(r["source"] for r in rows))
print("chars: min", min(r["chars"] for r in rows), "max", max(r["chars"] for r in rows))
