# Benchmark refiner v2 — la taille du modèle contre la forme du prompt

Date : 2026-09-01 · Données : `benchmark/results-v2.jsonl` (263 générations) · Jugements :
`benchmark/judgments_v2/` (765 scores) · Agrégateur : `benchmark/aggregate_v2.py` ·
Descriptif machine : `benchmark/describe_v2.py` · Lecture stratifiée : `benchmark/stratify_v2.py` ·
Grille : `benchmark/rubric.md`, **gelée, identique au v1**

Le v1 (`docs/benchmarks/2026-08-refiner-benchmark.md`) comparait 4 modèles contre UN prompt fixe.
Le v2 répond à deux questions que le v1 ne pouvait pas poser : est-ce que 7,2 Go achètent quelque
chose face à 4,3 Go, et combien le prompt pèse-t-il face au modèle.

---

## Verdict

### Question 1 — oui, le 12B achète quelque chose, et le prix est chiffrable

Sur `prompt_cleanup`, à prompt identique, **`gemma4-12b-qat` bat `gemma4-e2b-qat` de façon nette et
non ambiguë** : médiane 8,0 contre 7,0, moyenne 7,76 contre 7,10, **0 auto-fail contre 3**, et un
record par paquet de **9 victoires / 5 égalités / 1 défaite** sur 15 fixtures. Les trois juges de
l'arm, indépendamment, produisent le même classement à cinq positions.

Ce que ça coûte, en clair et pas en note de bas de page :

| | `gemma4-12b-qat` | `gemma4-e2b-qat` | ce que le 12B achète |
|---|---:|---:|---|
| médiane / 8 | **8,0** | 7,0 | +1,0 point |
| moyenne / 8 | **7,76** | 7,10 | +0,66 point |
| pire tirage sur 45 | **6** | 5 | un plancher plus haut |
| auto-fails | **0** | 3 (f08) | la disqualification en moins |
| latence médiane (dictée ~46 mots) | 3,17 s | **0,81 s** | **×3,9** |
| latence médiane (dictée 260-370 mots) | 19,0 s | *non mesuré* | — |
| taille disque | 7,2 Go | **4,3 Go** | **+2,9 Go** |

**La formulation honnête du compromis : le 12B achète un point de médiane et l'élimination d'une
disqualification, pour presque quatre fois la latence et 2,9 Go de plus.** Ce n'est pas un demi-point
gagné pour rien — la disqualification est un mode d'échec discret, pas une nuance de style — mais
ce n'est pas non plus un gouffre : sur 5 des 15 fixtures les deux sont à égalité, et sur une l'e2b
gagne. La décision reste arbitrable et elle dépend d'un chiffre qui n'est pas dans le tableau
ci-dessus : **19 s de médiane sur une dictée de 300 mots**. Louis a dit préférer la qualité à la
vitesse ; il a aussi trouvé le 12B suspect. Les deux positions sont compatibles avec ces données,
parce que le point de bascule est la longueur de la dictée, pas la qualité.

Ma recommandation, si une seule réponse est demandée : **prendre le 12B pour `prompt_cleanup` court
et régler la question du long format avant de le mettre en production**, parce que l'écart de
qualité est réel et reproductible, tandis que le coût de latence n'a été mesuré qu'à un seul bout de
la distribution des longueurs pour le 12B et jamais pour l'e2b.

Sur `message_rewrite`, la hiérarchie est la même en tête (12B médiane 8,0, moyenne 7,51, jamais en
dessous de 7 sur 45 tirages) mais **l'e2b s'effondre sur un critère précis : fidélité médiane 1,0,
moyenne 1,02.** Il ne réécrit pas, il résume : sur `f15` il rend 15 mots pour 53 et perd la règle de
nommage dictée, sur `f12` 18 mots pour 61 et perd la structure en trois points. Sur cette tâche
`qwen3.5-4b` (3,4 Go, 1,68 s) passe devant l'e2b, 8-4-3 par paquet.

### Question 2 — le prompt pèse peu en moyenne, et beaucoup sur un mode d'échec précis

**En moyenne, presque rien.** Sur le 12B, la meilleure variante (`cleanup_B`) gagne **+0,24 de
moyenne** sur la baseline (7,60 contre 7,36), à médiane identique (8,0). Sur l'e2b, +0,12 (7,07
contre 6,95), à médiane identique (7,0). À comparer aux **+0,66 de moyenne et +1,0 de médiane** que
le passage e2b → 12B achète. Le modèle pèse environ trois fois ce que pèse le prompt, en moyenne.

Il y a une raison mécanique à la faiblesse de l'effet : **le prompt ne change souvent rien du tout.**
À température 0, sur 15 fixtures × 4 variantes, on compte **20 paires de sorties strictement
identiques sur 90 pour le 12B et 25 sur 90 pour l'e2b**. Deux fixtures de l'e2b (`f04`, `f05`)
produisent la même sortie exacte pour les quatre variantes. Une différence de prompt qui ne produit
aucune différence de sortie ne peut pas produire de différence de score.

