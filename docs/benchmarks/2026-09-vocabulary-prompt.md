# Un vocabulaire dicté à Whisper — c'est une espace, pas une liste

Date : 2026-09-02/03 · Corpus : 109 dictées réelles sélectionnées dans
`~/Documents/superwhisper/recordings` (120 min d'audio, médiane 46 s, max 308 s),
**jamais commitées** · Résultats : `benchmark/results-vocab-*.local.jsonl`, **jamais
commités** · Harnais : `benchmark/vocabprobe/` (SwiftPM) + `benchmark/vocab_*.py`,
commités · Modèle : `large-v3-turbo`, `DecodingOptions(language: "fr")`, `promptTokens`
seule variable · **2 180 décodages, 20 bras.**

La question : la moitié « recognizer » de la fonctionnalité Vocabulaire — donner à Whisper
la liste des termes que Louis prononce (`Claude Code`, `Trucost`, `WeeFin`) pour qu'il les
écrive correctement — vaut-elle d'être construite, et sous quelle forme ?

**Réponse : oui, et elle tient en un caractère.** Une liste de trois termes précédée d'une
**espace** répare 86 des 106 occurrences abîmées pour 11 tokens et 1,9 % de mots perdus.
La même liste sans l'espace en répare 52. Une liste de trente termes n'en répare pas
davantage — elle coûte simplement cinq fois plus cher.

---

## 1. La taille de la liste n'est pas le levier — il faut le dire avant le verdict

La première courbe de dose, en ordre décroissant d'importance (le plus abîmé en tête),
descend au lieu de monter :

| termes | 1 | 3 | 5 | 10 | 20 | 30 |
|---|---:|---:|---:|---:|---:|---:|
| réparations | 17 | 52 | 47 | 44 | 36 | 36 |

On lit spontanément « dilution : plus la liste est longue, moins chaque terme pèse ». C'est
faux. **La même liste de 30 termes, simplement retournée, répare 88 fois au lieu de 36**,
pour un coût en tokens rigoureusement identique (103 dans les deux cas, aucune troncature).
Et la courbe inversée est **plate** — 86, 88, 87, 88 à N = 3, 10, 20, 30.

Ce qui change entre les deux n'est donc ni la taille ni le contenu. C'est **la place du
terme dans la liste**, et §4 montre que l'essentiel de cette place se joue au niveau du
tokenizer, pas du modèle.

## 2. Le plancher : les bras se reproduisent sous prompt

Le plancher de bruit mesuré jusque-là l'avait été **sans prompt** (0 bascule de verdict sur
111 paires). La stabilité *sous* prompt n'avait jamais été mesurée — donc aucun écart entre
bras n'était encore interprétable.

`termsB` rejoue le prompt de `terms` à l'octet près, dans un processus séparé :

| | réparations | `Claude Code` | `Trucost` |
|---|---:|---:|---:|
| `terms` | 75 | 55 | 12 |
| `termsB` | 76 | 55 | 13 |

**2 bascules de verdict sur 112 paires (1,8 %).** C'est le bruit de fond de tout ce qui
suit : un écart de 3 réparations ne veut rien dire, un écart de 30 en veut un.

## 3. La table complète

`enc` = tokens encodés, `kept` = tokens réellement conservés par le décodeur (budget 111).
Les colonnes de termes comptent les réparations : le baseline produisait une déformation
connue, le bras produit l'orthographe correcte. Opportunités : `CC` 60, `TC` 35, `WF` 10.
`mots` = variation du nombre de mots par rapport au baseline (161,4 mots/fichier).
`regr` = régressions, un terme correct au baseline et cassé par le bras.

