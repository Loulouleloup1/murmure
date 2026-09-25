#!/usr/bin/env bash
# Contract probe for the 10-S panel/socket seam.
#
# Two families of checks, kept strictly apart:
#
#   * the WIRING graph, read from Swift sources.  Each named control is always executed and is
#     red or green on the evidence found in the source; none of them is red by construction.  A
#     server that satisfies the graph passes all of them, and the DEV that lands the 10-S seam
#     turns this whole family green.
#   * the CORE filter, a real XCTest run, split into three named controls so a red says which of
#     the three things went wrong: the 10-S test target not compiling, a filter that selects
#     nothing (silent evidence, never a passing verdict), or an actual test failure.  Only the
#     verdict control can be green, and it is green on a non-zero execution with zero failures.
#
# The 10-S sources are untracked in every writer worktree, so the tree under test may not carry
# them at all.  Each of the four is therefore an INVENTORY control ON THE TREE UNDER TEST: a file
# that only exists in a writer worktree is red by name, so a green verdict can never rest on a
# source the tested tree does not contain.  The graph controls still read the real assembled
# source — every resolved path is printed with the root it came from — so what they report is the
# wiring actually written, and the red they raise is the red of that wiring, not of an empty file.
#
# A mutant mode is a DIFFERENCE, not a state: the run re-checks the graph on the unmutated
# assembly, then on the mutated one, and claims a capture only for a control that was GREEN on the
# first and RED on the second.  A control that was already red proves nothing, and a mutation that
# changes nothing is inapplicable; both exit 3 saying so.
#
# `wire` is the ONLY mode that renders a verdict end to end.  The graph-only re-run the mutant
# harness needs takes `graph` as a SECOND argument and deliberately cannot report green: it skips
# the XCTest filter, prints `PARTIEL` instead of `VERT contrôle=10-S`, and exits 1.  It is not a
# public mode, because a run that never executed the tests must never look like one that did.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MODE=${1:-wire}
EXPECTED=""

# `graph` re-runs the wiring family alone, so a mutant can be measured as a DIFFERENCE between two
# assemblies.  It is not a mode of the contract: it is accepted as the SECOND argument only, never
# as `$1`, and it cannot report green (see the tail).  Accepting it as `$1` would let a run that
# never executed the XCTest filter print `VERT contrôle=10-S` and exit 0 — a green output
# indistinguishable from a real one.
GRAPH_ONLY=${2:-}

# The tree under test.  `MURMURE_WIRING_ROOT` lets a harness declare a different assembly AS the
# tree under test (a correct-by-construction 10-S, for instance); the inventory controls then judge
# that assembly instead, which is what makes a green base reproducible outside the worktree.  It is
# a source root, never a test hook: the controls below read files and run XCTest, they do not know
# who supplied them.
TEST_ROOT=${MURMURE_WIRING_ROOT:-$ROOT}
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")