**Mais sur un mode d'échec, l'effet est discret et important.** Les variantes `B` et `C` **suppriment
l'auto-fail de dérive linguistique de l'e2b sur `f08`** : baseline et `A` sont disqualifiées par les
trois juges (traduction intégrale du segment français vers l'anglais), `B` et `C` ne le sont pas.
C'est le seul effet de prompt qui change une catégorie plutôt qu'une décimale, et le drapeau
mécanique `LANG_DRIFT_EN` de `describe_v2.py` le confirme indépendamment des juges, sur exactement
les mêmes deux cellules.

**Et l'avantage de score de `B`, lui, ne se généralise pas** — mesuré, pas supposé. Les few-shot de
`B` et `C` contiennent une amorce abandonnée « non attends » et un chemin dicté en « slash »/
« point », motifs que 5 des 15 fixtures portent aussi. La lecture stratifiée (section dédiée
ci-dessous) donne : sur l'e2b, seul modèle où la strate contaminée a de la marge pour répondre,
**`B` gagne +0,40 sur les fixtures proches des exemples et −0,11 sur les fixtures éloignées**. Sur
le 12B la strate proche est saturée (baseline déjà à 8,0 sur 4 fixtures sur 5), donc le test n'y est
pas concluant. Autrement dit : **le seul endroit où la mesure a du pouvoir dit contamination.**

D'où la formulation exacte de la recommandation :

- **Si on garde l'e2b, `B` reste non optionnelle — mais pour une raison, pas deux.** Elle supprime
  le seul mode d'échec disqualifiant mesuré sur ce modèle, sur `f08`, qui est une fixture
  **éloignée** des exemples : ce gain-là n'est pas explicable par la contamination et il tient. Son
  gain de *score*, en revanche, n'est pas établi comme généralisable.
- **Si on prend le 12B, `B` est un bonus non démontré** (+0,24 de moyenne pour +0,82 s de latence),
  du même ordre que le décalage entre panels de juges. Ne pas engager de complexité de prompt
  dessus.

Deuxième mise en garde sur ce classement : **`C` n'a émis aucune typographie française** — 0 U+202F,
0 U+00A0, 0 « » sur ses 30 sorties. La règle qui distingue `C` des autres variantes n'a jamais été
appliquée par le modèle. Le classement de `C` ne dit donc **rien** sur la typographie ; il dit
seulement ce que produisent une reformulation en français et deux exemples supplémentaires.

### Question 3 — `s1-mini` ne tient pas le choc, mais le chiffre publié est en partie de notre faute

`s1-mini` (0,48 Go, 0,29 s — 11× plus rapide et 15× plus petit que le 12B) finit **dernier** de
l'arm modèle : médiane 6,0, moyenne 5,67, record 0-2-13 contre le 12B. Sa signature est nette :
**disfluency médiane 1,0 (moyenne 1,11)** — il ne nettoie qu'à moitié — et **format médiane 1,0
(moyenne 1,38)**.

Le second chiffre n'est pas une mesure du modèle. Notre passe de recapitalisation, documentée en
section E de `describe_v2.py`, **échoue sur 7 sorties sur 15**, et j'ai tracé la cause exacte dans
`run_benchmark_v2.py` : `_SENTENCE_START` capture `[^\s]+`, donc le premier token inclut la
ponctuation collée (`'alors,'`, `'bonjour,'`, `'coucou,'`), et `_PLAIN_WORD = ^[a-zà-öø-ÿ']+$` le
rejette. Résultat : aucune majuscule initiale sur `f01 f02 f03 f04 f10 f11 f13`, et les juges l'ont
relevé — 16 des 45 notes sur `s1-mini` citent une capitalisation ou une ponctuation manquante.

**Contrefactuel calculé** (format forcé à 2, toutes les autres notes inchangées) : la moyenne passe
de 5,67 à 6,29, la médiane reste 6,0, et **le classement ne bouge pas** — `s1-mini` reste dernier,
derrière `qwen3.5-2b-q8` (6,18 → inchangé). Corriger notre bug ne le sauve pas. Ce qui le condamne
est le critère `disfluency`, qui est bien du modèle.

---

## Les chiffres

### Population comparée

- **263 générations** dans `results-v2.jsonl` ; **225 d'entre elles jugées** (config `v2`, jeu
  `synthetic`). Les 38 restantes servent l'A/B de configuration et le long format, jamais jugés.
- **60 paquets**, 15 par arm, 4 arms, chacun avec un panel de **3 juges indépendants**.
- **12 juges** = 4 arms × 3, chacun notant 15 paquets × 4 ou 5 candidats.
- **765 sorties notées**, dont **12 auto-fails** (4 sorties distinctes, chacune signalée par les 3
  juges de son arm), soit 753 scores numériques.
- Échelle : 4 critères (fidelity, disfluency, verbatim, format) × 0-2 = **0-8 par sortie**.

| arm | question | candidats | paquets |
|---|---|---|---|
| `armA` | effet du prompt sur `gemma4-12b-qat` | baseline, A, B, C | 15 |
| `armB` | effet du prompt sur `gemma4-e2b-qat` | baseline, A, B, C | 15 |
| `armC` | effet du modèle, `prompt_cleanup` | 5 modèles | 15 |
| `armD` | effet du modèle, `message_rewrite` | 4 modèles | 15 |

### `armC` — modèles sur `prompt_cleanup` (3 juges × 15 paquets)

| condition | n | min | méd | max | moy | auto-fail | lat. méd s | lat. p90 s | Go |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **`gemma4-12b-qat`** | 45 | 6 | **8,0** | 8 | **7,76** | **0** | 3,17 | 3,90 | 7,2 |
| `gemma4-e2b-qat` | 42 | 5 | 7,0 | 8 | 7,10 | 3 | 0,81 | 1,07 | 4,3 |
| `qwen3.5-4b` | 42 | 4 | 7,0 | 8 | 6,29 | 3 | 1,68 | 2,01 | 3,4 |
| `qwen3.5-2b-q8` | 45 | 4 | 6,0 | 8 | 6,18 | 0 | 0,90 | 1,14 | 2,7 |
| `s1-mini` | 45 | 4 | 6,0 | 8 | 5,67 | 0 | **0,29** | **0,39** | **0,5** |

Histogrammes — c'est la forme qui sépare, pas la médiane seule :

- `gemma4-12b-qat` : 8 ×35, 7 ×9, 6 ×1. **Un seul tirage sous 7 sur 45.**
- `gemma4-e2b-qat` : 8 ×15, 7 ×18, 6 ×7, 5 ×2.
- `qwen3.5-4b` : 8 ×3, 7 ×21, 6 ×8, 5 ×5, 4 ×5. Une queue basse épaisse.
- `qwen3.5-2b-q8` : 8 ×2, 7 ×17, 6 ×15, 5 ×9, 4 ×2.
- `s1-mini` : 8 ×3, 7 ×4, 6 ×21, 5 ×9, 4 ×8.

Par critère (médiane / min / moyenne) :

| modèle | fidelity | disfluency | verbatim | format |
|---|---|---|---|---|
| `gemma4-12b-qat` | 2 / 1 / 1,98 | 2 / 1 / 1,87 | 2 / 1 / 1,91 | 2 / 2 / 2,00 |
| `gemma4-e2b-qat` | 2 / 0 / 1,52 | 2 / 1 / 1,74 | 2 / 1 / 1,83 | 2 / 2 / 2,00 |
| `qwen3.5-4b` | 2 / 1 / 1,76 | **1 / 0 / 1,31** | 2 / 0 / 1,57 | 2 / 1 / 1,64 |
| `qwen3.5-2b-q8` | 2 / 0 / 1,51 | **1 / 0 / 1,40** | 2 / 0 / 1,33 | 2 / 1 / 1,93 |
| `s1-mini` | 2 / 1 / 1,69 | **1 / 0 / 1,11** | 2 / 0 / 1,49 | **1 / 1 / 1,38** |

Lire la colonne `disfluency` avant le total, comme au v1 : les trois derniers ne nettoient qu'à
moitié. Aucun n'est pour autant un no-op au sens d'`ornith-9b` au v1 — seuls 3 scores sur 45
tombent à `disfluency` 0 pour chacun d'eux, contre 37/45 à exactement 6 pour ornith.

Détail par fixture (médiane des 3 juges, `AF` = disqualifié) :

