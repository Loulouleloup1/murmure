# s1-mini quantifié ou pleine précision — l'argument mémoire ne tient pas

Date : 2026-09-02 · Corpus : 15 fixtures synthétiques (`benchmark/fixtures.jsonl`, commitées) +
48 dictées réelles stratifiées par densité franglais (`benchmark/fixtures-franglais.local.jsonl`,
**jamais commité**) · Résultats : `benchmark/results-v4-*.local.jsonl`, **jamais commités** ·
Mesures mémoire : `benchmark/ram-v4-quant.json` (commité — il ne porte aucune dictée) ·
Harnais : `benchmark/v4_quant.py`, `v4_measure_ram.py`, `v4_compare.py`, `v4_determinism.py`,
`v4_headroom.py`

Louis a remarqué que le modèle qui refine son mode `Prompt` est déjà minuscule et qu'on le fait
quand même tourner quantifié en 4 bits : « est-ce qu'on a vraiment besoin d'avoir une quantification
pour ce modèle-là ? »

**Décision : on garde `Q4_K_M`.** Mais pas pour la raison qu'on croit.

---

## 1. L'argument mémoire est faux, et il faut le dire avant le verdict

L'argument qu'on dégaine spontanément — « c'est quantifié pour tenir dans la RAM » — **ne résiste
pas à la mesure**. Le surcoût de la pleine précision est exactement le delta de poids, au mégaoctet
près, et le cache KV ne bouge pas d'un pouce :

| | `Q4_K_M` | `F16` | écart |
|---|---:|---:|---:|
| poids sur disque | 484,2 Mo | 1 509,3 Mo | +1 025,1 Mo |
| **RSS crête résident @ `num_ctx` 4096** | **1,084 Go** | **2,109 Go** | **+1,025 Go** |
| `ollama ps` | 1,0 Go | 2,0 Go | +1,0 Go |
| RSS crête sur la dictée de 531 mots | 1,107 Go | 2,133 Go | +1,026 Go |

+1,025 Go mesuré contre +1,025 Go de poids : **la quantification n'achète rien d'autre que ses
propres octets de poids.** Sur la machine cible 16 Go, passer de 1,1 à 2,1 Go ne met aucune pile en
danger — la pile actuelle Whisper + s1-mini passerait d'environ 2,6 à 3,6 Go.

**Donc : la quantification de s1-mini n'a jamais été nécessaire pour la mémoire.** Elle reste le bon
choix, mais le dossier repose entièrement sur la **latence** et sur un **mode d'échec** de la pleine
précision, développés plus bas. Qui saute directement au verdict doit repartir avec ça et pas avec
l'inverse.

Le balayage `num_ctx` sur `F16` (1,87 / 2,11 / 2,58 Go à 2048 / 4096 / 8192) montre que le levier a
la même course qu'en q4 (0,84 / 1,07 / 1,54 / 2,48 Go à 2048 / 4096 / 8192 / 16384, `ram-v3-ctxsweep.json`) :
il rendrait **0,24 Go**, jamais le gigaoctet. Il ne peut pas payer `F16` — et de toute façon
§7 l'interdit.

### Les deux tags, vérifiés et non devinés

`superwhisper/s1-mini-GGUF` publie exactement deux fichiers. Les manifestes ont été lus sur le point
d'accès Hugging Face avant tout téléchargement :

| tag | blob de poids | empreinte |
|---|---:|---|
| `Q4_K_M` (= `latest`) | 484,2 Mo | `sha256:3b41ebe2502cb` |
| `F16` | 1 509,3 Mo | `sha256:0370da4f1bae1` |

Les blobs `license`, `template` et `params` sont **identiques sur les deux tags**. La précision des
poids est donc la seule variable de cette campagne.

---

## 2. Le plancher : q4 se reproduit 63/63 octet pour octet

C'est ce contrôle qui rend le reste du document lisible, et il a été passé **avant** de tirer la
moindre conclusion d'un écart.

Les deux bras reçoivent `temperature: 0` et une graine fixe, donc en principe un rejeu redonne la
même chaîne d'octets. « En principe » n'est pas une mesure. `benchmark/v4_determinism.py` rejoue le
bras q4 dans un processus neuf, contre un modèle fraîchement chargé, sur les 63 mêmes fixtures :

**63 sorties sur 63 reproduites octet pour octet.**

Le plancher de bruit est donc nul. Tout écart entre q4 et f16 est attribuable aux poids et à rien
d'autre. Sans ce contrôle, le « 49 sur 63 » de la section suivante serait un nombre illisible.

---

## 3. Les deux bras diffèrent — 49 sorties sur 63

