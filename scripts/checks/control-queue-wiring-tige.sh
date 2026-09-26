#!/usr/bin/env bash
# Contract probe for lot 10-S-R: the stem of the WRITTEN document is carried, never re-derived.
#
#   usage : control-queue-wiring-tige.sh <chemin/TranscriptsPaneModel.swift> [mutant]
#   mutant-b, mutant-c, mutant-d, mutant-table, mutant-fantome, mutant-fantome-c2, mutant-c1,
#   mutant-c5, mutant-d2
#   sortie : 0 = câblage sain, 1 = défaut constaté, 2 = base inexploitable, 3 = mutant inapplicable
#
# WHY A SEPARATE FILE, and not `scripts/checks/control-queue-wiring.sh`
# ---------------------------------------------------------------------------------------
# Plan rev. 25 (l. 1481-1483) states that path "n'existe pas encore" and gives this QA sole
# authorship of it.  MEASURED, that is false: the path is already occupied by the 10-S gate
# written by parent `t_3762b434` — 494 lines, sha256 c5f75566…, three mutant modes and a real
# XCTest filter — and the round-2 review of that parent replayed it green (wire 21/21 rc=0) on
# those exact bytes.  Overwriting it would delete a gate another card owns and whose verdict a
# passed review rests on, so this contract does not touch it.  The two contracts also judge
# different things: that one is the 10-S panel/socket seam, this one is the 10-S-R result key.
# Folding C1..C5 into it would make the 10-S verdict red for a reason none of ITS three mutants
# models.  The path decision belongs to the architect; the contract is delivered here so no
# measured work is lost either way.
#
# REPLAYING IT — one command, all of it:
#   bash scripts/checks/evidence-10sr.sh
# That harness is the author's evidence, not a second gate: it prints the rc of every assembly
# and every mutant, and asserts only what a reader can check by re-running this file by hand.
#
# MEASURES behind this file (replayed by its author, not asserted):
#   assembly                rc   named controls red
#   10-S base as delivered   1   C1, C2, C3, C5
#   corrected base           0   — (5/5 vert)
#   unreadable file          2   refused
#   panel with no seam       2   refused (a control that cannot fail is not a control)
#   mutant-b  identity       1   C3 only
#   mutant-c  key table      1   C4 only
#   mutant-d  re-tests source 1  C2 only
#   mutant-table [entryID:]  1   C4 only
#   mutant-fantome           1   C3 only  (this is R2, caught — see below)
#   mutant-fantome-c2       1   C2 only  (this is R3, caught — see below)
#   mutant-c1               1   C1 only  (the table had no C1 capture)
#   mutant-c5               1   C5 only  (the table had no C5 capture)
#
# WHAT THIS CONTRACT DOES **NOT** COVER — measured, not assumed.  Re-measure with
# `bash scripts/checks/.evasions-tige.sh`, which replays four escape routes:
#   A  the re-test two levels down (arm -> f1 -> f2 -> launch)      C2 red   covered
#   C  the re-test spelled `launch (for:)`, one space               C2 red   covered
#   D  a helper declared inside a closure the arm calls             C2 red   covered
#   B  the re-test behind a STORED PROPERTY (`lecteur?.tige(…)`)    rc=0     NOT COVERED
#
# B is the honest limit of a source-reading probe, and it is the same limit as the one the plan
# fixed by principle rather than by pattern: a second authority reached through a property is
# outside what a call graph can see.  The plan's own answer is rule 10 — a single writer, the
# queue — and C4 catches the second authority where it is *declared* in the panel.  What no
# reading of one Swift file can establish is that a type declared in another file does not
# re-derive; only the XCTest card `t_de890205` (a) and the Finder gate 11-S can, and they do it by
# RUNNING the code.  This file therefore does not claim B, and a rewriter must not read the
# silence as coverage.
#
# THE TWO MEASURED PITFALLS the plan's candidate documents, both preserved:
#  1. The resolution path is the `.done` arm PLUS the body of `documentID(for:)`.  On the
#     delivered base the defect lives INSIDE `documentID(for:)`, not in the arm: reading the arm
#     alone turns C2 and C3 GREEN AT FAITH.  Measured, not theorised — it is what let
#     `documentID(for:)` go unnoticed.
#  2. The pattern is `launch(for:` WITHOUT the closing parenthesis.  Real code reads
#     `launch(for: <expr>)`, so `grep 'launch(for:)'` matches nothing on a source that contains
#     three (measured: 0 vs 3).  A probe using the parenthesised pattern is DEAD: green
#     everywhere, and it lets mutant (d) through.
#
# R2 (non-blocking finding of the round-4 review of the parent, handed to this card): the
# candidate resolved the path with a FIXED `grep -A 8` WINDOW — a length in lines, not a
# syntactic extent — so a `library.transcript(id:)` on a recomputed key planted beyond the
# window reads BASE-SAINE rc=0.  A rewriter inherits that false green.  This file resolves by
# BRACE BALANCING instead, the tool already used in this repo for the twelve parent closures:
# a forbidden word cannot escape by sitting a few lines further down.
#
# R3 (finding of the round-1 review of THIS contract, and the reason the extractor closes over
# calls): C2 was still scoped to the arm plus the body of `documentID(for:)`, while C3 had
# already been widened to every call site.  Measured on the green base, a helper
# `relireTige(entree:)` declared OUTSIDE the switch, called from the `.done` arm and re-entering
# `launch(for:`, left C2 VERT: the success path re-tested the source again — contract 4's exact
# defect — and the gate said 5/5.  R2's principle ("a window is a line count, the class is
# reachability") applied to C3 applies to C2, so it now does.  `mutant-fantome-c2` is the
# capture; `mutant-d2` is demoted below from a "falsifiability condition" to a KNOWN LIMIT, which
# is what it always measured — its anchor does not exist on the corrected base.
set -u
PANE="${1:?usage: control-queue-wiring-tige.sh <chemin/TranscriptsPaneModel.swift> [mutant-b|mutant-c|mutant-d]}"
MUTANT="${2:-}"

