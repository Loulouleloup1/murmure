#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SERVER="$ROOT/Murmure/TranscriptControlServer.swift"
PANE="$ROOT/Murmure/TranscriptsPaneModel.swift"
TEST="$ROOT/MurmureCore/Tests/MurmureCoreTests/TranscriptQueueTests.swift"
MODE=${1:-wire}
for path in "$SERVER" "$PANE" "$TEST"; do
  [[ -f "$path" ]] || { printf 'ROUGE contrôle=fichiers-disponibles détail=%s\n' "$path"; exit 2; }
done
work=$(mktemp -d "${TMPDIR:-/tmp}/murmure-control-queue.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Return the brace-balanced body of the declaration matched by SIGNATURE. SIGNATURE is
# a regular expression, so `statusProvider` in an initialiser cannot capture `status`.
function_body() {
  local signature=$1 source=$2
  SIGNATURE="$signature" SOURCE="$source" perl -0777 -e '
    my $s=$ENV{SIGNATURE}; my $source=$ENV{SOURCE}; my $i=0;
    while (($source =~ /$s/g) && $i < 4) { $i++ }
    exit 1 if $i != 1;
    my $open=index($source,"{",$-[0]); exit 1 if $open<0;
    my $depth=0; my $end=$open;
    for my $p ($open .. length($source)-1) {
      $depth++ if substr($source,$p,1) eq "{"; $depth-- if substr($source,$p,1) eq "}";
      if (!$depth) { $end=$p; last }
    }
    exit 1 if $depth; print substr($source,$open+1,$end-$open-1);'
}

function_containing() {
  local relation=$1 source=$2
  RELATION="$relation" SOURCE="$source" perl -0777 -e '
    my $r=$ENV{RELATION}; my $source=$ENV{SOURCE};
    while ($source =~ /func\s+\w+\s*\([^)]*\)[^{]*\{/g) {
      my $open=$-[0]; my $depth=0; my $end=$open;
      for my $p ($open .. length($source)-1) {
        $depth++ if substr($source,$p,1) eq "{"; $depth-- if substr($source,$p,1) eq "}";
        if (!$depth) { $end=$p; last }
      }
      my $body=substr($source,$open+1,$end-$open-1);
      if ($body =~ /$r/) { print $body; last } }'
}

check_graph() {
  local server=$1 pane=$2 expected=${3:-} failures=()
  local init transcribe status enqueue_body status_body
  init=$(function_body 'init\s*\(' "$server") || failures+=(initialiseur-introuvable)
  [[ "$init" == *submitter* && "$init" == *statusProvider* ]] || failures+=(injections-absentes)
  transcribe=$(function_body '\bfunc\s+transcrire\s*\(' "$server") || failures+=(transcribe-introuvable)
  [[ "$transcribe" == *'submitter('* ]] || failures+=(transcribe-submitteur-injecte)

  status=$(function_body '\bfunc\s+status\s*\(' "$server" 2>/dev/null || true)
  [[ -n "$status" ]] || status=$(function_body 'case\s+\.status\s*:' "$server" 2>/dev/null || true)
  [[ -n "$status" ]] || failures+=(status-chemin-introuvable)
  [[ "$status" == *'statusProvider('* && "$status" != *'TranscriptQueue('* ]] || failures+=(status-provider-injecte)

  local stripped
  stripped=$(printf '%s' "$server" | perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g')
  for forbidden in ControlJobBoard enchainer dernierTravail 'Task<ControlJobOutcome'; do
    [[ "$stripped" != *"$forbidden"* ]] || failures+=(file-secondaire)
  done
  [[ $(printf '%s\n' "${failures[@]}" | sort -u | wc -l | tr -d ' ') -eq ${#failures[@]} ]] || failures=($(printf '%s\n' "${failures[@]}" | sort -u))

  # Both application relations are checked in actual function bodies, never as words
  # elsewhere in the pane: submit -> queue.enqueue, status -> queue.status.
  enqueue_body=$(function_containing '(?:file|queue)\s*\.enqueue\s*\(' "$pane")
  status_body=$(function_containing '(?:file|queue)\s*\.status\b' "$pane")
  [[ -n "$enqueue_body" ]] || failures+=(modele-file-absente)
  [[ -n "$status_body" ]] || failures+=(modele-status-absent)
  local count
  count=$(printf '%s' "$pane" | perl -ne '$n += () = /TranscriptQueue\s*\{/g; END {print $n+0}')
  [[ "$count" == 1 ]] || failures+=(modele-file-secondaire)

  if [[ -n "$expected" ]]; then
    [[ " ${failures[*]} " == *" $expected "* ]] || { printf 'MUTANT incorrect contrôle=%s failures=%s\n' "$expected" "${failures[*]:-aucun}"; return 2; }
    [[ " ${failures[*]} " == *" $expected "* && ${#failures[@]} -eq 1 ]] || { printf 'MUTANT ambigu contrôle=%s failures=%s\n' "$expected" "${failures[*]}"; return 2; }
    printf 'MUTANT capturé contrôle=%s\n' "$expected"; return 1
  fi
  [[ ${#failures[@]} -eq 0 ]] || { printf 'ROUGE contrôle=câblage-10-S failures=%s\n' "${failures[*]}"; return 1; }
}

fixture_server='actor Server { init(submitter: @escaping (String) async -> String, statusProvider: @escaping () async -> String) { self.submitter = submitter; self.statusProvider = statusProvider }; private let submitter: (String) async -> String; private let statusProvider: () async -> String; func transcrire(_ source: String) async -> String { await submitter(source) }; func status() async -> String { await statusProvider() } }'
fixture_pane='final class Pane { private let file = TranscriptQueue { _ in }; func submit(_ source: String) async { await file.enqueue(source: source) }; var controlStatus: String { get async { await file.status } } }'
case "$MODE" in
  wire) check_graph "$(cat "$SERVER")" "$(cat "$PANE")" || true ;;
  mutant-queue) check_graph "$fixture_server
final class ControlJobBoard {}" "$fixture_pane" file-secondaire || true ;;
  mutant-runner) check_graph "${fixture_server/await submitter(source)/await runner.submit(source)}" "$fixture_pane" transcribe-submitteur-injecte || true ;;
  mutant-status) check_graph "${fixture_server/await statusProvider()/await phantomQueue.status()}" "$fixture_pane" status-provider-injecte || true ;;
  *) printf 'usage: %s [wire|mutant-queue|mutant-runner|mutant-status]\n' "$0"; exit 64 ;;
esac

# Graph and Swift are separate acceptance levels. Every mutant must stop at its named graph
# control (non-zero above); only wire additionally runs the six behavioural acceptance cases.
[[ "$MODE" != wire ]] && exit 1
swift_log="$work/swift.log"
(cd "$ROOT/MurmureCore" && swift test --filter TranscriptQueueSharedContractTests) >"$swift_log" 2>&1
rc=$?; summary=$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$swift_log" | tail -1 || true)
printf 'SWIFT rc=%s résumé="%s"\n' "$rc" "$summary"
[[ $rc -ne 0 && -n "$summary" ]] || exit 1
exit 1