| fixture | 12b | e2b | qwen4b | qwen2b | s1 | 12b vs e2b |
|---|---:|---:|---:|---:|---:|---|
| f01 | 8,0 | 8,0 | 5,0 | 5,0 | 6,0 | égalité |
| f02 | 7,0 | **8,0** | 5,0 | 5,0 | 5,0 | **e2b** |
| f03 | 8,0 | 7,0 | 6,0 | 7,0 | 4,0 | 12b |
| f04 | 8,0 | 8,0 | 8,0 | 7,0 | 6,0 | égalité |
| f05 | 8,0 | 6,0 | 4,0 | 6,0 | 6,0 | 12b |
| f06 | 8,0 | 6,0 | 7,0 | 7,0 | 6,0 | 12b |
| f07 | 7,0 | 7,0 | 7,0 | 6,0 | 6,0 | égalité |
| **f08** | 8,0 | **AF** | **AF** | 7,0 | 8,0 | 12b (e2b disqualifié) |
| f09 | 8,0 | 7,0 | 7,0 | 5,0 | 4,0 | 12b |
| f10 | 8,0 | 7,0 | 7,0 | 6,0 | 6,0 | 12b |
| f11 | 8,0 | 7,0 | 7,0 | 6,0 | 5,0 | 12b |
| f12 | 8,0 | 7,0 | 7,0 | 7,0 | 6,0 | 12b |
| f13 | 8,0 | 8,0 | 7,0 | 6,0 | 4,0 | égalité |
| f14 | 7,0 | 7,0 | 6,0 | 7,0 | 7,0 | égalité |
| f15 | 8,0 | 6,0 | 5,0 | 5,0 | 7,0 | 12b |

Head-to-head par paquet, sous les deux conventions d'auto-fail :

| paire | auto-fail exclu | auto-fail = 0 |
|---|---|---|
| `gemma4-12b-qat` vs `gemma4-e2b-qat` | 8-5-1 | **9-5-1** |
| `gemma4-12b-qat` vs `qwen3.5-4b` | 12-2-0 | 13-2-0 |
| `gemma4-12b-qat` vs `qwen3.5-2b-q8` | 14-1-0 | 14-1-0 |
| `gemma4-12b-qat` vs `s1-mini` | 13-2-0 | 13-2-0 |
| `gemma4-e2b-qat` vs `qwen3.5-4b` | 7-6-1 | 7-7-1 |
| `gemma4-e2b-qat` vs `qwen3.5-2b-q8` | 9-4-1 | 9-4-2 |
| `gemma4-e2b-qat` vs `s1-mini` | 10-3-1 | 10-3-2 |
| `qwen3.5-4b` vs `qwen3.5-2b-q8` | 6-5-3 | 6-5-4 |
| `qwen3.5-4b` vs `s1-mini` | 9-1-4 | 9-1-5 |
| `qwen3.5-2b-q8` vs `s1-mini` | 7-5-3 | 7-5-3 |

**Aucune paire ne s'inverse entre les deux conventions**, et le classement des cinq modèles est
identique sous l'une comme sous l'autre. Les cellules qui bougent sont exactement celles impliquant
`f08`, d'un paquet.

### `armD` — modèles sur `message_rewrite` (3 juges × 15 paquets)

| condition | n | min | méd | max | moy | auto-fail | lat. méd s | Go |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **`gemma4-12b-qat`** | 45 | **7** | **8,0** | 8 | **7,51** | 0 | 3,17 | 7,2 |
| `qwen3.5-4b` | 45 | 4 | 7,0 | 8 | 7,00 | 0 | 1,68 | 3,4 |
| `gemma4-e2b-qat` | 45 | 5 | 7,0 | 8 | 6,80 | 0 | 0,81 | 4,3 |
| `qwen3.5-2b-q8` | 45 | 3 | 6,0 | 8 | 6,22 | 0 | 0,90 | 2,7 |

Histogrammes : 12b `8 ×23, 7 ×22` — **jamais en dessous de 7 sur 45 tirages** ; qwen4b
`8 ×19, 7 ×13, 6 ×9, 5 ×2, 4 ×2` ; e2b `8 ×8, 7 ×25, 6 ×7, 5 ×5` ; qwen2b
`8 ×6, 7 ×13, 6 ×16, 5 ×6, 4 ×3, 3 ×1`.

Par critère, la ligne qui compte :

| modèle | fidelity | disfluency | verbatim | format |
|---|---|---|---|---|
| `gemma4-12b-qat` | 2 / 1 / 1,60 | 2 / 2 / **2,00** | 2 / 1 / 1,93 | 2 / 1 / 1,98 |
| `qwen3.5-4b` | 2 / 1 / 1,64 | 2 / 1 / 1,91 | 2 / 0 / 1,56 | 2 / 1 / 1,89 |
| `gemma4-e2b-qat` | **1 / 0 / 1,02** | 2 / 1 / 1,87 | 2 / 1 / 1,91 | 2 / 2 / 2,00 |
| `qwen3.5-2b-q8` | **1 / 0 / 1,13** | 2 / 1 / 1,84 | 2 / 0 / 1,36 | 2 / 1 / 1,89 |

Head-to-head : 12b vs e2b **7-8-0** (le 12B ne perd jamais un paquet, mais en égalise 8) ;
12b vs qwen4b 6-5-4 ; 12b vs qwen2b 10-4-1 ; **qwen4b vs e2b 8-4-3** ; qwen4b vs qwen2b 9-4-2 ;
e2b vs qwen2b 7-4-4. Aucun auto-fail sur cette tâche, donc les deux conventions coïncident.

La fidélité médiane de 1,0 de l'e2b est un fait mesurable indépendamment des juges — le drapeau
`SHORT<50%` de `describe_v2.py` tire sur 3 de ses 15 sorties, et l'inspection donne :

| fixture | entrée | sortie e2b | ce qui est perdu |
|---|---:|---:|---|
| f15 | 53 mots | 15 mots (28 %) | la règle « deux points remplacés par des tirets » et son motif macOS |
| f12 | 61 mots | 18 mots (30 %) | la structure en trois points annoncée par le locuteur |
| f05 | 36 mots | 17 mots (47 %) | l'énumération « premièrement / deuxièmement / troisièmement » |
| f07 | 49 mots | 24 mots (49 %) | l'interface `TranscriptionEngine` citée en exemple |

### `armA` — variantes de prompt sur `gemma4-12b-qat` (3 juges × 15 paquets)

| condition | n | min | méd | max | moy | AF | tok. prompt | lat. méd s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **`cleanup_B`** | 45 | 6 | 8,0 | 8 | **7,60** | 0 | 518 | 3,99 |
| `cleanup_A` | 45 | 6 | 8,0 | 8 | 7,47 | 0 | 356 | 3,42 |
| `cleanup_baseline` | 45 | 5 | 8,0 | 8 | 7,36 | 0 | **292** | **3,17** |
| `cleanup_C` | 45 | 5 | 7,0 | 8 | 7,36 | 0 | 716 | 4,75 |

Histogrammes : `B` `8 ×29, 7 ×14, 6 ×2` ; `A` `8 ×25, 7 ×16, 6 ×4` ; baseline
`8 ×24, 7 ×15, 6 ×4, 5 ×2` ; `C` `8 ×21, 7 ×20, 6 ×3, 5 ×1`.

**Les trois juges classent `B` premier et `A` deuxième, unanimement.** Ils divergent seulement sur
l'ordre baseline / `C`, à moyenne strictement égale (7,36 les deux).

