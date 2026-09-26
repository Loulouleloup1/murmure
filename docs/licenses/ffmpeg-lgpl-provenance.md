# Provenance du binaire `ffmpeg` LGPL embarqué

Plan §2.6 et §4 lot 5, carte `ops` `t_67e52cfd`. Ce fichier est la pièce qui rend
le binaire embarqué vérifiable : sa source exacte, la ligne de configuration
utilisée, ce qui en a été produit, et où. `scripts/checks/embedded-ffmpeg-license.sh`
vérifie que ce fichier existe et n'est pas vide ; c'est **ici** que se lit ce
qu'il n'est pas en mesure de juger.

## 1. Pourquoi ce binaire est construit à la main

`ffmpeg` est **agrégé** par Murmure — appelé en sous-processus, jamais lié à
l'application — mais reste un binaire tiers redistribué dans un paquet
propriétaire : un build GPL v3 y est une faute de licence. Il n'existe aucune
distribution macOS LGPL prête à l'emploi et maintenue (les sources usuelles
publient des builds GPL ; FFmpegKit est arrêté et visait iOS/Android). Le
binaire est donc construit depuis une source **épinglée**, par
`scripts/build-ffmpeg-lgpl.sh`, et la présente provenance en est vendue avec lui.

## 2. Source épinglée

| | |
|---|---|
| URL | `https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz` |
| Taille | 11 388 848 octets |
| SHA-256 du tarball | `05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41` |
| Signature détachée | `https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz.asc` |
| Clef de release | `FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8` — « FFmpeg release signing key `<ffmpeg-devel@ffmpeg.org>` » |
| Verdict GPG | **Bonne signature**, datée du 2025-11-20 03:39:31 CET |

Le hash est revérifié à chaque exécution du script, qui **échoue** si le tarball
ne correspond pas. La signature GPG est vérifiée quand la clef est dans le
trousseau, et le script annonce explicitement quand elle ne l'est pas — jamais
un vert par défaut :

```
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys FCF986EA15E6E293A5644F10B4322F04D67658D8
gpg --verify ffmpeg-8.0.1.tar.xz.asc ffmpeg-8.0.1.tar.xz
```

Pourquoi 8.0.1 et pas la dernière version : c'est la version sur laquelle le
plan a **mesuré** son comportement (§2.1, seuils de `silencedetect`, décodage
AAC/Opus) et celle du binaire d'essai. Une autre version ferait diverger le
binaire embarqué de ce que le plan a mesuré, sans que rien ne le signale.

## 3. Ligne de `configure` complète

Telle qu'exécutée (arguments du script, un par ligne dans le script lui-même) :

```
configure --disable-gpl --disable-nonfree --disable-autodetect --disable-network --disable-doc --disable-ffplay --disable-ffprobe --disable-programs --enable-ffmpeg --disable-swscale --disable-avdevice --disable-audiotoolbox --disable-videotoolbox --disable-appkit --disable-coreimage --disable-securetransport --disable-metal --disable-opencl --disable-everything --enable-avformat --enable-avcodec --enable-avfilter --enable-swresample --enable-protocol=file,pipe --enable-demuxer=mov,matroska,mpegts,hls,wav --enable-muxer=wav,null --enable-decoder=aac,opus,vorbis,flac,mp3,mp3float,pcm_s16le,pcm_s16be,pcm_u8,pcm_f32le,pcm_f32be,pcm_s24le,pcm_s32le,pcm_alaw,pcm_mulaw --enable-encoder=pcm_s16le --enable-parser=aac,opus,vorbis,flac,mpegaudio --enable-filter=silencedetect,aresample,aformat,anull
```

Justification, famille par famille :

- `--disable-gpl --disable-nonfree` : rien de GPL, rien de non redistribuable.
  C'est la condition du critère 4 et la raison d'être de tout ce fichier.
- `--disable-autodetect` : configure ne va **pas** chercher les bibliothèques
  installées sur la machine. Sans lui, un `x264` ou un `lame` GPL présent dans
  `/opt/homebrew` serait lié sans qu'aucune ligne du dépôt ne le dise, et le
  binaire dépendrait de la machine qui l'a construit.
