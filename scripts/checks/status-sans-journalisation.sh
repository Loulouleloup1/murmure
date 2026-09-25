#!/usr/bin/env bash
# Règle gelée du lot 10-S : « `status` ne journalise ni source ni transcript ».
#
# `control-queue-wiring.sh` (427 l.) observe le GRAPHE de la couture — qui appelle qui, qui possède
# la file — et `TranscriptQueueTests.swift` (728 l.) observe le COMPORTEMENT de la file. Ni l'un ni
# l'autre ne dit quoi que ce soit de ce que `status` FAIT de la valeur qu'il renvoie : un serveur qui
# lirait la file commune puis en journaliserait la source et le transcript verdirait les deux
# artefacts, et la règle gelée serait perdue. Ce contrôle est le troisième regard ; il est nommé
# `status-sans-journalisation` pour cela.
#
# Il est volontairement SÉPARÉ du script de câblage : `control-queue-wiring.sh` est un artefact revu
# et transporté, et son dénominateur (21 contrôles) est une valeur de contrat. L'ajouter là-dedans
# aurait changé ce dénominateur et cassé la comparaison `cmp` avec la branche donatrice. L'addition
# est une preuve, pas une retouche d'un artefact validé.
#
# Ce que le contrôle observe, et pourquoi ce n'est pas une recherche de mots :
#
#   * le CHEMIN EXÉCUTÉ de la commande `status` seul — `func status`, `func statut`, ou `case
#     .status:` — extrait par un parseur de bloc équilibré (ou, pour un `case` sans accolades,
#     jusqu'au `case` suivant ou à la fermeture du switch, mesurés à son indentation) ;
#   * dans CE CHEMIN, l'absence de tout puits de journalisation (`logger`, `Logger`, `os_log`,
#     `NSLog`, `print(`, `debugPrint(`) ;
#   * dans CE CHEMIN, l'absence de toute lecture de la source ou du transcript (`requete.source`,
#     `.transcript`, `.texte`, `.contenu`, `entree.source`, …) : une valeur lue pour être
#     journalisée est exactement ce que la règle interdit.
#
# Un mot de ce vocabulaire ailleurs dans le fichier — un commentaire, une autre méthode, un
# `logger` légitime dans `transcribe` — ne peut donc ni rendre ce contrôle rouge ni le rendre vert :
# seul le corps de la commande compte.
#
# MODES
#   check              rend un verdict.  VERT = la règle est respectée.
#   mutant-journalise  mesure une DIFFÉRENCE : le contrôle sur l'assemblage de référence, puis sur
#                      l'assemblage où `status` journalise la source et le transcript, ligne
#                      interdite en TÊTE de bras.  Un contrôle déjà rouge ne prouve rien, donc un
#                      mutant qui ne fait rien (ou qui ne peut rien faire) est dit INAPPLICABLE et
#                      sort 3 — jamais « capturé ».
#   mutant-journalise-apres-blanc
#                      le même mutant, mais placé APRÈS la première ligne du corps et une ligne
#                      blanche. C'est la forme que le code réel prend (une instruction ajoutée
#                      au-dessus d'un `return` existant) et, avant correction, celle que ce
#                      contrôle ratait : l'extraction s'arrêtait à la ligne blanche et le `logger`
#                      restait hors du périmètre observé, donc VERT. Un contrôle qui ne capture que
#                      `mutant-journalise` est capturé PAR CONSTRUCTION et ne prouve rien sur la
#                      qualité de l'extraction : les deux modes doivent être capturés, et dans cet
#                      ordre (le placement difficile d'abord).
#   mutant-journalise-apres-imbre
#                      le même mutant, mais placé APRÈS la fermeture d'un BLOC IMBRIQUÉ du bras
#                      (`switch` ou `if` interne), puis une ligne vide. C'est la forme que le
#                      second parseur ratait : il acceptait une indentation supérieure à celle du
#                      `case .status:`, donc le `case`/`default`/`}` imbriqué terminait le bras.
#                      Sans ce mode, les deux précédents deviennent capturés PAR CONSTRUCTION dès
#                      qu'un bloc imbriqué précède leur point d'insertion. Sur une base dont le
#                      `status` n'a aucun bloc imbriqué (un `func`, typiquement), le mode sort
#                      INAPPLICABLE (3) plutôt que « capturé » : rien à y muter, donc rien à prouver.
#   mutant-journalise-second-chemin
#                      le même mutant, mais placé dans le SECOND chemin `status` observé — le
#                      `case .status:` d'un serveur qui expose aussi un `func status` bénin. Les
#                      trois modes ci-dessus ne placent la ligne interdite que dans le PREMIER
#                      chemin trouvé : sur ce site-là ils seraient capturés PAR CONSTRUCTION, donc
#                      ils ne prouveraient rien. Sort INAPPLICABLE (3) si la base n'expose pas les
#                      DEUX chemins : sans second chemin, il n'y a rien à prouver.
#   mutant-journalise-second-case
#                      le même mutant, mais placé dans le SECOND `case .status:` — celui d'un autre
#                      switch. L'extracteur ne retenait que le PREMIER (`/m` sans `/g`), donc un
#                      second bras qui journalise rendait VERT. `second-chemin` ne comble pas ce
#                      trou : il exige un `func status` ET un `case`, et sortait donc INAPPLICABLE
#                      sur une base à deux `case` — pendant que les quatre autres modes continuaient
#                      à muter le premier, capturés par construction. Sort INAPPLICABLE (3) sans
#                      deux `case`.
#   mutant-lecture-chaine-brut
#                      la lecture interdite est placée DANS une chaîne brute, par l'interpolation
#                      `\#(…)` que Swift utilise dans `#"…"#` (et non `\(…)`). Les six autres modes
#                      n'écrivent que du CODE : ils seraient capturés par construction sur ce site.
#                      Un masque qui ignore la chaîne brute neutralise le contenu et rend VERT un
#                      `status` qui LIT la source — c'est-à-dire la moitié « lecture » de la règle
#                      gelée qui disparaissait, pas seulement les puits. Applicable partout : il
#                      doit être capturé, et il cesse de l'être dès que le masque est neutralisé.
#
# SORTIES : 0 = règle respectée · 1 = règle violée (ou mutant capturé) · 2/3 = rien à mesurer
# (mutant inapplicable, extraction refusée sur une source illisible, ou harnais câblé vers une
# racine qui ne porte pas le serveur) · 64 = mode inconnu. Le 3 « rien à mesurer » est délibéré :
# mieux vaut une erreur bruyante qu'un verdict valide obtenu sur une arborescence que le harnais
# n'a pas demandée, ou sur une extraction qui a renoncé. Un refus d'extraction ne sort JAMAIS 1 :
# il n'a pas été constaté que la règle est violée, et l'annoncer serait un diagnostic mensonger.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MODE=${1:-check}
TEST_ROOT=${MURMURE_WIRING_ROOT:-$ROOT}
SERVER_REL=Murmure/TranscriptControlServer.swift