| bras | prompt | enc | kept | CC | TC | WF | total | mots | sim | regr |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `n01` | `Claude Code.` | 5 | 5 | 17 | 0 | 0 | 17 | −1,2 % | 0,990 | 0 |
| `n03` | 3 termes, importants en tête | 12 | 12 | 15 | 27 | 10 | 52 | −1,8 % | 0,985 | 0 |
| `n05` | 5 termes | 21 | 21 | 15 | 22 | 10 | 47 | −2,2 % | 0,987 | 1 |
| `n10` | 10 termes | 36 | 36 | 15 | 19 | 10 | 44 | −2,3 % | 0,988 | 0 |
| `n20` | 20 termes | 71 | 71 | 11 | 15 | 10 | 36 | −2,3 % | 0,987 | 0 |
| `n30` | 30 termes | 103 | 103 | 12 | 14 | 10 | 36 | −5,0 % | 0,973 | 0 |
| `n03r` | les 3, **inversés** | 11 | 11 | 58 | 28 | 0 | 86 | −2,0 % | 0,977 | 0 |
| `n10r` | les 10, inversés | 35 | 35 | 57 | 21 | 10 | 88 | −3,3 % | 0,979 | 0 |
| `n20r` | les 20, inversés | 70 | 70 | 55 | 22 | 10 | 87 | −2,8 % | 0,981 | 0 |
| `n30r` | les 30, inversés | 103 | 103 | 56 | 22 | 10 | 88 | −5,4 % | 0,954 | 0 |
| `n01s` | ` Claude Code.` | **4** | 4 | 50 | 0 | 0 | 50 | −2,3 % | 0,981 | 0 |
| **`n03s`** | **les 3 + espace initiale** | **11** | 11 | 49 | 27 | 10 | **86** | **−1,9 %** | 0,981 | 0 |
| `n03rs` | les 3, inversés + espace | 11 | 11 | 58 | 30 | 1 | **89** | −2,2 % | 0,976 | 1 |
| `n10rs` | les 10, inversés + espace | 35 | 35 | 57 | 22 | 10 | **89** | −3,6 % | 0,978 | 1 |
| `terms` | 35 termes, ordre d'origine | 121 | 111 | 55 | 12 | 8 | 75 | −6,6 % | 0,919 | 0 |
| `termsB` | réplication de `terms` | 121 | 111 | 55 | 13 | 8 | 76 | −6,8 % | 0,919 | 0 |
| `n35f` | les 35, ordre fréquence | 122 | 111 | 0 | 0 | 0 | **0** | −8,5 % | 0,933 | 2 |
| `unrelated` | 35 mots français sans rapport | 147 | 111 | 0 | 0 | 0 | 0 | −6,4 % | 0,968 | 1 |
| `overflow` | 300 mots | 966 | 111 | 0 | 0 | 0 | 0 | −7,7 % | 0,968 | 3 |

## 4. Effet n°1 : le premier terme de la liste n'est pas écrit comme les autres

`tokencount` lit le tokenizer de WhisperKit lui-même. Deux prompts qui ne diffèrent que par
une espace initiale :

```
"Claude Code, Trucost, WeeFin."     12 tokens
  34 "C"  875 "la"  2303 "ude"  15549 " Code"  11 ","  21388 " Tru"  27718 "cost" …

" Claude Code, Trucost, WeeFin."    11 tokens
  12947 " Cla"  2303 "ude"  15549 " Code"  11 ","  21388 " Tru"  27718 "cost" …
```

En tête de chaîne, le terme est découpé en fragments de caractères — `C`, `la`, `ude` — qui
**n'apparaissent jamais dans de la parole transcrite**, où chaque mot arrive précédé d'une
espace. Ailleurs dans la liste il reçoit ` Cla`, exactement l'identifiant qu'il porte dans
les bras inversés qui fonctionnent.

Le comportement suit, et dans les deux sens :

| | sans espace | avec espace | tokens |
|---|---:|---:|---:|
| `Claude Code` seul (`n01` → `n01s`) | 17/60 | **50/60** | 5 → **4** |
| `Claude Code` en tête de 3 (`n03` → `n03s`) | 15/60 | **49/60** | 12 → **11** |

