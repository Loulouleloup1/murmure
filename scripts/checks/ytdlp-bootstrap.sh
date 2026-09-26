#!/usr/bin/env bash
# Contrat du critère 5 — la première utilisation de `yt-dlp` (plan §2.3, §4 lot 6 ; décision R5).
#
# POURQUOI CE CONTRÔLE EXISTE. `yt-dlp` n'est pas dans le bundle : il est **téléchargé par
# l'application au premier besoin** (`Application Support/Murmure/tools/yt-dlp`, critère 5), dans
# un paquet macOS qui exige, sur arm64, un binaire signé pour être exécutable. Ce dépôt a mesuré
# l'asymétrie qui rend l'étape délicate : `curl` ne pose pas l'attribut de quarantaine,
# `URLSession` **oui** — l'application retire donc un attribut que macOS a posé exprès
# (plan §8, dernière ligne). L'utilisateur, lui, n'a qu'une exigence : que ça marche **sans
# dialogue Gatekeeper**.
#
# CE QUE CE SCRIPT CONTRÔLE, et pourquoi ce sont ces faits-là. Un dialogue Gatekeeper ne
# s'observe pas depuis un script ; ce qui s'observe, et qui le conditionne, est l'**état du
# binaire installé** :
#   1. l'installateur de l'application existe (`Murmure/YtDlpInstaller.swift`) — sans lui, il n'y
#      a pas de procédure de première utilisation, seulement un fichier tombé du ciel ;
#   2. le binaire est **là où l'application le cherchera** ;
#   3. il y est **vraiment** — un lien vers le `yt-dlp` de Homebrew (`/opt/homebrew/bin/yt-dlp`
#      existe sur cette machine) passerait les contrôles 4 à 6 sans rien prouver du critère 5 ;
#   4. il s'exécute et rend sa version : c'est l'exécution d'un binaire **téléchargé**, donc le
#      contrôle de fait de la signature (mesuré : un binaire non signé ne s'exécute pas sur arm64) ;
#   5. **aucune quarantaine** (`com.apple.quarantine`) ne subsiste : c'est cet attribut qui
#      déclenche le dialogue, et c'est lui que l'application doit avoir retiré (`xattr -d`) ;
#   6. la signature est **ad-hoc** (`codesign -s -`) et vérifie (`codesign --verify`) : mesuré, un
#      binaire simplement téléchargé n'est **pas signé du tout** (`code object is not signed at
#      all`), donc ce contrôle n'est pas redondant avec les précédents.
#
# Ce qu'il ne peut pas distinguer, et c'est dit plutôt que caché : si l'implémentation
# téléchargeait avec `curl`, l'attribut de quarantaine n'aurait jamais été posé et le contrôle 5
# serait satisfait sans qu'aucune ligne ne le retire. Le plan a tranché l'inverse (`URLSession`,
# §8) ; le contrôle qui ne dépend pas de ce détail est le 6.
#
# CE QU'IL NE FAIT PAS, ET C'EST DÉLIBÉRÉ : il ne télécharge rien, n'installe rien, ne signe rien,
# ne modifie aucun attribut et n'écrit aucun fichier (AGENTS.md : aucune installation dans une
# gate automatique). Il **lit**. C'est l'acquisition réelle — périmètre réseau explicite de la
# carte d'implémentation, qui est seule à avoir le droit de télécharger et d'installer — qui
# produit l'artefact contrôlé ici ; le script, lui, reste rejouable sans réseau. Il n'est **pas**
# ajouté à `scripts/codex/verify.sh` pour la même raison.
#
# SECOND USAGE (critère 6, « pas de re-téléchargement »). Le script imprime l'empreinte du binaire
# installé — sha256, taille, date de modification. Rejoué **après** un second lancement, il rend la
# même empreinte si le binaire n'a pas été retéléchargé, et l'affiche si `yt-dlp` a été mis à jour
# volontairement. C'est la moitié « script » du critère 6 (plan §7) ; la moitié « test » est dans
# `AcquisitionBootstrapDiagnosticsTests` (`bootstrapStep`, `recoveryStep`).
#
# Usage : bash scripts/checks/ytdlp-bootstrap.sh [chemin-du-binaire]
#         Défaut : $HOME/Library/Application Support/Murmure/tools/yt-dlp
#         L'argument sert à contrôler un artefact ailleurs (copie d'essai, disque de test) ;
#         l'installateur, lui, est toujours cherché dans le dépôt de ce script.
#         bash scripts/checks/ytdlp-bootstrap.sh --help
#
# La racine du dépôt est déduite de l'emplacement du script, jamais de l'environnement : une gate
# qu'un `export` peut déplacer ne contrôle plus le dépôt.
#
# Sortie : 0 si les 6 contrôles passent ; 1 si au moins un manque ou si un contrôle a dû être
#          laissé non exécuté ; 2 si l'usage est invalide. Chaque contrôle affiche le chemin
#          réellement testé, la commande réellement lancée et son code de sortie : un rouge se lit
#          sans relire ce fichier.