# Mêmes racines de repli que le script de câblage : les sources 10-S ne sont suivies dans aucune
# branche, donc l'arbre sous test peut ne pas les porter. Le contrôle nomme alors l'origine lue.
FALLBACK_ROOTS=("$ROOT/../t_0799321d" "$ROOT/../t_d1dbdc77")
canon() {
  local dir base
  dir=$(dirname "$1"); base=$(basename "$1")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s' "$dir/$base"
}
server_file=""
for root in "$TEST_ROOT" "${FALLBACK_ROOTS[@]}"; do
  [[ -f "$root/$SERVER_REL" ]] && { server_file=$(canon "$root/$SERVER_REL"); break; }
done
printf 'INFO source=serveur chemin=%s résolu=%s\n' "$SERVER_REL" "${server_file:-ABSENT}"

# Repli SILENCIEUX, c'est-à-dire mensonger : un harnais qui pointe vers une racine INEXISTANTE
# obtenait un verdict valide sur une AUTRE arborescence — discrimination inversée, sans le savoir.
# Le repli lui-même est légitime quand la racine demandée est l'arbre livré : les sources 10-S ne
# sont suivies dans aucune branche (cf. FALLBACK_ROOTS). Il ne l'est plus quand le harnais a
# EXPLICITEMENT nommé une racine, y compris la verte qu'il pense avoir préparée : dans ce cas
# l'absence du serveur est une erreur de câblage, et on la fait bruyamment (rc 3) au lieu de
# mesurer autre chose et de rendre un verdict valide.
if [[ -n "$server_file" && -n "${MURMURE_WIRING_ROOT:-}" && ! -f "$TEST_ROOT/$SERVER_REL" ]]; then
  printf 'ERREUR source=%s absent de la racine demandée (%s) ; le repli a mesuré %s.\n' \
    "$SERVER_REL" "$TEST_ROOT" "$server_file"
  printf 'ERREUR un repli silencieux rendrait un verdict valide sur une AUTRE arborescence.\n'
  exit 3
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/murmure-status-journalisation.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Les deux programmes perl vivent dans des fichiers : aucune citation ne traverse bash, donc aucune
# interpolation de Swift (`\(...)`) ne peut être mangée par le shell.
cat >"$work/extrait.pl" <<'PL'
use strict; use warnings;
local $/; my $x = <STDIN>;

# `trouve` rend l'ACCUMULATION explicite : un serveur peut exposer PLUSIEURS chemins `status`
# (un `func status` bénin en helper, un `case .status:` qui journalise réellement, un second
# `case .status:` dans un AUTRE switch). Sortir au premier chemin trouvé laissait les autres hors
# du périmètre observé, et le contrôle disait VERT sur un `status` qui journalise : c'est la
# famille de faux verts qui s'est reproduite à chaque round. On cumule donc TOUS les corps
# `func status` et TOUS les bras `case .status:`.
my $trouve = 0;