- `--disable-network` : aucun accès réseau (critère 3 — la transcription est
  locale). Les protocoles réseau et la résolution DNS sont hors du binaire.
- `--disable-doc --disable-ffplay --disable-ffprobe --disable-programs --enable-ffmpeg` :
  un seul programme, le binaire `ffmpeg`. Pas de documentation, pas de lecteur
  (qui tirerait SDL).
- `--disable-swscale --disable-avdevice --disable-{audio,video}toolbox --disable-appkit --disable-coreimage --disable-securetransport --disable-metal --disable-opencl` :
  audio seul, sans accélération matérielle ni surface d'interface. Vérifié :
  `ffmpeg -hwaccels` ne liste **rien**.
- `--disable-everything` puis les `--enable-…` nommés un à un : la règle du plan
  (« rien qu'on ne sache justifier ») devient mécanique — tout ce que le binaire
  contient est nommé ci-dessous, et tout le reste est absent.
- conteneurs : `mov` (m4a/mp4), `matroska` (webm/mkv), `mpegts`, `hls`, `wav` en
  entrée ; `wav` et `null` en sortie. `hls` sélectionne automatiquement `aac`,
  `ac3`, `eac3` en entrée (règle `hls_demuxer_select` du configure amont).
- décodeurs : AAC, Opus, Vorbis, FLAC, MP3 (`mp3` et `mp3float`), PCM — la
  raison d'être du binaire est le refus d'Opus/WebM par Core Audio (§2.2).
- encodeur : `pcm_s16le` seul (WAV 16 kHz mono, et sortie `null`).
- filtre : `silencedetect` (§2.1), plus `aresample`/`aformat` (conversion
  16 kHz mono) et `anull`.
- analyseurs : `aac, opus, vorbis, flac, mpegaudio`.

Le binaire **imprime lui-même** cette ligne, les listes entre apostrophes (c'est
la forme que `configure` enregistre) — `ffmpeg -version`, section `configuration:`.

## 4. Version obtenue

```
ffmpeg version 8.0.1 Copyright (c) 2000-2025 the FFmpeg developers
built with Apple clang version 21.0.0 (clang-2100.1.1.101)
libavutil      60.  8.100 / 60.  8.100
libavcodec     62. 11.100 / 62. 11.100
libavformat    62.  3.100 / 62.  3.100
libavfilter    11.  4.100 / 11.  4.100
libswresample   6.  1.100 /  6.  1.100
```

(FFmpeg 8.0.1 termine aussi sa sortie par `Exiting with exit code 0` : c'est le
comportement amont de cette version, pas une ligne ajoutée par ce dépôt.)

## 5. Binaire produit

| | |
|---|---|
| Chemin dans le dépôt | `Murmure/Resources/ffmpeg` (ressource du bundle, voir `project.yml`) |
| SHA-256 | `5dc623699e935a4842e2510f7730b4baf3d19b76ae6f3c2290c593bf6f838b8c` |
| Taille | 2 480 912 octets |
| Type | Mach-O 64-bit executable **arm64** |
| Signature | ad-hoc (`codesign --force --sign -`), `Signature=adhoc`, `codesign --verify` → « valid on disk / satisfies its Designated Requirement ». À la distribution, Developer ID + Hardened Runtime, signé **avec** l'application (§2.6). |
| Liage ffmpeg | **statique** : les bibliothèques `libav*` sont dans le binaire, aucun `.dylib` tiers |
| Liage système | `otool -L` → `/usr/lib/libSystem.B.dylib`, `CoreFoundation`, `CoreVideo`, `CoreMedia` — les seuls frameworks d'Apple, jamais redistribués. **Aucun** chemin `/opt/homebrew`, aucun `VideoToolbox`, aucun `AudioToolbox`. |

`CoreMedia`/`CoreVideo` apparaissent parce que la section Darwin du `configure`
amont appelle `check_apple_framework` sur ces frameworks sans condition ; aucun
décodeur matériel n'est activé pour autant (`CONFIG_VIDEOTOOLBOX` désactivé,
`-hwaccels` vide).

## 6. Texte de licence joint

