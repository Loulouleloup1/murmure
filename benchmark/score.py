"""Score each arm on the two mechanical metrics the rubric defines.

FAB-TASK  a NO-ASK dictation answered with a "Tâche :" line -- a task made up where the speaker
          asked for nothing. The sharpest form of "does not invent", and arm-independent because
          the NO-ASK set was fixed before any arm was scored.
EMPTY-HDG a heading emitted with nothing behind it ("Contraintes : Aucune", "Contexte : Non
          spécifié", or a heading followed by nothing) despite the instruction to omit it.
          Instruction-following, and the tell that the template is driving the model.
"""
import json, re, sys, unicodedata

no_ask = {l.strip() for l in open(
    "benchmark/no_ask.txt")
    if l.strip() and not l.startswith("#")}

EMPTY = re.compile(
    r"^\s*(Tâche|Contexte|Contraintes)\s*:\s*(aucun\w*|non\s+spécifié\w*|n/?a|rien|\s*)\s*$",
    re.I | re.M)
# A "Tâche :" whose value is "Aucune"/"Non spécifié" is the model DECLINING to invent a task.
# Counting it as a fabrication would overstate the defect; only a real action counts.
HAS_TASK = re.compile(r"^\s*Tâche\s*:\s*(?!aucun|non\s+spécifié|n/?a\b|rien|\s*$)\S", re.I | re.M)
ANY_HDG = re.compile(r"^\s*(Tâche|Contexte|Contraintes)\s*:", re.I | re.M)

print(f"{'arm':<12} {'n':>3} {'FAB-TASK':>18} {'EMPTY-HDG':>16} {'structured':>11} {'med_s':>7} {'max_s':>7}")
for arm in sys.argv[1:]:
    rows = [json.loads(l) for l in open(f"benchmark/results-promptmode-{arm}.local.jsonl")]
    fab = [r["id"] for r in rows if r["id"] in no_ask and HAS_TASK.search(r["output"])]
    empt = [r["id"] for r in rows if EMPTY.search(r["output"])]
    struct = sum(1 for r in rows if ANY_HDG.search(r["output"]))
    lat = sorted(r["latency_s"] for r in rows)
    med = lat[len(lat) // 2]
    n_noask = sum(1 for r in rows if r["id"] in no_ask)
    print(f"{arm:<12} {len(rows):>3} {len(fab):>3}/{n_noask:<3} ({100*len(fab)/max(1,n_noask):>4.0f}%)"
          f"   {len(empt):>3}/{len(rows):<3} ({100*len(empt)/len(rows):>4.0f}%)"
          f"  {struct:>3}/{len(rows):<3} {med:>7.2f} {max(lat):>7.2f}")
    print(f"             FAB-TASK ids: {', '.join(fab) if fab else '(none)'}")