if [ ! -r "$PANE" ]; then
  echo "BASE-INEXPLOITABLE — $PANE illisible"
  exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/murmure-control-tige.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$PANE" "$work/pane.swift"

# --- mutants: applied to the COPY, never to the tree under test -------------------------
# Each mutant is the class of defect it names, written the way a careless DEV writes it.  The
# probe then re-reads the copy: a control that flips is a capture, and a mutation that changes
# nothing is inapplicable — reported as such (rc=3) rather than counted as proof.
case "$MUTANT" in
  mutant-b)
    # (b) the IDENTITY is handed over where the stem is expected — the key defect itself.
    # Anchored on `terminal.documentID`, the shape the corrected base actually has: a
    # re-derivation replacing the carried stem.  (Anchoring on the OLD base's
    # `transcript(id: identity)` is inapplicable here by construction — the corrected base has
    # no such call left, and a mutation that changes nothing proves nothing, so it would be
    # reported inapplicable rather than counted as a capture.)
    perl -0777 -i -pe 's{return \.complete\(documentID: terminal\.documentID\)}{return .complete(documentID: terminal.source.identity)}' \
      "$work/pane.swift" || : ;;
  mutant-c)
    # (c) a SECOND AUTHORITY beside the queue: a key table in the panel.  Anchored on the
    # library property as it is DECLARED (`private let library:`, measured) — anchoring on a
    # `var` spelling that the file does not use is a mutation that changes nothing, which is
    # inapplicable and proves nothing.
    perl -0777 -i -pe 's{(\n    private let library: TranscriptLibrary)}{    private var tigeParEntree: [String: String] = [:]$1}' \
      "$work/pane.swift" || : ;;
  mutant-d)
    # (d) the success path RE-TESTS the source: it re-enters `launch(for:`, so a source deleted
    # mid-job fails a second time, silently.  (b) is about the KEY, (d) about the DEPENDENCY on
    # the source existing — neither substitutes for the other.
    perl -0777 -i -pe 's{(case \.done:\n)}{$1            _ = Self.launch(for: terminal.source)\n}' \
      "$work/pane.swift" || : ;;
  mutant-d2)
    # KNOWN LIMIT, not a falsifiability condition — reclassified after the round-1 review, which
    # was right that the previous table sold it as more than it measured.  Its anchor
    # (`private func documentID(for element:`) is ABSENT from the corrected base, so on that base
    # the mutation changes nothing and rc=3 says only that.  What it cannot say is that C2 covers
    # the shape; the shape is covered by `mutant-fantome-c2`, which reaches the same dependency
    # through a helper and IS in the capture table.  This mutant keeps its other use, below.
    perl -0777 -i -pe 's{(private func documentID\(for element: TranscriptQueueEntry\) -> String\? \{\n)}{$1        _ = Self.launch(for: element.source)\n}' \
      "$work/pane.swift" || : ;;
  mutant-fantome)
    # A recomputed key planted far from the arm, past where a FIXED-LINE-WINDOW probe would
    # stop.  This is the false green R2 measured; C3 must still catch it.  The mutation is
    # applied to the DELIVERED base, where the arm and the helper both exist.
    perl -0777 -i -pe 's{(\n    private func announceFailure\()}{\n    private func relireTige(entree: TranscriptQueueEntry) -> String? {\n        library.transcript(id: Self.launch(for: entree.source)?.source.identity ?? "")\n        return nil\n    }\n$1}' \
      "$work/pane.swift" || : ;;
  mutant-fantome-c2)
    # R3, the round-1 finding, as a CAPTURE: the re-test of the source reached through a HELPER
    # declared OUTSIDE the switch and called from the `.done` arm.  C2 used to read the arm plus
    # the body of `documentID(for:)` and nothing else, so this mutation came out BASE-SAINE
    # rc=0 — the success path re-tested the source, contract 4's exact defect, under a green gate.
    # It is applied to the CORRECTED base, where `documentID(for:)` is gone: the hole this probes
    # is a hole in the gate's reachability, not in the fix, so the corrected base is the honest
    # place to demonstrate it.  Without this capture the gate's silence on this shape would be
    # indistinguishable from coverage, which is exactly what the review refused to accept.
    perl -0777 -i -pe 's{(\n    private func announceFailure\()}{\n    private func relireTige(entree: TranscriptQueueEntry) -> String? {\n        _ = Self.launch(for: entree.source)\n        return nil\n    }\n$1}' \
      "$work/pane.swift" || :;
    perl -0777 -i -pe 's{(case \.done:\n)}{$1            _ = relireTige(entree: terminal)\n}' \
      "$work/pane.swift" || : ;;
  mutant-c1)
    # C1's own capture, which the proof table was missing: a re-derivation reintroduced on the
    # success path — a `documentID(for:)` again, called from the `.done` arm.  It must flip C1 and
    # NOTHING ELSE: a re-derivation that also re-tested the source would flip C2 too and would
    # prove nothing about C1 alone.  The helper is named `documentID` because C1 asks about THAT
    # name — a first attempt called it `reDerive(terminal)` and came out rc=0, which measures
    # nothing: C1 was never dead, the mutant simply did not spell the seam it claims to reintroduce.
    perl -0777 -i -pe 's{(\n    private func announceFailure\()}{\n    private func documentID(for entree: TranscriptQueueEntry) -> String? {\n        return entree.documentID\n    }\n$1}' \
      "$work/pane.swift" || : ;
    perl -0777 -i -pe 's{(case \.done:\n)([ \t]*return \.complete\(documentID: terminal\.documentID\))}{$1            _ = documentID(for: terminal)\n$2}' \
      "$work/pane.swift" || : ;;
  mutant-c5)
    # C5's own capture: the "finished without writing" fallback re-armed on the success path.  The
    # corrected base carries no such phrase, so this proves the control is not dead.
    perl -0777 -i -pe 's{(case \.done:\n)}{$1            let vide = terminal.documentID.isEmpty\n            if vide { return .failed(reason: "finished without writing") }\n}' \
      "$work/pane.swift" || : ;;
  mutant-table)
    # (c) again, spelled the way the plan forbids: an `[entryID: stem]` table.  A French and an
    # English spelling of the same forbidden second authority, so C4 does not merely learn one
    # vocabulary.
    perl -0777 -i -pe 's{(\n    private let library: TranscriptLibrary)}{    private var table: [entryID: stem] = [:]$1}' \
      "$work/pane.swift" || : ;;
  "") : ;;
  *) echo "MODE INCONNU $MUTANT" >&2; exit 64 ;;
