#!/usr/bin/env bash
# Construit le binaire `ffmpeg` **LGPL** embarqué par Murmure (plan §2.6, §4 lot 5).
#
# POURQUOI CE SCRIPT EXISTE. Murmure est propriétaire et embarque `ffmpeg` : il
# ne peut donc pas embarquer un build GPL v3. Or **il n'existe aucune
# distribution macOS LGPL prête à l'emploi et maintenue** — les sources usuelles
# publient des builds GPL, et FFmpegKit (arrêté) visait iOS/Android. La seule
# voie compatible est de construire le binaire nous-mêmes, depuis une source
# épinglée, et d'en vendre la provenance (`docs/licenses/ffmpeg-lgpl-provenance.md`).
#
# CE QUE CE SCRIPT GARANTIT :
#   1. la source est **épinglée** : URL + SHA-256 du tarball, revérifiés à chaque
#      exécution. Un tarball qui ne correspond pas au hash **fait échouer le
#      script** (jamais de construction sur une source non vérifiée) ;
#   2. la signature GPG détachée `ffmpeg-X.tar.xz.asc` est vérifiée dès que la
#      clef de release FFmpeg est dans le trousseau (sinon : avertissement
#      explicite, jamais un faux vert) ;
#   3. `--disable-gpl --disable-nonfree` : le binaire produit ne peut pas
#      contenir une once de code GPL ou non redistribuable ;
#   4. `--disable-autodetect` : configure ne va pas chercher les bibliothèques
#      installées sur la machine (x264/lame = GPL, openssl = réseau). Sans lui,
#      le binaire produit dépendrait de la machine qui l'a construit et pourrait
#      redevenir GPL sans qu'une ligne change ;
#   5. la ligne de `configure` complète est imprimée à chaque exécution et
#      reportée telle quelle dans la provenance — c'est elle qui est enregistrée,
#      pas un résumé.
#
# HORS GATE AUTOMATIQUE. Ce script télécharge, compile et signe : il n'est
# **jamais** appelé par `scripts/codex/verify.sh` ni par une autre gate
# (AGENTS.md : aucune installation ni téléchargement dans une gate automatique).
# Il est exécuté à la main, dans le périmètre explicite d'une carte.
#
# CE QUE CE SCRIPT NE FAIT PAS : aucune écriture Git, aucun `git add`, aucun
# commit, aucun push. Il écrit le binaire et le texte de licence, c'est tout.
#
# Usage : bash scripts/build-ffmpeg-lgpl.sh [options]
#   --output CHEMIN   binaire produit (défaut : <racine>/Murmure/Resources/ffmpeg)
#   --work CHEMIN     répertoire de travail (défaut : ~/Library/Caches/Murmure/ffmpeg-lgpl-build)
#   --jobs N          parallélisme de `make` (défaut : nombre de cœurs)
#   --skip-sign       ne pas signer ad-hoc le binaire produit (déconseillé)
#   -h, --help        cette aide
#
# Sortie : 0 si le binaire est construit, signé et vérifié ; 1 en échec ;
#          2 si l'usage est invalide.

set -euo pipefail

NOM="build-ffmpeg-lgpl"

# --- Source épinglée -------------------------------------------------------
# Version 8.0.1 : c'est la version sur laquelle le plan a *mesuré* son
# comportement (§2.1 : seuils de silencedetect, décodage AAC/Opus) et celle du
# binaire d'essai. Construire une autre version ferait diverger le binaire
# embarqué de ce que le plan a mesuré, sans que rien ne le signale.
FFMPEG_VERSION="8.0.1"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_SHA256="05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41"
# Clef de release FFmpeg (« FFmpeg release signing key <ffmpeg-devel@ffmpeg.org> »),
# empreinte complète — c'est elle qu'on vérifie, jamais un identifiant court.
FFMPEG_SIGNING_KEY="FCF986EA15E6E293A5644F10B4322F04D67658D8"
FFMPEG_SIGNER_UID="FFmpeg release signing key <ffmpeg-devel@ffmpeg.org>"

USAGE="usage: bash scripts/build-ffmpeg-lgpl.sh [--output CHEMIN] [--work CHEMIN]
                                          [--jobs N] [--skip-sign]
       défaut : sortie <racine>/Murmure/Resources/ffmpeg"

