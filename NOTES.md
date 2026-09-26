# NOTES — lot 13 DEV (`t_7785056d`)

## Décision d'arbitrage appliquée

`ARBITRAGE-t_9ab9f3b9-r6.md` (`017852cc…`, 600 l.) fait foi ; le corps de la carte porte la r1 et
est périmé sur deux points (pointeur r1, « switch à quatre cas »).

## Transport (règle 10) — empreintes avant / après

| Fichier | Amont | shasum amont | shasum livré |
|---|---|---|---|
| `MurmureCore/Sources/MurmureCore/TranscriptDocument.swift` | `t_95eaa2b1` | `682de890…` | modifié |
| `MurmureCore/Sources/MurmureCore/TranscriptFilenames.swift` | `t_95eaa2b1` | `f29c42b9…` | modifié |
| `Murmure/TranscriptsPaneModel.swift` | **`t_95eaa2b1`** (lot 10-S-R, parent) | `b509b461…` | modifié |
| `Murmure/TranscriptControlServer.swift` | `t_95eaa2b1` | `7b9ddfa7…` | modifié |
| `…Tests/TranscriptSourceResolutionTests.swift` | QA `t_1aa0ce0d` | `fa40f40f…` | **inchangé** (cmp) |

Le worktree de la carte partait de `8117857` sans aucun fichier `Transcript*` : l'arbre a été
transporté depuis `t_95eaa2b1` (rsync, tout le dépôt, `.git` exclu) **puis** le contrat QA recopié
`cp -p`. Aucun fichier n'a été réécrit depuis zéro.

## Ce qui a été écrit

1. Cœur : `TranscriptSourceFamily` (la seule table d'hôtes, elle rend l'**identité**, pas un
   `kind`), `TranscriptSourceResolution` (5 cas), `TranscriptSource.resolve(_:)`.
2. `identityFor(url:)` **délègue** à `resolve` et rend `""` pour ce qu'il refuse ; signature,
   comportement et les 382 lignes du contrat du lot 1 inchangés. `identityFor(path:)` **non
   touchée**.
3. CLI : `kind(pourHote:)` disparaît, `switch` sur les **cinq** cas, la `String` du cas est passée
   telle quelle — `.unsupportedURL` et `.unsupportedScheme` convergent vers le même
   `Failure.unsupportedURL` **par construction**, chaque charge utile étant celle d'aujourd'hui.
4. Panneau : liste d'hôtes supprimée, `guard case .source(let s) = TranscriptSource.resolve(entree)`,
   `refusal(for:)` **inchangé**.

## Décision prise en cours de route (F15, non tranchée par l'arbitrage)

`TranscriptSourceResolution` est `Sendable` (exigé par la signature du contrat QA), ce qui exige
que `TranscriptSource` et `TranscriptSourceKind` le soient aussi : les deux `public` sans
conformité explicite ne l'infèrent pas. J'ai **ajouté** `Sendable` à ces deux types (aucun
champs non `Sendable` : `String`, `URL?`, `Date`, `Double`). C'est un ajout de conformité, pas un
changement de contrat de données — mais c'est une **modification hors des quatre lignes du corps**,
signalée ici et au reviewer.

## Preuves exécutées

- `swift build` (MurmureCore) : BUILD COMPLETE, 0 warning.
- `swift test --filter TranscriptSourceResolution` : **7 tests, 0 échec** (le rouge de la QA).
- `swift test --filter 'Transcript(Document|Filenames|Markdown)'` : 35 tests, 0 échec.
- `swift test` (global) : **1655 tests, 0 échec**.
- `bash scripts/codex/verify.sh` : `summary exit 0, failures=0`
  (journal `.codex/workflow-runs/verify-20260926T030514Z-30772.jsonl`).
- `xcodebuild -scheme Murmure -configuration Debug CODE_SIGNING_ALLOWED=NO` : **BUILD SUCCEEDED**,
  seul avertissement = `Metadata extraction skipped. No AppIntents.framework dependency` (préexistant).
- `git diff --check` : vide.

## Bornes

Lignes de code ajoutées, 4 fichiers de production : **+99** (`TranscriptDocument` +76,
`TranscriptFilenames` +3, panneau +9, serveur +11) — **≤ 120**. Retirées : **-86**.
**Diff négatif sur les deux appelants** (-27 et -25 lignes de code), comme exigé.

## Reste à faire pour un autre

Aucun. Pas de commit, pas de push (interdit par la carte).

---

# Rework — revue round 1, F17 (bloquant)

## Le défaut, tel que la revue l'a mesuré

