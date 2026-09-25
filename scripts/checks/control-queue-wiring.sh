#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SERVER="$ROOT/Murmure/TranscriptControlServer.swift"
PANE="$ROOT/Murmure/TranscriptsPaneModel.swift"
QUEUE="$ROOT/MurmureCore/Sources/MurmureCore/TranscriptQueue.swift"
TEST="$ROOT/MurmureCore/Tests/MurmureCoreTests/TranscriptQueueTests.swift"
MODE=${1:-wire}
for path in "$SERVER" "$PANE" "$QUEUE" "$TEST"; do
  [[ -f "$path" ]] || { printf 'ROUGE contrôle=fichiers-disponibles détail=%s\n' "$path"; exit 2; }
done
work=$(mktemp -d "${TMPDIR:-/tmp}/murmure-control-queue.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$SERVER" "$work/server.swift"; cp "$PANE" "$work/pane.swift"

function_body() {
  local signature=$1 body=$2
  BODY="$body" SIGNATURE="$signature" perl -0777 -e '
    my $s=$ENV{SIGNATURE}; my $i=index($_,$s); exit 1 if $i<0;
    my $open=index($_,"{",$i); exit 1 if $open<0;
    my $depth=0; my $end=$open;
    for my $p ($open .. length($_)-1) { $depth++ if substr($_,$p,1) eq "{"; $depth-- if substr($_,$p,1) eq "}"; if (!$depth) { $end=$p; last } }
    print substr($_,$open+1,$end-$open-1);'
}
check_graph() {
  local server=$1 pane=$2 expected=${3:-} fail=0 init transcribe status count forbidden
  init=$(printf '%s' "$server" | perl -0777 -ne 'print $1 if /init\s*\((.*?)\)\s*\{/s')
  [[ "$init" == *submitter* ]] || fail=1
  [[ "$init" == *statusProvider* ]] || fail=1
  [[ "$init" != *TranscriptQueue* ]] || fail=1
  transcribe=$(function_body transcrire "$server"); status=$(function_body status "$server")
  [[ "$transcribe" == *'submitter('* ]] || fail=1
  [[ "$status" == *'statusProvider('* ]] || fail=1
  [[ "$status" != *'TranscriptQueue('* ]] || fail=1
  for forbidden in ControlJobBoard enchainer dernierTravail 'Task<ControlJobOutcome'; do [[ "$server" != *"$forbidden"* ]] || fail=1; done
  count=$(printf '%s' "$pane" | perl -ne '$n += () = /TranscriptQueue\s*\{/g; END {print $n+0}')
  [[ "$count" == 1 ]] || fail=1
  [[ "$pane" == *submit* && "$pane" == *status* ]] || fail=1
  if [[ -n "$expected" ]]; then
    [[ $fail -ne 0 ]] && printf 'MUTANT capturé contrôle=%s\n' "$expected"
    return $fail
  fi
  [[ $fail -eq 0 ]] || { printf 'ROUGE contrôle=câblage-10-S\n'; return 1; }
}
fixture_server='actor Server { init(submitter: Submitter, statusProvider: @escaping () -> String) {} func transcrire(_ r: Request) async { await submitter(r.source) } func status() -> String { statusProvider() } }'
fixture_pane='final class Pane { let queue = TranscriptQueue { _ in }; func submit() {}; func status() -> String { queue.status } }'
case "$MODE" in
  wire) check_graph "$(cat "$work/server.swift")" "$(cat "$work/pane.swift")" || true ;;
  mutant-queue) s="$fixture_server
class ControlJobBoard {}"; check_graph "$s" "$fixture_pane" file-secondaire || true ;;
  mutant-runner) s="${fixture_server/await submitter(r.source)/await runner.submit(r.source)}"; check_graph "$s" "$fixture_pane" transcribe-submitteur-injecte || true ;;
  mutant-status) s="${fixture_server/statusProvider()/phantomQueue.status()}"; check_graph "$s" "$fixture_pane" status-provider-injecte || true ;;
  *) printf 'usage: %s [wire|mutant-queue|mutant-runner|mutant-status]\n' "$0"; exit 64 ;;
esac

swift_log="$work/swift.log"
(cd "$ROOT/MurmureCore" && swift test --filter TranscriptQueueSharedContractTests) >"$swift_log" 2>&1
rc=$?; summary=$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$swift_log" | tail -1 || true)
printf 'SWIFT rc=%s résumé="%s"\n' "$rc" "$summary"
[[ $rc -ne 0 && -n "$summary" ]] || exit 1
[[ "$MODE" == wire ]] && exit 1
exit 0
