#!/usr/bin/env bash
# Evidence for the 10-S-R contract `control-queue-wiring-tige.sh`, regenerable in one command.
#
#   bash scripts/checks/evidence-10sr.sh
#
# This is the QA author's evidence, not a second gate.  It re-runs the contract on every assembly
# and every mutant and prints the rc, so each number in the handoff can be checked by hand with
# the same file.  It asserts nothing the contract does not already say.
#
# What it establishes, and why each half is needed:
#   * the contract is RED on the delivered 10-S base — the lot's initial red, read as source,
#     with nothing compiled, which is what "the initial red must come from the real seam"
#     means;
#   * the SAME contract is VERT on a corrected-by-construction base — a probe red on every input
#     discriminates nothing and would accept a fix that changes nothing;
#   * each mutant flips exactly ONE named control, measured on the green base, so a capture says
#     which defect was caught instead of reddening everything;
#   * a file with no seam is REFUSED, not reported healthy: a control that cannot fail is not a
#     control, and a future rewrite that renames the seam must not turn this probe silently inert.
set -u
cd "$(dirname "$0")/../.." || exit 2
PROBE=scripts/checks/control-queue-wiring-tige.sh
S=${TMPDIR:-/tmp}/murmure-10sr-evidence
CORRIGEE="$S/pane-corrigee.swift"
mkdir -p "$S"

verdict() { case "$1" in
  0) echo VERT ;; 1) echo ROUGE ;; 2) echo REFUSÉ ;; 3) echo INAPPLICABLE ;; *) echo "rc=$1" ;;
esac; }
attendu() { # <label> <rc observed> <rc expected>
  if [ "$2" = "$3" ]; then
    printf 'OK       %-40s rc=%s  %s\n' "$1" "$2" "$(verdict "$2")"
  else
    printf 'ÉCHEC    %-40s rc=%s  %s   (attendu rc=%s %s)\n' \
      "$1" "$2" "$(verdict "$2")" "$3" "$(verdict "$3")"
  fi
}
rouges() { printf '%s\n' "$1" | sed -n 's/^ROUGE contrôle=\([A-Z0-9]*\).*/\1/p' | tr '\n' ',' | sed 's/,$//'; }
capture() { # <label> <expected controls> <file> [mutant]
  local label=$1 attendu=$2 file=$3 mutant=${4:-} out rc vue
  if [ -n "$mutant" ]; then out=$(bash "$PROBE" "$file" "$mutant" 2>&1); else out=$(bash "$PROBE" "$file" 2>&1); fi
  rc=$?; vue=$(rouges "$out")
  if [ "$rc" = 1 ] && [ "$vue" = "$attendu" ]; then
    printf 'CAPTURE   %-40s %s seulement   rc=%s\n' "$label" "$vue" "$rc"
  elif [ "$rc" = 1 ]; then
    printf 'IMPRÉCIS  %-40s %s   (attendu %s)\n' "$label" "${vue:-aucun}" "$attendu"
  else
    printf 'MANQUÉ    %-40s rc=%s — aucun contrôle basculé\n' "$label" "$rc"
  fi
}

# The corrected base, built from the delivered one and VERIFIED not to still look defective —
# a "corrected" base that still greps as defective would make the green meaningless.
bash scripts/checks/.build-base-corrigee.sh Murmure/TranscriptsPaneModel.swift "$CORRIGEE" >/dev/null

echo "=== 1. FALSIFIABILITÉ : rouge sur la base livrée, vert sur la base corrigée ==="
bash "$PROBE" Murmure/TranscriptsPaneModel.swift >/dev/null 2>&1
attendu "base 10-S livrée" "$?" 1
bash "$PROBE" "$CORRIGEE" >/dev/null 2>&1
attendu "base corrigée par construction" "$?" 0
bash "$PROBE" /nonexistent/TranscriptsPaneModel.swift >/dev/null 2>&1
attendu "fichier illisible" "$?" 2
cat >"$S/pane-sans-couture.swift" <<'FIN'
import Foundation
final SansCouture {
    private let library: TranscriptLibrary
}
FIN
bash "$PROBE" "$S/pane-sans-couture.swift" >/dev/null 2>&1
attendu "panneau sans la couture (contrôle mort)" "$?" 2

