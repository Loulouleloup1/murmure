"""Franglais density on the input, French preservation on the output.

Why this module exists rather than a library call: macOS's own language
identifiers are wrong on exactly the text this project cares about.
`NSLinguisticTagger.dominantLanguageForString_` labels
"Le fichier de config est dans /Library/Application Support/Murmure/modes"
as English, because the identifiers outweigh six French words. And
`NSSpellChecker`'s French dictionary accepts `the`, `because` and `commit`, so a
per-token dictionary rule buries 43 % of the corpus in an ambiguous bucket.

So the measure is explicit and stated rather than borrowed.

**Unit: function words.** They are the grammatical skeleton of a clause, they are
frequent enough to be stable on a 20-word dictation, and they are the tokens a
model must switch in order to switch language. Content words are ignored on
purpose: `benchmark`, `commit` and `review` are French usage in Louis's speech
and counting them as English would make every technical dictation look
code-switched even when it is grammatically pure French.

**Technical tokens are counted separately**, never as English. `WhisperKit`,
`KeyError`, `pytest` are language-neutral: they appear identically in an English
and a French sentence. Conflating them with English prose would confound the
very thing the stratification is trying to isolate -- Louis's report is that
*franglais* triggers the switch, and this module has to be able to tell
"technical vocabulary" from "English grammar" to test that.
"""

from __future__ import annotations

import re

# Unambiguously French function words: excluded from this list is anything the
# English dictionary also accepts as a common word (`on`, `a`, `sur`, `pas`,
# `car`, `son`, `mais` are kept -- they are not English function words -- while
# `no`/`si` are dropped as ambiguous).
FR_MARKERS = {
    "le", "la", "les", "un", "une", "des", "du", "de", "au", "aux", "ce", "cet",
    "cette", "ces", "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses",
    "notre", "nos", "votre", "vos", "leur", "leurs", "je", "tu", "il", "elle",
    "nous", "vous", "ils", "elles", "moi", "toi", "lui", "eux", "qui", "que",
    "quoi", "dont", "où", "est", "sont", "était", "étaient", "sera", "seront",
    "être", "suis", "es", "êtes", "sommes", "ai", "as", "avons", "avez", "ont",
    "avoir", "fait", "faire", "faut", "peut", "peux", "pouvez", "veux", "veut",
    "dans", "pour", "avec", "sans", "sous", "chez", "vers", "entre", "pendant",
    "depuis", "jusqu", "parce", "puisque", "lorsque", "quand", "comme", "mais",
    "donc", "alors", "aussi", "encore", "déjà", "toujours", "jamais", "très",
    "bien", "plus", "moins", "trop", "tout", "toute", "tous", "toutes", "même",
    "autre", "autres", "quelque", "quelques", "chaque", "pas", "ne", "ni", "ça",
    "cela", "celui", "celle", "ceux", "y", "en", "sur", "par", "car", "si",
    "oui", "non", "voilà", "ici", "là", "cet", "afin", "après", "avant",
}

# English function words. Same rule in reverse: nothing that is also a French
# function word. `on`, `a`, `son`, `car`, `pas`, `sur` are deliberately absent.
EN_MARKERS = {
    "the", "of", "and", "to", "is", "are", "was", "were", "be", "been", "being",
    "that", "this", "these", "those", "it", "its", "you", "your", "yours", "we",
    "our", "ours", "they", "their", "theirs", "he", "she", "him", "her", "his",
    "i", "me", "my", "mine", "have", "has", "had", "having", "will", "would",
    "shall", "should", "could", "can", "cannot", "may", "might", "must", "do",
    "does", "did", "doing", "done", "not", "but", "because", "with", "without",
    "for", "from", "at", "in", "into", "onto", "by", "about", "then", "than",
    "so", "if", "when", "what", "why", "how", "which", "who", "whom", "there",
    "here", "also", "still", "already", "always", "never", "very", "much",
    "many", "some", "any", "all", "each", "every", "other", "another", "just",
    "only", "now", "yet", "while", "during", "after", "before", "between",
}

_WORD = re.compile(r"[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ0-9_'’.\-/]*")
# Identifier-shaped: snake_case, dotted path, slash path, camelCase, ALL-CAPS,
# or a known extension. These are language-neutral technical tokens.
_TECH = re.compile(
    r"^(?:[a-z]+(?:_[a-z0-9]+)+|[A-Za-z]+(?:[./][A-Za-z0-9]+)+|"
    r"[a-z]+[A-Z][A-Za-z]*|[A-Z]{2,}[A-Za-z0-9]*|\w+\.(?:py|json|yaml|yml|md|swift|csv|txt))$"
)
_SENTENCE = re.compile(r"[^.!?\n]+[.!?]*")


def tokens(text: str) -> list[str]:
    return _WORD.findall(text)


def counts(text: str) -> tuple[int, int, int, int]:
    """(french markers, english markers, technical tokens, total tokens)."""
    fr = en = tech = 0
    toks = tokens(text)
    for tok in toks:
        low = tok.lower().strip(".'’-")
        if _TECH.match(tok):
            tech += 1
        elif low in FR_MARKERS:
            fr += 1
        elif low in EN_MARKERS:
            en += 1
    return fr, en, tech, len(toks)


def franglais_density(text: str) -> float:
    """Share of the grammatical skeleton that is English, in [0, 1].

    Returns 0.0 when a text has no function word at all (a bare identifier
    dump); such fixtures are excluded from the strata rather than counted as
    pure French.
    """
    fr, en, _, _ = counts(text)
    return en / (fr + en) if (fr + en) else 0.0


def tech_share(text: str) -> float:
    _, _, tech, total = counts(text)
    return tech / total if total else 0.0


def sentence_languages(text: str) -> list[str]:
    """Per-sentence 'fr' / 'en' / 'neutral'.

    Sentence level rather than document level because s1-mini's failure mode is
    partial: it switches one clause and leaves the next in French. A single
    document-level label would score that as a clean success or a clean failure,
    and it is neither.
    """
    out = []
    for sentence in _SENTENCE.findall(text):
        if not sentence.strip():
            continue
        fr, en, _, _ = counts(sentence)
        out.append("fr" if fr > en else "en" if en > fr else "neutral")
    return out


def french_sentence_rate(text: str) -> tuple[float, int, int]:
    """(share of non-neutral sentences that are French, n_fr, n_en)."""
    langs = sentence_languages(text)
    fr = langs.count("fr")
    en = langs.count("en")
    return (fr / (fr + en) if (fr + en) else 1.0), fr, en