usage() { printf '%s\n' "$USAGE"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT="$REPO_ROOT/Murmure/Resources/ffmpeg"
WORK="${MURMURE_FFMPEG_BUILD_DIR:-$HOME/Library/Caches/Murmure/ffmpeg-lgpl-build}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
SIGN=1

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)   [ "$#" -ge 2 ] || { printf '%s: --output attend un chemin\n' "$NOM" >&2; exit 2 ;}; OUTPUT="$2"; shift 2 ;;
        --work)     [ "$#" -ge 2 ] || { printf '%s: --work attend un chemin\n' "$NOM" >&2; exit 2 ;}; WORK="$2"; shift 2 ;;
        --jobs)     [ "$#" -ge 2 ] || { printf '%s: --jobs attend un nombre\n' "$NOM" >&2; exit 2 ;}; JOBS="$2"; shift 2 ;;
        --skip-sign) SIGN=0; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) printf '%s: argument inconnu « %s »\n' "$NOM" "$1" >&2; usage >&2; exit 2 ;;
    esac
done

for outil in curl tar shasum make; do
    command -v "$outil" >/dev/null 2>&1 || { printf '%s: outil requis absent : %s\n' "$NOM" "$outil" >&2; exit 1; }
done

TARBALL="$WORK/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SRC_DIR="$WORK/ffmpeg-${FFMPEG_VERSION}"
LICENSE_SRC="$SRC_DIR/COPYING.LGPLv2.1"
LICENSE_DEST="$REPO_ROOT/docs/licenses/ffmpeg-LGPL-2.1.txt"
BUILT_BIN="$SRC_DIR/ffmpeg"

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

printf '%s — ffmpeg %s LGPL, source épinglée\n\n' "$NOM" "$FFMPEG_VERSION"
printf 'dépôt      : %s\n' "$REPO_ROOT"
printf 'sortie     : %s\n' "$OUTPUT"
printf 'travail    : %s\n' "$WORK"
printf 'source     : %s\n' "$FFMPEG_URL"
printf 'sha256     : %s (attendu)\n' "$FFMPEG_SHA256"
printf 'jobs       : %s\n\n' "$JOBS"

mkdir -p "$WORK"

# --- 1. Téléchargement (mis en cache) --------------------------------------
if [ -f "$TARBALL" ] && [ "$(sha256_of "$TARBALL")" = "$FFMPEG_SHA256" ]; then
    printf '1/7 source : tarball déjà en cache et conforme\n'
else
    printf '1/7 source : téléchargement de %s\n' "$FFMPEG_URL"
    rm -f "$TARBALL"
    curl --fail --location --retry 3 --silent --show-error -o "$TARBALL" "$FFMPEG_URL"
fi

# --- 2. Vérification du hash : échec explicite, jamais un avertissement -----
printf '2/7 hash   : vérification du tarball\n'
GOT_SHA256="$(sha256_of "$TARBALL")"
if [ "$GOT_SHA256" != "$FFMPEG_SHA256" ]; then
    printf '\nÉCHEC : le tarball ne correspond pas au hash épinglé — construction refusée.\n' >&2
    printf '  fichier  : %s\n' "$TARBALL" >&2
    printf '  URL      : %s\n' "$FFMPEG_URL" >&2
    printf '  attendu  : %s\n' "$FFMPEG_SHA256" >&2
    printf '  obtenu   : %s\n' "$GOT_SHA256" >&2
    printf '  Conduite à tenir : supprimer le fichier et relancer (une source qui a bougé n’est\n' >&2
    printf '  pas la source épinglée ; ne jamais modifier le hash sans revérifier la signature GPG).\n' >&2
    exit 1
fi
printf '            hash conforme : %s\n' "$GOT_SHA256"

# --- 3. Signature GPG détachée (si la clef est disponible) -----------------
printf '3/7 gpg    : vérification de la signature de release\n'
SIG_VERDICT="non vérifiée"
if ! command -v gpg >/dev/null 2>&1; then
    printf '            AVERTISSEMENT : gpg absent — signature non vérifiée (hash vérifié, lui).\n'
    SIG_VERDICT="gpg absent — non vérifiée"