| jeu de fixtures | n | identiques | différentes |
|---|---:|---:|---:|
| synthétiques | 15 | 1 | 14 |
| réelles | 48 | 13 | 35 |
| **total** | **63** | **14** | **49** |

Similarité caractère par caractère sur les 49 paires différentes : **médiane 0,971**. L'écrasante
majorité des différences est cosmétique — une virgule, une majuscule, un apostrophe. Mais la queue
ne l'est pas : 0,042 · 0,112 · 0,487 · 0,493 · 0,549. C'est dans cette queue que se joue la
décision, et §5 y revient.

---

## 4. Latence — `F16` coûte 70 %

| | `Q4_K_M` | `F16` |
|---|---:|---:|
| médiane à chaud, synthétiques | 0,275 s | 0,454 s |
| médiane à chaud, réelles | **0,381 s** | **0,645 s** |
| p90 / pire, réelles | 1,228 / 3,325 s | 1,626 / 5,252 s |
| débit | 236 tok/s | 145 tok/s |
| médiane à froid | 0,81 s | 0,90 s |

Le débit s'effondre d'un tiers. Sur une dictée courte l'écart absolu reste sous la demi-seconde et
ne se sent probablement pas ; sur les dictées longues il se voit (5,25 s contre 3,33 s au pire).

---

## 5. `F16` supprime du contenu au milieu d'une dictée

**C'est le fait qui décide, et l'agrégat le cache intégralement.**

Le taux de conservation moyen sur les 48 dictées réelles est de 97,7 % en q4 contre 97,5 % en f16 —
une égalité. Cette moyenne est vraie et elle est inutile : le défaut touche trois fixtures, et une
moyenne sur 63 ne peut pas le voir. Il faut le demander directement.

| fixture | mots en entrée | q4 restitue | f16 restitue |
|---|---:|---:|---:|
| `fg-pure-11` | 223 | 97 % | **52 %** |
| `fg-heavy-08` | 57 | 100 % | 82 % |
| `fg-mixed-02` | 103 | 105 % | 87 % |

Trois cas, **tous contre `F16`, aucun contre q4**. Sévères (< 75 % conservés) : q4 zéro, f16 un.

**Et ce ne sont pas des troncatures.** Les queues ont été vérifiées une par une : chaque sortie
`F16` **se termine bien sur la dernière phrase de l'entrée**, avec `done_reason: "stop"`, HTTP 200,
aucun drapeau. Sur `fg-pure-11`, 114 mots reviennent pour 223 dictés — 172 jetons de complétion
contre 312 pour q4 — et la sortie ouvre et ferme exactement où il faut.

**Rien dans la sortie ne dit qu'elle est incomplète.** C'est ce qui met ce défaut au-dessus du seul
gain mesuré de `F16` : une moitié de dictée disparue qui se lit comme un texte fini ne sera jamais
rattrapée par la relecture. Qui reprend ce sujet regardera l'agrégat en premier : l'agrégat ne le
verra pas.

`F16` a par ailleurs corrompu un nombre sur `f14` — « les cent trente-quatre lignes attendues »
revient en « les 34 quatrièmes attendues » — et n'y a mis aucune majuscule. Sur l'ensemble du
corpus la fidélité aux nombres est toutefois une égalité : 25/30 pour q4, 24/30 pour f16.

---

## 6. La langue — le seul gain de `F16`, et il ne se reproduit pas sur le réel

C'est le mode d'échec qui compte le plus pour Louis : s1-mini est documenté pour basculer en anglais
sous certains réglages. `F16` y gagne un point, franchement, et il faut l'écrire.

Mesure en mots-outils anglais pour 100 mots de sortie, comparés à la part de l'entrée :

| fixture | entrée EN / FR | q4 EN / FR | f16 EN / FR | moins bon |
|---|---:|---:|---:|---|
| `f13` (synthétique) | 3,9 / 29,4 | **14,9 / 10,6** | 4,2 / 29,2 | **q4** |
| `fg-heavy-07` (réelle) | 0,0 / 37,0 | 0,0 / 28,0 | **4,2 / 33,3** | **f16** |
| `f08` (synthétique, hors distribution) | 8,8 / 20,6 | 25,0 / 0,0 | 28,1 / 0,0 | les deux |

Sur `f13`, q4 traduit la moitié de la phrase (« Okay, so listen, I think we should rather start over
an architecture where each layer is behind a protocol, because otherwise we'll se retrouver avec un
truc monolithique ») là où `F16` garde le français quasi intact. Le gain est réel et porte sur la
bonne classe d'échec.