**Un caractère triple les réparations et coûte un token de moins.** Deux instruments
indépendants concordent — le dump du tokenizer et les bras de décodage — et la prédiction
chiffrée était écrite dans `vocab_order.py` avant que les bras ne tournent.

## 5. Effet n°2 : une pénalité de première position que l'espace NE corrige pas

L'espace n'explique pas tout, et c'est le point où l'explication simple casse.

`n03s` = ` Claude Code, Trucost, WeeFin.` et `n03rs` = ` WeeFin, Trucost, Claude Code.`
portent **exactement les mêmes identifiants de tokens**, seulement permutés (vérifié au
tokenizer : ` We`/`e`/`Fin` et ` Cla`/`ude`/` Code` dans les deux). Pourtant :

| terme | en première position | ailleurs |
|---|---:|---:|
| `WeeFin` | **1/10** (`n03rs`) | 10/10 (`n03`, `n03s`, `n10rs`, `n30`) |
| `Claude Code` | 49–50/60 (`n01s`, `n03s`) | 55–58/60 (`n03r`, `n10r`, `n20r`, `n30r`) |

Donc **la position compte pour elle-même**, en plus de la tokenisation. Sur `WeeFin`, la
pénalité de tête est même totale et l'espace n'y change rien. Je n'ai pas de mécanisme pour
celle-là ; elle est mesurée, pas expliquée.

Conséquence de conception, elle : **la première place est une place sacrificielle.** Le bras
`n10rs` en fait la démonstration involontaire — sa liste inversée commence par `Serena`, un
terme qui n'a aucune réparation à offrir, et finit par `Claude Code` : 89 réparations, la
meilleure valeur mesurée, sans rien sacrifier.

## 6. La troncature coupe par l'avant, silencieusement

`n35f` et `terms` contiennent **les mêmes 35 mots**. Seul l'ordre diffère. `n35f` les range
par fréquence, ce qui met les trois termes réparables en tête ; le budget est dépassé de 11
tokens ; le décodeur applique `Array(promptTokens.suffix(111))` et jette l'avant.

**Résultat : 0 réparation sur 106**, contre 75 pour le même vocabulaire autrement ordonné.
Aucune erreur, aucun avertissement, un décodage parfaitement normal.

C'est la démonstration empirique du `suffix` documenté dans `TextDecoder.swift:199-200`
(budget `(Constants.maxTokenContext / 2) - 1` = 111, `Models.swift:1340`). Une interface qui
accepte une liste sans limite **jette en silence les entrées saisies en premier**.

## 7. Le coût croît avec la longueur du prompt

Le prompt fait toujours perdre des mots à la transcription. Ce n'est pas gratuit et ça
n'est pas plat :

| tokens | 4 | 5 | 11–12 | 21 | 35–36 | 70–71 | 103 | 111 (tronqué) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| mots perdus | 2,3 % | 1,2 % | 1,8–2,2 % | 2,2 % | 2,3–3,6 % | 2,3–2,8 % | 5,0–5,4 % | 6,4–8,5 % |

Le coude est net : **jusqu'à ~70 tokens (20 termes) la note reste sous 3 %, au-delà elle
double.** Une campagne antérieure avait conclu que la note était fixe — elle comparait deux
bras déjà pleins, tous deux tronqués à 111 tokens, ce qui est exactement l'endroit où la
courbe est plate. Le bon plan d'expérience est la courbe, pas la paire.

## 8. Les contrôles

- **`unrelated`** — 35 mots français sans aucun rapport avec l'audio (`Bordeaux`, `clavecin`,
  `Kilimandjaro`), même forme, même ordre de grandeur en tokens : **0 réparation**, et
  −6,4 % de mots. La note se paie donc pour la *présence* d'un prompt, mais les réparations
  se paient bien pour son *contenu*.
- **`overflow`** — 300 mots, 966 tokens encodés, 111 conservés : **0 réparation**, 3
  régressions. Le débordement n'aide pas, il abîme.