set -uo pipefail

NOM="ytdlp-bootstrap"
CHECK_TOTAL=6
USAGE="usage: bash scripts/checks/ytdlp-bootstrap.sh [chemin-du-binaire]
       défaut : \$HOME/Library/Application Support/Murmure/tools/yt-dlp
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

INSTALLER="$REPO_ROOT/Murmure/YtDlpInstaller.swift"
SUPPORT="$HOME/Library/Application Support/Murmure"
TOOLS_DIR="$SUPPORT/tools"
DEFAULT_BIN="$TOOLS_DIR/yt-dlp"

BIN_ARG="${1:-}"
if [ -z "$BIN_ARG" ]; then
    BIN="$DEFAULT_BIN"
    BIN_ORIGIN="chemin par défaut de l'application"
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
date_de() { stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$1" 2>/dev/null || printf 'date-indisponible'; }

# Une empreinte complète du fichier installé : c'est elle qui permet de comparer deux exécutions
# (critère 6) sans rien écrire sur le disque.
empreinte() {
    printf 'sha256 %s  taille %s octets  modifié %s' \
        "$(sha256_of "$1")" "$(octets_de "$1")" "$(date_de "$1")"
}

printf '%s — première utilisation de yt-dlp (critère 5, lot 6)\n\n' "$NOM"
printf 'dépôt      : %s\n' "$REPO_ROOT"
printf 'installateur : %s\n' "$INSTALLER"
printf 'binaire    : %s  [%s]\n' "$BIN" "$BIN_ORIGIN"
printf 'emplacement attendu : %s\n\n' "$DEFAULT_BIN"

printf '1/%s la procédure de première utilisation existe dans l’application\n' "$CHECK_TOTAL"
if [ ! -e "$INSTALLER" ]; then
    echec "installateur absent : « $INSTALLER » n'existe pas (test -e) — sans lui, yt-dlp n'a pas d'installation en Application Support et le critère 5 n'est pas tenu"
elif [ ! -f "$INSTALLER" ]; then
    echec "installateur invalide : « $INSTALLER » existe mais n'est pas un fichier régulier (test -f)"
elif [ ! -s "$INSTALLER" ]; then
    echec "installateur vide : « $INSTALLER » (test -s)"
else
    ok "installateur présent : « $INSTALLER », $(octets_de "$INSTALLER") octets"
fi

printf '2/%s le binaire est à l’emplacement de l’application\n' "$CHECK_TOTAL"
if [ ! -e "$BIN" ]; then
    echec "binaire absent : « $BIN » n'existe pas (test -e) — rien n'a été téléchargé pour l'application"
elif [ ! -f "$BIN" ]; then
    echec "binaire invalide : « $BIN » existe mais n'est pas un fichier régulier (test -f)"
elif [ ! -s "$BIN" ]; then
    echec "binaire vide : « $BIN » (test -s)"
else
    ok "binaire présent : « $BIN », $(empreinte "$BIN")"
fi

printf '3/%s ce binaire est bien celui de l’application, pas celui du système\n' "$CHECK_TOTAL"
if [ ! -f "$BIN" ]; then
    non_execute "provenance : aucun fichier régulier à situer (voir 2/$CHECK_TOTAL)"
elif [ -L "$BIN" ]; then
    echec "lien symbolique : « $BIN » est un lien (« $(readlink "$BIN" 2>/dev/null || printf '?') ») — un yt-dlp emprunté au système ne prouve pas le téléchargement du critère 5"
else
    RESOLU="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
    case "$RESOLU" in
        "$SUPPORT"/*)
            ok "le binaire vit dans Application Support : « $RESOLU »"
            ;;
        *)
            echec "hors Application Support : « $RESOLU » n'est pas sous « $SUPPORT » — l'application ne télécharge pas là où elle lit"
            ;;
    esac
fi

printf '4/%s le binaire s’exécute et rend sa version\n' "$CHECK_TOTAL"
if [ ! -f "$BIN" ]; then
    non_execute "exécution : aucun fichier régulier à lancer (voir 2/$CHECK_TOTAL)"
elif [ ! -x "$BIN" ]; then
    echec "binaire non exécutable : « $BIN » (test -x) — un binaire téléchargé qui ne s'exécute pas est le cas que la signature et la quarantaine produisent"
else
    VERSION_OUT="$("$BIN" --version 2>&1)" ; VERSION_RC=$?
    printf '    commande : « %s --version »  -> code %s\n' "$BIN" "$VERSION_RC"
    if [ "$VERSION_RC" -ne 0 ]; then
        echec "exécution refusée : « $BIN --version » sort en $VERSION_RC — $(printf '%s' "$VERSION_OUT" | head -1)"
    elif [ -z "$VERSION_OUT" ]; then
        echec "version illisible : « $BIN --version » n'a rien écrit (sortie vide)"
    else
        ok "exécution réelle, version rendue : $(printf '%s' "$VERSION_OUT" | head -1)"
    fi
fi

printf '5/%s aucune quarantaine sur le binaire installé\n' "$CHECK_TOTAL"
if [ ! -f "$BIN" ]; then
    non_execute "quarantaine : aucun fichier régulier à lire (voir 2/$CHECK_TOTAL)"
else
    QUAR_OUT="$(xattr -p com.apple.quarantine "$BIN" 2>&1)" ; QUAR_RC=$?
    printf '    commande : « xattr -p com.apple.quarantine %s »  -> code %s\n' "$BIN" "$QUAR_RC"
    if [ "$QUAR_RC" -eq 0 ]; then
        echec "quarantaine toujours posée : « $QUAR_OUT » — c'est cet attribut qui déclenche le dialogue Gatekeeper, et l'application doit l'avoir retiré (xattr -d com.apple.quarantine)"
    elif printf '%s' "$QUAR_OUT" | grep -q 'No such xattr'; then
        ok "aucun attribut com.apple.quarantine (xattr -p sort en $QUAR_RC : « No such xattr »)"
    else
        non_execute "quarantaine : « xattr -p » a échoué pour une autre raison (code $QUAR_RC) — « $QUAR_OUT »"
    fi
fi

printf '6/%s signature ad-hoc valide\n' "$CHECK_TOTAL"
if [ ! -f "$BIN" ]; then
    non_execute "signature : aucun fichier régulier à vérifier (voir 2/$CHECK_TOTAL)"
else
    SIGN_VERIF_OUT="$(codesign --verify --verbose "$BIN" 2>&1)" ; SIGN_VERIF_RC=$?
    SIGN_DESC_OUT="$(codesign -dvvv "$BIN" 2>&1)"
    printf '    commande : « codesign --verify --verbose %s »  -> code %s\n' "$BIN" "$SIGN_VERIF_RC"
    printf '    descripteur : %s\n' "$(printf '%s' "$SIGN_DESC_OUT" | grep -m1 -e 'Signature=' || printf '(aucune ligne Signature=)')"
    if [ "$SIGN_VERIF_RC" -ne 0 ]; then
        echec "signature invalide : « codesign --verify » sort en $SIGN_VERIF_RC — $(printf '%s' "$SIGN_VERIF_OUT" | head -1)"
    elif printf '%s' "$SIGN_DESC_OUT" | grep -q -e 'Signature=adhoc'; then
        ok "signature ad-hoc vérifiée (codesign --verify : $(printf '%s' "$SIGN_VERIF_OUT" | head -1))"
    else
        echec "signature absente ou non ad-hoc : « codesign -dvvv » ne porte pas « Signature=adhoc » — un binaire simplement téléchargé n'est pas signé du tout (code object is not signed at all)"
    fi
fi

printf '\n'
if [ "$failures" -eq 0 ] && [ "$not_run" -eq 0 ]; then
    printf 'VERT — %s/%s contrôles passent : « %s » est installé dans Application Support, s’exécute (version %s), sans quarantaine et signé ad-hoc.\n' \
        "$CHECK_TOTAL" "$CHECK_TOTAL" "$BIN" "$(printf '%s' "${VERSION_OUT:-}" | head -1)"
    printf '        empreinte pour la comparaison du critère 6 : %s\n' "$(empreinte "$BIN")"
    exit 0
fi

printf "ROUGE — la première utilisation de yt-dlp n'est pas certifiable : %s manque(s) constaté(s), %s contrôle(s) non exécuté(s) sur %s.\n" \
    "$failures" "$not_run" "$CHECK_TOTAL"
if [ "$failures" -gt 0 ]; then
    printf '  manques :\n%s' "$FAIL_LIST"
fi
if [ "$not_run" -gt 0 ]; then
    printf '  contrôles non exécutés :\n%s' "$SKIP_LIST"
fi
printf '\n  attendu : « %s » produit par l’application (Murmure/YtDlpInstaller.swift),\n' "$DEFAULT_BIN"
printf '            téléchargé depuis https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos,\n'
printf '            quarantaine retirée et signature ad-hoc appliquée (plan §2.3, §4 lot 6, critère 5).\n'
exit 1
