# Pre-registered metric for the no-task-slot design (written BEFORE any arm was run)

FAB-TASK cannot score this design: there is no `Tâche :` slot to fabricate into. Its equivalent,
per the constraint that the metric must change with the design:

## ADD-CLAIM (primary) — an assertion in the output that is absent from the input

Counted **wherever it appears** — bullet, paragraph, anywhere — precisely because a model denied a
task slot can still invent under a heading or in prose. Scored per output as 0 or >=1.

An ADD-CLAIM is a proposition the output asserts that the transcript does not: a task, a
constraint, a success criterion, a verification step, a file, a tool, a number, a name, or a fact
about the world. A rewording of something the speaker did say is NOT an ADD-CLAIM.

### Two layers, because one is not enough

- **Layer A (mechanical, deterministic).** Every *content word* in the output absent from the
  input after accent/inflection normalisation. Extended from the earlier hard-token detector on
  purpose: this design claims to keep the speaker's own words, so a novel content word is
  on-target evidence here, where under a task-slot design it would have been noise.
- **Layer B (adjudication).** I read every output Layer A flags, AND a fixed random sample of
  20 that it does not, to estimate how much Layer A misses. Reporting the false-negative check
  rather than assuming the mechanical layer caught everything.

## Guard against the degenerate winner

An output that copies the input passes ADD-CLAIM perfectly and is worth nothing.

- **COPY**: output >= 0.95 similar to the input (difflib ratio) — the degenerate case.
- **SEG**: output carries >= 2 distinct segments (bullets or paragraphs).
- **Usefulness on the 42 request dictations**: judged and reported separately, because that is
  the population the mode exists for.

## Held constant from the first measurement

Same 53 dictations, same wire shapes, same seed, models strictly sequential, both candidates run.