Head-to-head : `A` vs `B` **1-11-3** — onze égalités sur quinze, ce qui est la mesure la plus
parlante de l'effet du prompt ici. `B` vs baseline 6-7-2 ; `A` vs baseline 6-6-3 ; `C` vs baseline
4-8-3 ; `B` vs `C` 4-10-1.

Accord inter-juges : |Δ| moyen **0,22**, max 2, unanimité sur le total exact **41/60**.

### `armB` — variantes de prompt sur `gemma4-e2b-qat` (3 juges × 15 paquets)

| condition | n | min | méd | max | moy | AF | tok. prompt | lat. méd s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **`cleanup_B`** | 45 | 5 | 7,0 | 8 | **7,07** | **0** | 514 | 0,95 |
| `cleanup_baseline` | 42 | 5 | 7,0 | 8 | 6,95 | **3** | 288 | 0,81 |
| `cleanup_C` | 45 | 5 | 7,0 | 8 | 6,87 | **0** | 712 | 0,68 |
| `cleanup_A` | 42 | 5 | 7,0 | 8 | 6,71 | **3** | 352 | 0,84 |

Les quatre variantes ont la **même médiane** (7,0) et la même médiane chez chacun des trois juges.
La seule chose qui les sépare vraiment est la colonne auto-fail. Les trois juges classent
unanimement `B` premier et `A` dernier.

Head-to-head : `B` vs baseline 3-10-1 (exclu) / 4-10-1 (zéro) ; `A` vs `B` 2-7-5 / 2-7-6 ;
`B` vs `C` 3-11-1 ; `C` vs baseline 3-7-4 / 4-7-4.

**Ici la convention d'auto-fail inverse le classement** : baseline et `C` échangent la 2ᵉ et la 3ᵉ
place selon qu'on exclut l'auto-fail ou qu'on le compte 0. Cinq des six paires changent de record.
C'est exactement le cas de figure que le v1 avait signalé et il se produit ici ; les deux
conventions sont imprimées côte à côte par `aggregate_v2.py` et le rapport ne tranche pas — sauf
pour dire que la 1ʳᵉ place de `B` et la dernière de `A` tiennent sous les deux.

Accord inter-juges : |Δ| moyen **0,36**, max 2, unanimité **35/58**. C'est l'arm le moins
consensuel des quatre, ce qui est cohérent avec des candidats plus proches les uns des autres.

### L'effet du prompt, mesuré mécaniquement et sans juge

À température 0, combien de sorties distinctes les 4 variantes produisent-elles par fixture ?

| modèle | 1 sortie unique | 2 | 3 | 4 | paires byte-identiques |
|---|---:|---:|---:|---:|---:|
| `gemma4-12b-qat` | 0 fixture | 5 | 6 | 4 | **20 / 90** |
| `gemma4-e2b-qat` | **2** (`f04`, `f05`) | 3 | 4 | 6 | **25 / 90** |

Sur l'e2b, `cleanup_A` et `cleanup_baseline` produisent la sortie **exactement identique sur 8 des
15 fixtures**. Une part substantielle des écarts de score de l'arm prompt porte donc sur des sorties
qui ne diffèrent pas.

Le coût du prompt, lui, est direct et monotone sur le 12B : 292 → 356 → 518 → 716 tokens d'entrée
donnent 3,17 → 3,42 → 3,99 → 4,75 s. **La variante `C` coûte +50 % de latence à la variante
baseline sur le 12B**, pour une moyenne strictement égale. Sur l'e2b la relation ne tient pas (`C`
est la plus rapide à 0,68 s malgré le prompt le plus long), ce qui indique que le prefill n'est pas
le facteur limitant à cette taille.

### Lecture stratifiée — l'avantage de `B` et `C` vient-il des few-shot ou de leur ressemblance aux fixtures ?

Les trois exemples des variantes `B` et `C` (identiques dans les deux) démontrent deux opérations
précises :

| exemple | opération démontrée |
|---|---|
| `« le fichier config point yaml »` | rendu de symbole dicté |
| `« euh non attends tu lances plutôt make install »` | amorce abandonnée |
| `« source slash lib slash logger point py »` | rendu de symbole dicté |
| `« le benchmark tourne sur quinze fixtures »` | virgule seule, aucune des deux |

