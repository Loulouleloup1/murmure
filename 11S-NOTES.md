# NOTES — lot 11-S DEV (`t_6ebc3f69`)

(`NOTES.md` à la racine du worktree est celui du lot 13 (`t_7785056d`), transporté avec l'arbre ;
je ne l'ai pas écrasé. Ce fichier est le mien.)

## Base transportée (le worktree partait de `8117857`, sans aucun fichier `Transcript*`)

| Source | Ce qui est repris | Empreinte |
|---|---|---|
| `t_7785056d` (lot 13 DEV, amont) | tout l'arbre, `.git`/`.build`/`Murmure.xcodeproj` exclus | rsync |
| `t_d1dbdc77` (L11-R) | `project.yml`, `MurmureCore/Package.swift`, `MurmureCore/Package.resolved`, `Murmure/Info.plist`, `Murmure/Resources/`, `MurmureCore/Sources/murmure/`, `docs/licenses/`, `scripts/build-ffmpeg-lgpl.sh`, 6 `scripts/checks/` | `project.yml` `279d0a48…` |
| `t_aeb3aea0` (QA 11-S) | `scripts/checks/control-startup-contract.sh` (1782 l.) | `7d5cce23…` |

`project.yml` est donc celui de `t_d1dbdc77`, comme l'exige la carte — jamais réécrit.

## Écrit — 123 lignes d'implémentation, 4 fichiers, tous de la liste de la carte

borné par `diff -u` contre `t_7785056d` (la borne du plan est 390) :

| Fichier | Lignes |
|---|---|
| `Murmure/DictationController.swift` | 9 |
| `Murmure/TranscriptsPaneModel.swift` | 45 |
| `Murmure/MurmureApp.swift` | 37 |
| `Murmure/AppDelegate.swift` | 32 |
| `Murmure/TranscriptControlServer.swift` | **0** |

1. **`DictationController`** : `let transcriptionEngine: WhisperKitEngine` + `transcriptionEngine = engine`
   dans le `init`. Une seule construction de moteur dans tout `Murmure/`, et elle est ici.
2. **`TranscriptsPaneModel`** : `private let engine: WhisperKitEngine` reçu par `init(library:engine:)`,
   plus jamais construit ; `videoRunner()` appelle `engine.loadedModelForVideo(dedicatingComputeUnits: false)` ;
   `finishedDocument(id:)` lit le disque par la tige que la file a portée.
3. **`MurmureApp`** : `TranscriptsPaneModel(engine: controller.transcriptionEngine)` ; le handover
   `configureControlServer(submitteur:fournisseurStatut:)` dans `body` (le submitteur est celui du
   panneau, 10-S) ; la table `outcome(of:model:)` qui traduit la tige en `ControlJobOutcome` — une
   seule table, dans un seul fichier.
4. **`AppDelegate`** : `controlServer` en propriété, `applicationLaunched`,
   `configureControlServer` gardé par `guard controlServer == nil else { return }` et
   `if applicationLaunched { … start() }`, `start()` dans `applicationDidFinishLaunching`, `stop()`
   dans `applicationWillTerminate`.

`TranscriptControlServer.swift` n'est **pas** touché : il ne construit ni moteur ni file
(`server-no-queue` / `server-no-phantom-board` le lisaient déjà verts)
et son `init` prend déjà le submitteur et le status provider injectés. C'est une lecture, pas un
évitement : les deux contrôles qui lisent le serveur (`server-no-queue`, `server-no-phantom-board`)
étaient déjà verts sur la base.

## Preuves exécutées

| Preuve | Résultat |
|---|---|
| `xcodegen generate` + `xcodebuild -configuration Debug` | **BUILD SUCCEEDED**, rc=0 |
| **`control-startup-contract.sh wire` (gate Finder réelle)** | **CONTRÔLE=49/49**, rc=0 |
| ↳ `open -gj` LaunchServices | rc=0, pid 10628 vivant, socket détenu par ce pid |
| ↳ socket | apparu en **1 s** (fenêtre §2.5 : 10 s), chemin 65 octets |
| ↳ `murmure status` | rc=0, `idle` ; après le travail, `idle` encore |
| ↳ `murmure transcribe <fixture> --wait` | **rc=0**, `complete 0.9663472928` |
| ↳ transcript sur disque / avec texte | verts |
| ↳ signature du bundle ouvert | `TeamIdentifier=U569JMM3TX` |
| ↳ journal | 9 lignes, activité du contrôle présente, **aucun texte transcrit** |
| ↳ refus `MURMURE_NO_APP_LAUNCH=1` | rc=3 |
| `control-queue-wiring-tige.sh` (10-S-R) | BASE-SAINE 5/5 |
| `control-queue-wiring.sh` (10-S) | 21/21, swift 15/15 |
| `swift test` (MurmureCore) | **1655 tests, 0 échec** |
| 19 mutants du contrat QA | 16 capturés (rc=1 sur leur contrôle nommé) ; 3 non capturés, **finding ci-dessous** |

Le critère 3 — `transcribe --wait` en 0 — est VERT **sur l'état livré**, sans l'invention `documentID`
que la QA avait faite dans sa base de référence : le correctif 10-S-R (`t_95eaa2b1`) est bien dans ma
base, et c'est lui qui rend ce critère atteignable.

## Finding 1 — trois mutants du contrat ne peuvent rien attraper (défaut de la QA, pas du lot)

`mutant-dedicated-compute`, `mutant-dedicated-compute-multiligne` et `mutant-default-dedicated`
mutent `$work/pane.swift` (ou `$work/engine.swift`) **en place**, mais `run_graph` ne repasse ces
fichiers par un localisateur : le script n'a de surcharge que pour `SERVER`, `DELEGATE`, `APP`,
`ENGINE` et `CORPUS` — **pas `PANE`**. Le contrôle relit donc le vrai panneau de `TEST_ROOT`, inchangé,
et la mutation n'atteint jamais le contrôle visé. Les trois sortent `rc=3` « MUTANT NON capturé »,
alors que le contrôle lui-même est **discriminant** : vérifié par sonde, en remplaçant l'argument
dans une copie de l'arbre et en la passant par `MURMURE_STARTUP_ROOT` (l'unique localisateur qui
porte sur l'arbre entier) :

```
VERT  contrôle=video-uses-shared-engine
ROUGE contrôle=video-compute-not-dedicated détail=… dedicatingComputeUnits EXPLICITE et non false
CONTRÔLE=27/28
```

Donc le contrôle est vivant, la charge utile du mutant ne l'atteint pas. `mutant-sous-dossier-video`,
qui utilise `MURMURE_STARTUP_CORPUS`, tombe bien — ce qui confirme le diagnostic : ce sont les trois
mutants à mutation **en place** sur le panneau qui sont inopérants. Je n'ai **pas** touché au script
QA (interdit sans finding ; il est écrit par `t_aeb3aea0`).

## Finding 2 — la phrase « preparing model » du panneau devient inatteignable (conséquence du critère 1)

Le moteur partagé annonce sa préparation par le closure de la **dictée** (`StatusRouter`, notch,
status panel). Le `preparation` du **panneau** n'était alimenté que par la construction locale
supprimée ici : `MurmureApp.swift:355` (`StatusPanelText.label(for: .preparingModel(…))`) ne
s'affichera plus pendant une première transcription vidéo. La barre indéterminée, elle, reste
(`transcriptsModel.isWorking`). Rétablir la phrase demanderait une seconde surface d'observation
sur le moteur de la dictée — hors des cinq fichiers de la carte. **Signalé, non absorbé.**

## Périmètre

`cmp` sur tous les `.swift` contre `t_7785056d` : seuls mes 4 fichiers diffèrent, plus
`MurmureCore/Package.swift` — dont le contenu est **identique à `t_d1dbdc77`** (transport L11-R,
`cmp` = 0). `project.yml` = `t_d1dbdc77` (`279d0a48…`). Aucun commit, aucun push. HEAD `8117857`.