`identityFor(url:)` **déléguait** à `TranscriptSource.resolve(_:)` sans rien filtrer, alors que
`resolve` reconnaît **aussi** les fichiers locaux. Une URL **absolue sans schéma** désignant un
fichier existant — que `URL(string:)` accepte — tombait donc dans la branche « fichier local » et
rendait l'empreinte de contenu (`7e1ec011…`) là où la fonction rendait `""` avant le lot. Le contrat
du lot 1 — « signature et comportement inchangés » — était donc rompu pour une classe d'entrées
que le contrat rouge n'exerce pas (son cas 7 ne teste que du `http(s)`), et le commentaire de la
fonction affirmait encore le contraire.

## Le correctif — local à `TranscriptFilenames.swift`

Un garde de schéma avant la délégation : `identityFor(url:)` ne franchit plus que la **branche
d'adresse** de `resolve`, donc `""` pour tout ce qui n'est pas `http`/`https`. `resolve`,
`identityFor(path:)` et les 382 lignes du contrat du lot 1 sont **intacts**. Le commentaire de la
fonction a été amendé pour dire pourquoi le filtre existe, au lieu de laisser le code contredire sa
propre documentation.

+3 lignes de code, +7 de commentaire. Un seul fichier touché.

## Preuves exécutées (sur les octets courants)

- `swift test --filter TranscriptSourceResolutionTests` → **7 tests, 0 échec**.
  *Réserve de forme du reviewer honorée* : le filtre cité au compte rendu précédent
  (`--filter TranscriptSourceResolution`) rendait « 0 tests in 0 suites » — il ne sélectionne pas
  la suite swift-testing. Le 7/0 exige `--filter TranscriptSourceResolutionTests`.
- `swift test --filter 'Transcript(Document|Filenames|Markdown)'` → **35 tests, 0 échec**.
- `swift test` (global) → **1655 tests, 0 échec**.
- `bash scripts/codex/verify.sh` → `{"event": "summary", "exit": 0, "detail": "failures=0"}`,
  journal `.codex/workflow-runs/verify-20260926T031307Z-91475.jsonl`.
- `git diff --check` → vide.

**La mesure qui prouve F17 levé** — sonde compilée contre le cœur livré, sur un fichier de
4096 octets `0x41` (le même que la revue) :

| entrée | avant correctif | après correctif | amont (revue) |
|---|---|---|---|
| chemin absolu sans schéma, fichier existant | `7e1ec011…` | **`""`** | `""` ✔ |
| `file://…` | `""` | `""` | `""` ✔ |
| `~/x.m4a` | `""` | `""` | `""` ✔ |
| `ftp://…` | `""` | `""` | `""` ✔ |
| `https://www.youtube.com/watch?v=dQw4w9WgXcQ` | `dQw4w9WgXcQ` | `dQw4w9WgXcQ` | inchangé ✔ |
| `https://youtu.be/dQw4w9WgXcQ` | `dQw4w9WgXcQ` | `dQw4w9WgXcQ` | inchangé ✔ |
| `https://x.com/user/status/1234567890` | `1234567890` | `1234567890` | inchangé ✔ |
| `https://example.com/v/ID` | `""` | `""` | `""` ✔ |
| `notyoutube.com.evil.example/watch?v=…` | `""` | `""` | `""` ✔ (ancrage) |

Les six lignes du tableau de la revue sont **restaurées à l'identique de l'amont**, et
`resolve(chemin)` rend toujours `source(kind: .file, identity: 7e1ec011…)` — la résolution du lien
symbolique du lot est intacte. La sonde est dans
`~/.hermes/profiles/dev/cache/scratch/f17probe/` (**hors dépôt**, aucun effet sur le livrable ;
suppression refusée en session non assistée, je ne contourne pas le refus).

## Bornes après rework

`TranscriptFilenames.swift` passe de **+3** à **+6** lignes de code sur le lot ; total des quatre
fichiers de production : **+102**, toujours **≤ 120**. Le diff reste **négatif sur les deux
appelants** (-27, -25). Aucun autre fichier touché, aucun commit, aucun push.

## Empreintes courantes (après rework)

- `MurmureCore/Sources/MurmureCore/TranscriptDocument.swift` `78c31fef519302f15fb75d65dc6e09195dd3c7b7f0c16aece1035a1adc5faa8e`
- `MurmureCore/Sources/MurmureCore/TranscriptFilenames.swift` `928c7c8ea58b471af8f2676b99f5350ef62ba4988fe68d99dee996223b1fe38f` (213 l.)
- `Murmure/TranscriptsPaneModel.swift` `e044db8762a498881a332bb3fef2e6234d7da38fafa5115900592084b92c2429`
- `Murmure/TranscriptControlServer.swift` `72c1a660e51bff67c7ad1978beeaf51167cd0554c9a6b6ae89c53caba827d1b8`
- `TranscriptSourceResolutionTests.swift` `fa40f40f6e6ed98746c2d036885f36d9595a5ffee00e9247773ef5efcdcc73fa` —
  **inchangé**, identique à l'empreinte annoncée au compte rendu précédent : le contrat rouge de la
  QA n'a pas été touché.
