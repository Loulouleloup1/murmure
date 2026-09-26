#!/usr/bin/env bash
# Contrat du critère 4 — le binaire `ffmpeg` embarqué doit être un build LGPL.
#
# POURQUOI CE CONTRÔLE EXISTE. Le binaire `ffmpeg` utilisé pendant les essais
# était un build GPL v3 (`configuration: … --enable-gpl …`). L'embarquer dans
# une application propriétaire est une faute de licence, pas un détail de
# packaging. Le contrôle retenu par le plan (§2.6) est mécanique et c'est
# celui-là : la sortie de `ffmpeg -version` ne doit contenir ni `--enable-gpl`
# ni `--enable-nonfree`, et le dépôt doit porter le texte de licence LGPL 2.1
# ainsi que la provenance du binaire construit (§4, lot 5).
#
# CE SCRIPT EST LE CONTRAT ROUGE DU LOT 5 (carte `qa` t_9011e7e9) : la carte
# `ops` enfant l'exécute tel quel et n'en change pas le sens (§7.1, règle 9).
#
# CE QU'IL FAIT : lit trois chemins, lance UNE commande (`<binaire> -version`,
# avec `--version` en repli si la première ne répond rien), et compare.
# CE QU'IL NE FAIT PAS : il n'installe rien, ne télécharge rien, ne compile
# rien, ne signe rien et n'écrit aucun fichier — ni dans le dépôt, ni ailleurs
# (AGENTS.md : aucune installation dans une gate automatique). Il ne juge pas
# le CONTENU des deux fichiers de conformité : le critère demande qu'ils soient
# présents, il vérifie qu'ils sont présents et non vides.
#
# Usage : bash scripts/checks/embedded-ffmpeg-license.sh [chemin-du-binaire]
#         Défaut : <racine du dépôt>/Murmure/Resources/ffmpeg.
#         L'argument sert à contrôler un candidat AVANT de l'embarquer, ou un
#         binaire embarqué ailleurs ; il peut pointer hors du dépôt.
#         bash scripts/checks/embedded-ffmpeg-license.sh --help
#
# La racine du dépôt est déduite de l'emplacement du script, jamais de
# l'environnement : une gate qu'un `export` peut déplacer ne contrôle plus le
# dépôt. Copié dans une arborescence jetable portant ses propres
# `Murmure/Resources/ffmpeg` et `docs/licenses/`, ce script y contrôle cette
# arborescence — c'est ainsi que sa branche verte a été exercée.
#
# Sortie : 0 si les 5 contrôles passent ; 1 si au moins un manque ou si un
#          contrôle a dû être laissé non exécuté ; 2 si l'usage est invalide.
# Chaque contrôle affiche le chemin réellement testé, la commande réellement
# lancée et son code de sortie : un rouge se lit sans relire ce fichier.

set -euo pipefail

NOM="embedded-ffmpeg-license"
CHECK_TOTAL=5
USAGE="usage: bash scripts/checks/embedded-ffmpeg-license.sh [chemin-du-binaire]
       défaut : <racine du dépôt>/Murmure/Resources/ffmpeg
       options : -h, --help"

case "${1:-}" in
    -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
esac
if [ "$#" -gt 1 ]; then
    printf "%s: trop d'arguments (%s) — un seul chemin attendu\n" "$NOM" "$#" >&2
    printf '%s\n' "$USAGE" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DEFAULT_BIN="$REPO_ROOT/Murmure/Resources/ffmpeg"
LICENSE_TEXT="$REPO_ROOT/docs/licenses/ffmpeg-LGPL-2.1.txt"
PROVENANCE="$REPO_ROOT/docs/licenses/ffmpeg-lgpl-provenance.md"

BIN_ARG="${1:-}"
if [ -z "$BIN_ARG" ]; then
    BIN="$DEFAULT_BIN"
    BIN_ORIGIN="chemin par défaut"