# When the tested tree lacks a 10-S source, the graph is read from the worktrees that actually
# wrote it, newest first: t_0799321d carries the current version of all four, t_d1dbdc77 the
# earlier 10-S assembly (its TranscriptsPaneModel predates decision O1 on the menu-bar badge, so
# it is a fallback for reachability only, never an authority).
FALLBACK_ROOTS=(
  "$ROOT/../t_0799321d"   # all four 10-S sources, current version
  "$ROOT/../t_d1dbdc77"   # all four 10-S sources, earlier assembly
)
ROOTS=("$TEST_ROOT" "${FALLBACK_ROOTS[@]}")
# Every path is canonicalised through its DIRECTORY (`cd` into a file fails, so canonising the
# file itself would silently keep the `..` segments), so a sibling worktree reached through `..`
# can never string-prefix the tree under test and pass a `-sous-test` control it does not own.
canon() { # a file path -> that file with its directory resolved
  local dir base
  dir=$(dirname "$1"); base=$(basename "$1")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  [[ "$base" == "." || -z "$base" ]] && { printf '%s' "$dir"; return 0; }
  printf '%s' "$dir/$base"
}
TEST_ROOT_REAL=$(canon "$TEST_ROOT") || TEST_ROOT_REAL=$TEST_ROOT
resolve() { # relative path -> prints the absolute path of the first root that holds it
  local rel=$1 root
  for root in "${ROOTS[@]}"; do
    [[ -f "$root/$rel" ]] && { canon "$root/$rel"; return 0; }
  done
  return 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/murmure-control-queue.XXXXXX")
trap 'rm -rf "$work"' EXIT

SERVER_REL=Murmure/TranscriptControlServer.swift
PANE_REL=Murmure/TranscriptsPaneModel.swift
QUEUE_REL=MurmureCore/Sources/MurmureCore/TranscriptQueue.swift
TEST_REL=MurmureCore/Tests/MurmureCoreTests/TranscriptQueueTests.swift

server_file=$(resolve "$SERVER_REL" || true)
pane_file=$(resolve "$PANE_REL" || true)
queue_file=$(resolve "$QUEUE_REL" || true)
test_file=$(resolve "$TEST_REL" || true)

for pair in "server:$SERVER_REL:${server_file:-ABSENT}" \
            "pane:$PANE_REL:${pane_file:-ABSENT}" \
            "queue:$QUEUE_REL:${queue_file:-ABSENT}" \
            "swift-test:$TEST_REL:${test_file:-ABSENT}"; do
  name=${pair%%:*}; rest=${pair#*:}; rel=${rest%%:*}; hit=${rest#*:}
  printf 'INFO source=%s chemin=%s résolu=%s\n' "$name" "$rel" "$hit"
done

[[ -n "$server_file" ]] && cp "$server_file" "$work/server.swift" || : >"$work/server.swift"
[[ -n "$pane_file" ]] && cp "$pane_file" "$work/pane.swift" || : >"$work/pane.swift"

# `MURMURE_WIRING_SERVER` points the server check at one specific file, so a mutant can be measured
# as a DIFFERENCE between two assemblies of the same tree instead of being asserted.  Like
# MURMURE_WIRING_ROOT it is a source locator, not a verdict hook: the controls below re-read the
# file and re-run XCTest, they do not learn from it whether they should pass.
if [[ -n "${MURMURE_WIRING_SERVER:-}" && -f "${MURMURE_WIRING_SERVER:-}" ]]; then
  server_file=$(canon "$MURMURE_WIRING_SERVER")
  cp "$server_file" "$work/server.swift"
  printf 'INFO source=serveur-surchargé chemin=%s\n' "$server_file"
fi

# A mutant is only PROOF if it flips a control that was green: a control already red before the
# mutation proves nothing, so the run measures the baseline and the mutant and compares them.  Both
# halves read real files through the same controls — the mutant is not a claim, it is a difference.
mutate() { # <perl-args...>: applies the edit in place, 0 if the file changed
  local before after
  before=$(shasum -a 256 <"$work/server.swift")
  perl "$@" "$work/server.swift"
  after=$(shasum -a 256 <"$work/server.swift")
  [[ "$before" != "$after" ]]
}
# The graph family is re-run in this same process, on whichever server file MURMURE_WIRING_SERVER
# names, and its red set is collected in `red_set`.  Swift is not re-run: it filters MurmureCore,
# which no server mutation touches.
run_graph() { # <label> -> prints the red controls of that assembly
  local label=$1 line name out
  # `red_set` is a space-delimited list padded on BOTH ends, so the membership test is exactly
  # `" $EXPECTED "` against the list.  Padding only the front would make the LAST element of the
  # list unmatchable — a silent failure that reads as "green on the reference" for whichever
  # control happens to come last, and as a capture the run never measured.
  red_set=" "
  # MURMURE_WIRING_ROOT travels with the call: the reference assembly and the mutated one must be
  # judged against the SAME tree under test, or their red sets are not comparable.
  out=$(MURMURE_WIRING_ROOT="$TEST_ROOT" MURMURE_WIRING_SERVER=$work/server.swift "$SELF" wire graph 2>&1)
  while IFS= read -r line; do
    [[ "$line" == ROUGE\ contrôle=* ]] || continue
    name=${line#ROUGE contrôle=}; name=${name%% *}
    red_set="$red_set $name"
  done <<<"$out"
  printf '%s rouges=%s\n' "$label" "${red_set:- aucun}"
  # The re-read server lives in a temp directory, so `source-serveur-sous-test` is red BY
  # CONSTRUCTION here and says nothing about the assembly under test.  It is excluded from the
  # comparison so it can never stand in for the control a mutant is meant to flip.
  red_set=${red_set// source-serveur-sous-test/}
  red_set="$red_set "
  # Recorded, not just printed: the verdict below compares the MUTATED red set against this one.
  baseline_red=$red_set
}
case "$MODE" in
  wire) ;;
  mutant-queue) EXPECTED=server-no-secondary-queue
    # Appending a job board is the mutation the card forbids: a secondary queue in the server.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    printf '\nprivate final class ControlJobBoard2 {}\n' >>"$work/server.swift"
    MUTATED=1 ;;
  mutant-runner) EXPECTED=transcribe-injected
    # transcribe routes to its own runner instead of the injected submitter.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    if mutate -0pi -e 's/await (?:submitter|submitteur)\(/await runner.submit(/g'; then
      MUTATED=1
    fi ;;
  mutant-status) EXPECTED=status-injected
    # status reads a file of its own instead of the injected provider.
    baseline_red=" "; run_graph "ASSEMBLAGE DE RÉFÉRENCE"
    if mutate -0pi -e 's/(?:statusProvider|fournisseurStatut)\(\)/phantomFile.status()/g'; then
      MUTATED=1
    fi ;;
  *) printf 'usage: %s [wire|mutant-queue|mutant-runner|mutant-status]\n' "$0" >&2; exit 64 ;;