`docs/licenses/ffmpeg-LGPL-2.1.txt` — **copie verbatim** de `COPYING.LGPLv2.1`
extrait du tarball épinglé (un texte de licence retouché ne serait plus le texte
de la licence). 502 lignes, 26 517 octets, SHA-256
`246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30` — identique à
celui du fichier source du tarball.

Mention « À propos » exigée par ffmpeg.org, écrite verbatim dans
`Murmure/AdvancedPaneView.swift` (groupe *About*) :

> This software uses libraries from the FFmpeg project under the LGPLv2.1

## 7. Ce que le binaire contient, exactement

Relevé sur le binaire produit (`-demuxers`, `-muxers`, `-decoders`, `-encoders`,
`-filters`, `-protocols`, `-hwaccels`) :

| Famille | Contenu |
|---|---|
| protocoles | `file`, `pipe` |
| démultiplexeurs | `mov,mp4,m4a,3gp,3g2,mj2` · `matroska,webm` · `mpegts` · `hls` · `wav` · (+ `aac`, `ac3`, `eac3` tirés par `hls`) |
| muxers | `wav`, `null` |
| décodeurs | `aac` `flac` `mp3` `mp3float` `opus` `vorbis` `pcm_alaw` `pcm_f32be` `pcm_f32le` `pcm_mulaw` `pcm_s16be` `pcm_s16le` `pcm_s24le` `pcm_s32le` `pcm_u8` |
| encodeurs | `pcm_s16le` |
| filtres | `silencedetect` `aresample` `aformat` `anull` — plus les filtres que le programme `ffmpeg` sélectionne lui-même (`ffmpeg_select` du configure amont : `buffer`/`abuffer`/`buffersink`/`abuffersink`/`format`/`null`/`crop`/`trim`/`hflip`/`vflip`/`rotate`/`transpose`) |
| accélération matérielle | aucune |
| analyse de flux (bitstream filters) | aucune |

## 8. Preuves d'exécution (le binaire fait ce pour quoi il est embarqué)

Sur les sources du plan (décodage complet, sortie `-f null -`) :

```
$ Murmure/Resources/ffmpeg -i .../fixtures/yt-src.m4a -f null -
Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'yt-src.m4a':
  Stream #0:0[0x1](eng): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, stereo, fltp, 128 kb/s
  Stream #0:0 -> #0:0 (aac (native) -> pcm_s16le (native))

$ Murmure/Resources/ffmpeg -i .../measure/yt-raw.webm -f null -
Input #0, matroska,webm, from 'yt-raw.webm':
  Stream #0:0(eng): Audio: opus, 48000 Hz, stereo, fltp
  Stream #0:0 -> #0:0 (opus (native) -> pcm_s16le (native))
```

**WebM/Opus est décodé** — c'est précisément ce que Core Audio refuse (§2.2) et
la raison d'être du binaire. Décodage vers le WAV 16 kHz mono du plan §2.1 :

| source | commande | résultat |
|---|---|---|
| `yt-src.m4a` (AAC, 38 min 12 s) | `-ar 16000 -ac 1 -c:a pcm_s16le` | 73 363 246 octets, 1,92 s, pic RSS 19 Mo |
| `yt-raw.webm` (Opus, 38 min 12 s) | `-ar 16000 -ac 1 -c:a pcm_s16le` | 73 361 486 octets, 3,46 s, pic RSS 10 Mo |

Découpage `-c copy` du plan §2.1 sur le WAV décodé : `-ss 60 -t 10 -c copy` →
`slice.wav`, 321 614 octets, 10,04 s, code 0.

`silencedetect` fonctionne et se comporte **exactement** comme le build de
référence : sur un WAV fabriqué (3 s de son + 3 s de silence),
`-af silencedetect=noise=-30dB:duration=0.5` donne les deux mêmes lignes des deux
côtés (`silence_start: 2.999938`, `silence_end: 6 | silence_duration: 3.000062`)
avec le binaire embarqué et avec `/opt/homebrew/bin/ffmpeg`.

## 9. Reproduction

```bash
bash scripts/build-ffmpeg-lgpl.sh                    # construit, signe, installe
bash scripts/checks/embedded-ffmpeg-license.sh       # doit sortir 0 (VERT 5/5)
```