else
    SIGFILE="$TARBALL.asc"
    sig_ok=0
    if gpg --batch --list-keys "$FFMPEG_SIGNING_KEY" >/dev/null 2>&1; then
        sig_ok=1
    else
        printf '            clef %s absente du trousseau, tentative d’import…\n' "$FFMPEG_SIGNING_KEY"
        for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org; do
            if curl --fail --silent --max-time 15 -o "$SIGFILE" "$FFMPEG_URL.asc" \
               && gpg --batch --keyserver "$ks" --recv-keys "$FFMPEG_SIGNING_KEY" >/dev/null 2>&1; then
                sig_ok=1
                break
            fi
        done
    fi
    [ -f "$SIGFILE" ] || curl --fail --location --silent --show-error -o "$SIGFILE" "$FFMPEG_URL.asc" || true
    if [ "$sig_ok" -eq 0 ]; then
        printf '            AVERTISSEMENT : clef de release indisponible — signature non vérifiée\n'
        printf '            (le hash épinglé reste, lui, vérifié ; pour la vérifier, une fois :\n'
        printf '             gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys %s)\n' "$FFMPEG_SIGNING_KEY"
        SIG_VERDICT="clef de release indisponible — non vérifiée"
    elif [ ! -f "$SIGFILE" ]; then
        printf '            AVERTISSEMENT : signature détachée non téléchargeable — non vérifiée\n'
        SIG_VERDICT="signature détachée indisponible — non vérifiée"
    else
        # Une signature PRÉSENTE et invalide est un échec dur : c'est le seul cas
        # où l'on sait que la source est mauvaise.
        GPG_OUT="$(gpg --batch --verify "$SIGFILE" "$TARBALL" 2>&1)" || {
            printf 'ÉCHEC : signature de release invalide pour %s\n%s\n' "$TARBALL" "$GPG_OUT" >&2
            exit 1
        }
        printf '            signature valide : %s\n' "$FFMPEG_SIGNER_UID"
        printf '            empreinte         : %s\n' "$FFMPEG_SIGNING_KEY"
        SIG_VERDICT="valide, clef $FFMPEG_SIGNING_KEY ($FFMPEG_SIGNER_UID)"
    fi
fi

# --- 4. Extraction ---------------------------------------------------------
printf '4/7 source : extraction\n'
if [ ! -f "$SRC_DIR/configure" ]; then
    # Le tarball a un unique répertoire de tête (`ffmpeg-<version>/`) : il se
    # déplie directement dans le répertoire de travail, sans nettoyage préalable.
    tar -xJf "$TARBALL" -C "$WORK"
fi
printf '            arbre source : %s\n' "$SRC_DIR"

# --- 5. configure ----------------------------------------------------------
# La ligne est écrite en clair, un argument par ligne : c'est la pièce
# enregistrée dans la provenance, elle doit être lisible et copiable telle
# quelle. Chaque famille d'options est justifiée par un commentaire parce que
# la règle du plan §2.6 est « rien de GPL, rien de réseau, rien qu'on ne sache
# justifier ».
CONFIGURE_ARGS=(
    # licence : aucune ligne GPL, aucune ligne non redistribuable. Si l'une
    # cédait, le contrat scripts/checks/embedded-ffmpeg-license.sh rougirait.
    --disable-gpl
    --disable-nonfree
    # aucune bibliothèque détectée sur la machine : un build qui dépend de
    # /opt/homebrew n'est ni reproductible ni à l'abri d'un x264 GPL.
    --disable-autodetect
    # aucun accès réseau (critère 3 : la transcription locale ne sort pas) ;
    # --disable-network désactive les protocoles réseau et la résolution DNS.
    --disable-network
    # documentation, lecteurs : hors périmètre, et ffplay tirerait SDL.
    --disable-doc
    --disable-ffplay
    --disable-ffprobe
    # un seul programme : le binaire `ffmpeg` (pas de ffplay/ffprobe malgré
    # les deux drapeaux ci-dessus, qui restent pour que l'intention soit lisible).
    --disable-programs
    --enable-ffmpeg
    # audio seul : ni vidéo, ni accélération matérielle Apple, ni UI.
    --disable-swscale
    --disable-avdevice
    --disable-audiotoolbox
    --disable-videotoolbox
    --disable-appkit
    --disable-coreimage
    --disable-securetransport
    --disable-metal
    --disable-opencl
    # --disable-everything impose de nommer chaque composant conservé :
    # c'est ce qui rend la revue possible ligne à ligne.
    --disable-everything
    --enable-avformat
    --enable-avcodec
    --enable-avfilter
    --enable-swresample
    # protocoles : `file` (chemins locaux) et `pipe` (`-f null -`).
    --enable-protocol=file,pipe
    # conteneurs d'entrée : m4a (mov), webm/mkv (matroska), flux HLS et MPEG-TS,
    # et wav — le découpage `-c copy` du plan §2.1 relit le WAV décodé.
    --enable-demuxer=mov,matroska,mpegts,hls,wav
    # conteneurs de sortie : wav (décodage 16 kHz mono), null (silencedetect).
    --enable-muxer=wav,null
    # décodeurs : AAC, Opus, Vorbis, MP3, FLAC et PCM — la raison d'être du
    # binaire est le refus d'Opus/WebM par Core Audio (plan §2.2).
    --enable-decoder=aac,opus,vorbis,flac,mp3,mp3float,pcm_s16le,pcm_s16be,pcm_u8,pcm_f32le,pcm_f32be,pcm_s24le,pcm_s32le,pcm_alaw,pcm_mulaw
    --enable-encoder=pcm_s16le
    # analyseurs : nécessaires à l'AAC/Opus/Vorbis/FLAC/MP3 en flux.
    --enable-parser=aac,opus,vorbis,flac,mpegaudio
    # filtres : silencedetect (plan §2.1), aresample/aformat (16 kHz mono),
    # anull (filtre nul inséré automatiquement dans une chaîne -af).
    --enable-filter=silencedetect,aresample,aformat,anull
)

