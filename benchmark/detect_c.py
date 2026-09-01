"""Layer A for the no-task-slot design: novel content words, plus the degenerate-winner guards.

This design claims to keep the speaker's own words, so a content word appearing in the output and
nowhere in the input is direct evidence of added material -- which it would not have been under a
task-slot design, where reformulation is the whole point. That is why the detector changes with
the design rather than being carried over.

Over-reports by construction (French inflection, a legitimate connective). It selects what Layer B
reads; it does not decide.
"""
import difflib, json, re, sys, unicodedata

# Function words, auxiliaries and discourse glue: their appearance asserts nothing on its own.
STOP = set("""
le la les un une des de du au aux a et ou mais donc car ni or que qui quoi dont ou si non oui
je tu il elle on nous vous ils elles me te se lui leur y en ce cet cette ces celui celle ceux
mon ma mes ton ta tes son sa ses notre nos votre vos leurs
est sont etre suis es sommes etes etaient etait sera seront ete
ai as a avons avez ont avait avaient eu
pour par sur dans avec sans sous vers chez entre pas plus moins tres bien mal aussi meme
tout tous toute toutes autre autres chaque quelque quelques
ne pas plus jamais rien aucun aucune
il faut faut falloir peut peuvent pouvoir doit doivent devoir va vont aller fait faire fais faites
comme alors ainsi puis ensuite enfin voila donc quand lors lorsque parce
ce cela ca c s d l j m n t qu qu'il qu'on
la les des du de a
""".split())


def norm(s):
    s = unicodedata.normalize("NFD", s)
    return "".join(c for c in s if unicodedata.category(c) != "Mn").lower()


def content_words(text):
    return [w for w in re.findall(r"[\w'./~-]{3,}", norm(text)) if w not in STOP]


def grounded(w, src_words):
    if w in src_words:
        return True
    # French inflection: accept a shared 5-char stem in either direction.
    stem = w[:max(5, len(w) - 3)]
    return any(s.startswith(stem) or w.startswith(s[:max(5, len(s) - 3)]) for s in src_words)


rows = [json.loads(l) for l in open(sys.argv[1])]
flagged, copies, seg, novel_tot = [], 0, 0, 0
for r in rows:
    src = set(content_words(r["raw"]))
    novel = sorted({w for w in content_words(r["output"]) if not grounded(w, src)})
    ratio = difflib.SequenceMatcher(None, norm(r["raw"]), norm(r["output"])).ratio()
    segs = len([x for x in re.split(r"\n\s*\n|\n\s*[-*]\s+", r["output"].strip()) if x.strip()])
    if ratio >= 0.95:
        copies += 1
    if segs >= 2:
        seg += 1
    novel_tot += len(novel)
    if novel:
        flagged.append((r["id"], r["stratum"], novel))

print(f"=== {sys.argv[1]}")
for i, s, n in flagged:
    print(f"  {i:>16} [{s:>6}] {', '.join(n[:12])}")
print(f"  outputs with >=1 novel content word: {len(flagged)}/{len(rows)}"
      f"   total novel words: {novel_tot}")
print(f"  COPY (>=0.95 similar to input): {copies}/{len(rows)}"
      f"   SEG (>=2 segments): {seg}/{len(rows)}")