# --- masque du texte non exécutable ------------------------------------------------------------
# Un `{` ou un `}` dans une chaîne n'est pas une accolade de CODE, et un `{` dans un commentaire
# non plus. Sans masque, le comptage d'accolades s'arrêtait sur `let ligne = "}"` et le `logger`
# placé après passait hors du périmètre observé (faux VERT mesuré) ; à l'inverse, sur un `func
# status` CONFORME dont un littéral contient `{`, l'extraction débordait sur la méthode voisine —
# qui elle journalise légitimement — et le contrôle rougissait à tort (faux ROUGE mesuré). Les
# deux sens ont été mesurés sur leparseur livré avant correction.
#
# Le masque conserve la LONGUEUR et les RETOURS À LA LIGNE : la structure du fichier reste
# adressable au caractère près, seul le texte non exécutable est neutralisé. Il remplace le
# simple `s{//[^\n]*}{}g` d'avant, qui aurait mangé un `//` À L'INTÉRIEUR d'une chaîne.
#
# Le CONTENU d'une interpolation `\(…)` est en revanche conservé comme du CODE : c'est une
# lecture réelle — `"\(requete.source)"` lit la source — et la neutraliser serait un nouveau
# faux VERT. Les parenthèses y sont comptées pour retomber sur la bonne `)`, et uneCHAÎNE
# imbriquée dans l'interpolation est à son tour neutralisée : c'est une machine à états, pas
# deux boucles imbriquées, sinon la fermeture d'une interpolation était avalée par la boucle de
# la chaîne qui l'avait ouverte.
sub masque {
  my ($t) = @_;
  my $o = ''; my $i = 0; my $n = length $t;
  my $incomplet = 0;
  # @pile : une entrée par littéral ouvert. Each entry: [type, profondeur des parenthèses].
  # type = 1 (simple) · 2 (multi-lignes) · 0 (interpolation : on y compte les `(`).
  my @pile;
  while ($i < $n) {
    my $c = substr($t, $i, 1);
    my $type = @pile ? $pile[-1][0] : -1;      # -1 = CODE
    if ($type == 0) {                          # à l'intérieur de `\(…)` : c'est du CODE
      if ($c eq '(') { $pile[-1][1]++; $o .= $c; $i++; next }
      if ($c eq ')') {
        if ($pile[-1][1] > 0) { $pile[-1][1]--; $o .= $c; $i++; next }
        pop @pile; $o .= $c; $i++; next;      # cette `)` referme l'interpolation
      }
      # un `"` dans l'interpolation ouvre un littéral imbriqué, traité par le cas « CODE » plus bas
    } elsif ($type == 3 || $type == 4) {       # littéral BRUT : #"…"#, ##"…"##, #"""…"""#
      # Swift n'y interpole pas par `\(…)` mais par `\#(…)` — et c'est du CODE. Un `\(` y est
      # LITTÉRAL : le masquer revenait à manger la lecture elle-même (faux VERT mesuré au round 5).
      #
      # LA RÈGLE, établie par COMPILATION (swiftc) et non déduite — les deux formes étaient
      # fausses dans les DEUX sens avant cette correction (faux VERT ET faux ROUGE, round 6) :
      # le délimiteur d'échappement d'une chaîne brute à N dièses est **`\` + N×`#`**, puis UN
      # caractère. Ce n'est PAS « N antislashs puis `#(` », qui ne coïncide que pour N = 1 :
      #   #"a\#(v)b"#      -> aSRCb        (1 #, `\`+1# puis `(` : interpole)
      #   #"x\\#(v)b"#     -> x\SRCb       (1 #, le 1er `\` est ordinaire, le 2e interpole)
      #   #"a\(v)b"#       -> a\(v)b       (1 #, `\(` : aucun `#` après, donc littéral)
      #   #"a\#n b"#       -> a<NL>b       (1 #, `n` est un ÉCHAPPEMENT : littéral)
      #   ##"a\##(v)b"##  -> aSRCb        (2 #, `\`+2# puis `(` : interpole)
      #   ###"a\###(v)"###-> aSRCb        (3 # : interpole aussi)
      #   ##"a\#(v)b"##   -> a\#(v)b      (2 # mais 1 seul `#` après `\` : littéral)
      #   ##"a\\#(v)b"##  -> a\\#(v)b     (2 antislashs, 1 # : littéral)
      #   ###"a\##(v)b"###-> a\##(v)b     (3 # mais 2 : littéral)
      # `\#n`, `\#t`, `\#0`, `\#"`, `\#\`, `\#u{…}` sont des ÉCHAPPEMENTS : leur caractère est
      # LITTÉRAL et doit être consommé avec le délimiteur — sans cela un `\"` refermerait la
      # chaîne au `(` de l'interpolation, ou un `\#"` la refermerait au guillemet échappé.
      #   Limite assumée : plus de N `#` après le `\` est une ERREUR DE COMPILATION Swift
      #   (« too many '#' characters in delimited escape », compilé) ; ce code n'existe donc pas
      #   dans un serveur qui compile, et le masque le traite en antislash ordinaire.
      my $h = $pile[-1][2];
      if ($c eq "\\") {
        my $d = 0; $d++ while substr($t, $i + 1 + $d, 1) eq '#';   # N dièses après l'antislash
        if ($d == $h) {
          my $suivant = substr($t, $i + 1 + $d, 1);
          if ($suivant eq '(') {                 # interpolation BRUTE = CODE
            $o .= substr($t, $i, $d + 2); $i += $d + 2; push @pile, [0, 0, 0]; next;
          }
          if ($suivant ne '') {                 # ÉCHAPPEMENT : `\``+N dièses+1 car. = LITTERAL
            $o .= ' ' x ($d + 2); $i += $d + 2; next;
          }
        }
        $o .= ' '; $i++; next;                  # un antislash ordinaire : un caractère littéral
      }
      if ($type == 3) {                        # BRUT simple : fermant `"` + h `#`
        if ($c eq '"' && substr($t, $i + 1, $h) eq '#' x $h) {
          $o .= substr($t, $i, 1 + $h); $i += 1 + $h; pop @pile; next;
        }
        # Un `"` qui n'est PAS suivi des `#` du délimiteur ne referme rien : `#"a " b"#` est
        #legal (compilé). Le prendre pour un fermant faisait repartir le masque en CODE au
        # milieu de la chaîne.
        if ($c eq "\n") { $incomplet = 1; $i++; next }   # pas de ligne dans un littéral simple
        $o .= ' '; $i++; next;
      }
      if (substr($t, $i, 3) eq '"""' && substr($t, $i + 3, $h) eq '#' x $h) {
        $o .= substr($t, $i, 3 + $h); $i += 3 + $h; pop @pile; next;
      }
      $o .= ($c eq "\n") ? "\n" : ' ';
      $i++; next
    } elsif ($type == 1) {                     # littéral simple
      if ($c eq "\\") {
        my $e = substr($t, $i + 1, 1);
        if ($e eq '(') { $o .= '\\('; $i += 2; push @pile, [0, 0]; next }   # interpolation
        $o .= '  '; $i += 2; next;             # `\"` `\\` `\n` : jamais une accolade de code
      }
      if ($c eq '"') { $o .= '"'; $i++; pop @pile; next }
      if ($c eq "\n") { $incomplet = 1; $i++; next }   # Swift : un littéral simple ne franchit
      $o .= ' '; $i++; next                    # pas la ligne ; on le signale et on avance
    } elsif ($type == 2) {                     # littéral MULTI-LIGNES
      if ($c eq "\\") {
        my $e = substr($t, $i + 1, 1);
        if ($e eq '(') { $o .= '\\('; $i += 2; push @pile, [0, 0]; next }
        $o .= '  '; $i += 2; next;
      }
      if (substr($t, $i, 3) eq '"""') { $o .= '"""'; $i += 3; pop @pile; next }
      $o .= ($c eq "\n") ? "\n" : ' ';
      $i++; next
    }
    # --- CODE (aucun littéral ouvert) ---
    if ($c eq '#') {
      # Un `#` suivi d'un `"` ouvre un littéral BRUT ; le nombre de `#` est conserved jusqu'au
      # fermant, qui est `"` + ce même nombre de `#`. Tout autre `#` (`#if`, `#selector`,
      # `#available`, `#colorLiteral`…) est un mot-clé ordinaire : il est recopié tel quel.
      my $h = 0; $h++ while substr($t, $i + $h, 1) eq '#';
      if (substr($t, $i + $h, 3) eq '"""') {
        $o .= substr($t, $i, $h + 3); $i += $h + 3; push @pile, [4, 0, $h]; next;
      }
      if (substr($t, $i + $h, 1) eq '"') {
        $o .= substr($t, $i, $h + 1); $i += $h + 1; push @pile, [3, 0, $h]; next;
      }
    }
    if ($c eq '"') {                            # début de littéral
      if (substr($t, $i, 3) eq '"""') { $o .= '"""'; $i += 3; push @pile, [2, 0, 0] }
      else                         { $o .= '"';  $i++;     push @pile, [1, 0, 0] }
      next
    }
    if ($c eq '/' && substr($t, $i + 1, 1) eq '/') {          # commentaire de fin de ligne
      while ($i < $n && substr($t, $i, 1) ne "\n") { $o .= ' '; $i++ }
      next
    }
    if ($c eq '/' && substr($t, $i + 1, 1) eq '*') {          # commentaire de bloc
      # Swift IMBRIQUE les commentaires de bloc : `/* a /* b */ c */` tient jusqu'au DERNIER
      # `*/` (compilé). S'arrêter au premier laissait la suite en CODE, et un `logger` qui s'y
      # trouve était signalé — un faux ROUGE sur du texte mort (mesuré au round 5). D'où le
      # compteur de profondeur : il retombe à 0, et le fermant est consommé avec lui.
      $o .= '  '; $i += 2;
      my $prof = 1;
      while ($i < $n) {
        if (substr($t, $i, 2) eq '/*') { $o .= '  '; $i += 2; $prof++; next }
        if (substr($t, $i, 2) eq '*/') {
          $o .= '  '; $i += 2; $prof--;
          last if !$prof;
          next
        }
        $o .= (substr($t, $i, 1) eq "\n") ? "\n" : ' ';
        $i++;
      }
      next
    }
    $o .= $c; $i++;
  }
  $incomplet = 1 if @pile;      # littéral ou interpolation encore ouvert en fin de fichier
  return ($o, $incomplet);
}