echo
echo "=== 2. NON-RÉGRESSION : la base 10-S livrée reste rouge ==="
capture "10-S livrée" "C1,C2,C3,C5" Murmure/TranscriptsPaneModel.swift

echo
echo "=== 3. MUTANTS : un contrôle nommé bascule, et lui seul (base verte) ==="
capture "mutant-b  (identité là où la tige est attendue)" C3 "$CORRIGEE" mutant-b
capture "mutant-c  (seconde autorité, [String: String])"  C4 "$CORRIGEE" mutant-c
capture "mutant-d  (la source est re-testée)"            C2 "$CORRIGEE" mutant-d
capture "mutant-table  ([entryID: stem])"                C4 "$CORRIGEE" mutant-table
capture "mutant-fantome  (R2 : clé recalculée hors fenêtre)" C3 "$CORRIGEE" mutant-fantome
capture "mutant-fantome-c2  (R3 : re-test via un helper)"   C2 "$CORRIGEE" mutant-fantome-c2
capture "mutant-c1  (re-dérivation réintroduite)"          C1 "$CORRIGEE" mutant-c1
capture "mutant-c5  (« finished without writing » réarmée)" C5 "$CORRIGEE" mutant-c5

echo
echo "=== 4. LIMITES CONNUES : ce que le contrôle ne couvre pas, mesuré ==="
out=$(bash "$PROBE" "$CORRIGEE" mutant-d2 2>&1); rc=$?
if [ "$rc" = 3 ]; then printf 'LIMITE   %-40s rc=3  %s\n' "mutant-d2 (ancre absente de la base corrigée)" \
  "$(printf '%s' "$out" | head -1)"
else printf 'ÉCHEC    %-40s rc=%s (attendu rc=3)\n' "mutant-d2" "$rc"; fi
# R3 replayed a second way: the same mutation on the DELIVERED base.  It is UNOBSERVABLE there and
# that is a fact about the base, not a failure of the probe: C2 is already red on the delivered 10-S
# base, so a mutation that only adds another `launch(for:` cannot move a control that is already
# red.  A capture needs a green base to be a difference; this line exists so the table does not
# leave a reader wondering whether d2 was tried there at all.
out=$(bash "$PROBE" Murmure/TranscriptsPaneModel.swift mutant-d2 2>&1); rc=$?
vue=$(rouges "$out")
if [ "$rc" = 1 ] && [ "$vue" = "C1,C2,C3,C5" ]; then
  printf 'INUTILE   %-40s rc=%s  rouges=%s — C2 est déjà rouge sur la base livrée\n' \
    "mutant-d2 sur la base LIVRÉE" "$rc" "$vue"
else
  printf 'ÉCHEC    %-40s rc=%s  rouges=%s (attendu C1,C2,C3,C5 inchangés)\n' \
    "mutant-d2 sur la base LIVRÉE" "$rc" "${vue:-aucun}"
fi
echo
echo "--- évasions rejouées (bash scripts/checks/.evasions-tige.sh) ---"
bash scripts/checks/.evasions-tige.sh 2>&1 | sed 's/^/  /'

echo
echo "C1 le résultat se lit depuis l'élément de la file, jamais par re-dérivation"
echo "C2 le chemin de succès ne dépend pas de l'existence de la source (contrat 4)"
echo "C3 la clé lue est la tige, jamais l'identité canonique"
echo "C4 aucune table de correspondance dans le panneau (seconde autorité)"
echo "C5 la phrase « finished without writing » n'arme plus le chemin de succès"
