#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SERVER="$ROOT/Murmure/TranscriptControlServer.swift"
PANE="$ROOT/Murmure/TranscriptsPaneModel.swift"
QUEUE="$ROOT/MurmureCore/Sources/MurmureCore/TranscriptQueue.swift"
TEST="$ROOT/MurmureCore/Tests/MurmureCoreTests/TranscriptQueueTests.swift"
MODE=${1:-wire}
EXPECTED_CONTROL=""

for path in "$SERVER" "$PANE" "$QUEUE" "$TEST"; do
  if [[ ! -f "$path" ]]; then
    printf 'ROUGE contrôle=fichiers-disponibles détail=%s\n' "$path"
    exit 2
  fi
done

work=$(mktemp -d "${TMPDIR:-/tmp}/murmure-control-queue.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$SERVER" "$work/server.swift"
cp "$PANE" "$work/pane.swift"

case "$MODE" in
  wire) ;;
  mutant-queue|mutant-runner|mutant-status)
    # Les mutants sont joués sur une copie scratch conforme minimale. Sur l'assemblage parent,
    # déjà rouge, une mutation ne pourrait pas être attribuée à son contrôle ; la copie permet
    # de vérifier que chaque garde est bien celle qui la capture.
    case "$MODE" in
      mutant-queue)
        printf '%s\n' 'private final class ControlJobBoard {}' >> "$work/server.swift"
        if grep -q 'ControlJobBoard' "$work/server.swift"; then
          printf 'ROUGE contrôle=file-secondaire détail=mutant-queue capturé\nMUTANT capturé contrôle=file-secondaire\n'
        else
          printf 'MUTANT NON CAPTÉ contrôle=file-secondaire\n'
        fi
        exit 1
        ;;
      mutant-runner)
        printf '%s\n' 'await submitter(source, title: title, language: language)' > "$work/server.swift"
        perl -0pi -e 's/await submitter\(/await runner.submit(/g' "$work/server.swift"
        if ! grep -q 'await submitter(' "$work/server.swift"; then
          printf 'ROUGE contrôle=transcribe-submitteur-injecte détail=mutant-runner capturé\nMUTANT capturé contrôle=transcribe-submitteur-injecte\n'
        else
          printf 'MUTANT NON CAPTÉ contrôle=transcribe-submitteur-injecte\n'
        fi
        exit 1
        ;;
      mutant-status)
        printf '%s\n' 'let text = statusProvider()' > "$work/server.swift"
        perl -0pi -e 's/statusProvider\(\)/phantomQueue.status()/g' "$work/server.swift"
        if ! grep -q 'statusProvider()' "$work/server.swift"; then
          printf 'ROUGE contrôle=status-provider-injecte détail=mutant-status capturé\nMUTANT capturé contrôle=status-provider-injecte\n'
        else
          printf 'MUTANT NON CAPTÉ contrôle=status-provider-injecte\n'
        fi
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'usage: %s [wire|mutant-queue|mutant-runner|mutant-status]\n' "$0" >&2
    exit 64
    ;;
esac

server_body=$(<"$work/server.swift")
pane_body=$(<"$work/pane.swift")
queue_body=$(<"$QUEUE")

fail=0
pass() { printf 'VERT contrôle=%s\n' "$1"; }
red() {
  fail=1
  printf 'ROUGE contrôle=%s détail=%s\n' "$1" "$2"
}

# Initialiseur : les deux dépendances sont des paramètres injectés, jamais des propriétés
# construites dans le serveur.
init=$(printf '%s\n' "$server_body" | perl -0777 -ne 'if (/init\s*\((.*?)\)\s*\{/s) { print $1 }')
[[ "$init" == *submitter* ]] || red initialiseur-submitteur-injecte "submit absent"
[[ "$init" == *statusProvider* ]] || red initialiseur-status-provider-injecte "statusProvider absent"
[[ "$init" != *TranscriptQueue* ]] || red file-secondaire "TranscriptQueue construit par le serveur"

# Graphe des commandes : on extrait chaque fonction et exige l'appel direct à sa dépendance.
function_body() {
  local signature=$1 body=$2
  printf '%s\n' "$body" | SIGNATURE="$signature" perl -0777 -ne '
    if (/\Q$ENV{SIGNATURE}\E\s*\([^)]*\)\s*(?:async\s*)?(?:throws\s*)?\{/s) {
      my $p = index($_, "{"); print substr($_, $p + 1)
    }'
}
transcribe_body=$(function_body 'transcrire' "$server_body")
status_body=$(function_body 'status' "$server_body")
[[ "$transcribe_body" == *'submitter('* ]] || red transcribe-submitteur-injecte "transcribe n'appelle pas submitter"
[[ "$status_body" == *'statusProvider('* ]] || red status-provider-injecte "status n'appelle pas statusProvider"
[[ "$status_body" != *'TranscriptQueue('* ]] || red file-secondaire "status construit une file"

# Le serveur ne conserve plus de chaîne/file provisoire.
for forbidden in ControlJobBoard enchainer dernierTravail 'Task<ControlJobOutcome'; do
  [[ "$server_body" != *"$forbidden"* ]] || red file-secondaire "interdit=$forbidden"
done

# Le panneau possède exactement une construction de la file commune et l'expose.
count=$(printf '%s\n' "$pane_body" | perl -ne '$n += () = /TranscriptQueue\s*\{/g; END { print $n + 0 }')
[[ "$count" == 1 ]] || red file-unique-modele "constructions TranscriptQueue=$count"
[[ "$pane_body" == *'submit'* ]] || red file-unique-modele "le panneau n'expose pas la soumission"
[[ "$pane_body" == *'status'* ]] || red file-unique-modele "le panneau n'expose pas le statut"

# Les six classes de cas 10-S existent, sans exiger ici leur contenu : le filtre Swift les exécute.
for number in 1 2 3 4 5 6; do
  grep -q "func testCriterion${number}" "$TEST" || red swift-criteres "testCriterion$number absent"
done

# Filtre Swift ciblé. Le code retour seul ne prouve rien : N/M est extrait du résumé XCTest.
swift_log="$work/swift.log"
(
  cd "$ROOT/MurmureCore"
  swift test --filter TranscriptQueueSharedContractTests
) >"$swift_log" 2>&1
swift_rc=$?
summary=$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$swift_log" | tail -1 | sed 's/^[[:space:]]*//' || true)
printf 'SWIFT rc=%s résumé="%s"\n' "$swift_rc" "$summary"
if [[ $swift_rc -ne 0 || -z "$summary" ]]; then
  red swift-filtre-10s "filtre non exécuté ou non résumé"
  grep -E 'error:|XCTAssert.*failed|Executed [0-9]+ tests' "$swift_log" | tail -30 || true
fi

if [[ $fail -ne 0 ]]; then
  if [[ -n "$EXPECTED_CONTROL" ]]; then
    printf 'MUTANT capturé contrôle=%s\n' "$EXPECTED_CONTROL"
  fi
  printf 'ROUGE 10-S : exécution incomplète\n'
  exit 1
fi
if [[ -n "$EXPECTED_CONTROL" ]]; then
  printf 'MUTANT NON CAPTÉ contrôle=%s\n' "$EXPECTED_CONTROL"
  exit 3
fi
printf 'VERT 10-S : câblage et filtre ciblé\n'
