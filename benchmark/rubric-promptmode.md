# Layer B rubric — pre-registered before reading any output

Applied identically to every arm, one verdict per (input, output) pair.

## Categories

- **INV-REQ** (the primary metric): the output states a task, constraint, success criterion,
  verification step, deliverable, file, tool or method that the input did not state.
  This is Louis's bar: "structure without inventing". Any count > 0 is a defect.
- **INV-FACT**: the output asserts a fact about the world or the codebase absent from the input.
- **DROP-REQ**: a request, question or constraint present in the input is missing from the output.
  The dual failure — a prompt mode that loses a constraint is worse than one that adds prose.
- **FMT**: preamble, commentary, fences, or an empty heading written anyway
  ("Contraintes : Aucune") — instruction-following, cosmetic but diagnostic.
- **LANG**: output not in French, or a technical term translated.
- **STRUCT**: 1 if the output actually segments the content into task / context / constraints and
  assigns it correctly; 0 if it returns undifferentiated prose. Guards against the degenerate
  winner — echoing the input verbatim passes the invention test perfectly and is worth nothing.

## Primary verdict

Fraction of outputs with >= 1 INV-REQ, per arm. A candidate that structures beautifully and
invents on 1 dictation in 4 loses to one that structures plainly and never invents.