**Critère de partition, fixé sur le contenu des exemples seuls et jamais sur les scores** : une
fixture est *proche* si sa transcription brute contient un symbole dicté (`\bslash\b` ou
`\bpoint\b` suivi d'une extension) **ou** une auto-correction de la famille « non attends ».

| strate | n | fixtures | motif déclencheur |
|---|---:|---|---|
| **proche** | 5 | `f02`, `f05`, `f06`, `f09`, `f15` | `f02` slash + « enfin non » ; `f05` slash ; `f06` « non attends » ; `f09` slash ; `f15` « attends non » |
| **éloignée** | 10 | `f01`, `f03`, `f04`, `f07`, `f08`, `f10`, `f11`, `f12`, `f13`, `f14` | — |

Écart à la baseline par strate (médiane des 3 juges par fixture, puis moyenne sur la strate) :

| arm | variante | strate | n | moy. variante | moy. baseline | écart | W-T-L |
|---|---|---|---:|---:|---:|---:|---|
| `armA` 12b | `cleanup_B` | proche | 5 | 7,80 | 7,80 | **+0,00** | 1-3-1 |
| `armA` 12b | `cleanup_B` | éloignée | 10 | 7,60 | 7,10 | **+0,50** | 5-4-1 |
| `armA` 12b | `cleanup_A` | proche | 5 | 7,40 | 7,80 | −0,40 | 1-2-2 |
| `armA` 12b | `cleanup_A` | éloignée | 10 | 7,50 | 7,10 | +0,40 | 5-4-1 |
| `armA` 12b | `cleanup_C` | proche | 5 | 7,80 | 7,80 | +0,00 | 1-3-1 |
| `armA` 12b | `cleanup_C` | éloignée | 10 | 7,20 | 7,10 | +0,10 | 3-5-2 |
| `armB` e2b | `cleanup_B` | proche | 5 | 6,80 | 6,40 | **+0,40** | **2-3-0** |
| `armB` e2b | `cleanup_B` | éloignée | 9 | 7,11 | 7,22 | **−0,11** | 1-7-1 |
| `armB` e2b | `cleanup_A` | proche | 5 | 5,80 | 6,40 | −0,60 | 0-3-2 |
| `armB` e2b | `cleanup_A` | éloignée | 9 | 7,11 | 7,22 | −0,11 | 1-6-2 |
| `armB` e2b | `cleanup_C` | proche | 5 | 6,80 | 6,40 | +0,40 | 2-3-0 |
| `armB` e2b | `cleanup_C` | éloignée | 9 | 6,89 | 7,22 | −0,33 | 1-4-4 |

Convention `auto-fail exclu`. Sous `auto-fail = 0`, `armA` est inchangé (aucun auto-fail) et
`armB` voit la strate éloignée de `B` passer à +0,60 — **mais cette bascule est entièrement le
seul paquet `f08`**, dont l'auto-fail de la baseline est alors compté 0.

**Le résultat des deux arms pointe dans des directions opposées, et c'est l'effet de plafond qui
explique pourquoi.**

| arm | strate | moy. baseline | marge restante | fixtures déjà à 8,0 |
|---|---|---:|---:|---|
| `armA` 12b | **proche** | 7,80 | **0,20 pt** | **4 / 5** |
| `armA` 12b | éloignée | 7,10 | 0,90 pt | 4 / 10 |
| `armB` e2b | **proche** | 6,40 | **1,60 pt** | **0 / 5** |
| `armB` e2b | éloignée | 7,22 | 0,78 pt | 3 / 9 |

Sur le 12B, la baseline est déjà à 8,0 sur 4 des 5 fixtures proches. **Il n'y a mécaniquement pas
de place pour qu'un avantage de contamination s'y exprime** : le test n'est pas négatif, il est
non concluant sur cette strate. Le +0,50 de `B` sur la strate éloignée est donc à lire comme
« le seul endroit où il restait de la marge », pas comme une preuve de généralisation.

Sur l'e2b, la strate proche a 1,60 point de marge et aucune fixture au plafond — **c'est le seul
endroit du benchmark où la question peut recevoir une réponse.** Et la réponse est : `B` gagne
+0,40 sur la strate proche (2-3-0, ne perd jamais) et −0,11 sur la strate éloignée. Le détail
par fixture montre que ce +0,40 vient de `f02` (7→8) et `f15` (6→7) — **les deux fixtures qui
portent le motif « non attends » démontré par le deuxième exemple.** n = 2, donc c'est faible,
mais c'est exactement la direction que l'hypothèse de contamination prédit.

**Conclusion de cette mesure**, en trois affirmations séparées parce qu'elles n'ont pas la même
solidité :

1. **L'avantage de *score* de `B` n'est pas établi comme généralisable.** Là où le test a du
   pouvoir, il vit sur les fixtures qui ressemblent aux exemples et disparaît ailleurs. La lecture
   « le few-shot marche » n'est pas soutenue par ces données ; « le few-shot marche quand l'exemple
   ressemble à l'entrée » l'est faiblement.
2. **L'avantage *catégoriel* de `B` sur l'e2b tient.** La suppression de l'auto-fail se produit sur
   `f08`, fixture **éloignée** qui ne contient ni symbole dicté ni amorce abandonnée. Aucun exemple
   du few-shot ne démontre la résistance au code-switch. Ce gain n'est pas explicable par la
   contamination.
3. **Le test reste sous-dimensionné.** 5 fixtures contre 10, des écarts de ±0,4, et un décalage
   entre panels mesuré à +0,14 et +0,40. Ces chiffres sont du même ordre de grandeur. Ils orientent,
   ils ne concluent pas.

L'étape qui trancherait est de régénérer `B` et `C` avec des exemples hors de la distribution des
fixtures et de rejuger — 60 générations. **Elle n'a pas été engagée.**

### Accord inter-juges et pont de calibration entre panels

| arm | \|Δ\| moyen par paire | Δ max | unanimité sur le total exact |
|---|---:|---:|---|
| `armA` | 0,22 | 2 | 41 / 60 |
| `armB` | 0,36 | 2 | 35 / 58 |
| `armC` | 0,29 | 2 | 46 / 73 |
| `armD` | 0,27 | 2 | 40 / 60 |

Aucun Δ ne dépasse 2 dans aucun arm — le v1 montait à 3 sur `message_rewrite`.

**Les 12 auto-fails sont 4 sorties, chacune signalée par les 3 juges de son arm, et rien d'autre.**
Toutes les quatre sont sur `f08`, toutes pour le même motif (traduction intégrale du segment
français vers l'anglais). Douze juges indépendants convergeant sur les mêmes quatre sorties, et sur
aucune autre, est la meilleure preuve disponible que la grille gelée reste calibrée.

**Le pont de calibration** — mesure que le v1 n'avait pas. Deux conditions ont été notées par **deux
panels indépendants** sur les **mêmes sorties exactes**, parce qu'elles apparaissent dans deux arms :

| condition | panel 1 | moy | méd | panel 2 | moy | méd | Δ moyenne | médianes par fixture identiques |
|---|---|---:|---:|---|---:|---:|---:|---|
| `gemma4-12b-qat` + baseline | `armA` | 7,36 | 8,0 | `armC` | 7,76 | 8,0 | **+0,40** | 9 / 15 |
| `gemma4-e2b-qat` + baseline | `armB` | 6,95 | 7,0 | `armC` | 7,10 | 7,0 | **+0,14** | 10 / 14 |

Conséquence directe pour la lecture de ce rapport : **un écart de moyenne inférieur à ~0,4 entre
deux arms différents n'est pas interprétable.** Les médianes, elles, coïncident dans les deux cas.
Toutes les comparaisons du verdict sont intra-arm, sauf une, signalée comme telle en limites.

### Métriques machine (config `v2`, jeu `synthetic`, 15 appels par cellule)

| modèle | prompt | lat. méd s | lat. p90 s | lat. max s | tok/s méd | tok. sortie méd | Go |
|---|---|---:|---:|---:|---:|---:|---:|
| `gemma4-12b-qat` | `cleanup_baseline` | 3,17 | 3,90 | 4,15 | 19,2 | 61 | 7,2 |
| `gemma4-12b-qat` | `cleanup_A` | 3,42 | 4,10 | 4,49 | 18,0 | 61 | 7,2 |
| `gemma4-12b-qat` | `cleanup_B` | 3,99 | 4,68 | 5,04 | 15,0 | 61 | 7,2 |
| `gemma4-12b-qat` | `cleanup_C` | 4,75 | 5,34 | 5,73 | 12,8 | 61 | 7,2 |
| `gemma4-12b-qat` | `rewrite_baseline` | 2,66 | 2,94 | 3,07 | 19,3 | 51 | 7,2 |
| `gemma4-e2b-qat` | `cleanup_baseline` | 0,81 | 1,07 | 3,78 | 76,5 | 62 | 4,3 |
| `gemma4-e2b-qat` | `cleanup_B` | 0,95 | 1,12 | 1,20 | 65,2 | 62 | 4,3 |
| `gemma4-e2b-qat` | `rewrite_baseline` | 0,58 | 0,71 | 0,72 | 73,2 | 42 | 4,3 |
| `qwen3.5-4b` | `cleanup_baseline` | 1,68 | 2,01 | 3,46 | 41,1 | 66 | 3,4 |
| `qwen3.5-2b-q8` | `cleanup_baseline` | 0,90 | 1,14 | 2,63 | 67,8 | 61 | 2,7 |
| `s1-mini` | `s1_control` | **0,29** | **0,39** | 1,10 | **231,2** | 65 | **0,5** |

Long format, `gemma4-12b-qat` uniquement, sur les fixtures réelles (`fixture_set: real_long`,
config `v2`) :

| fixture | mots en entrée | latence | tokens sortie | fin |
|---|---:|---:|---:|---|
| `r-verylong-03` | 260 | 14,51 s | 351 | `stop` |
| `r-verylong-02` | 288 | 15,86 s | 389 | `stop` |
| `r-verylong-01` | 301 | 22,15 s | 405 | `stop` |
| `r-verylong-04` | 370 | **26,35 s** | 580 | `stop` |

Médiane 19,0 s. Aucun autre modèle n'a été mesuré sur ce jeu.

### A/B de configuration (`describe_v2.py` section C)

- `v1cfg` → `v2mid` (température 0,2 → 0 + seed, plafonds inchangés) : **14 sorties sur 15
  byte-identiques**, latence médiane +0,01 s. La température n'était pas un facteur.
- `v2mid` → `v2` (`num_predict` 512 → 2048, `num_ctx` → 8192) : 15/15 identiques sur le jeu court ;
  sur le jeu long **la troncature de `r-verylong-04` disparaît** (512 tok `length` → 580 tok
  `stop`), pour +2,75 s de latence médiane. C'est la confirmation du bug de plafond identifié en
  limitation 1 du v1 : il était bien de notre fait et il est corrigé.

### `f08` — la fixture code-switch discrimine, elle ne sature pas

| arm | étendue des scores sur `f08` | auto-fails |
|---|---|---:|
| `armA` (prompt, 12b) | 3 points (5 → 8) | 0 |
| `armB` (prompt, e2b) | 0 point parmi les non-disqualifiés (7 partout) | **6** (baseline ×3, `A` ×3) |
| `armC` (modèles) | 1 point (7 → 8) | **6** (e2b ×3, qwen4b ×3) |
| `armD` (modèles, rewrite) | **4 points (4 → 8)** | 0 |

`f08` est **la seule fixture du benchmark à produire un auto-fail**, et elle en produit 12 sur 12.
Elle ne fait pas déraper tout le monde : `gemma4-12b-qat` la traite à 8,0 sur les deux tâches,
`s1-mini` à 8,0 en nettoyage, `qwen3.5-2b-q8` à 7,0. Elle sépare précisément les modèles et les
prompts qui résistent au code-switch de ceux qui basculent. **Elle discrimine plus que n'importe
quelle autre fixture et doit être conservée.**

Nuance sur le 12B : contrairement à ce que le brief anticipait, **il ne dérape pas sur `f08` en v2**
— ni en nettoyage (8,0, aucun auto-fail) ni en réécriture (8,0). Le drapeau mécanique
`LANG_DRIFT_FR` tire bien sur sa sortie `rewrite_baseline/f08`, mais les trois juges de `armD` ne
l'ont pas retenu comme disqualifiant et lui ont donné 8,0 de médiane. Le drapeau mécanique et le
jugement divergent sur ce point précis ; le drapeau est un test de ratio de mots-outils, pas une
lecture, et les fixtures majoritairement anglaises le déclenchent facilement.

---

## Méthode

1. **Génération déjà faite**, non rejouée : 263 lignes dans `results-v2.jsonl`, produites par
   `run_benchmark_v2.py` sur ollama 0.33.2, un modèle résident à la fois. Seules les 225 lignes
   `config_id: v2` + `fixture_set: synthetic` sont jugées.
2. **15 fixtures synthétiques françaises** (`benchmark/fixtures.jsonl`), les mêmes qu'au v1, médiane
   46 mots.
3. **`make_packets_v2.py`** construit 60 paquets anonymisés. Lettres mélangées par paquet avec un
   seed distinct de celui du v1 (20260901 contre 20260831) ; 11 à 14 ordonnancements distincts par
   arm sur 15 paquets. La correspondance lettre → condition est écrite dans
   `letter_mapping_v2.json`, **hors de `packets_v2/`**.
4. **Contrôle d'étanchéité automatisé, pas déclaratif** : le script relit chaque fichier de paquets
   écrit et lève si l'une des chaînes `gemma`, `qwen`, `s1-mini`, `s1_control`, `cleanup_A/B/C`,
   `cleanup_baseline`, `rewrite_baseline`, `latency`, `size_gb`, `ollama` y apparaît. Aucun juge ne
   voit un nom de modèle, un nom de prompt, une latence ni une taille.
5. **12 juges** lancés par `run_judges_v2.py` comme **processus `claude -p` séparés**, sans contexte
   partagé, depuis un répertoire de travail vide et temporaire — un appel d'outil égaré ne peut donc
   pas atteindre `letter_mapping_v2.json`. Chaque juge reçoit `judge_prompt.txt`, `rubric.md` gelée,
   et les 15 paquets de son arm, **dans un ordre propre à lui** (seed par juge), pour qu'un
   éventuel effet de position ne soit pas partagé par les trois.
6. **Validation avant écriture** : chaque paquet jugé exactement une fois, jeu de lettres conforme
   au paquet, `autofail` booléen présent, quatre critères présents et dans 0-2. Un juge non conforme
   est relancé ; aucun fichier partiel n'est écrit. **Les 12 juges ont validé au premier essai.**
7. **`aggregate_v2.py`** dés-anonymise et joint aux métriques machine. Doctrine du v1 conservée :
   min / médiane / max / moyenne sur les trois juges, jamais un tirage unique ; auto-fails comptés
   **séparément**, jamais repliés en 0 ; head-to-head imprimé sous **les deux** conventions ;
   inversion de classement entre conventions détectée et nommée. Le script lève sur un fichier de
   juge manquant, un paquet non jugé, un doublon, un jeu de lettres non conforme ou une condition
   sans ligne de performance.

### Deux écarts de protocole assumés

**(a) L'arm prompt ne montre pas le prompt réel.** Dans `armA` et `armB`, les quatre candidats *sont*
quatre prompts différents : y mettre le prompt réel révélerait la condition, en mettre un seul en
ferait le prompt de tous. Le champ `task_prompt` de ces paquets contient donc un **brief neutre**
(`prompts/neutral_cleanup_brief.txt`) énonçant l'intention commune aux quatre variantes. `armC` et
`armD` gardent le prompt réel, comme au v1. Conséquence : les scores de l'arm prompt et de l'arm
modèle ne sont pas comparables terme à terme — c'est précisément ce que le pont de calibration
ci-dessus quantifie (+0,40 et +0,14 de moyenne).

**(b) L'arm prompt est scindé en deux panels de juges, un par modèle.** Le brief demandait 3 juges
pour les 30 paquets de l'arm prompt ; j'ai fait 3 juges pour les 15 paquets du 12B et 3 autres pour
les 15 de l'e2b. Motif : cela ramène la charge par juge à 15 paquets × 4 candidats = 60 scores,
exactement la charge du v1, sur laquelle la calibration des juges a été mesurée. Un juge à 120
scores est un régime que rien dans ce benchmark ne documente. L'anonymisation et l'indépendance
sont inchangées.

**Conséquence à ne pas manquer : `armA` et `armB` sont jugés par des panels DIFFÉRENTS.** On peut
donc comparer le *classement* des quatre prompts à l'intérieur d'un modèle, mais **pas les scores
terme à terme entre les deux modèles**. Croiser le tableau `armA` et le tableau `armB` pour en
déduire un écart 12b−e2b serait une erreur de lecture : cet écart-là est tranché par `armC`, qui est
un panel unique. Le pont de calibration ci-dessus chiffre l'ampleur du décalage entre panels (+0,40
et +0,14 de moyenne sur des sorties strictement identiques) — c'est l'ordre de grandeur en dessous
duquel aucune comparaison inter-arms n'est interprétable.

---

## Ce qui a été vérifié, et comment

- **Recomputation indépendante de tous les scores.** Les 17 cellules `arm × condition` ont été
  recalculées par une seconde passe de structure inverse : au lieu d'itérer les fichiers de juges et
  de résoudre les lettres via le mapping (ce que fait `aggregate_v2.py`), elle **inverse** le mapping
  en `condition → {paquet: lettre}` et tire les scores condition-first. Les 17 cellules coïncident
  exactement sur `n`, min, médiane, max, moyenne et nombre d'auto-fails.
- **Étanchéité vérifiée mécaniquement, pas déclarée.** `make_packets_v2.py` relit chaque fichier de
  paquets écrit et lève sur toute chaîne identifiante (liste `FORBIDDEN`). Il passe sur les 4
  fichiers. Vérification séparée : aucune occurrence de la ligne de contrôle `[Styling: semi-casual]`
  de `s1-mini` dans les paquets.
- **Le brief neutre n'encode que l'intention produit, pas une règle mono-variante.** Audit
  automatisé des 10 règles qu'il énonce contre les 4 variantes : **les 10 sont portées par les 4**.
  Contrôle inverse sur les 4 règles qu'une seule famille de variantes porte — typographie française
  (`C` seule), interdiction d'appliquer la typo dans un chemin (`C` seule), garde-fou anti-no-op
  (`A`, `B`, `C`), exemples few-shot (`B`, `C`) — : **aucune n'apparaît dans le brief**. Une
  variante ne peut donc pas être pénalisée pour n'avoir pas fait ce que son propre prompt ne
  demandait pas. À l'inverse, une variante qui laisse tomber une règle commune et produit une moins
  bonne sortie perd bien des points, ce qui est le test voulu.
- **Chiffres de la lecture stratifiée produits par script**, pas calculés à la main :
  `stratify_v2.py` partitionne les fixtures avec un critère fixé sur le contenu des exemples seuls,
  imprime les écarts sous les deux conventions d'auto-fail, et imprime la marge restante de la
  baseline par strate — c'est cette dernière colonne qui empêche de lire un test non concluant
  comme un test négatif.
- **Absence d'indice typographique pour la variante `C`.** Contrôlé avant expédition aux juges :
  0 U+202F, 0 U+00A0, 0 « sur ses 30 sorties. La seule occurrence de « » dans tout `armC` vient de
  `qwen3.5-4b`, une autre condition.
- **Régénération déterministe.** `make_packets_v2.py` relancé après coup reproduit un
  `letter_mapping_v2.json` sur lequel `aggregate_v2.py` valide toujours les 12 fichiers de juges —
  si le mélange n'était pas déterministe, les jeux de lettres ne correspondraient plus et
  l'agrégateur lèverait.
- **Complétude de la population.** L'agrégateur lève sur un fichier de juge manquant, un paquet non
  jugé, un paquet jugé deux fois, un jeu de lettres non conforme ou une condition sans ligne de
  performance. Il tourne proprement : les 12 fichiers, les 60 paquets × 3 juges et toutes les
  lettres sont présents — 765 scores, aucun ignoré.
- **Validation à l'entrée, pas seulement à l'agrégation.** `run_judges_v2.py` a validé la sortie de
  chaque juge avant de l'écrire (couverture, lettres, `autofail` booléen, critères dans 0-2).
  **Les 12 juges ont passé au premier essai**, aucune relance.
- **Cause du bug de recapitalisation tracée jusqu'au code**, pas déduite : les 7 sorties `s1-mini`
  sans majuscule initiale sont exactement les 7 dont le premier token capturé porte une ponctuation
  collée (`'alors,'`, `'okay,'`, `'salut,'`, `'bonjour,'`, `'hey,'`, `'coucou,'`, `'okay,'`), et
  `_PLAIN_WORD` rejette chacun de ces tokens (vérifié en exécutant la regex sur eux).
- **Artefacts du v1 intacts.** `results.jsonl`, `letter_mapping.json`, `packets/` et `judgments/`
  portent tous une date de modification du 2026-08-31 ; rien n'a été écrit dedans. `aggregate.py`
  (v1) tourne toujours proprement et produit les mêmes chiffres. Le v2 vit dans des fichiers
  distincts : `packets_v2/`, `letter_mapping_v2.json`, `judgments_v2/`, `aggregate_v2.py`,
  `make_packets_v2.py`, `run_judges_v2.py`.

**Non vérifié** : que le raisonnement *qualitatif* des juges soit juste. L'accord est mesuré, la
vérité terrain ne l'est pas — il n'existe pas de nettoyage de référence. Et rien de ce rapport ne
porte sur des dictées réelles jugées.

---

## Limites — à lire avant d'utiliser les tableaux

### 1. Les few-shot de `B` et `C` sont contaminés — mesuré, et le résultat n'est pas rassurant

Ce n'était pas une précaution de fin de rapport : la lecture stratifiée est faite plus haut et elle
change ce qu'on a le droit de conclure. Résumé : **l'avantage de score de `B` ne survit pas au seul
test qui avait du pouvoir.** Sur l'e2b, `B` gagne +0,40 sur les 5 fixtures proches des exemples et
−0,11 sur les 9 éloignées. Sur le 12B la strate proche est saturée (baseline à 8,0 sur 4 fixtures
sur 5), donc son +0,50 sur la strate éloignée ne démontre pas de généralisation — il constate qu'il
n'y avait de la marge que là.

Ce qui survit : **la suppression de l'auto-fail de `f08` sur l'e2b**, obtenue sur une fixture
éloignée qu'aucun exemple ne prépare. C'est le seul gain de `B` que ces données établissent.

La mesure qui trancherait — régénérer `B` et `C` avec des exemples hors distribution, 60
générations — n'a pas été engagée.

### 2. La variante `C` n'a jamais appliqué la règle qui la distingue

0 U+202F, 0 U+00A0, 0 « » sur ses 30 sorties (section D de `describe_v2.py`). La consigne
typographique française qui est la raison d'être de `C` a été **ignorée par les deux modèles**.
Que `C` finisse dernière sur le 12B ou troisième sur l'e2b **ne dit rien sur la typographie
française** : ça compare une consigne en français plus longue de 424 tokens à une consigne en
anglais, à typographie identique dans les faits. Une seule note de juge sur 765 mentionne une espace
fine manquante, et elle porte sur `s1-mini`, pas sur `C`.

### 3. Le long format n'est mesuré que pour un modèle, et jamais en qualité

`gemma4-12b-qat` est le seul modèle mesuré sur les dictées réelles longues (260-370 mots, médiane
19,0 s). **`gemma4-e2b-qat` n'a aucune mesure long format.** Or c'est exactement là que la question
de coût se joue : si le rapport de latence ×3,9 mesuré à 46 mots se maintient à 300 mots, l'e2b y
serait autour de 5 s contre 19 s — un écart d'une autre nature que 0,81 contre 3,17. Le v1 avait
montré (§1b) que le rapport reste proportionnel entre modèles, ce qui rend l'extrapolation
plausible, mais **elle n'est pas mesurée ici**. Et dans les deux cas, **aucune sortie longue n'a été
jugée** : la qualité au-delà de 61 mots reste invisible.

### 4. Le critère `format` de `s1-mini` mesure notre post-traitement autant que le modèle

Établi et tracé plus haut : la passe de recapitalisation échoue sur 7 sorties sur 15 à cause du
token de début de phrase qui capture la ponctuation collée. Le contrefactuel montre que corriger ce
bug ne changerait pas le classement, mais le chiffre publié (`format` moyenne 1,38) n'est pas une
propriété de `s1-mini`. À noter aussi que 13 sorties sur 15 n'ont **aucune ponctuation finale**, ce
que la passe ne corrige pas du tout et que les juges relèvent.

### 5. Les quatre limites de grille du v1 sont toujours là, et une cinquième s'ajoute

Les limites **(a) un no-op marque 6/8**, **(b) la normalisation d'identifiant n'est pas tranchée**,
**(c) le registre n'est pas noté**, **(d) l'auto-fail langue est indéfini pour l'entrée
code-switchée** sont inchangées, la grille étant gelée. Le mining des 765 notes confirme que (b)
reste actif : 10 notes portent sur `files_used` / `transcribe_audio_path` / snake_case, sans
convention écrite pour les départager.

La cinquième, propre au v2 : **la grille n'a aucun critère pour « le prompt a-t-il été suivi ».**
C'est sans conséquence pour l'arm modèle, mais l'arm prompt mesure l'effet d'une consigne avec une
grille qui ignore le respect de la consigne — c'est exactement pourquoi l'échec typographique de `C`
est invisible dans son score. **Je ne l'ai pas ajoutée** ; l'ajouter rendrait les 360 scores du v1
incomparables, ce qui coûterait plus que ça ne rapporte.

### 6. Un désaccord juge / drapeau mécanique, non arbitré

Le drapeau `LANG_DRIFT_FR` tire sur `gemma4-12b-qat` + `rewrite_baseline` + `f08` ; les trois juges
de `armD` donnent 8,0 de médiane à cette même sortie et aucun auto-fail. L'un des deux a tort et ce
rapport ne dit pas lequel. Le drapeau est un ratio de mots-outils, donc faillible sur une entrée
majoritairement anglaise ; les juges lisent, mais la grille ne définit pas le cas code-switché
(limite (d) du v1). Aucun chiffre du verdict ne repose sur cette cellule.

### 7. Reproductibilité des latences

Chaque latence est une médiane sur 15 appels, une machine, une journée, avec Louis en train de
travailler dessus. Le v1 avait relevé ~1 s de variation entre deux passages du même modèle. Les
écarts de latence inférieurs à la seconde entre variantes de prompt sont à lire avec cette réserve ;
le rapport ×3,9 entre 12B et e2b, lui, la dépasse largement.

---

## Ce qui reste non tranché

1. **Le long format pour tout ce qui n'est pas le 12B.** C'est le trou le plus coûteux du rapport.
   La question « 7,2 Go valent-ils le coup » se joue à 300 mots autant qu'à 46, et à 300 mots on ne
   connaît qu'un seul point de mesure. Une passe de 4 fixtures réelles × 4 modèles suffirait à
   fermer ça ; elle n'a pas été faite.
2. **La qualité au-delà de 61 mots.** Aucune sortie longue n'a jamais été jugée, ni au v1 ni au v2.
   Rien n'exclut qu'un petit modèle correct à 46 mots se dégrade à 300 — c'est même le mode d'échec
   attendu, vu la compression de contenu que l'e2b montre déjà sur `message_rewrite`.
3. **Ce que vaut réellement `cleanup_B` en score.** Sa première place est unanime sur les deux
   modèles, mais la stratification montre que son avantage de score vit sur les fixtures qui
   ressemblent à ses exemples, là où la mesure a du pouvoir. L'effet global (+0,24 et +0,12 de
   moyenne) est par ailleurs du même ordre que le décalage entre panels (+0,40 et +0,14). **Sur les
   moyennes, `B` n'est pas séparée du bruit, et la part qu'on lui mesure est suspecte de
   contamination.** Ce qui est solide reste la disparition de l'auto-fail sur l'e2b : catégoriel,
   sur une fixture éloignée des exemples.
   La question ouverte n'est donc plus « `B` gagne-t-elle ? » mais **« un few-shot dont les exemples
   ne ressemblent pas à l'entrée apporte-t-il encore quelque chose ? »**, à laquelle ce benchmark ne
   répond pas et qu'une régénération de `B`/`C` hors distribution trancherait.