printf '5/7 configure : ligne complète\n'
CONFIGURE_CMD="$SRC_DIR/configure ${CONFIGURE_ARGS[*]}"
printf '            %s\n' "$CONFIGURE_CMD"
( cd "$SRC_DIR" && ./configure "${CONFIGURE_ARGS[@]}" ) >"$WORK/configure.log" 2>&1 || {
    printf 'ÉCHEC : configure a échoué (journal : %s)\n' "$WORK/configure.log" >&2
    tail -20 "$WORK/configure.log" >&2
    exit 1
}
# Le contrôle de licence au plus tôt : inutile de compiler vingt minutes un
# binaire qu'on refusera d'embarquer.
if grep -q -e '--enable-gpl' -e '--enable-nonfree' "$SRC_DIR/ffbuild/config.mak" "$WORK/configure.log" 2>/dev/null; then
    printf 'ÉCHEC : la configuration produite porte --enable-gpl ou --enable-nonfree.\n' >&2
    exit 1
fi
printf '            configuration sans --enable-gpl ni --enable-nonfree\n'

# --- 6. Compilation --------------------------------------------------------
printf '6/7 make      : %s jobs (journal : %s)\n' "$JOBS" "$WORK/make.log"
( cd "$SRC_DIR" && make -j"$JOBS" ffmpeg ) >"$WORK/make.log" 2>&1 || {
    printf 'ÉCHEC : la compilation a échoué (journal : %s)\n' "$WORK/make.log" >&2
    tail -30 "$WORK/make.log" >&2
    exit 1
}
[ -x "$BUILT_BIN" ] || { printf 'ÉCHEC : binaire attendu introuvable : %s\n' "$BUILT_BIN" >&2; exit 1; }

# --- 7. Signature ad-hoc, installation, empreintes ------------------------
printf '7/7 pose     : signature et installation\n'
mkdir -p "$(dirname "$OUTPUT")"
install -m 0755 "$BUILT_BIN" "$OUTPUT"
if [ "$SIGN" -eq 1 ]; then
    codesign --force --sign - "$OUTPUT"
    printf '            binaire signé ad-hoc (codesign --sign -)\n'
fi

# Le texte de licence est copié **verbatim** depuis la source épinglée : un
# texte de licence retouché ne serait plus le texte de la licence.
mkdir -p "$(dirname "$LICENSE_DEST")"
install -m 0644 "$LICENSE_SRC" "$LICENSE_DEST"

BIN_SHA256="$(sha256_of "$OUTPUT")"
LICENSE_SHA256="$(sha256_of "$LICENSE_DEST")"
VERSION_BANNER="$("$OUTPUT" -version 2>&1 | sed -n '1p')"
CONFIG_LINE="$("$OUTPUT" -version 2>&1 | grep -m1 -e 'configuration:' || true)"

if "$OUTPUT" -version 2>&1 | grep -q -e '--enable-gpl'; then
    printf 'ÉCHEC : --enable-gpl présent dans le binaire produit.\n' >&2
    exit 1
fi
if "$OUTPUT" -version 2>&1 | grep -q -e '--enable-nonfree'; then
    printf 'ÉCHEC : --enable-nonfree présent dans le binaire produit.\n' >&2
    exit 1
fi

printf '\nCONSTRUIT\n'
printf '  binaire              : %s\n' "$OUTPUT"
printf '  taille               : %s octets\n' "$(wc -c < "$OUTPUT" | tr -d '[:space:]')"
printf '  sha256 (binaire)     : %s\n' "$BIN_SHA256"
printf '  version              : %s\n' "$VERSION_BANNER"
printf '  licence              : %s (sha256 %s, verbatim depuis %s)\n' "$LICENSE_DEST" "$LICENSE_SHA256" "$LICENSE_SRC"
printf '  signature de release : %s\n' "$SIG_VERDICT"
printf '  sha256 (tarball)     : %s\n' "$FFMPEG_SHA256"
printf '  vérification finale  : bash scripts/checks/embedded-ffmpeg-license.sh\n'