my ($masque, $incomplet) = masque($x);
if ($incomplet) {
  # Refuser de conclure vaut mieux que conclure sur une extraction douteuse : une accolade de
  # chaîne non appariée décalerait tout le comptage, et le contrôle rendrait un verdict construit
  # sur un corps qui n'est pas celui du fichier. rc=3 = rien à mesurer, jamais « conforme ».
  print STDERR "extrait.pl: littéral de chaîne ou interpolation non terminated ; extraction refusée\n";
  exit 3;
}
$x = $masque;
# 1. Une fonction nommée status / statut. `[^{]*` traverse les parenthèses de la signature
#    (`() async -> String`) ; le corps s'arrête à l'accolade qui ramène la profondeur à 0, donc un
#    `logger` de la méthode voisine ne peut pas y entrer.
while ($x =~ /^[ \t]*(?:(?:public|private|internal|fileprivate|open|override|convenience|required|final|static|mutating)[ \t]+)*func[ \t]+(?:status|statut)\b[^{]*\{/gm) {
  # `$-[0]` est le DÉBUT DE LA DÉCLARATION, pas son accolade : compter la profondeur depuis là
  # ferait retomber le compteur à 0 sur le premier espace, et une longueur négative en substr
  # étirerait le corps « extrait » jusqu'à la fin du fichier — donc jusqu'aux déclarations
  # suivantes, qui sont précisément ce que ce contrôle doit ignorer. On démarre donc sur l'accolade.
  my $o = index($x, '{', $-[0]);
  my $d = 0; my $e = -1;
  for my $p ($o .. length($x) - 1) {
    my $c = substr($x, $p, 1);
    $d++ if $c eq '{'; $d-- if $c eq '}';
    if (!$d) { $e = $p; last }
  }
  # Des accolades jamais équilibrées jusqu'à la fin du fichier : le `func` observé n'est pas un
  # `func`, et `$e` resterait au dernier offset — le corps « extrait » aurait été le reste du
  # fichier, la méthode voisine comprise. Refuser vaut mieux qu'un verdict sur ce corps-là.
  if ($e < 0) {
    print STDERR "extrait.pl: accolades non équilibrées après func status ; extraction refusée\n";
    exit 3;
  }
  print substr($x, $o + 1, $e - $o - 1);
  $trouve = 1;
}
# 2. Un `case .status:` sans accolades : jusqu'au `case`/`default`/`}` suivant de MÊME indentation.
#    Une ligne BLANCHE ne termine pas le bras. Elle le faisait, et c'était un faux VERT : le corps
#    extrait s'arrêtait à la première ligne vide, donc TOUT ce qui suivait — y compris un
#    `logger` de la source et du transcript — sortait du périmètre observé. Sur un serveur réel
#    (`let board = …` / ligne vide / `logger…`), le contrôle disait vert sur un `status` qui
#    journalise. Une ligne vide est conservée dans l'extraction (elle ne peut rien masquer) et un
#    commentaire en tête de bras, vidé par le strip de commentaires plus haut, ne provoque plus
#    « aucun chemin status exécutable trouvé ».
#
#    L'arrêt exige l'indentation EXACTE du `case .status:`, sans tolérance d'espaces : c'est la
#    seule promesse tenable. Un `[ \t]*` intercalé autorisait n'importe combien d'espaces
#    supplémentaires, donc un `case`, un `default` ou une `}` IMBRIQUÉ terminait le bras — le
#    second faux VERT de la même famille, mesuré sur le serveur réel : un `status` qui
#    journalise la source et le transcript APRÈS un `switch` imbriqué (ou un `if` imbriqué fermé
#    par une `}` plus indentée) rendait VERT, le corps extrait s'arrêtant à 2-3 lignes et ne
#    contenant jamais le `logger`. En Swift, un `case` imbriqué n'est pas un nouveau bras : il
#    appartient au switch qui le contient, et seule une ligne de MÊME indentation que le
#    `case .status:` — le `case`/`default` suivant, ou l'accolade qui ferme le switch — sort du
#    bras. C'est exactement ce que la regex exprime désormais, et `mutant-journalise-apres-imbre`
#    le mesure : sur le parseur qui tronquait, ce mutant sortait NON capturé (rc=3).
#
#    Limite assumée : une chaîne multi-lignes dont une ligne commencerait, à l'indentation du
#    `case`, par `}`, `case` ou `default`, tronquerait l'extraction — MAIS le masque ci-dessus a
#    déjà neutralisé son contenu, donc cette limite a disparu avec le défaut qu'elle décrivait.
#
#    `/gm` et une BOUCLE, pas un `if` : un second `case .status:` dans un AUTRE switch n'était
#    jamais observé, donc un `status` qui y journalisait rendait VERT. C'est le même défaut que
#    le `exit 0` au premier `func status`, sur l'autre chemin d'extraction ; le round 4 l'a mesuré
#    sur le serveur réel. Tous les bras sont désormais cumulés comme tous les `func status`.
while ($x =~ /^([ \t]*)case[ \t]+\.status[ \t]*:[ \t]*\n/gm) {
  my $st = $-[0]; my $ind = $1;
  my $p = index($x, "\n", $st); my $out = '';
  while ($p < length($x)) {
    my $nl = index($x, "\n", $p + 1); $nl = length($x) if $nl < 0;
    my $line = substr($x, $p + 1, $nl - $p - 1);
    last if $line =~ /^\Q$ind\E(?:case\b|default\b|\})/;
    $out .= $line . "\n";
    $p = $nl;
  }
  print $out;
  $trouve = 1;
  # Reprendre la recherche APRÈS le bras observé : deux `case` ne peuvent pas s'imbriquer dans un
  # même switch, donc le bras suivant appartient forcément à un autre switch. Sans ce
  # repositionnement, la boucle réexaminerait indéfiniment le même bras.
  pos($x) = $p;
}
# Sortir 0 seulement si AU MOINS UN chemin a été observé. Un `exit 0` ici ferait dire au
# contrôle qu'il a trouvé son chemin alors qu'il n'a rien imprimé : le harnais verrait un corps
# vide et le diagnostic mentirait sur la cause du rouge.
exit($trouve ? 0 : 1);
PL

cat >"$work/journalise.pl" <<'PL'
use strict; use warnings;
local $/; my $x = <STDIN>;
# La mutation interdite : le chemin `status` journalise la source ET le transcript qu'il vient de
# lire. Elle est insérée dans le bras trouvé par le MÊME parseur que l'extraction, donc elle ne peut
# pas atterrir ailleurs — un mutant qui ne trouve pas le chemin ne change rien et le harnais le
# dira INAPPLICABLE plutôt que « capturé ».
#
# PLACEMENT, le paramètre de ce programme, est ce qui sépare une preuve d'un faux vert :
#
#   tete         la ligne interdite ouvre le corps. C'est la forme la plus facile à voir : un
#                parseur même grossier la trouve, et l'ancien parseur la trouvait. Un mutant
#                capturé par CE placement seul ne prouve RIEN sur la qualité de l'extraction —
#                c'est un contrôle capturé par construction, pas une preuve de discrimination.
#   apres-blanc  la première ligne du corps est conservée, puis UNE LIGNE VIDE, puis la ligne
#                interdite. C'est la forme que l'ancien parseur ratait (il s'arrêtait sur la ligne
#                blanche) et que le code réel prend spontanément quand quelqu'un ajoute une
#                journalisation au-dessus d'un `return` existant. Un contrôle qui capture CE
#                placement prouve que l'extraction couvre le bras entier, pas seulement sa tête.
#   apres-imbre  la ligne interdite est placée APRÈS un BLOC IMBRIQUÉ (un `switch` ou un `if`
#                interne, fermé par une accolade ou un `case`/`default` plus indenté que le
#                `case .status:`), puis une ligne vide. C'est la forme que le second parseur
#                ratait : son arrêt à `^\Q$ind\E[ \t]*(?:case|default|\})` acceptait
#                l'indentation supplémentaire, donc le `case`/`default`/`}` imbriqué terminait
#                le bras et la ligne interdite, plus bas, sortait du périmètre observé.
#                SANS ce placement, les deux mutants précédents sont capturés PAR CONSTRUCTION
#                dès qu'un bloc imbriqué précède leur point d'insertion : le mutant ne prouve
#                plus rien sur la qualité de l'extraction, il ne fait que constater que le
#                parseur voit la première ligne du bras. C'est pour cela que ce placement
#                existe, et il doit être capturé comme les deux autres.
#   second-chemin la ligne interdite est placée dans le SECOND chemin `status` observé, pas dans
#                le premier : sur une base qui expose un `func status` bénin ET un `case .status:`
#                qui journalise, l'ancien extracteur sortait au `func` et ne voyait jamais le
#                `case` — il rendait donc VERT. Placée dans le `func`, la même mutation aurait été
#                capturée par construction sur ce site et n'aurait rien prouvé. Ce placement exige
#                que les DEUX chemins existent : absent, il est INAPPLICABLE (2), jamais « capturé ».
#   second-case   la ligne interdite est placée dans le SECOND `case .status:` — celui d'un AUTRE
#                switch. L'extracteur ne retenait que le PREMIER (`/m` sans `/g`, un seul `if`) :
#                sur une base où le second bras journalise, il rendait VERT. C'est le même défaut
#                que `second-chemin`, sur le même chemin d'extraction mais entre deux `case` : sans
#                ce placement, `second-chemin` sortait INAPPLICABLE sur une base à deux `case` et
#                les quatre autres modes continuaient à muter le premier — donc à être capturés par
#                construction sur ce site. Exige DEUX `case .status:` : absent, INAPPLICABLE (2).
#   chaine-brut  la lecture interdite est placée DANS une chaîne BRUTE, via son interpolation
#                `\#(…)`. Les six autres modes n'écrivent que du CODE : ils sont donc captérés par
#                construction sur ce site, quelle que soit la qualité du masque. Or Swift
#                n'imbrique pas l'interpolation d'une `#"` par `\(…)` mais par `\#(…)` : un masque
#                qui ne connaît pas cette forme neutralise tout le contenu et rend VERT un `status`
#                qui LIT la source — mesuré au round 5. C'est la moitié « lecture » de la règle qui
#                disparaissait, pas seulement les puits de journalisation. Applicable partout (la
#                forme n'exige aucune structure particulière) : c'est bien ce qui le rend nuancé —
#                il doit être capturé PARCE QUE le masque connaît la chaîne brute, et cesse de
#                l'être dès qu'on désactive ce masque.
#   chaine-brut-2
#                la MÊME lecture interdite, dans la forme à DEUX dièses — `##"…\##(…)"##` — qui
#                est la forme IDIOMATIQUE dès qu'un littéral contient `"#`. Le mode `chaine-brut`
#                ne la couvre pas : il écrit la forme à UNE dièse, qu'un masque ne connaissant que
#                N=1 capture quand même, parce que les deux règles COÏNCIDENT en N=1. C'est
#                précisément cette coïncidence qui a masqué le défaut du round 6 — un masque
#                implémentant « N antislashs puis `#(` » est juste pour N=1 et faux pour tout
#                N≥2, dans les DEUX sens (un vrai `\##(requete.source)` masqué → VERT ; un
#                littéral `\\#(requete.source)` lu comme du code → ROUGE). Établi par COMPILATION :
#                le délimiteur d'échappement est `\` + N×`#`, donc les deux lectures ne se
#                rejoignent qu'en N=1. Ce mode n'est donc PAS capturé par construction sur ce
#                site : sur le parseur fautif il sort NON capturé (rc=3) alors que le mutant à une
#                dièse passe encore — les deux trous sont indépendants, et c'est ce qui fait de
#                la paire une discrimination.
my $placement = shift(@ARGV) || 'tete';
my $ligne = 'logger.info("source=\(source) transcript=\(transcript)")';

# `chaine-brut` ne remplace pas la LIGNE interdite par une journalisation : il la rend sous la
# forme exacte que le masque ignorant. Le `\#( )` est écrit en interpolation simple pour que le
# mode reste lisible ; le contenu vu par le masque est le même.
if ($placement eq 'chaine-brut') {
  $ligne = 'let charge = #"source=\#(requete.source) transcript=\#(transcript)"#';
  $placement = 'tete';
}
# `chaine-brut-2` : la forme à DEUX dièses. Écrite en interpolation simple elle aussi — c'est la
# sémantique COMPILÉE que le masque doit deviner, pas la façon dont Perl écrit la chaîne.
if ($placement eq 'chaine-brut-2') {
  $ligne = 'let charge = ##"source=\##(requete.source) transcript=\##(transcript)"##';
  $placement = 'tete';
}

# `second-chemin` exige les deux chemins et vise le `case` — celui que l'ancien extracteur
# n'atteignait jamais. Il ne se contente pas de réarmer le placement `tete` : le programme teste
# le `func status` AVANT le `case`, donc un `tete` réarmé muterait le PREMIER chemin et le mode
# serait capturé par construction — exactement ce qu'il existe pour empêcher. D'où le drapeau
# `$cible`, qui court-circuite le bloc `func`. La regex de reconnaissance est celle du programme
# principal : une seule définition, donc le mode ne peut pas muter un chemin que le contrôle ne
# sait pas nommer.
my $cible = '';
if ($placement eq 'second-chemin') {
  my $a_func = ($x =~ /^[ \t]*(?:(?:public|private|internal|fileprivate|open|override|convenience|required|final|static|mutating)[ \t]+)*func[ \t]+(?:status|statut)\b[^{]*\{/m) ? 1 : 0;
  my $b_case = ($x =~ /^([ \t]*)case[ \t]+\.status[ \t]*:[ \t]*\n/m) ? 1 : 0;
  exit 2 if !($a_func && $b_case);          # un seul chemin : rien à prouver ici
  $cible = 'case';
  $placement = 'tete';                      # insertion en tête du bras `case .status:`
}
# `second-case` vise le SECOND `case .status:`. Il exige deux `case` : avec un seul, il n'y a
# rien à prouver, et « capturé » serait un mensonge.
if ($placement eq 'second-case') {
  my @bras;
  while ($x =~ /^([ \t]*)case[ \t]+\.status[ \t]*:[ \t]*\n/gm) { push @bras, $-[0] }
  exit 2 if @bras < 2;
  $cible = 'case2';
  $placement = 'tete';
}

# Insère « ligne vide + ligne interdite » après la première ligne du corps qui commence à
# $debut. Retourne 0 si le corps n'a pas de première ligne exploitable (l'appelant retombe alors
# sur le placement `tete`, qui exige seulement l'accolade).
sub apres_premiere_ligne {
  my ($debut) = @_;
  my $nl = index($x, "\n", $debut);
  return 0 if $nl < 0;
  my $premiere = substr($x, $debut, $nl - $debut);
  return 0 if $premiere =~ /^[ \t]*$/;            # corps qui commence par une ligne vide
  return 0 if $premiere =~ /^[ \t]*\}/;            # corps déjà terminé
  return 0 if $premiere !~ /\S/;
  return 0 unless $premiere =~ /\S[^\n]*$/;
  my $suite = substr($x, $nl + 1);
  return 0 if $suite =~ /^\s*$/;                   # plus rien après : rien où insérer
  return 1;
}

# Repère la fin du PREMIER bloc imbriqué du bras : une ligne plus indentée que le `case .status:`
# qui ouvre un bloc (`switch x {`, `if y {`), puis la ligne de fermeture de CE bloc, revenue à la
# MÊME indentation que cette ligne d'ouverture. On s'appuie sur l'indentation et non sur un
# comptage d'accolades global : le contrôle doit rester insensible à la profondeur, et c'est
# précisément l'indentation que le parseur fautif tronquait. Retourne l'offset juste après la
# fermeture, ou undef si le bras n'a pas de bloc imbriqué (mutant alors INAPPLICABLE, pas capturé).
sub fin_bloc_imbrique {
  my ($debut, $ind) = @_;                          # $debut = 1re ligne du corps, $ind = indentation du case
  my $p = $debut;
  my ($ouv_ind) = undef;
  # `$debut` peut pointer SUR le retour à la ligne qui suit l'accolade ou le `case` : on se place
  # donc sur un début de ligne. Ensuite `$p = $nl + 1` guarantees qu'on avance toujours d'au moins
  # un caractère — sans quoi une ligne vide ferait boucler la recherche indéfiniment.
  $p++ if $p < length($x) && substr($x, $p, 1) eq "\n";
  while ($p < length($x)) {
    my $nl = index($x, "\n", $p); $nl = length($x) if $nl < 0;
    my $line = substr($x, $p, $nl - $p);
    if (!defined $ouv_ind) {
      if ($line !~ /^[ \t]*$/) {                             # ligne non blanche
        my ($lead) = $line =~ /^([ \t]*)/;
        # Une ligne plus indentée que le `case` qui OUVRE un bloc : c'est notre bloc imbriqué.
        if (length($lead) > length($ind) && $line =~ /^[ \t]*(?:switch|if|guard|for|while|repeat)\b[^\n]*\{[ \t]*$/) {
          $ouv_ind = $lead;
        }
      }
    } else {
      # Fermeture : une ligne revenue à l'indentation d'ouverture et qui commence par `}`.
      return $nl + 1 if $line =~ /^\Q$ouv_ind\E\}/;
    }
    $p = $nl + 1;
  }
  return undef;
}

if ($cible ne 'case' && $cible ne 'case2'
    && $x =~ /^[ \t]*(?:(?:public|private|internal|fileprivate|open|override|convenience|required|final|static|mutating)[ \t]+)*func[ \t]+(?:status|statut)\b[^{]*\{/gm) {
  my $debut = $-[0];
  my $ouvrant = index($x, '{', $debut);
  my ($ind) = substr($x, $debut, $ouvrant - $debut) =~ /\A[ \t]*/;
  $ind = '' unless defined $ind;
  if ($placement eq 'apres-blanc' && apres_premiere_ligne($ouvrant + 1)) {
    my $nl = index($x, "\n", $ouvrant + 1);
    print substr($x, 0, $nl + 1)                      # ...jusqu'à la fin de la 1re ligne
        . "\n" . $ind . '    ' . $ligne . "\n"        # ligne vide, puis la journalisation
        . substr($x, $nl + 1);                        # le reste du fichier, intact
    exit 0;
  }
  # `apres-imbre` : après la fermeture du premier bloc imbriqué du corps. Sur un `func` le corps
  # est délimité par des accolades, donc tout placement y est vu par construction — le mode y est
  # INAPPLICABLE plutôt que « capturé », pour ne pas compter une preuve qui ne prouve rien.
  if ($placement eq 'apres-imbre') {
    if (defined(my $fin = fin_bloc_imbrique($ouvrant + 1, $ind))) {
      print substr($x, 0, $fin)
          . $ind . '    ' . "\n" . $ind . '    ' . $ligne . "\n"
          . substr($x, $fin);
      exit 0;
    }
    exit 2;                                          # pas de bloc imbriqué : rien à muter
  }
  # L'insertion se fait à la PREMIÈRE accolade après la déclaration, donc dans le corps et nulle
  # part ailleurs ; l'indentation est lue sur la déclaration elle-même. Aucun parcours de braces
  # n'est nécessaire ici : le reste du fichier est recopié tel quel.
  print substr($x, 0, $ouvrant + 1)                # ...jusqu'à l'accolade d'ouverture
      . "\n" . $ind . '    ' . $ligne . "\n"       # la journalisation interdite
      . substr($x, $ouvrant + 1);                  # le reste du fichier, intact
  exit 0;
}
if ($cible eq 'case2') {
  # Second `case .status:` du fichier. On mémorise le premier pour qu'il soit sauté, puis on
  # reprend la regex globale : c'est ce `/gm` que l'extracteur livré n'avait pas, et c'est
  # exactement ce que ce mode doit mettre en défaut.
  my $premier = 1;
  while ($x =~ /^([ \t]*)case[ \t]+\.status[ \t]*:[ \t]*\n/gm) {
    my $st = $-[0];
    if ($premier) { $premier = 0; next }
    my $ind = $1; my $tete = $&;
    print substr($x, 0, $st + length($tete))
        . $ind . '    ' . $ligne . "\n"
        . substr($x, $st + length($tete));
    exit 0;
  }
  exit 1;                                    # deuxième `case` introuvable : rien à muter
}
if ($x =~ /^([ \t]*)case[ \t]+\.status[ \t]*:[ \t]*\n/m) {
  my $st = $-[0]; my $ind = $1; my $tete = $&;
  if ($placement eq 'apres-blanc' && apres_premiere_ligne($st + length($tete))) {
    my $nl = index($x, "\n", $st + length($tete));
    print substr($x, 0, $nl + 1)                    # ...jusqu'à la fin de la 1re ligne du bras
        . "\n" . $ind . '    ' . $ligne . "\n"      # ligne vide, puis la journalisation
        . substr($x, $nl + 1);
    exit 0;
  }
  if ($placement eq 'apres-imbre') {
    if (defined(my $fin = fin_bloc_imbrique($st + length($tete), $ind))) {
      print substr($x, 0, $fin)
          . $ind . '    ' . "\n" . $ind . '    ' . $ligne . "\n"
          . substr($x, $fin);
      exit 0;
    }
    exit 2;                                        # pas de bloc imbriqué dans ce bras
  }
  print substr($x, 0, $st + length($tete))
      . $ind . '    ' . $ligne . "\n"
      . substr($x, $st + length($tete));
  exit 0;
}
exit 1;
PL

# --- contrôle nommé ---------------------------------------------------------------------------
# Listes explicites, sans joker : un puits ajouté plus tard doit être nommé ici pour être vu, sinon
# le contrôle dirait vert sur un puits qu'il ignore. C'est une limite assumée et lisible.
PUITS='(?:\blogger\b|\bLogger\b|os_log|\bNSLog\b|\bprint[[:space:]]*\(|\bdebugPrint[[:space:]]*\()'
LECTURE='(?:\.source\b|\.transcript\b|\.texte\b|\.contenu\b|entree\.source|requete\.source)'

# rend 0 si la règle est respectée ; 1 si elle est violée ; 2 si l'extraction a été REFUSÉE
# (littéral non apparié, accolades jamais équilibrées). 2 n'est pas 1 : un refus n'est pas une
# violation, et le confondre produirait un ROUGE dont le diagnostic ment sur la cause.
respecte_la_regle() { # <fichier-serveur>
  local corps rc
  corps=$(perl "$work/extrait.pl" <"$1"); rc=$?
  [[ $rc -eq 3 ]] && return 2
  [[ $rc -eq 0 ]] || return 1
  [[ -n "${corps//[[:space:]]/}" ]] || return 1
  printf '%s' "$corps" | grep -qE "$PUITS" && return 1
  printf '%s' "$corps" | grep -qE "$LECTURE" && return 1
  return 0
}

rapport() { # <fichier-serveur> <étiquette>
  local corps="" rc
  respecte_la_regle "$1"; rc=$?
  if [[ $rc -eq 0 ]]; then
    printf 'VERT contrôle=status-sans-journalisation détail=ni source ni transcript lus ni journalisés dans le chemin status (%s)\n' "$2"
    return 0
  fi
  if [[ $rc -eq 2 ]]; then
    # Le refus est BRUYANT et distinct : ni VERT, ni « la règle est violée ». Le corps vaut
    # zéro, l'extraction est un pansement sur une source illisible, et le dire « rouge » ferait
    # croire à une violation de la règle gelée — un diagnostic qui ment sur sa propre cause.
    printf 'REFUS contrôle=status-sans-journalisation détail=extraction refusée sur %s (structure illisible : ni « conforme », ni « violé »)\n' "$1"
    return 2
  fi
  corps=$(perl "$work/extrait.pl" <"$1" 2>/dev/null || true)
  if [[ -z "${corps//[[:space:]]/}" ]]; then
    printf 'ROUGE contrôle=status-sans-journalisation détail=aucun chemin status exécutable trouvé dans %s\n' "$1"
  elif printf '%s' "$corps" | grep -qE "$PUITS"; then
    printf 'ROUGE contrôle=status-sans-journalisation détail=le chemin status journalise (%s) via %s\n' \
      "$2" "$(printf '%s' "$corps" | grep -oE "$PUITS" | sort -u | tr '\n' ' ')"
  else
    printf 'ROUGE contrôle=status-sans-journalisation détail=le chemin status lit la source ou le transcript (%s) : %s\n' \
      "$2" "$(printf '%s' "$corps" | grep -oE "$LECTURE" | sort -u | tr '\n' ' ')"
  fi
  return 1
}

if [[ -z "$server_file" ]]; then
  printf 'ROUGE contrôle=status-sans-journalisation détail=%s absent de tout assemblage : la règle ne peut pas être observée\n' \
    "$SERVER_REL"
  exit 1
fi

if [[ "$MODE" == mutant-journalise || "$MODE" == mutant-journalise-apres-blanc \
   || "$MODE" == mutant-journalise-apres-imbre || "$MODE" == mutant-journalise-second-chemin \
   || "$MODE" == mutant-journalise-second-case || "$MODE" == mutant-lecture-chaine-brut \
   || "$MODE" == mutant-lecture-chaine-brut-2 ]]; then
  # Le placement est le mode lui-même : `mutant-journalise` place la ligne interdite en TÊTE de
  # bras, `mutant-journalise-apres-blanc` la place après la première ligne du corps et une ligne
  # blanche, `mutant-journalise-apres-imbre` après la fermeture du premier bloc imbriqué,
  # `mutant-journalise-second-chemin` dans le second chemin `status` plutôt que dans le premier,
  # `mutant-journalise-second-case` dans le SECOND `case .status:` plutôt que dans le premier,
  # `mutant-lecture-chaine-brut` sous la forme d'une lecture par l'interpolation `\#(…)` d'une
  # chaîne brute à une dièse, `mutant-lecture-chaine-brut-2` sous la forme à DEUX dièses
  # `\##(…)` — la forme idiomatique dès qu'un littéral contient `"#`. Les six derniers sont les
  # preuves de discrimination — ceux que les parseurs successifs rataient. Un contrôle qui ne
  # capture que le premier serait vert sur un `status` qui journalise.
  PLACEMENT=tete
  [[ "$MODE" == mutant-journalise-apres-blanc ]] && PLACEMENT=apres-blanc
  [[ "$MODE" == mutant-journalise-apres-imbre ]] && PLACEMENT=apres-imbre
  [[ "$MODE" == mutant-journalise-second-chemin ]] && PLACEMENT=second-chemin
  [[ "$MODE" == mutant-journalise-second-case ]] && PLACEMENT=second-case
  [[ "$MODE" == mutant-lecture-chaine-brut ]] && PLACEMENT=chaine-brut
  [[ "$MODE" == mutant-lecture-chaine-brut-2 ]] && PLACEMENT=chaine-brut-2
  # DIFFÉRENCE, pas état : référence d'abord, mutant ensuite. Un contrôle déjà rouge sur la
  # référence ne prouve rien et ne doit jamais être compté comme une capture — un refus
  # d'extraction non plus : on ne sait alors pas quoi muter ni quoi mesurer.
  rapport "$server_file" "assemblage de référence"; rc_ref=$?
  if [[ $rc_ref -eq 2 ]]; then
    printf 'MUTANT INAPPLICABLE mode=%s : extraction refusée sur l’assemblage de référence, rien à mesurer\n' "$MODE"
    exit 3
  fi
  if [[ $rc_ref -ne 0 ]]; then
    printf 'MUTANT NON capturé contrôle=status-sans-journalisation (déjà rouge sur l’assemblage de référence : la mutation ne prouve rien)\n'
    exit 3
  fi
  # `! perl … ; then` ne permettrait pas de lire le code de sortie : `!` inverse `$?`. On capture donc
  # le statut séparément, et 2 se distingue de 1 (aucun chemin status du tout).
  perl "$work/journalise.pl" "$PLACEMENT" <"$server_file" >"$work/server-mutant.swift"
  rc_mut=$?
  if [[ $rc_mut -ne 0 ]]; then
    if [[ $rc_mut -eq 2 ]]; then
      # Le chemin visé n'existe pas sur cette base : pour `apres-imbre`, aucun bloc imbriqué dans
      # le bras ; pour `second-chemin`, pas les DEUX chemins `status`. Le mutant n'a rien à prouver
      # ici. INAPPLICABLE, jamais « capturé ».
      if [[ "$PLACEMENT" == second-chemin ]]; then
        printf 'MUTANT INAPPLICABLE mode=%s : %s n’expose pas les DEUX chemins status (func ET case)\n' \
          "$MODE" "$server_file"
      elif [[ "$PLACEMENT" == second-case ]]; then
        printf 'MUTANT INAPPLICABLE mode=%s : %s n’expose pas les DEUX `case .status:`\n' \
          "$MODE" "$server_file"
      else
        printf 'MUTANT INAPPLICABLE mode=%s : le chemin status de %s n’a aucun bloc imbriqué\n' "$MODE" "$server_file"
      fi
    else
      printf 'MUTANT INAPPLICABLE mode=%s : aucun chemin status dans %s\n' "$MODE" "$server_file"
    fi
    exit 3
  fi
  if cmp -s "$server_file" "$work/server-mutant.swift"; then
    printf 'MUTANT INAPPLICABLE mode=%s : la mutation n’a rien changé\n' "$MODE"
    exit 3
  fi
  rapport "$work/server-mutant.swift" "assemblage journalisé"; rc_mut2=$?
  if [[ $rc_mut2 -eq 2 ]]; then
    printf 'MUTANT INAPPLICABLE mode=%s : extraction refusée sur l’assemblage journalisé, rien à mesurer\n' "$MODE"
    exit 3
  fi
  if [[ $rc_mut2 -eq 0 ]]; then
    printf 'MUTANT NON capturé contrôle=status-sans-journalisation (aucun rouge sur l’assemblage journalisé)\n'
    exit 3
  fi
  printf 'MUTANT capturé contrôle=status-sans-journalisation placement=%s (vert sur l’assemblage de référence, rouge sur l’assemblage journalisé)\n' "$PLACEMENT"
  exit 1
fi

if [[ "$MODE" != check ]]; then
  printf 'usage: %s [check|mutant-journalise|mutant-journalise-apres-blanc|mutant-journalise-apres-imbre|mutant-journalise-second-chemin|mutant-journalise-second-case|mutant-lecture-chaine-brut|mutant-lecture-chaine-brut-2]\n' "$0" >&2
  exit 64
fi

rapport "$server_file" "arbre sous test"; rc=$?
if [[ $rc -eq 0 ]]; then
  printf 'VERT contrôle=10-S-journalisation\n'
  exit 0
fi
# Un refus d'extraction n'est pas un rouge : le dire « ROUGE » afficherait une violation de la
# règle gelée qui n'a pas été constatée. rc=3 = rien à mesurer, comme le repli silencieux.
if [[ $rc -eq 2 ]]; then
  printf 'REFUS contrôle=10-S-journalisation\n'
  exit 3
fi
printf 'ROUGE contrôle=10-S-journalisation\n'
exit 1