4. **La typographie française.** Non testée, parce que le seul prompt qui la demandait n'a jamais
   été suivi. Si elle compte, il faut une variante qui l'obtienne effectivement, et un critère de
   grille pour la noter.
5. **12B contre e2b + `cleanup_B`.** C'est la comparaison qui intéresse vraiment une décision de
   produit et c'est la seule du rapport qui traverse deux panels : 7,76 (`armC`) contre 7,07
   (`armB`), soit ~0,55 après correction du décalage de panel de +0,14. L'écart survit à la
   correction, mais **il n'a pas été mesuré dans un même arm** et devrait l'être avant qu'on
   engage 2,9 Go dessus.
6. **Le seuil de latence acceptable pour Louis.** Le rapport chiffre le coût ; il ne dit pas où est
   la limite. 3,17 s contre 0,81 s sur une dictée courte est probablement indolore ; 19 s sur une
   dictée de 300 mots ne l'est probablement pas. Ce point-là n'est pas une question de benchmark,
   c'est une question à poser à Louis, et le seul essai qui y répond est un A/B sur ses propres
   dictées.
7. **Le classement de `armB` selon la convention d'auto-fail.** Baseline et `C` échangent leur place
   selon qu'on exclut la disqualification ou qu'on la compte 0. Les deux lectures sont imprimées ;
   aucune n'est déclarée juste. Ça n'affecte ni la première ni la dernière place.