- **Écho** — un terme absent du baseline et apparu dans le bras pourrait être une réparation
  comme un simple perroquet du prompt. Ce compartiment vaut **0 ou 2 selon les bras**, et
  **0 pour `unrelated` et `overflow`**. Le modèle ne recopie pas sa liste.
- **Scoring positif** — un bras est crédité seulement si l'orthographe correcte est
  littéralement présente, jamais sur l'absence d'une déformation connue : une déformation
  nouvelle inventée par le prompt ne peut donc pas se lire comme un succès.

## 9. Ce qui n'est PAS établi

- **Trois termes portent la mesure.** Sur les cinq suivis, `Cursor` n'a aucune occurrence
  abîmée dans ce corpus et `Superwhisper` en a une. Tout ce qui précède repose sur
  `Claude Code` (60), `Trucost` (35) et `WeeFin` (10). La recommandation se généralise à une
  liste d'utilisateur **par hypothèse**, pas par mesure.
- **La pénalité de première position résiduelle (§5) n'a pas de mécanisme.** Tokens
  identiques, résultats différents. Je ne sais pas pourquoi.
- **`Trucost` bouge sans que je sache le prédire** — 12 à 30 réparations selon les bras, sans
  loi lisible ni sur la taille ni sur la position. Seul `Claude Code` a un comportement
  propre.
- **Aucun bras n'a été répété sauf `terms`.** Le plancher de §2 vaut 1,8 % de bascules sur un
  seul prompt ; il est appliqué aux autres par extension.
- **Le corpus vient de dictées déjà transcrites par `small`** (le modèle de Superwhisper). La
  sélection prouve que Louis a *dit* le terme, pas que `large-v3-turbo` le rate — c'est le
  bras baseline qui l'établit, et il le rate effectivement 106 fois.
- **Rien de tout cela n'est mesuré en français hors de son vocabulaire technique.** Le prompt
  est une liste de mots majoritairement anglais insérée devant de la parole française ; les
  −2 % de mots sont mesurés, leur nature ne l'est pas.

## 10. Ce que la fonctionnalité doit faire

1. **Préfixer le prompt d'une espace.** Un caractère, un token de moins, +33 réparations.
   C'est le résultat le plus rentable de toute la campagne.
2. **Placer les termes les plus souvent corrigés en DERNIER**, au contact de l'audio — et
   ne jamais mettre un terme de valeur en première place. La moitié « remplacement » de la
   fonctionnalité compte déjà les corrections : cet ordre se dérive tout seul, l'utilisateur
   n'a aucune règle à apprendre.
3. **Plafonner la liste bien en dessous du budget**, autour de 20 termes / 70 tokens : la
   note reste sous 3 % et la troncature silencieuse de §6 devient inatteignable. Au-delà de
   111 tokens, l'interface doit refuser ou avertir — jamais tronquer sans le dire.
4. **Ne pas viser une longue liste.** Trois termes bien placés valent trente (86 contre 88)
   pour un cinquième du coût.

---

## Reproduire

```
swift build -c release --package-path benchmark/vocabprobe

python3 benchmark/vocab_select.py arms   jobs.local.json      # sélection + bras de base
python3 benchmark/vocab_dose.py          jobs-dose.local.json  jobs.local.meta.local.json
python3 benchmark/vocab_order.py         jobs-ord.local.json   jobs.local.meta.local.json

benchmark/vocabprobe/.build/release/vocabprobe jobs-dose.local.json results-dose.local.jsonl

python3 benchmark/vocab_report.py floor  results-floor.local.jsonl      # le plancher d'abord
python3 benchmark/vocab_curve.py                                        # la table de §3
benchmark/vocabprobe/.build/release/tokencount ' Claude Code, Trucost.' # les dumps de §4
```

Un bras à la fois : le probe garde le modèle résident et deux instances se disputeraient
l'ANE. Les décodages ne lisent que `~/Documents/superwhisper/recordings` et n'écrivent que
dans `benchmark/*.local.*` — **aucun benchmark n'écrit jamais dans
`~/Library/Application Support/Murmure/`.**