esac

before=$(shasum -a 256 <"$PANE")
after=$(shasum -a 256 <"$work/pane.swift")
if [ -n "$MUTANT" ] && [ "$before" = "$after" ]; then
  echo "MUTANT INAPPLICABLE $MUTANT — la mutation n'a rien changé dans la copie"
  exit 3
fi

# --- the resolution path, resolved SYNTACTICALLY (see R2 above) ---------------------------
# Two bounded extents, concatenated:
#   * the `.done` arm, closed by INDENTATION at the next same-indent `case`/`default`/`}`;
#   * the body of `documentID(for:)`, closed by brace balancing.
# Comments are stripped first, so a forbidden word in prose is never a finding — a control of
# this kind must be red for a missing seam, never for a way of talking about one.
#
# The extractor lives in a heredoc'd FILE, not in a `perl -e '…'` inside `$( )`: bash parses the
# whole command substitution before perl ever sees it, so a program containing `(` and `)` in
# that position is a shell syntax error (measured: `syntax error near unexpected token '('`).
# That failure is silent in the worst way — the substitution yields nothing, the probe finds no
# forbidden word and reports BASE-SAINE.  Same idiom as `status_paths.pl` in the 10-S gate.
cat >"$work/chemin_resolution.pl" <<'CHEMIN_RESOLUTION_PL'
use strict; use warnings;
local $/; my $x = <STDIN>;
$x =~ s{/\*.*?\*/}{}gs;
$x =~ s{//[^\n]*}{}g;
sub balanced {           # index of an opening brace -> its body, up to the matching close
  my $i = shift; my $d = 0;
  for my $p ($i .. length($x) - 1) {
    my $c = substr($x, $p, 1);
    $d++ if $c eq "{"; $d-- if $c eq "}";
    return substr($x, $i + 1, $p - $i - 1) if !$d && $p > $i;
  }
  return "";
}
my $trouve = 0;
my $bras = '';
# 1. the `.done` ARM, closed at the next `case`/`default`/`}` that is NOT DEEPER than the arm.
#    Brace balancing is wrong here, and was measured wrong: `case .done:` is followed by
#    statements, and the first `{` after it belongs to the `guard … else {` block, so a
#    balanced read of that brace returns the guard alone and MISSES the very call it wraps —
#    C1 came out VERT on the delivered base, a false green in the lot's initial red.
#
#    The arm's own indent is taken from its FIRST BODY LINE, not from the `case` line.  A
#    `case .done:` written flush at column 0 (measured: a rewritten assembly does exactly that)
#    would otherwise give an empty reference indent, no line could ever be "not deeper", and
#    the arm would run to the end of the file — judging unrelated code below as the success
#    path.  The body is the truth about how deep this arm is.
#    A NESTED `switch`/`if` is not a new arm in Swift and its `}` sits deeper, so a deeper
#    terminator is ignored and the arm stays whole.
while ($x =~ /case[ \t]+\.done[ \t]*:[ \t]*\n/gm) {
  my $st = $-[0]; my $p = index($x, "\n", $st); my $out = ''; my $ind;
  # reference indent = the indentation of the first non-blank line of the arm
  my $q = $p;
  while ($q < length($x)) {
    my $nl = index($x, "\n", $q + 1); $nl = length($x) if $nl < 0;
    my $l = substr($x, $q + 1, $nl - $q - 1);
    if ($l =~ /^([ \t]*)\S/) { $ind = $1; last }
    $q = $nl;
  }
  $ind = '' unless defined $ind;
  while ($p < length($x)) {
    my $nl = index($x, "\n", $p + 1); $nl = length($x) if $nl < 0;
    my $line = substr($x, $p + 1, $nl - $p - 1);
    if ($line =~ /^([ \t]*)(?:case\b|default\b|\})/ && length($1) <= length($ind)) { last }
    $out .= $line . "\n";
    $p = $nl;
  }
  print $out;
  $bras = $out;
  $trouve = 1;
  last;   # the success path has one shape; a second `.done` belongs to another switch
}
# 2. the body of `documentID(for:)`, wherever it is declared.  On the delivered base the defect
#    lives HERE, not in the arm: reading the arm alone turns C2 and C3 green at faith.
my $seed = '';
if ($x =~ /func[ \t]+documentID[ \t]*\(/g) {
  my $o = index($x, "{", $-[0]);
  $seed = balanced($o) if $o >= 0;
  $trouve = 1;
}
# 3. THE CLOSURE — what the success path can REACH, not what it spells.
#
#    R3 (round-1 review of this contract, MEASURED on the green base): C2 was scoped to the arm
#    plus the body of `documentID(for:)`, while C3 had been widened to every call site.  The
#    reviewer's probe declared a helper `relireTige(entree:)` OUTSIDE the switch, called it from
#    the `.done` arm, and had it re-enter `launch(for:` — the success path re-tested the source
#    again, the exact defect contract 4 exists to forbid, and the gate was 5/5 VERT.  A window is
#    a line count; the class is REACHABILITY.  So the resolution path is closed over calls: every
#    function body named by the arm or by `documentID(for:)` joins it, transitively, until fixpoint.
#
#    This is the same principle applied to C2 that R2 forced onto C3, and for the same reason: a
#    factoriser that lifts the read out of the switch reintroduces the defect under a green gate.
#
#    `init` is excluded: it is constructed, never called from a result path, and following it would
#    pull the whole panel in through `TranscriptLibrary()`.  A `func` is excluded from being its own
#    seed, which is what makes the fixpoint terminate on a recursive helper.
#
#    `launch` is excluded as well, and this exclusion is MEASURED, not tidiness.  C2 asks whether
#    the success path CALLS `launch(for:`; `launch` is the leaf that answers, so its own body is the
#    definition, not the success path.  Following it pulled `identity:` (l. 546, the `Launch` it
#    builds) into the resolution, and C3 — which reads `.identity` there — false-reded on mutant
#    (d) and on `mutant-fantome-c2`, which each flip C2 and nothing else.  A control that is red for
#    a neighbour's evidence discriminates nothing.
my %corps;                                     # declared name -> body, for every func in the panel
while ($x =~ /(?:^|\n)([ \t]*)(?:(?:public|private|fileprivate|internal|open|static|final|override|class|mutating|nonmutating|required|convenience)\s+)*func[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*(?:<[^>\n]*>)?[ \t]*\(/g) {
  my $o = index($x, "{", $-[0]);
  $corps{$2} = balanced($o) if $o >= 0;
}
my %vu;                                        # names already in the closure
# Both entry points seed the closure: the `.done` ARM and the body of `documentID(for:)`.  The
# reviewer's probe entered through the ARM (`relireTige(entree:)` called from it), so seeding only
# the helper would have left the same hole one level up.
my @graines = grep { defined && $_ ne '' } ($bras, $seed);
my @file_choisi = @graines;
my @a_visiter = @graines;
while (my $courant = shift @a_visiter) {
  while ($courant =~ /([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(/g) {
    my $nom = $1;
    next if $nom eq 'init' || $nom eq 'self' || $nom eq 'super' || $nom eq 'Self';
    next if $nom eq 'launch';   # the leaf that answers C2; its body is not the success path
    next if $vu{$nom}++;
    my $c = $corps{$nom};
    next unless defined $c && $c ne '';
    push @file_choisi, "/* via $nom */\n$c\n";
    push @a_visiter, $c;
  }
}
print @file_choisi;
# Printing nothing while exiting 0 would let a broken probe look like a found path, so the
# marker is emitted and the CALLER turns it into a hard stop rather than a pass.
print "AUCUN-CHEMIN-EXTRAIT\n" unless $trouve;
CHEMIN_RESOLUTION_PL
resolution=$(perl "$work/chemin_resolution.pl" <"$work/pane.swift")

# An empty or marked extraction is a BROKEN PROBE, not a healthy base.  A run that extracted
# nothing would find no forbidden word and report 5/5 VERT on any input at all — a control that
# cannot fail proves nothing, and this one is the lot's initial red.  Measured: this exact
# mistake (perl reading STDIN with nothing piped in) turned the delivered 10-S base
# BASE-SAINE 5/5, rc=0.  So the marker is a hard stop, never a pass.
case "$resolution" in
  *AUCUN-CHEMIN-EXTRAIT*)
    echo "BASE-INEXPLOITABLE — le chemin de résolution n'a pas pu être extrait (contrôle mort)"
    exit 2 ;;
esac
if [ -z "$resolution" ]; then
  echo "BASE-INEXPLOITABLE — le chemin de résolution n'a pas pu être extrait"
  exit 2
fi

echecs=0
rouge() { echo "ROUGE contrôle=$1 détail=$2"; echecs=$((echecs + 1)); }
vert()  { echo "VERT contrôle=$1"; }

# C1 — the result is read FROM the queue element, never through a re-derivation.
if printf '%s' "$resolution" | grep -q 'documentID(for:'; then
  rouge C1 "le résultat est lu par documentID(for:) : la clé est re-dérivée"
else
  vert C1
fi

# C2 — the success path does not depend on the source still existing (contract 4).
# Pattern WITHOUT the closing parenthesis — see pitfall 2 in the header.
#
# The whitespace between the callee and its parenthesis is NORMALISED away before matching.
# Measured: Swift permits `Self.launch (for: e.source)`, and that spelling came out
# BASE-SAINE rc=0 — a one-space evasion of the very defect C2 exists to catch.  A control keyed on
# one exact spelling is a control of a spelling, not of a defect.
#
# SCOPE: the whole REACHABLE set, not the arm and one helper.  R3 (round-1 review, measured on the
# green base): a `relireTige(entree:)` helper declared outside the switch, called from the `.done`
# arm and re-entering `launch(for:`, left this control VERT — the success path re-tested the source
# again, contract 4's exact defect, and the gate said 5/5.  The extractor now closes over calls, so
# a factoriser that lifts the read out of the switch reintroduces the defect under a RED gate
# instead.  `mutant-fantome-c2` is the capture that keeps that honest; without it, silence on this
# shape would be indistinguishable from coverage.
if printf '%s' "$resolution" | tr -d ' \t' | grep -q 'launch(for:'; then
  rouge C2 "le chemin de succès rappelle launch(for: : il re-teste l'existence de la source"
else
  vert C2
fi

# C3 — the key read is the stem, never the canonical identity.
#
# Read over EVERY `library.transcript(id:)` CALL SITE in the panel, not over the resolution path
# above.  Scoping C3 to the `.done` arm plus `documentID(for:)` is what the plan describes, and
# measured on the candidate it leaves a false green: a re-derivation planted in ANY other helper
# — `relireTige(entree:)`, say, ten lines below the arm — is outside that window, so the probe
# reports BASE-SAINE rc=0 on a panel that still recomputes its key.  That is R2, and it is a
# property of the CONCEPT, not of the window's length: a window is a line count, the class is
# "some call site hands a recomputed key to the library".
#
# So C3 asks of every call site one question: is the key a CANONICAL IDENTITY?  That is the
# defect the lot is about — `transcript(id:)` wants a stem, and the identity is never a stem.
#
# A first attempt also flagged any call site whose argument contained a CALL, on the theory that
# re-running something means recomputing the key.  Measured, that is wrong: it false-reds the
# two call sites the plan explicitly declares correct — `transcript(id: openID)` (l. 140) and
# `transcript(id: tile.id)` (l. 147) — so the corrected base came out DEFAUT-CONSTATE and the
# control could never be green.  A control that is red on a correct base proves nothing, and this
# is the lot's initial red.  Identity is the signal; a call is not.
#
# The four call sites the plan blesses — `openID`, `tile.id` — are plain reads and stay green,
# which is what makes this a control and not a blanket ban.
#
# The call site is extracted by BALANCING the parentheses from `transcript(id:` to its real
# close.  A first attempt used `grep -oE 'transcript\(id:[^)]*\)'`, and that is a trap: `[^)]*`
# stops at the FIRST `)`, so a nested call is cut in half — `transcript(id: Self.launch(for:
# entree.source)?.source.identity ?? "")` was extracted as `transcript(id: Self.launch(for:
# entree.source)`, which does not contain `.identity`, and the mutant-fantome slipped through
# with BASE-SAINE rc=0.  The defect is in the ARGUMENT, and the argument is exactly what a
# non-balancing read throws away.
cat >"$work/cles.pl" <<'CLES_PL'
use strict; use warnings;
local $/; my $x = <STDIN>;
my $n = 0;
# One ARGUMENT per line, parentheses balanced from `transcript(id:` to its real close.
while ($x =~ /transcript\(id:/g) {
  my $i = index($x, "(", $-[0]);
  my $d = 0; my $e = -1;
  for my $p ($i .. length($x) - 1) {
    my $c = substr($x, $p, 1);
    $d++ if $c eq "("; $d-- if $c eq ")";
    if (!$d) { $e = $p; last }
  }
  next if $e < 0;                       # unbalanced: not a call, do not invent one
  print substr($x, $i + 1, $e - $i - 1), "\n";
  $n++;
  pos($x) = $e;
}
# Exit non-zero when there is NO call site, so an empty extraction cannot read as a clean panel.
exit($n ? 0 : 1);
CLES_PL
toutes_les_cles=$(perl "$work/cles.pl" <"$work/pane.swift") || toutes_les_cles=""
if [ -z "$toutes_les_cles" ]; then
  # No call site at all is a broken probe, not a healthy panel: C3 could never fire.
  echo "BASE-INEXPLOITABLE — aucun appel transcript(id:) dans le panneau (contrôle mort)"
  exit 2
fi
cle_recalculee=0
while IFS= read -r un_appel; do
  [ -n "$un_appel" ] || continue
  if printf '%s' "$un_appel" | grep -q '[.]identity'; then
    cle_recalculee=1
    echo "  clé canonique lue : transcript(id:$un_appel)"
  fi
done <<<"$toutes_les_cles"
if [ "$cle_recalculee" -ne 0 ]; then
  rouge C3 "une identité canonique est lue là où la tige est attendue"
elif printf '%s' "$resolution" | grep -q '\.identity'; then
  rouge C3 "une identité canonique est lue dans le chemin de résolution"
else
  vert C3
fi

# C4 — no second authority: a key table in the panel would compete with the queue.
if grep -qE '\[String: *String\]|\[entryID|\[entree\.id|tigeParEntree' "$work/pane.swift"; then
  rouge C4 "table de correspondance dans le panneau (seconde autorité)"
else
  vert C4
fi

# C5 — the "finished without writing" fallback no longer arms the success path.
if printf '%s' "$resolution" | grep -q 'finished without writing'; then
  rouge C5 "la phrase « finished without writing » arme encore le chemin de succès"
else
  vert C5
fi

if [ "$echecs" -gt 0 ]; then
  echo "DEFAUT-CONSTATE contrôles=$((5 - echecs))/5"
  [ -n "$MUTANT" ] && echo "MUTANT $MUTANT appliqué à la copie"
  exit 1
fi
echo "BASE-SAINE contrôles=5/5"
[ -n "$MUTANT" ] && echo "MUTANT $MUTANT : aucun contrôle basculé (il ne prouve rien)"
exit 0