Le script n'est appelé par **aucune** gate automatique : il télécharge, compile
et signe (AGENTS.md). Répertoire de travail par défaut :
`~/Library/Caches/Murmure/ffmpeg-lgpl-build` (tarball, arbre source,
`configure.log`, `make.log`), surchargeable par `--work`. Aucune écriture Git :
le binaire produit n'est pas commité par ce script.

Le chemin d'échec du hash a été **éprouvé**, pas seulement écrit : avec un `curl`
de test qui dépose un contenu non conforme à la place du tarball, le script
s'arrête à l'étape 2/7 sur `ÉCHEC : le tarball ne correspond pas au hash épinglé
— construction refusée`, avec les deux empreintes (attendue et obtenue), code de
sortie 1, **aucun binaire produit et aucun arbre source extrait**.

**Reproductibilité, mesurée.** Une seconde construction du même arbre a donné un
binaire de même taille (2 480 912 octets) dont le **code est identique** : sur
2 480 912 octets, 77 différents, tous dans deux zones — les 16 octets d'UUID de
liaison (`LC_UUID`, tiré au hasard par le linker à chaque édition de liens) et
l'empreinte de signature qui en découle, `LC_UUID` entrant dans le `CodeDirectory`.
Le reste du binaire, `__TEXT` compris, est identique octet pour octet. La
provenance fixe donc l'empreinte du binaire **installé** ; une reconstruction
redonne le même binaire à l'UUID près, jamais à l'octet près.

## 10. Date et machine de construction

| | |
|---|---|
| Date | 2026-09-21 21:56:07 CEST |
| Machine | MacBook M1 (Apple M1), 8 cœurs, 16 Go |
| Système | macOS 26.3.1 (build 25D2128), Darwin 25.3.0 arm64 |
| Compilateur | Apple clang version 21.0.0 (clang-2100.1.1.101) — Xcode 26.5, SDK macOS 26.5 |
| Durée | téléchargement + configure + `make -j8` ≈ 70 s |

## 11. Limites connues

- **arm64 uniquement** : binaire *thin*. Une version x86_64 (ou universelle)
  demanderait une seconde construction.
- **Aucun analyseur de flux** (`-bsfs` vide) : suffisant pour décoder et
  remuxer du WAV, insuffisant pour un `-c copy` qui exigerait p. ex.
  `aac_adtstoasc` (AAC ADTS → MP4) ou `h264_mp4toannexb`. À rouvrir si un lot
  ultérieur copie des flux compressés dans un autre conteneur.
- **Signature ad-hoc** aujourd'hui ; la distribution signera le binaire **avec**
  l'application (Developer ID + Hardened Runtime).
- Le décompte des silences dépend du niveau du **silence de la source** : sur le
  WAV de 16 kHz tiré de `yt-src.m4a`, `noise=-30dB` ne détecte rien et
  `noise=-20dB` détecte 4 passages — cohérent avec la mesure du plan §2.1
  (niveau de silence de la vidéo A ≈ −19,3 dB, au-dessus du seuil −30 dB).

## 12. Fichiers de ce lot

| Fichier | Rôle |
|---|---|
| `scripts/build-ffmpeg-lgpl.sh` | construction, source épinglée, signature, installation (SHA-256 `a42f210309eac84a76e88082a4bdceb8211229a3d5b267537a95a51f475410d1`) |
| `scripts/checks/embedded-ffmpeg-license.sh` | contrat de licence (carte `qa` `t_9011e7e9`, copié verbatim — SHA-256 `dbea398ee0f89f00690e2aeca4476db18e6ebcceb5164914df547b88bcc05bb8`) |
| `Murmure/Resources/ffmpeg` | le binaire embarqué (SHA-256 `5dc623699e935a4842e2510f7730b4baf3d19b76ae6f3c2290c593bf6f838b8c`) |
| `docs/licenses/ffmpeg-LGPL-2.1.txt` | texte de licence, verbatim |
| `docs/licenses/ffmpeg-lgpl-provenance.md` | ce fichier |
| `project.yml` | `Murmure/Resources` copié comme ressource du bundle |
| `Murmure/AdvancedPaneView.swift` | mention « À propos » |