esac
if [[ -n "$EXPECTED" && -z "${MUTATED:-}" ]]; then
  printf 'MUTANT INAPPLICABLE mode=%s : la mutation n’a rien changé dans la copie du serveur\n' "$MODE"
  exit 3
fi

fail=0
matched=0
total=0
failed_controls=" "
pass() { printf 'VERT contrôle=%s\n' "$1"; }
red() { fail=1; failed_controls="$failed_controls$1 "; printf 'ROUGE contrôle=%s détail=%s\n' "$1" "$2"; }
# check <name> <0=ok> <detail-if-not>
check() {
  total=$((total + 1))
  if [[ "$2" -eq 0 ]]; then matched=$((matched + 1)); pass "$1"; else red "$1" "$3"; fi
}
# Two inventory controls per 10-S source, both executed, never skipped:
#   <name>-present    the file was resolved somewhere, so the graph below reads a real source;
#   <name>-sous-test  the file is IN THE TREE UNDER TEST, which is what a verdict must rest on.
# A source that only exists in a writer worktree therefore turns the second control red by name:
# green and absent stay distinguishable, and the denominator counts executed controls only.
source_check() { # <name> <resolved-path> <detail-when-absent>
  local name=$1 hit=$2 detail=$3
  total=$((total + 1))
  if [[ -z "$hit" ]]; then
    red "$name-present" "$detail absent de tout assemblage"
  else
    matched=$((matched + 1)); pass "$name-present"
  fi
  total=$((total + 1))
  if [[ -n "$hit" && "$hit" == "$TEST_ROOT_REAL/"* ]]; then
    matched=$((matched + 1)); pass "$name-sous-test"
  elif [[ -n "$hit" ]]; then
    red "$name-sous-test" "$detail présent hors de l'arbre sous test : $hit"
  else
    red "$name-sous-test" "$detail absent de l'arbre sous test $TEST_ROOT"
  fi
}

