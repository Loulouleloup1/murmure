"""Layer A of the invention test: deterministic hard-token grounding.

A "hard token" is a token that paraphrase does not legitimately create: a number, a code
identifier (snake_case, camelCase, dotted, slashed, ALL-CAPS), or a capitalised word that is not
sentence-initial (a proper noun). Restructuring may freely reword prose; it may not conjure a
figure, a filename or a name. So: every hard token in the output that is absent from the input is
an invention CANDIDATE, listed for adjudication rather than counted as a verdict.

Deliberately a candidate generator, not a judge. It over-reports (a French inflection, a
re-cased word) and it under-reports (an invented constraint written in plain prose carries no
hard token at all). Layer B, the pre-registered rubric applied per output, is the verdict.
"""
import json, re, sys, unicodedata

HEADINGS = {"tache", "contexte", "contraintes", "taches", "contrainte"}
# Sentence-initial capitals and common French openers are not proper-noun evidence.
STOP = {
    "le","la","les","un","une","des","de","du","il","elle","on","je","tu","nous","vous","ils",
    "ce","cette","ces","et","ou","mais","donc","car","que","qui","quoi","dont","ou","si","non",
    "oui","pour","par","sur","dans","avec","sans","pas","plus","moins","tout","tous","toute",
    "toutes","est","sont","etre","avoir","fait","faire","peut","pouvoir","doit","devoir","alors",
    "aussi","meme","tres","bien","cela","ca","en","au","aux","a","y","l","d","c","s","n","j","m",
    "t","qu","actuellement","ensuite","enfin","voila","ok","aucune","aucun","rien","comme",
}


def norm(s):
    s = unicodedata.normalize("NFD", s)
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    return s.lower()


def hard_tokens(text, sentence_initial_ok=True):
    """Return (kind, token) pairs worth grounding."""
    out = []
    for m in re.finditer(r"\d[\d.,]*", text):
        out.append(("num", m.group()))
    for m in re.finditer(r"[A-Za-z_~./][\w./~-]*[\w/]", text):
        t = m.group()
        if "_" in t or "/" in t or "." in t and not t.endswith(".") or "~" in t:
            if not re.fullmatch(r"[A-Za-zÀ-ÿ]+", t):
                out.append(("ident", t))
        elif re.fullmatch(r"[A-Z]{2,}", t):
            out.append(("acronym", t))
        elif re.search(r"[a-z][A-Z]", t):
            out.append(("ident", t))
    # Proper nouns: capitalised, not after a sentence end, not a heading, not a stopword.
    for m in re.finditer(r"(?<![.!?:\n]\s)(?<!^)\b([A-ZÀ-Ý][\wÀ-ÿ-]{2,})\b", text, re.M):
        t = m.group(1)
        if norm(t) in STOP or norm(t) in HEADINGS:
            continue
        out.append(("proper", t))
    return out


def grounded(tok, src_norm, src_words):
    t = norm(tok).strip(".,;:!?()\"'")
    if not t:
        return True
    if t in src_norm:
        return True
    # French inflection / plural: accept a 5+ char prefix match against any source word.
    if len(t) >= 5:
        for w in src_words:
            if w.startswith(t[:max(5, len(t) - 2)]) or t.startswith(w[:max(5, len(w) - 2)]):
                return True
    return False


rows = [json.loads(l) for l in open(sys.argv[1])]
tot = 0
flagged = 0
for r in rows:
    src = norm(r["raw"])
    src_words = set(re.findall(r"[\w./~-]+", src))
    cands = []
    seen = set()
    for kind, tok in hard_tokens(r["output"]):
        if norm(tok) in seen:
            continue
        seen.add(norm(tok))
        if not grounded(tok, src, src_words):
            cands.append(f"{kind}:{tok}")
    tot += len(cands)
    if cands:
        flagged += 1
        print(f"{r['id']:>16} [{r['stratum']:>6}] {', '.join(cands)}")
print(f"\n{sys.argv[1]}")
print(f"outputs with >=1 hard-token candidate: {flagged}/{len(rows)}   total candidates: {tot}")