else
    case "$BIN_ARG" in
        /*) BIN="$BIN_ARG" ;;
        *)  BIN="$(pwd)/$BIN_ARG" ;;
    esac
    BIN_ORIGIN="argument 1"
fi

failures=0
not_run=0
FAIL_LIST=""
SKIP_LIST=""
RUNNABLE=0

ok() { printf '  [OK]          %s\n' "$1"; }
echec() {
    printf '  [ECHEC]       %s\n' "$1"
    failures=$((failures + 1))
    # printf -v : une substitution de commande mangerait le saut de ligne final
    # et collerait deux manques sur la même ligne du compte rendu.
    printf -v FAIL_LIST '%s    - %s\n' "$FAIL_LIST" "$1"
}
# Un contrôle non exécuté n'est jamais un vert : il rend la sortie rouge aussi,
# mais il est compté à part pour que le nombre de manques reste lisible.
non_execute() {
    printf '  [NON EXÉCUTÉ] %s\n' "$1"
    not_run=$((not_run + 1))
    printf -v SKIP_LIST '%s    - %s\n' "$SKIP_LIST" "$1"
}

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        printf 'sha256-indisponible'
    fi
}

octets_de() { wc -c < "$1" | tr -d '[:space:]'; }

# Renseigne PROBE_CMD, PROBE_CODE, PROBE_OUT.
probe_version() {
    PROBE_CMD="$1 -version"
    if PROBE_OUT="$("$1" -version 2>&1)"; then PROBE_CODE=0; else PROBE_CODE=$?; fi
    if [ "$PROBE_CODE" -ne 0 ] || [ -z "$PROBE_OUT" ]; then
        # ffmpeg 8.0.1 répond aux deux formes (`-version` et `--version`), et
        # le plan comme la carte citent `-version` / `--version` : le repli
        # évite de déclarer illisible un binaire qui n'accepterait que la
        # seconde. Si aucune des deux ne répond, le binaire reste non
        # certifiable — c'est un échec, jamais un vert par défaut.
        if ALT_OUT="$("$1" --version 2>&1)"; then ALT_CODE=0; else ALT_CODE=$?; fi
        if [ "$ALT_CODE" -eq 0 ] && [ -n "$ALT_OUT" ]; then
            PROBE_CMD="$1 --version"
            PROBE_CODE=0
            PROBE_OUT="$ALT_OUT"
        fi
    fi
}

# $1 = chemin, $2 = libellé court du contrôle
fichier_de_conformite() {
    if [ ! -e "$1" ]; then
        echec "$2 : « $1 » est absent (test -e)"
    elif [ ! -f "$1" ]; then
        echec "$2 : « $1 » existe mais n'est pas un fichier régulier (test -f)"
    elif [ ! -s "$1" ]; then
        echec "$2 : « $1 » est vide (test -s) — un fichier vide ne satisfait pas l'obligation de conformité"
    else
        ok "$2 : « $1 » présent, $(octets_de "$1") octets, sha256 $(sha256_of "$1")"
    fi
}

printf '%s — licence du ffmpeg embarqué (critère 4, lot 5)\n\n' "$NOM"
printf 'dépôt      : %s\n' "$REPO_ROOT"
printf 'binaire    : %s  [%s]\n' "$BIN" "$BIN_ORIGIN"
printf 'licence    : %s\n' "$LICENSE_TEXT"
printf 'provenance : %s\n\n' "$PROVENANCE"

printf '1/%s présence du binaire embarqué\n' "$CHECK_TOTAL"
if [ ! -e "$BIN" ]; then
    echec "binaire absent : « $BIN » n'existe pas (test -e) — aucun binaire embarqué à contrôler"
elif [ ! -f "$BIN" ]; then
    echec "binaire invalide : « $BIN » existe mais n'est pas un fichier régulier (test -f)"
else
    ok "binaire présent : « $BIN », $(octets_de "$BIN") octets, sha256 $(sha256_of "$BIN")"
fi

printf '2/%s exécutabilité du binaire\n' "$CHECK_TOTAL"
if [ ! -f "$BIN" ]; then
    non_execute "exécutabilité : aucun fichier régulier à contrôler (voir 1/$CHECK_TOTAL)"
elif [ ! -x "$BIN" ]; then
    echec "binaire non exécutable : « $BIN » (test -x) — sans bit d'exécution il ne peut être ni lancé ni certifié"
else
    ok "binaire exécutable : « $BIN » (test -x)"
    RUNNABLE=1
fi

printf '3/%s configuration du build : ni --enable-gpl ni --enable-nonfree\n' "$CHECK_TOTAL"
if [ "$RUNNABLE" -eq 0 ]; then
    non_execute "configuration : le binaire n'est pas lançable, sa configuration est donc inconnue (« $BIN »)"
else
    probe_version "$BIN"
    printf '    commande      : « %s »  -> code %s\n' "$PROBE_CMD" "$PROBE_CODE"
    PROBE_BANNER="$(printf '%s\n' "$PROBE_OUT" | sed -n '1p')"
    printf '    version       : %s\n' "$PROBE_BANNER"
    PROBE_CONFIG_LINE="$(printf '%s\n' "$PROBE_OUT" | grep -m1 -e 'configuration:' || true)"
    if [ -n "$PROBE_CONFIG_LINE" ]; then
        printf '    configuration : %s\n' "$PROBE_CONFIG_LINE"
    else
        printf '    configuration : (aucune ligne « configuration: » dans la sortie citée ci-dessus)\n'
    fi
    if [ "$PROBE_CODE" -ne 0 ]; then
        echec "configuration illisible : « $PROBE_CMD » a échoué (code $PROBE_CODE) — un binaire qui ne dit pas sa configuration ne peut pas être certifié LGPL"
    elif [ -z "$PROBE_OUT" ]; then
        echec "configuration illisible : « $PROBE_CMD » n'a rien écrit (sortie vide)"
    elif printf '%s\n' "$PROBE_OUT" | grep -q -e '--enable-gpl'; then
        echec "build GPL : « --enable-gpl » présent dans la sortie de « $PROBE_CMD » — binaire non embarquable dans une application propriétaire (critère 4)"
    elif printf '%s\n' "$PROBE_OUT" | grep -q -e '--enable-nonfree'; then
        echec "build non redistribuable : « --enable-nonfree » présent dans la sortie de « $PROBE_CMD »"
    else
        ok "aucun « --enable-gpl » ni « --enable-nonfree » dans la sortie de « $PROBE_CMD » (code $PROBE_CODE)"
    fi
fi

printf '4/%s texte de licence LGPL 2.1 dans le dépôt\n' "$CHECK_TOTAL"
fichier_de_conformite "$LICENSE_TEXT" "texte de licence LGPL 2.1"

printf '5/%s provenance du binaire construit\n' "$CHECK_TOTAL"
fichier_de_conformite "$PROVENANCE" "provenance"

printf '\n'
if [ "$failures" -eq 0 ] && [ "$not_run" -eq 0 ]; then
    printf 'VERT — %s/%s contrôles passent : « %s » est un build sans --enable-gpl ni --enable-nonfree, et le dépôt porte le texte LGPL 2.1 et la provenance.\n' \
        "$CHECK_TOTAL" "$CHECK_TOTAL" "$BIN"
    exit 0
fi

printf "ROUGE — le ffmpeg embarqué n'est pas certifiable LGPL : %s manque(s) constaté(s), %s contrôle(s) non exécuté(s) sur %s.\n" \
    "$failures" "$not_run" "$CHECK_TOTAL"
if [ "$failures" -gt 0 ]; then
    printf '  manques :\n%s' "$FAIL_LIST"
fi
if [ "$not_run" -gt 0 ]; then
    printf '  contrôles non exécutés :\n%s' "$SKIP_LIST"
fi
printf '\n  attendu : un build LGPL (sans --enable-gpl ni --enable-nonfree), avec docs/licenses/ffmpeg-LGPL-2.1.txt\n'
printf '            et docs/licenses/ffmpeg-lgpl-provenance.md présents et non vides (plan §2.6, §4 lot 5).\n'
exit 1