**Mais il ne se transporte pas au corpus réel.** Sur les 48 dictées réelles, les deux bras dérivent
**zéro fois** au drapeau `LANG_DRIFT_EN`, et la seule tache linguistique du corpus réel est *contre*
`F16` (`fg-heavy-07`, 4,2 mots-outils anglais là où l'entrée et q4 sont à 0,0). `f08` est à une
densité de 0,294, au-dessus des 1 500 dictées réelles : les deux bras y échouent également et il ne
doit pas être moyenné avec le reste.

### Amélioration de méthode : `LANG_DRIFT_EN` est binaire et rate les traductions partielles

**`LANG_DRIFT_EN` ne s'est pas déclenché sur `f13` pour q4.** Le drapeau exige que le français
s'effondre presque complètement (`fr_out <= max(1, fr_in // 4)`) ; une phrase à moitié traduite
garde trop de mots-outils français pour le faire tomber. Vu du drapeau, la sortie q4 de `f13` est
propre.

La mesure continue ci-dessus — part de mots-outils anglais rapportée à celle de l'entrée — la voit.
`benchmark/v4_compare.py` §F2 la produit. **La prochaine campagne doit utiliser les deux** : le
drapeau pour les effondrements, la mesure continue pour les traductions partielles. Compter sur le
seul drapeau, c'est publier un zéro qui n'en est pas un.

---

## 7. Piège : `num_ctx` 2048 efface 42 % d'une dictée en répondant 200

**Ce piège vaut pour les deux bras et il est indépendant de la question de la quantification.**

La lecture naturelle du tableau §1 est : « s1-mini répond au `num_ctx`, donc on peut le baisser ».
Le README et le document v3 présentent ce levier sans cette réserve. Elle est ici.

Le corpus compte aujourd'hui **1 500 dictées, la plus longue de 987 mots**, et **10 dépassent les
531 mots** contre lesquels le garde-fou avait été argumenté. Envoyée telle quelle :

| bras | `num_ctx` | prompt | complétion | total | fenêtre | réponse |
|---|---:|---:|---:|---:|---:|---|
| q4 | 2048 | 1 547 | 880 | **2 427** | **119 %** | HTTP 200, `stop` |
| q4 | 4096 | 1 547 | 1 482 | 3 029 | 74 % | HTTP 200, `stop` |
| f16 | 2048 | 1 547 | 669 | **2 216** | **108 %** | HTTP 200, `stop` |
| f16 | 4096 | 1 547 | 1 407 | 2 954 | 72 % | HTTP 200, `stop` |

À 2048, la requête dépasse la fenêtre de 19 % et **le serveur répond 200 avec `done_reason: "stop"`**.
La sortie q4 fait alors **574 mots pour 987 dictés — 42 % effacés au milieu** — en commençant et en
finissant exactement sur les bons mots. À 4096, la même entrée revient à 987 mots sur 987.

**Pourquoi `truncate: false` ne protège pas.** Le garde-fou refuse un *prompt* trop long. Ici le
prompt seul (1 547 jetons) tient sous 2048 : il n'y a rien à refuser. Le dépassement se produit
**pendant la génération**, où `llama-server` fait glisser la fenêtre (`--context-shift`, présent sur
sa ligne de commande) au lieu de s'arrêter. Le garde-fou est au bon endroit pour le défaut qu'il
vise, et ce défaut-ci passe à côté.

**Conclusion : `num_ctx` 4096 est validé à 74 % de la fenêtre sur le vrai maximum du corpus. En
dessous, c'est hors de question, pour les deux bras.**

---

## 8. Qualité — les agrégats, pour mémoire

Axes repris tels quels de v3 (`describe_v2.py`, `v3_describe.py` importés sans modification), donc
comparables aux deux rapports publiés.

| bras | jeu | n | maj. % | ponct. finale | long. % | conserv. % | dérive | drapeaux |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| q4 | synthétiques | 15 | **82,5 %** | **13/15** | 92,4 % | 86,9 % | 1 | 3 |
| f16 | synthétiques | 15 | 69,0 % | 10/15 | 92,7 % | 90,0 % | 1 | 3 |
| q4 | réelles | 48 | 95,5 % | 48/48 | 98,5 % | 97,7 % | 0 | 10 |
| f16 | réelles | 48 | 95,9 % | 47/48 | 96,9 % | 97,5 % | 0 | 8 |

Sur le réel, égalité sur tous les axes. Sur le synthétique, q4 devant sur la mise en majuscule
(82,5 % contre 69,0 %) et la ponctuation finale (13/15 contre 10/15). Santé : zéro sortie vide,
zéro `done_reason` autre que `stop`, zéro réponse non-200, sur les deux bras.

**Le solde.** Un gain `F16` sur une fixture synthétique, contre : un défaut de suppression de contenu
sur trois fixtures dont deux dictées réelles, une corruption de nombre, une mise en forme moins
bonne sur le synthétique, 70 % de latence en plus et +1,025 Go. On garde `Q4_K_M`.

---

## 9. Ce qui n'est PAS établi

- **Le déterminisme de `F16` n'a pas été vérifié.** Le rejeu 63/63 de §2 porte sur q4 seul. Rien ne
  laisse penser que f16 se comporte autrement — mêmes options, même graine, même serveur — mais ce
  n'est pas mesuré, et l'affirmer serait une extrapolation.
- **Aucun jury aveugle.** Cette campagne n'a produit que des mesures mécaniques. Les verdicts de
  qualité des rapports v2 et v3 venaient d'un panel ; ici il n'y en a pas eu, parce que le défaut de
  §5 se voit mécaniquement et tranche sans lui. Une préférence humaine entre deux sorties toutes
  deux correctes reste non mesurée.
- **`f13` est une fixture synthétique.** Le gain `F16` en préservation du français est réel mais
  repose sur une seule fixture fabriquée. Le corpus réel de Louis est à 95 % grammaticalement
  français et n'a produit aucune dérive sur aucun des deux bras — ce gain n'a donc pas d'occasion
  connue de servir.
- **« À froid » veut dire après un `ollama stop`**, GGUF encore dans le cache de pages du système.
  Un démarrage vraiment froid est plus lent, et l'écart entre les bras y serait plus marqué : le
  fichier `F16` fait 3,1 fois les octets à déplacer. Purger le cache de pages demande les droits
  root.
- **Le commentaire de `OllamaS1.numContext` est périmé** : il argumente sa marge contre « 531 mots,
  corpus de 1 449 ». Le corpus fait 1 500 dictées et la plus longue 987 mots (§7). La conclusion
  tient — 74 % de la fenêtre au vrai maximum — mais le nombre qui la porte est faux. `MurmureCore/`
  n'a pas été touché par cette campagne.

---

## Reproduire

Un bras à la fois, jamais deux modèles résidents en même temps — `unload_everything()` attend que le
RSS des processus `llama-server` retombe à zéro et **lève** plutôt que de charger par-dessus.

```
ollama pull hf.co/superwhisper/s1-mini-GGUF:F16

python3 benchmark/v4_quant.py --dry-run   # la grille : 2 bras x 63 fixtures
python3 benchmark/v4_quant.py             # 126 générations -> results-v4-quant.local.jsonl
python3 benchmark/v4_measure_ram.py       # RSS, froid/chaud, balayage num_ctx -> ram-v4-quant.json
python3 benchmark/v4_determinism.py --arm q4   # le plancher de bruit (§2)
python3 benchmark/v4_headroom.py          # la marge de contexte sur le vrai maximum (§7)
python3 benchmark/v4_compare.py           # toutes les tables ci-dessus
```

Les fixtures réelles se reconstruisent avec `benchmark/v3_sample_franglais.py`. Le corpus de §7 est
relu directement depuis les deux sources locales par `v4_headroom.py`, en `mode=ro` sur
`murmure.sqlite` — **aucun benchmark n'écrit jamais dans l'historique de Louis.**

**Réglages.** `benchmark/v4_quant.py` recopie le fil de la production depuis `OllamaS1.swift` et
`modes/prompt.json`, il ne l'approxime pas : `/api/generate`, `raw: true`, conversation ChatML
écrite à la main avec bloc `<think>` vide prérempli, ligne de contrôle `[Context: general]` (celle du
mode livré, **pas** le vainqueur de la grille v3), `temperature` 0, `repeat_penalty` 1.1, graine
20260901, `num_predict` 2048, `num_ctx` 4096, `truncate` false, `stop` sur les marqueurs de tour.
Toute divergence entre ces constantes et le Swift est un défaut de ce fichier. **Un benchmark sous
d'autres réglages mesure autre chose.**

**Confidentialité.** Les 48 dictées réelles sont du contenu de travail. Elles sont lues localement,
aucune n'est reproduite ici, et les fichiers de résultats suivent le motif `benchmark/*.local.jsonl`
couvert par `.gitignore` (vérifié au `git check-ignore`). `ram-v4-quant.json` est commité parce
qu'il ne porte que des durées et des comptes d'octets — son champ le plus long fait 114 caractères
et c'est une ligne d'`ollama ps`.