# Balanced Swift body for a named signature, so a forbidden word in a comment or in an unrelated
# method is never mistaken for the named graph.
body_for() {
  SIGNATURE="$1" SOURCE="$2" perl -0777 -e '
    my($s,$x)=@ENV{qw(SIGNATURE SOURCE)}; exit 1 unless $x =~ /\Q$s\E[^{]*\{/s;
    my $o=index($x,"{",$-[0]); my $d=0; my $e=$o;
    for my $p ($o..length($x)-1) { my $c=substr($x,$p,1); $d++ if $c eq "{"; $d-- if $c eq "}"; if (!$d) {$e=$p; last} }
    exit 1 if $d; print substr($x,$o+1,$e-$o-1);'
}
# Signature of a named DECLARATION, from the declaration keyword up to the opening brace, so an
# INJECTED dependency (a parameter) is seen and not only what the body does with it.
#
# The keyword is anchored to a line-initial DECLARATION, `^\s*(public |private |internal |
# fileprivate |override |convenience |required |final )*init\b`, and the window stops at the brace
# that opens the body.  Matching the bare substring instead — the round-4 defect — lets a comment
# that merely NAMES an initializer ("voir `MurmureApp.init`", "appelé à init", `initiated`) donate
# its own brace, the window then lands on prose, the parameters are never found, and the injection
# controls go red on a server whose injection is correct.  A control of injection must be red for
# a MISSING SEAM, never for a way of talking about one; this idiom is the house style here
# (`MurmureApp.init`, `DictationController.init`, `WhisperKit.init` all appear in `Murmure/`).
#
# A trailing-closure default (`handler: () -> Void = { _ in }`) also opens a brace before the
# body's, so the window counts brace depth from the declaration and stops at the brace that brings
# it back to 0 — the body's own opener, whatever the parameters contain.
sig_for() {
  SIGNATURE="$1" SOURCE="$2" perl -0777 -e '
    my($s,$x)=@ENV{qw(SIGNATURE SOURCE)}; my $k = $s;
    exit 1 unless $x =~ /^[ \t]*(?:(?:public|private|internal|fileprivate|open|override|convenience|required|final)[ \t]+)*\Q$k\E\b[^\n{(]*[(<]/m;
    my $st = $-[0];
    my $o = $st; my $d = 0; my $found = 0;
    for my $p ($st .. length($x) - 1) {
      my $c = substr($x, $p, 1);
      $d++ if $c eq "{"; $d-- if $c eq "}";
      if ($c eq "{" && $d == 1) { $o = $p; $found = 1; last }
    }
    exit 1 unless $found; print substr($x, $st, $o - $st);'
}
# EVERY executed `status` path of the server, ACCUMULATED — not just the first form found.
#
# `status` reaches its answer through one of two shapes, and BOTH are legitimate under the plan
# (§10-S criterion 3 only says that `status` reads the common queue, §11-S criterion 3 the same):
#   * a DECLARATION `func status()` / `func statut()` — a method that returns the provider's string;
#   * a ROUTING ARM `case .status:` / `case "status":` — the shape the DELIVERED server already
#     uses (`Murmure/TranscriptControlServer.swift:371-372`, `case .status:` →
#     `ControlResponse(…, text: board.description)`), where the provider is awaited inline.
# Reading only the declaration (the round-3 and round-7 defect, never closed) makes the contract
# red on the minimal, natural edit of the delivered code: a DEV forced to invent a method the plan
# does not ask for. Worse, it makes the plan's MANDATORY mutant (c) « lire un status fantôme »
# uncapturable — on an assembly whose `status` answers from a `case`, the control is already red
# before the mutation, so the mutation proves nothing (the run reports rc=3, honestly, but the
# contract then has no witness for the ghost-status defect at all).
#
# The sibling probe `status-sans-journalisation.sh` already accepts both shapes; the two artefacts
# disagreed on what a « chemin status » is. They now agree.
#
# Comments are stripped first, so a `statusProvider()` mentioned in prose is not a call, and the
# arm walk stops only on a line at the EXACT indentation of the `case` (`case`/`default`/`}`): a
# NESTED `switch` or `if` is not a new arm in Swift, and letting its `}` end the arm would hide
# everything below it — the false green already measured and fixed in the sibling probe.
cat >"$work/status_paths.pl" <<'STATUS_PATHS_PL'
use strict; use warnings;
local $/; my $x = <STDIN>;
$x =~ s{/\*.*?\*/}{}gs;
$x =~ s{//[^\n]*}{}g;
my $trouve = 0;
# 1. every `func status` / `func statut` body, balanced from the declaration's own brace.
while ($x =~ /^[ \t]*(?:(?:public|private|internal|fileprivate|open|override|class|static|final|mutating)[ \t]+)*func[ \t]+(?:status|statut)\b[^{]*\{/gm) {
  my $o = index($x, '{', $-[0]); my $d = 0; my $e = -1;
  for my $p ($o .. length($x) - 1) {
    my $c = substr($x, $p, 1);
    $d++ if $c eq '{'; $d-- if $c eq '}';
    if (!$d) { $e = $p; last }
  }
  next if $e < 0;   # unbalanced: not a func body, refuse rather than report on the file's tail
  print substr($x, $o + 1, $e - $o - 1);
  $trouve = 1;
}
# 2. every `case .status:` / `case "status":` arm, to the next same-indent `case`/`default`/`}`.
#    A BLANK line does not end the arm (it used to, which truncated the arm at the first empty
#    line and hid any logging added below it).
while ($x =~ /^([ \t]*)case[ \t]+(?:\.status|"status")[ \t]*:[ \t]*\n/gm) {
  my $st = $-[0]; my $ind = $1; my $p = index($x, "\n", $st); my $out = '';
  while ($p < length($x)) {
    my $nl = index($x, "\n", $p + 1); $nl = length($x) if $nl < 0;
    my $line = substr($x, $p + 1, $nl - $p - 1);
    last if $line =~ /^\Q$ind\E(?:case\b|default\b|\})/;
    $out .= $line . "\n";
    $p = $nl;
  }
  print $out;
  $trouve = 1;
  pos($x) = $p;   # resume AFTER the observed arm: the next one belongs to another switch
}
# Exit 0 only if at least one path was observed: printing nothing while exiting 0 would let an
# empty extraction look like a found path, and the diagnostic would name the wrong cause of red.
exit($trouve ? 0 : 1);
STATUS_PATHS_PL
status_paths() { # <swift-source> -> every executed `status` path, concatenated
  perl "$work/status_paths.pl"
}
# Body of the first func whose body matches $2 (regex source).
method_with() {
  RELATION="$1" SOURCE="$2" perl -0777 -e '
    my($r,$x)=@ENV{qw(RELATION SOURCE)};
    while ($x =~ /func\s+\w+\s*[^{]*\{/g) {
      my $o=$-[0]; my $d=0; my $e=$o;
      for my $p ($o..length($x)-1) { my $c=substr($x,$p,1); $d++ if $c eq "{"; $d-- if $c eq "}"; if (!$d) {$e=$p; last} }
      my $b=substr($x,$o+1,$e-$o-1); if ($b =~ /$r/) { print $b; last }
    }'
}

# The codebase names the same two seams in French or English depending on the file, so a control
# accepts either spelling rather than pinning a DEV to one.  Both lists are explicit: no wildcard.
#
# The initializer names its seams as PARAMETERS (`submitteur:`), the methods CALL them
# (`submitteur(`); requiring a call in the initializer would be red on a correct injection, and
# accepting a bare name in the methods would be green on a server that never calls its own seam.
SUBMIT_PARAMS=('submitteur:' 'submitter:')
STATUS_PARAMS=('fournisseurStatut:' 'statusProvider:')
SUBMIT_CALLS=('submitter(' 'submitteur(')
STATUS_CALLS=('statusProvider(' 'fournisseurStatut(')
has_any() { # <haystack> <needle>...
  local hay=$1 needle
  shift
  for needle in "$@"; do [[ "$hay" == *"$needle"* ]] && return 0; done
  return 1
}
# Does this code BUILD a queue?  A Swift construction is `TranscriptQueue(` or `TranscriptQueue {`
# — the trailing-closure form is the one a DEV actually writes, and matching only the parenthesised
# form lets a server smuggle a queue of its own past the control.  `TranscriptQueue` as a bare type
# (a parameter annotation, say) is not a construction and stays allowed.
builds_queue() { printf '%s' "$1" | grep -qE 'TranscriptQueue[[:space:]]*[({]'; }

server=$(<"$work/server.swift"); pane=$(<"$work/pane.swift")

# --- inventory: the 10-S sources themselves -------------------------------------------------
source_check source-serveur "$server_file"  "$SERVER_REL"
source_check source-pane   "$pane_file"    "$PANE_REL"
source_check source-file   "$queue_file"   "$QUEUE_REL"
source_check source-test   "$test_file"    "$TEST_REL"

# --- the named wiring graph: TranscriptControlServer -----------------------------------------
if [[ -n "$server_file" ]]; then
  # The seam is INJECTED: the initializer's SIGNATURE carries it as a parameter, and its body must
  # not build a queue of its own.  `TranscriptQueue(` in the initializer is caught by
  # `server-no-queue-construction` below, which reads the whole file, so no second, weaker read of
  # the initializer is kept here.
  init_sig=$(sig_for 'init' "$server" || true)
  [[ -n "$init_sig" ]] && has_any "$init_sig" "${SUBMIT_PARAMS[@]}"; check initialiseur-submitteur "$?" \
    "l'initialiseur ne reçoit pas de submitteur injecté"
  [[ -n "$init_sig" ]] && has_any "$init_sig" "${STATUS_PARAMS[@]}"; check initialiseur-status "$?" \
    "l'initialiseur ne reçoit pas de status provider injecté"
  transcribe=$(body_for 'func transcribe' "$server" || body_for 'func transcrire' "$server" || true)
  has_any "$transcribe" "${SUBMIT_CALLS[@]}" && [[ -n "$transcribe" ]]; check transcribe-injected "$?" \
    "transcribe n'appelle pas le submitteur injecté"
  # `status-injected` and `status-no-queue` read the ACCUMULATION of every executed `status` path
  # (`func status`/`func statut` bodies PLUS every `case .status:`/`case "status":` arm), so the
  # contract accepts the shape the delivered server already uses and judges the executed graph in
  # either shape. The control names stay the same: the denominator of the contract does not move.
  status=$(printf '%s' "$server" | status_paths || true)
  has_any "$status" "${STATUS_CALLS[@]}" && [[ -n "$status" ]]; check status-injected "$?" \
    "aucun chemin status exécuté n'appelle le status provider injecté (cherché : func status/statut, case .status:)"
  # `status` must not build OR reach a queue: the card puts the queue in the pane, so a server that
  # constructs one to answer `status` is a server with a second queue, however it spells the call.
  # A construction anywhere else in the server is caught by `server-no-queue-construction`.
  ! builds_queue "$status" && [[ -n "$status" ]]; check status-no-queue "$?" \
    "un chemin status construit une file secondaire"

  # Comments carry the vocabulary of the old design; only code is searched.
  clean=$(printf '%s' "$server" | perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g')
  [[ "$clean" != *'ControlJobBoard'* && "$clean" != *'enchainer'* \
     && "$clean" != *'dernierTravail'* && "$clean" != *'Task<ControlJobOutcome'* ]]
  check server-no-secondary-queue "$?" "le serveur contient une file/chaîne provisoire"
  ! builds_queue "$clean"; check server-no-queue-construction "$?" \
    "le serveur construit une file"
else
  for c in initialiseur-submitteur initialiseur-status transcribe-injected status-injected \
           status-no-queue server-no-secondary-queue server-no-queue-construction; do
    check "$c" 1 "$SERVER_REL absent de l'assemblage"
  done
fi

# --- the named wiring graph: TranscriptsPaneModel --------------------------------------------
# `TranscriptQueue` exposes enqueue / entries / waiting / running / drain / cancelCurrent.  The
# pane owns the queue and mirrors its state; there is no `status` member to look for.
if [[ -n "$pane_file" ]]; then
  enqueue=$(method_with '(?:file|fileDeTravail)\s*\.\s*enqueue\s*\(' "$pane" || true)
  [[ -n "$enqueue" ]]; check pane-submit "$?" "le panneau ne soumet pas via sa file"
  lecture=$(method_with '(?:file|fileDeTravail)\s*\.\s*(?:entries|waiting|running)\b' "$pane" || true)
  [[ -n "$lecture" ]]; check pane-status-source "$?" \
    "le panneau ne lit pas les éléments de sa file (entries/waiting/running)"
  # Exactly ONE construction, in either Swift form; the pane owns the queue and nothing else does.
  pane_clean=$(printf '%s' "$pane" | perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g')
  count=$(printf '%s' "$pane_clean" | perl -ne '$n+=()=/TranscriptQueue\s*[({]/g; END{print $n+0}')
  [[ "$count" -eq 1 ]]; check pane-one-queue "$?" \
    "constructions de file dans TranscriptsPaneModel=$count (exactement 1 attendue)"
else
  for c in pane-submit pane-status-source pane-one-queue; do
    check "$c" 1 "$PANE_REL absent de l'assemblage"
  done
fi

# --- the core behavioural filter ------------------------------------------------------------
# Three named controls, kept apart so each red says WHICH of the three things went wrong:
#   swift-10-S-compile     the 10-S test target builds.  This is where an unimplemented 10-S seam
#                          shows up: the contract calls API the production type does not have yet.
#   filtre-10-S-non-vide   the filter selects at least one test — a filter that selects nothing is
#                          silent evidence, never a passing verdict.
#   swift-10-S             the verdict: a non-zero execution with zero failures.  It can turn
#                          green, and it is the only one of the three that can.
# `TranscriptQueue` is a regex so it selects every XCTestCase class of the queue contract, added
# by 10-S or not.  The run happens in the same assembly that supplied the test file: running the
# filter in a `MurmureCore` without the contract would select nothing and prove nothing.
swift_pkg=""
if [[ -n "$test_file" ]]; then
  swift_pkg="$(cd "$(dirname "$test_file")/../../.." && pwd)/MurmureCore"
  [[ -f "$swift_pkg/Package.swift" ]] || swift_pkg=""
elif [[ -f "$TEST_ROOT/MurmureCore/Package.swift" ]]; then
  swift_pkg="$TEST_ROOT/MurmureCore"
fi

swift_log="$work/swift.log"
if [[ "$GRAPH_ONLY" == graph ]]; then
  # Graph family only.  A mutant is measured by re-running the graph on two
  # assemblies, and the core filter does not depend on any server mutation, so it is skipped here
  # rather than paid for twice per mutant.
  printf 'SWIFT paquet=inattiné (mode graph) résumé=""\n'
elif [[ -n "$swift_pkg" ]]; then
  (cd "$swift_pkg" && swift test --filter 'TranscriptQueue') >"$swift_log" 2>&1
  swift_rc=$?
  summary=$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$swift_log" | tail -1 | sed 's/^[[:space:]]*//' || true)
  # BSD sed has no `\+` in a basic regex: the counters are matched positionally.
  executed=$(printf '%s' "$summary" | sed -n 's/.*Executed \([0-9][0-9]*\) tests\{0,1\}.*/\1/p')
  failures=$(printf '%s' "$summary" | sed -n 's/.*with \([0-9][0-9]*\) failures\{0,1\}.*/\1/p')
  printf 'SWIFT paquet=%s rc=%s résumé="%s"\n' "$swift_pkg" "$swift_rc" "$summary"
  # A build error is the seam missing its implementation, so it is named as such: the first
  # `error:` line carries the API the production type is missing.
  build_error=$(grep -E '^[^ ].*: error: ' "$swift_log" | head -1 || true)
  [[ -z "$build_error" ]]; check swift-10-S-compile "$?" \
    "la cible de tests 10-S ne compile pas : ${build_error:-erreur de compilation non identifiée}"
  [[ -n "$summary" && "${executed:-0}" -gt 0 ]]; check filtre-10-S-non-vide "$?" \
    "le filtre Swift n'a sélectionné aucun test (preuve muette) : ${summary:-aucun résumé XCTest}"
  # verdict: a non-zero execution with zero failures is green, and can turn green.
  [[ -n "$summary" && "${executed:-0}" -gt 0 && "${failures:-1}" -eq 0 && "$swift_rc" -eq 0 ]]
  check swift-10-S "$?" "le contrat de file 10-S échoue (${summary:-aucun résumé XCTest})"
else
  red swift-10-S-compile "aucun assemblage MurmureCore exécutable (Package.swift absent)"
  red filtre-10-S-non-vide "aucun assemblage MurmureCore exécutable (Package.swift absent)"
  red swift-10-S "aucun assemblage MurmureCore exécutable (Package.swift absent)"
  total=$((total + 3))
  printf 'SWIFT paquet=aucun rc=skippé résumé=""\n'
fi

printf 'CONTRÔLE=N/M=%d/%d\n' "$matched" "$total"

# A mutant run is a DIFFERENCE, not a state: the expected control must have been GREEN on the
# reference assembly and RED on the mutated one.  A control that was already red proves nothing,
# so the run says so and exits 3 rather than claiming a capture it did not measure.
if [[ -n "$EXPECTED" ]]; then
  if [[ "$failed_controls" != *" $EXPECTED "* ]]; then
    printf 'MUTANT NON capturé contrôle=%s (aucun rouge exact sur l’assemblage muté)\n' "$EXPECTED"
    exit 3
  fi
  if [[ "${baseline_red:- }" == *" $EXPECTED "* ]]; then
    printf 'MUTANT NON capturé contrôle=%s (déjà rouge sur l’assemblage de référence : la mutation ne prouve rien)\n' \
      "$EXPECTED"
    exit 3
  fi
  printf 'MUTANT capturé contrôle=%s (vert sur l’assemblage de référence, rouge sur l’assemblage muté)\n' \
    "$EXPECTED"
  exit 1
fi
# The graph-only re-run exists to be COMPARED, not to be believed.  It skipped the XCTest filter,
# so it carries no verdict on the 10-S seam: it says so, and it never prints `VERT contrôle=10-S`
# and never exits 0, because a green output from a run that never executed the tests is exactly
# the false green this contract is meant to be incapable of.  `wire` is the only end-to-end mode,
# and the mutant harness only ever reads the red controls out of this re-run, never its exit code.
if [[ "$GRAPH_ONLY" == graph ]]; then
  printf 'PARTIEL famille=câblage N/M=%d/%d (filtre XCTest non exécuté : aucun verdict de bout en bout)\n' \
    "$matched" "$total"
  exit 1
fi
[[ "$fail" -eq 0 ]] || exit 1
printf 'VERT contrôle=10-S\n'
