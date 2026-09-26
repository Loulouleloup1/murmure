import Foundation
import MurmureCore
import os

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "transcription")

/// Le déroulé d'un travail de transcription vidéo, de bout en bout : acquisition → décodage →
/// carte de silence → unités → assemblage → écriture des **deux** fichiers → suppression de l'audio
/// (plan §2.1, §2.4 et §4 lot 8).
///
/// **Ce fichier ne décide de rien.** Où couper, dans quel ordre, ce qu'est un état reprisable,
/// comment recoller les horodatages et comment un document se nomme sont les décisions de
/// `VideoTranscriptionPlan`, `TranscriptAssembly`, `TranscriptJobState` (lot 3), `TranscriptLibrary`,
/// `TranscriptWorkDirectory`, `TranscriptCoverage` (lot 2), `AcquisitionService` (lot 6),
/// `SilenceMapBuilder`/`UnitSlicer` (lot 7) et `FfmpegCommand` (lot 4). Ici il n'y a que
/// l'enchaînement, et deux choses qui n'appartiennent qu'à lui :
///
/// 1. **le rythme des écritures** : `progress.json` et le document final sont réécrits **après
///    chaque unité** (`status: "inProgress"`, puis `"complete"`). C'est ce rythme qui rend la
///    reprise exacte : un travail interrompu reste lisible, et la relance repart de la première
///    unité non terminée **sans re-télécharger ni re-décoder** (plan §2.1, R7). **Et leur ordre en
///    est un** : le document d'abord — c'est lui qui porte les segments —, `progress.json` ensuite.
///    Le point de reprise n'est ainsi jamais en avance sur les segments écrits ; au pire il est en
///    retard d'une unité, et la relance la rejoue (absorbée par `TranscriptAssembly.merge`, règle 3) ;
/// 2. **la lecture de la langue à la reprise** : le document existant dit *avec quelle langue*,
///    `progress.json` dit *où* reprendre. La langue n'est **jamais re-détectée** (§2.1, décision
///    N1) — sinon un travail repris basculerait dans une autre langue que celle sous laquelle ses
///    unités déjà écrites ont été transcrites.
///
/// **Rien de ce qui se transcrit n'est journalisé** (critère 15, AGENTS.md) : les journaux de ce
/// fichier ne portent que des index, des durées, des comptes et des codes de sortie.
actor TranscriptJobRunner {
    /// Ce dont le travail a besoin et qu'il ne fabrique pas : la bibliothèque (qui décide du
    /// nommage et de la racine R3), le décodeur ffmpeg embarqué (critère 4), la racine
    /// d'`Application Support` (où vit `yt-dlp`) et le nom du modèle réellement utilisé, écrit tel
    /// quel dans le document (un repli du moteur doit se voir dans l'historique).
    struct Configuration {
        var library: TranscriptLibrary
        var ffmpeg: URL
        var applicationSupport: URL
        var model: String
        var nominalStep: Double = VideoTranscriptionPlan.nominalStep

        init(
            library: TranscriptLibrary,
            ffmpeg: URL,
            applicationSupport: URL,
            model: String,
            nominalStep: Double = VideoTranscriptionPlan.nominalStep
        ) {
            self.library = library
            self.ffmpeg = ffmpeg
            self.applicationSupport = applicationSupport
            self.model = model
            self.nominalStep = nominalStep
        }
    }

    /// Ce qu'un travail qui s'arrête laisse derrière lui. Les deux cas ont écrit un document ; ils
    /// ne disent pas la même chose de la suite.
    enum Outcome {
        /// Le travail est allé au bout : document `complete`, deux fichiers sur disque, répertoire
        /// de travail supprimé (R7 : seulement après succès vérifié).
        case complete(TranscriptDocument)
        /// L'arrêt a été demandé : document `inProgress` sur disque, et le répertoire de travail
        /// **conservé** — l'audio, les tranches et `progress.json` sont le point de reprise.
        case stopped(TranscriptDocument)
    }

    /// Ce que le travail annonce pendant qu'il tourne. Rien n'est décidé ici non plus : le lot 10
    /// branchera ces événements sur la progression et la notification (critère 18).
    enum Event: Equatable {
        case acquiring
        /// La durée du WAV **décodé** : la seule qui compte pour les coupes et la couverture.
        case decoded(seconds: Double)
        case planned(units: Int)
        case resuming(atUnit: Int, of: Int)
        case unitCompleted(index: Int, of: Int)
        case stopRequested
        case completed(units: Int)
    }

    enum Failure: LocalizedError, Equatable {
        case malformedDecodedWav(String)
        case decodeFailed(exitCode: Int32, excerpt: String)
        case sliceFailed(String)
        case progressWriteFailed(String)
        case writeNotVerified(String)
        /// Un document reprisable sans langue ne peut pas être décodé sans re-détecter — ce que
        /// §2.1 interdit. On le dit au lieu de le faire.
        case resumableDocumentWithoutLanguage(String)
        /// Les vingt tiges de la source sont prises : la bibliothèque refuse de nommer un
        /// vingt-et-unième fichier plutôt que d'en écraser un
        /// (`TranscriptFilenameError.allNamesTaken`). **Rapporté, jamais fatal** : la passe finit
        /// sur une erreur nommée, elle ne tue pas le processus (plan §4 lot 2/8-R). Il faut vingt
        /// transcripts **terminés** (ou étrangers) de cette source sous la même tige de base pour y
        /// arriver — une suite d'écritures du même travail ne l'atteint plus.
        case namingExhausted(base: String, folder: String)

        var errorDescription: String? {
            switch self {
            case .malformedDecodedWav(let reason):
                "The decoded audio is not a readable 16 kHz mono PCM WAV: \(reason)"
            case .decodeFailed(let code, let excerpt):
                "Could not decode the source audio (ffmpeg exit \(code)): \(excerpt)"
            case .sliceFailed(let reason):
                "Could not cut the audio into units: \(reason)"
            case .progressWriteFailed(let reason):
                "Could not write the resume point: \(reason)"
            case .writeNotVerified(let reason):
                "The transcript was not written as expected: \(reason)"
            case .resumableDocumentWithoutLanguage(let id):
                "The interrupted transcript « \(id) » carries no language: resuming it would mean "
                    + "detecting the language again, which the plan forbids"
            case .namingExhausted(let base, let folder):
                "No free name left for « \(base) » in \(folder): twenty transcripts of this source "
                    + "already occupy its stem. Delete one of them in the transcript library, then "
                    + "start the transcription again."
            }
        }
    }

    private let configuration: Configuration
    private let transcriber: VideoTranscriber

    /// Le frein de l'exécution en cours, et **rien de plus** : `nil` quand aucun travail ne tourne.
    ///
    /// **Un frein par exécution, jamais un frein d'acteur.** ``TranscriptionStop`` est monotone —
    /// `request()` ne se déarme pas — donc un frein gardé au niveau de l'acteur resterait armé pour
    /// la vie du runner : la boucle d'unités le consulte avant chaque unité, et **toute** exécution
    /// suivante — la reprise du travail qu'on vient de suspendre comprise — s'arrêterait à sa
    /// première unité en rendant `.stopped` **sans lever d'erreur**. Le frein naît donc dans
    /// ``run(source:title:language:onEvent:)`` et meurt avec elle ; ``requestStop()`` n'arme que
    /// l'exécution qui tourne.
    private var running: TranscriptionStop?

    // MARK: - La priorité dictée / vidéo (lot 12)
    //
    // **Le mécanisme est un paramètre, jamais une bifurcation** : la boucle ne teste pas un cas de
    // politique, elle lit les **valeurs** que `TranscriptPriority` expose (`admission`,
    // `dedicatesComputeUnits`) par la seule question qu'elle pose — « dois-je céder ? ».
    //
    // Le défaut est **(1b) le statu quo** : décision de Louis du 2026-09-21, « une dictée ne doit
    // jamais attendre un verrou pris par la vidéo ». Aucune politique n'a été retenue par la
    // campagne du lot 0 — le point de bascule entre (1b) et (3) est de l'ordre de 1,2 s, plus petit
    // que la dispersion naturelle du corpus réel — et la mesure qui décide est **reportée au lot 8**,
    // où le moteur vidéo tourne dans le processus de l'application.
    private let policy: TranscriptPriority.Policy

    /// Le signal « une dictée est en cours », injecté (voir `DictationSignal`).
    ///
    /// C'est **la seule entrée** de la machine : sans lui, aucune politique à frontière ne pourrait
    /// savoir qu'une voix réclame la machine, et la boucle vidéo n'aurait rien à consulter.
    private let dictation: DictationSignal

    /// La machine de priorité de **l'exécution en cours**, recréée par `run` comme le frein l'est
    /// (voir ``running``) : son état est monotone dans une exécution (`writtenUnits` ne recule pas)
    /// et la garder d'une exécution à l'autre ferait porter à une relance les unités d'un travail
    /// que la bibliothèque vient peut-être de retirer du disque.
    private var priority: TranscriptPriority

    init(
        configuration: Configuration,
        transcriber: VideoTranscriber,
        policy: TranscriptPriority.Policy = TranscriptPriority.defaultPolicy,
        dictation: DictationSignal = .shared
    ) {
        self.configuration = configuration
        self.transcriber = transcriber
        self.policy = policy
        self.dictation = dictation
        self.priority = TranscriptPriority(policy: policy)
    }

    /// Demande l'arrêt propre du travail en cours : l'unité en cours est interrompue (frein au
    /// jeton puis annulation de la `Task`), **rien n'est perdu de ce qui est déjà écrit**, et le
    /// travail rend `.stopped` avec un document `inProgress` sur disque.
    ///
    /// **Sans travail en cours, c'est un non-événement** : le frein appartient à l'exécution (voir
    /// ``running``), pas à l'acteur, donc il n'y en a aucun à armer. Corollaire, et c'est ce que la
    /// propriété par exécution achète : une exécution lancée **après** une demande d'arrêt travaille
    /// normalement — elle porte un frein neuf, non armé.
    func requestStop() async {
        guard let running else { return }
        await transcriber.requestStop(running)
    }

    /// Déroule un travail pour `source`.
    ///
    /// - Parameters:
    ///   - source: la source canonique (le `kind`/`identity` du §2.4). Un fichier local ne touche
    ///     aucun réseau : `AcquisitionService` rend le fichier avant qu'aucun processus n'existe.
    ///   - title: le titre du transcript (métadonnée `yt-dlp`, ou nom de fichier pour un local).
    ///   - language: une langue **explicite**. À son horloge, aucune surface ne la porte (le CLI
    ///     est le lot 11) : `nil` est le cas normal, et il veut dire « relis le document si le
    ///     travail est repris, sinon détecte ».
    func run(
        source: TranscriptSource,
        title: String,
        language: String? = nil,
        onEvent: @escaping @Sendable (Event) -> Void = { _ in }
    ) async throws -> Outcome {
        // Le frein de **cette** exécution (voir ``running``) : créé avant tout travail, il est
        // armable par ``requestStop()`` dès que l'exécution existe — acquisition comprise — et il
        // meurt avec elle. Un frein neuf à chaque `run` est ce qui garantit qu'une demande d'arrêt
        // ne survit pas à l'exécution qu'elle visait.
        let stop = TranscriptionStop()
        running = stop
        defer { running = nil }

        let resume = resumable(source: source, title: title)
        // Une reprise garde la tige **et** la date de création du document existant : c'est ce qui
        // fait retomber `TranscriptLibrary.write` sur la même tige (plan §2.4, arbitrage N1) au
        // lieu de suffixer un second transcript pour la même vidéo. Son répertoire de travail est
        // celui que ``workDirectory(for:launchTitle:)`` retrouve — nommé avec le titre de
        // l'**appelant**, celui que la reprise redonne à l'identique ; un travail neuf, lui, part
        // sous le stem calculé au lancement.
        let work = resume.map { workDirectory(for: $0.document, launchTitle: title).directory }
            ?? TranscriptWorkDirectory(
                base: configuration.library.base,
                jobID: TranscriptFilenames.stem(
                    title: title, date: Date(), identity: source.identity))
        try work.create()

        // MARK: 1. Acquisition
        onEvent(.acquiring)
        let acquired = try await AcquisitionService.acquire(
            source, into: work.directoryURL, applicationSupport: configuration.applicationSupport)

        // MARK: 1 bis. Le titre de la source — résolu **une seule fois**, ici
        //
        // C'est le point du lot 8-T. `Acquired.metadata` porte le titre `yt-dlp`, lu par
        // l'acquisition dans la **même** invocation que l'audio ; avant cette carte, personne ne le
        // lisait et le document était écrit avec le titre de l'appelant — vide pour un lien, parce
        // qu'au moment où la file reçoit le travail l'acquisition n'a pas encore tourné. La tuile
        // était sans titre (critère 16), le corps de la notification vide (critère 18), et la tige
        // tombait sur le repli « identité » du §2.4.
        //
        // La décision est dans le cœur (`TranscriptJobTitle`, pur donc testé) ; ici il n'y a que
        // l'appel, et il n'y en a **qu'un** : les cinq écritures du document reçoivent la même
        // valeur, et `persist` ne la recalcule pas. Deux calculs d'un même titre, c'est un calcul de
        // trop — c'est exactement ce qui laissait le titre de la reprise l'emporter sur celui de la
        // source sans que rien ne le dise.
        let titre = TranscriptJobTitle.resolve(
            resumed: resume?.document.title,
            acquisition: acquired.metadata?.title,
            caller: title)

        // MARK: 2. Décodage (jamais rejoué à la reprise : le WAV du répertoire de travail est réutilisé)
        let decoded = work.directoryURL.appendingPathComponent(Self.decodedName)
        if !FileManager.default.fileExists(atPath: decoded.path) {
            try decode(acquired.audio, to: decoded)
        }
        let duration = try Self.duration(ofDecodedWav: decoded)
        onEvent(.decoded(seconds: duration))

        // MARK: 3. Carte de silence, puis plan de morceaux
        //
        // La carte se mesure sur le **WAV décodé** (§2.1) : les coupes tombent ainsi sur la grille
        // d'échantillons, et le recollage des horodatages est exact sur toute la longueur.
        let analysis = try SilenceMapBuilder.analyze(
            wav: decoded, duration: duration, ffmpeg: configuration.ffmpeg)

        // MARK: 4. État et plan
        //
        // À la reprise, **le plan est celui de `progress.json`**, pas un plan recalculé : c'est le
        // point de reprise gelé, et deux calculs ne doivent pas pouvoir diverger sur des unités
        // déjà transcrites.
        var state: TranscriptJobState
        if let stored = readState(at: work.progressURL) {
            state = stored
            state.resume()
            if let index = state.nextUnitIndex {
                onEvent(.resuming(atUnit: index, of: state.units.count))
            }
        } else {
            state = TranscriptJobState(
                units: VideoTranscriptionPlan.units(
                    duration: duration, silences: analysis.intervals, nominal: configuration.nominalStep))
            try write(state, to: work.progressURL)
        }
        onEvent(.planned(units: state.units.count))

        // MARK: 5. Tranches
        //
        // Le dossier des tranches se lit à travers la convention du lot 2 (`unitURL(index:)`)
        // plutôt qu'en écrivant « units » ici : deux orthographes d'un même chemin finiraient par
        // diverger. `UnitSlicer.write` est déterministe et idempotent — une reprise repasse par lui
        // sans rien casser, et les tranches déjà écrites sont réécrites à l'identique.
        let slices: [UnitSlicer.Slice]
        do {
            slices = try UnitSlicer.write(
                wav: decoded,
                units: state.units,
                into: work.unitURL(index: 0).deletingLastPathComponent(),
                ffmpeg: configuration.ffmpeg)
        } catch {
            throw Failure.sliceFailed(String(describing: error))
        }

        // MARK: 6. La langue — décidée une fois, puis relue
        let resolved = try await resolveLanguage(
            explicit: language, resume: resume, firstUnit: slices.first?.url)

        // MARK: 7. Les unités — sous la priorité dictée / vidéo (lot 12)
        //
        // La machine est **recréée par exécution**, comme le frein : son état est celui de
        // ce travail-là, et rien d'autre. Le travail vidéo **commence** au sens de la machine
        // ici même : c'est à partir de ce point qu'il tourne, donc qu'il peut être suspendu.
        // Le déclarer plus tôt (acquisition, décodage, découpe) en ferait un travail « en
        // cours » pendant des minutes où il ne consomme pas un neurone, et une dictée paierait
        // une suspension pour rien.
        priority = TranscriptPriority(policy: policy)
        priority.videoBegan()
        var transcribed = previousUnits(from: resume)

        while let index = state.nextUnitIndex {
            // Le frein est consulté avant chaque unité : une demande d'arrêt arrivée pendant
            // l'écriture de l'unité précédente (le document, son point de reprise) s'arrête ici,
            // proprement, sans entamer l'unité suivante.
            if stop.isRequested {
                onEvent(.stopRequested)
                state.pause()
                // Le document d'abord, le point de reprise ensuite — même règle qu'à l'unité
                // terminée ci-dessous : le document est le record des segments, `progress.json`
                // n'est que l'index d'où reprendre et ne doit jamais être en avance sur lui.
                let document = try persist(
                    state: state, resume: resume, source: source, title: titre, duration: duration,
                    language: resolved.language, forced: resolved.forced, status: .inProgress,
                    units: transcribed, completedAt: nil)
                try write(state, to: work.progressURL)
                return .stopped(document.document)
            }

            // ── La frontière de priorité (lot 12) ────────────────────────────────────────────
            //
            // **Une seule question, posée là où la vidéo peut céder** : la frontière d'unité, le
            // seul endroit où la boucle peut s'arrêter sans couper un morceau en deux. La réponse
            // vient de la **politique** et du signal de dictée injecté ; sous le défaut câblé
            // (1b), elle est toujours non et la boucle ne paie qu'une lecture.
            if await frontier(ofUnit: index) {
                // La vidéo a cédé : suspendue, la dictée a fini, elle vient de reprendre — et
                // elle **rejoue cette unité**, qui n'a jamais été écrite.
                continue
            }

            let slice = slices[index]
            let outcome = try await transcriber.transcribe(
                unit: slice.url,
                duration: slice.duration,
                language: resolved.language,
                stop: stop,
                onProgress: { _ in })

            switch outcome {
            case .completed(let decoded):
                // ── La reprise d'une fenêtre sautée par le moteur (plan §2.1 révision 9, lot 8-R) ──
                //
                // Elle se place **entre le décodage de l'unité et son écriture**, et c'est ce qui
                // fait qu'une unité s'écrit une seule fois, avec ce qu'elle a de définitif. Le
                // défaut mesuré : WhisperKit saute une fenêtre entière de 30 s quand sa probabilité
                // de non-parole dépasse `noSpeechThreshold`, et sur la vidéo A la fenêtre sautée
                // portait de la parole — 24,4 s ou 30,0 s perdus, critère 9 mesuré à 0,9573 / 0,9680
                // / 0,9800 selon la passe. La détection et la décision sont dans le cœur
                // (`UnitSpeechRecovery`, testé) ; ici il n'y a que l'enchaînement.
                let segments: [TranscriptSegment]
                do {
                    segments = try await recoverSkippedWindow(
                        decoded, on: slice, boundary: state.units[index], index: index,
                        silences: analysis.intervals, language: resolved.language, stop: stop)
                } catch is CancellationError {
                    // **Le frein garde le même sens** : une demande d'arrêt pendant la reprise suit
                    // le chemin de `.stopped` — le document d'abord, `progress.json` ensuite, et
                    // l'unité **non écrite** sera rejouée à la relance (plan §2.1, « perte maximale =
                    // l'unité en cours »). Le point de reprise ne bouge pas : `state.pause()` laisse
                    // `nextUnitIndex` sur cette unité.
                    onEvent(.stopRequested)
                    state.pause()
                    let document = try persist(
                        state: state, resume: resume, source: source, title: titre,
                        duration: duration, language: resolved.language, forced: resolved.forced,
                        status: .inProgress, units: transcribed, completedAt: nil)
                    try write(state, to: work.progressURL)
                    return .stopped(document.document)
                }
                transcribed.append(
                    TranscribedUnit(boundary: state.units[index], segments: segments))
                state.advance()
                // Les deux écritures, dans cet ordre : **le document d'abord, le point de reprise
                // ensuite**. L'ordre est l'invariant, pas un détail : le document est le record des
                // segments de l'unité, `progress.json` n'est que l'index d'où reprendre, et il ne
                // doit **jamais** être en avance sur lui. Une interruption entre les deux — mort du
                // processus, `SIGKILL`, ou le document qui ne s'écrit pas (`persist` jette, l'erreur
                // remonte hors de `run`, le répertoire de travail est conservé) — laisse alors
                // `progress.json` **en retard** d'une unité : la relance rejoue l'unité en cours et
                // le rejeu est absorbé par `TranscriptAssembly.merge` (règle 3 : mêmes débuts
                // absolus → un seul segment conservé). Dans l'autre sens, l'intervalle audio de
                // l'unité `i` ne serait ni transcrit ni rejoué — perdu en silence, sans erreur, sans
                // journal, et `verifyWritten` ne regarde que le statut des deux fichiers.
                _ = try persist(
                    state: state, resume: resume, source: source, title: titre, duration: duration,
                    language: resolved.language, forced: resolved.forced, status: .inProgress,
                    units: transcribed, completedAt: nil)
                try write(state, to: work.progressURL)
                onEvent(.unitCompleted(index: index, of: state.units.count))

            case .stopped:
                onEvent(.stopRequested)
                state.pause()
                // Même ordre qu'au-dessus : le document (qui porte les segments déjà payés) avant le
                // point de reprise.
                let document = try persist(
                    state: state, resume: resume, source: source, title: titre, duration: duration,
                    language: resolved.language, forced: resolved.forced, status: .inProgress,
                    units: transcribed, completedAt: nil)
                try write(state, to: work.progressURL)
                return .stopped(document.document)
            }
        }

        // MARK: 8. Le document terminé, écrit, vérifié, et alors seulement l'audio supprimé
        let final = try persist(
            state: state, resume: resume, source: source, title: titre, duration: duration,
            language: resolved.language, forced: resolved.forced, status: .complete,
            units: transcribed, completedAt: Date())
        try verifyWritten(final)
        onEvent(.completed(units: state.units.count))
        logger.info(
            """
            transcript \(final.document.id, privacy: .public) written: \
            \(state.units.count, privacy: .public) unit(s)
            """)

        // R7 : la suppression de l'audio et des tranches est la **dernière** chose, et elle suit un
        // succès vérifié — deux fichiers relus sur disque, pas le seul retour d'écriture.
        work.remove()
        return .complete(final.document)
    }

    /// La **frontière de priorité** : la seule question que la boucle vidéo pose au sujet de la
    /// dictée, posée à l'endroit où la vidéo peut céder sans couper un morceau en deux.
    ///
    /// Elle ne décide pas de la mécanique : elle lit la **valeur** d'admission de la politique
    /// (`shouldYield`), jamais son cas — d'où l'absence de `switch` sur la politique dans cette
    /// fonction (plan §7.1 règle 5 : le mécanisme est un paramètre). La seule chose qui dépend de la
    /// politique est la **construction du moteur** (instance partagée ou dédiée).
    ///
    /// - Parameter index: l'unité qui **allait partir**. C'est elle qu'une préemption (1a)
    ///   interrompt : annoncée en cours d'unité, elle devient l'unité à rejouer, et elle ne sera
    ///   rejouée qu'**une fois** — le point de reprise n'a pas bougé.
    /// - Returns: `true` quand l'appelant doit **rejouer** l'unité `index` (la vidéo a cédé avant
    ///   de l'écrire).
    private func frontier(ofUnit index: Int) async -> Bool {
        guard dictation.isDictating else {
            // Aucune dictée : si la machine en tenait une, elle vient de finir — et c'est ici,
            // seule entrée de la machine, qu'elle l'apprend. Sans dictée servie, c'est un
            // non-événement (la comparaison coûte une lecture de drapeau).
            priority.dictationEnded()
            return false
        }

        // L'unité entre en traitement **avant** la question : c'est elle qu'une préemption
        // interrompt, donc la seule qui pourra être rejouée.
        priority.unitBegan(index)
        priority.dictationBegan()

        // La question de la boucle vidéo. Elle lit la **valeur** d'admission de la politique
        // (`shouldYield`), jamais son cas.
        let cede = priority.shouldYield(dictationPending: dictation.isDictating)
        // La frontière est annoncée **dans tous les cas** : c'est là qu'une dictée en attente est
        // admise — sous (1a) en suspendant la vidéo, sous (3) en la laissant tourner.
        priority.frontierReached()
        guard cede else { return false }

        // (1a) seulement : la vidéo se suspend et la voix a la machine. On attend la fin de la
        // dictée, puis on **reprend dans la même exécution** — le frein n'est pas armé, c'est ce
        // qui distingue une suspension d'un arrêt. `waitUntilIdle` est annulable : un travail vidéo
        // annulé ne reste pas suspendu sur une attente qui ne finit pas.
        let politique = priority.policy.rawValue
        logger.info("""
            priority: video yielding to dictation — unit \(index, privacy: .public) not written \
            and will be replayed, policy \(politique, privacy: .public)
            """)
        await dictation.waitUntilIdle()
        priority.dictationEnded()
        priority.videoResumed()
        return true
    }

    // MARK: - Les étapes qui ne décident pas

    /// Décode la source en WAV 16 kHz mono dans le répertoire de travail (lot 4 pour l'invocation).
    private func decode(_ input: URL, to output: URL) throws {
        let invocation = FfmpegCommand.decodeToWav16kMono(input, to: output, ffmpeg: configuration.ffmpeg)
        let result: SubprocessResult
        do {
            result = try Subprocess.run(
                invocation.executable, arguments: invocation.arguments, timeout: Self.decodeTimeout)
        } catch {
            throw Failure.decodeFailed(exitCode: -1, excerpt: error.localizedDescription)
        }
        guard !result.timedOut, result.exitCode == 0 else {
            throw Failure.decodeFailed(
                exitCode: result.exitCode, excerpt: String(result.stderr.prefix(Self.excerptLimit)))
        }
    }

    /// La langue du travail, décidée **une fois** : option explicite, sinon le document repris,
    /// sinon la détection automatique (critère 12).
    private func resolveLanguage(
        explicit: String?, resume: Resume?, firstUnit: URL?
    ) async throws -> (language: String, forced: Bool) {
        if let explicit, !explicit.isEmpty { return (explicit, true) }
        if let document = resume?.document {
            let stored = document.language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stored.isEmpty else {
                throw Failure.resumableDocumentWithoutLanguage(document.id)
            }
            return (stored, document.languageWasForced)
        }
        guard let firstUnit else {
            // Aucune unité : rien à détecter, et rien à transcrire — le document se terminera vide
            // de segments, ce que `VideoTranscriptionPlan.units` ne produit que pour une durée nulle.
            return (Self.undeterminedLanguage, false)
        }
        return (try await transcriber.detectedLanguage(of: firstUnit), false)
    }

    /// La reprise d'une unité : détecte l'intervalle non couvert, décide s'il vaut la peine d'être
    /// rejoué, le rejoue, et rend la liste de l'unité **recousue** (plan §2.1 révision 9, §4 lot 8-R).
    ///
    /// **L'ordre de la chaîne est celui de `UnitSpeechRecovery`, et il est porteur :**
    /// ``UnitSpeechRecovery/rebased(silences:on:)`` (les silences du lot 7, en temps absolu, ramenés
    /// au temps de l'unité) → ``UnitSpeechRecovery/uncovered(segments:duration:)`` (le complément de
    /// l'union des segments — une **position**, pas un nombre) →
    /// ``UnitSpeechRecovery/toReplay(segments:duration:silences:minimum:)`` (les trous qui portent
    /// ≥ 5,0 s d'audio que la carte de silence ne déclare pas silence — le plafond des pauses
    /// naturelles, §2.1) →
    /// ``UnitSpeechRecovery/merging(unit:replayed:in:duration:)`` (le rognage à l'intervalle rejoué
    /// puis le dédoublonnage entre rejoués).
    ///
    /// **Rien n'est réexaminé.** Une seule passe : la sortie d'une reprise n'est pas redécoupée
    /// (`toReplay` n'est calculé qu'une fois, sur les segments **décodés**). Une reprise qui ne rend
    /// rien laisse le trou en place, et c'est borné : au plus 5,0 s par unité non rejouable, 0,22 % de
    /// 2 292,6 s, dans la marge de 3 % du critère 9.
    ///
    /// - Throws: `CancellationError` quand le frein est armé avant ou pendant la reprise — l'appelant
    ///   suit alors le chemin de `.stopped`.
    private func recoverSkippedWindow(
        _ segments: [TranscriptSegment],
        on slice: UnitSlicer.Slice,
        boundary: UnitBoundary,
        index: Int,
        silences: [ClosedRange<Double>],
        language: String,
        stop: TranscriptionStop
    ) async throws -> [TranscriptSegment] {
        // `slice.duration` est la durée **exacte** de l'unité (le nombre d'échantillons réellement
        // écrits dans sa tranche, `UnitSlicer.align`) : c'est la seule borne qui vaille pour ce
        // calcul, exactement comme pour la transcription de l'unité.
        let trous = UnitSpeechRecovery.uncovered(segments: segments, duration: slice.duration)
        guard !trous.isEmpty else { return segments }

        // Les silences du lot 7 sont en secondes de **l'audio décodé** ; les segments d'une unité
        // sont horodatés depuis son début. L'ordre des deux appels n'est pas commutatif : convertir
        // après avoir décidé ferait comparer des silences absolus à des trous locaux, l'intersection
        // serait vide presque partout, et *tous* les trous seraient rejoués — silences compris.
        let locaux = UnitSpeechRecovery.rebased(silences: silences, on: boundary)
        let aRejouer = UnitSpeechRecovery.toReplay(
            segments: segments, duration: slice.duration, silences: locaux)
        guard !aRejouer.isEmpty else { return segments }

        var recousus = segments
        // `toReplay` rend les trous **dans l'ordre croissant** (celui de `uncovered`), et chacun est
        // rejoué puis fusionné dans la liste courante : la liste passée comme `unit` à `merging` est
        // donc celle de l'unité **déjà recousue**, et les segments précédemment rejoués y sont
        // traités comme des segments de l'unité — jamais rognés, jamais écartés.
        for intervalle in aRejouer {
            let rejoues = try await transcriber.transcribeInterval(
                of: slice.url,
                range: intervalle,
                duration: slice.duration,
                language: language,
                stop: stop)
            let fusionnes = UnitSpeechRecovery.merging(
                unit: recousus, replayed: rejoues, in: intervalle, duration: slice.duration)
            // Ce que le document gagne : `merging` ne retire jamais un segment de l'unité, donc la
            // différence des durées couvertes et des comptes **est** l'apport de la reprise (les
            // rejoués rognés à vide et les doublons entre rejoués n'y sont pas).
            let gagnes = fusionnes.count - recousus.count
            let secondes =
                fusionnes.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
                - recousus.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            recousus = fusionnes
            // Un seul journal de **compte** par intervalle rejoué — unité, intervalle, secondes
            // récupérées, nombre de segments —, et **jamais de texte** (critère 15, AGENTS.md).
            // Aucun événement nouveau non plus : la surface d'`Event` ne bouge pas (le lot 10 reste
            // intact, plan §2.1).
            logger.info(
                """
                recovery: unit \(index, privacy: .public) replayed \
                [\(intervalle.lowerBound, format: .fixed(precision: 1), privacy: .public), \
                \(intervalle.upperBound, format: .fixed(precision: 1), privacy: .public)) s — \
                \(secondes, format: .fixed(precision: 1), privacy: .public) s recovered \
                in \(gagnes, privacy: .public) segment(s)
                """)
        }
        return recousus
    }

    /// Le travail reprisable de cette source : même identité canonique, et un statut qui dit que le
    /// travail n'est pas fini (plan §2.4, arbitrage N1). Un `complete` n'est jamais repris — une
    /// seconde acquisition de la même source produit un second transcript, à côté.
    ///
    /// **La sélection n'est pas faite ici, et n'existe qu'à un endroit** :
    /// ``TranscriptLibrary/resumable(identity:)``, qui retient le plus récent des documents
    /// reprisables (date de création, puis segment le plus loin). Le runner la réécrivait, et deux
    /// copies d'une même règle finissent par diverger ; c'est en plus la bibliothèque qui décide de
    /// la tige **à l'écriture**, donc la seule à savoir de quel document il s'agit (plan §4
    /// lot 2/8-R, règle 9 : un seul propriétaire de la règle).
    ///
    /// Ce qui reste ici est ce que la bibliothèque ne peut pas savoir : le **répertoire de travail**
    /// du document repris — dont le repli par stem est le correctif F3, le répertoire portant le
    /// stem du lancement et non l'`id` suffixé par la bibliothèque — et son point de reprise.
    ///
    /// **`title` est le titre de l'appelant de cette exécution**, et c'est celui qui recompose le nom
    /// du répertoire de travail (voir ``workDirectory(for:launchTitle:)``). Il est disponible
    /// **avant** l'acquisition : la reprise se cherche donc sans réordonnancement, `work.create()`
    /// reste avant l'acquisition, et c'est ce qui permet à une reprise d'écrire ses tranches et son
    /// WAV décodé dans le répertoire où ils sont déjà.
    private struct Resume {
        var document: TranscriptDocument
        var state: TranscriptJobState?
    }

    private func resumable(source: TranscriptSource, title: String) -> Resume? {
        // Délégation, sans seconde copie de la sélection (plan §4 lot 2/8-R, règle 9).
        guard let document = configuration.library.resumable(identity: source.identity) else {
            return nil
        }
        let lookup = workDirectory(for: document, launchTitle: title)
        let state = readState(at: lookup.directory.progressURL)
        // ── Le garde du lot 8-T : le coût R7 reste, il cesse d'être muet ──────────────────────────
        //
        // Les deux titres **diffèrent désormais** pour un lien (le document porte celui de la
        // source, le lancement la chaîne vide) : c'est le titre de lancement qui nomme le
        // répertoire de travail, et le lookup ci-dessus l'utilise. Si pourtant **aucun** candidat ne
        // porte de `progress.json` alors que le document reprisable porte des segments, la reprise
        // va recalculer son plan et rejouer du travail déjà payé (et re-télécharger l'audio si la
        // source est un lien). On ne peut pas le réparer ici — le seul remède est de retrouver le
        // répertoire — mais on refuse de le taire : l'identifiant du document et les chemins
        // essayés, **jamais** de contenu (critère 15, AGENTS.md).
        if state == nil, !document.segments.isEmpty {
            logger.error(
                """
                resume of \(document.id, privacy: .public) carries \
                \(document.segments.count, privacy: .public) segment(s) but no resume point was \
                found: tried \(lookup.tried.map(\.path).joined(separator: ", "), privacy: .public) \
                — the decoded audio and the units under work/ will be replayed (R7 lost)
                """)
        }
        return Resume(document: document, state: state)
    }

    /// Le répertoire de travail d'un document existant, et ce qui a été essayé pour le trouver.
    ///
    /// **Le document n'est pas toujours le nom du répertoire.** Le répertoire porte le stem calculé au
    /// lancement du travail ; l'`id` du document, lui, est décidé par ``TranscriptLibrary/write(_:)``
    /// **à chaque écriture**, et suffixé (`-2`, `-3`…) quand le stem de base est déjà pris par un
    /// transcript terminé de la même source. Chercher `work/<id>` dans ce cas ne trouve rien —
    /// `readState` rend `nil`, le plan est recalculé, le WAV décodé et les tranches de `work/<stem>`
    /// sont abandonnés, et **tout le travail déjà payé est retranscrit** (R7 : « sans re-télécharger
    /// ni re-décoder »). Les deux candidats sont donc essayés, le premier qui porte réellement un
    /// point de reprise gagne.
    ///
    /// **Le stem est recomposé avec le titre de l'APPELLANT (`launchTitle`), jamais avec
    /// `document.title`** — c'est la moitié obligatoire du lot 8-T, et elle est récente. Depuis que
    /// le document porte le titre de la **source**, les deux titres diffèrent pour un lien : celui
    /// du document est le titre `yt-dlp` (« Apple doit arrêter ça. »), celui du lancement est la
    /// **chaîne vide** (la surface de lancement n'a pas encore la métadonnée). Un lookup qui lirait
    /// `document.title` recomposerait un stem que personne n'a jamais écrit, ne trouverait pas le
    /// `progress.json`, et perdrait R7 **en silence** : WAV décodé et tranches abandonnés, audio
    /// re-téléchargé, tout le travail reprisable rejoué. C'est pour cela que la reprise redonne à
    /// l'identique le titre de sa surface : la même entrée produit le même nom.
    ///
    /// Limite **héritée**, inchangée : la recomposition suppose le **même jour** que le lancement
    /// (`stem` porte `AAAA-MM-JJ`). Elle ne s'aggrave pas ici — c'est `TranscriptFilenames.stem` qui
    /// la porte, et le cas d'un travail reprisable à cheval sur deux jours reste celui du lot 2.
    private func workDirectory(for document: TranscriptDocument, launchTitle: String) -> (
        directory: TranscriptWorkDirectory, tried: [URL]
    ) {
        let base = configuration.library.base
        let parID = TranscriptWorkDirectory(base: base, jobID: document.id)
        if FileManager.default.fileExists(atPath: parID.progressURL.path) {
            return (parID, [parID.progressURL])
        }
        let parStem = TranscriptWorkDirectory(
            base: base,
            jobID: TranscriptFilenames.stem(
                title: launchTitle, date: document.createdAt, identity: document.source.identity))
        if FileManager.default.fileExists(atPath: parStem.progressURL.path) {
            return (parStem, [parID.progressURL, parStem.progressURL])
        }
        // Ni l'un ni l'autre : le répertoire a été supprimé (succès vérifié) ou le travail n'a jamais
        // écrit de plan. `parID` est alors le bon point de départ — c'est le cas d'une reprise qui
        // repart d'un plan neuf, comme avant. L'appelant décide s'il y a lieu de le journaliser
        // (voir ``resumable(source:title:)``) ; ici on rend les deux chemins essayés.
        return (parID, [parID.progressURL, parStem.progressURL])
    }

    /// Les unités déjà transcrites, telles que le document `inProgress` les porte.
    ///
    /// **Le document est leur record** : il est réécrit après chaque unité, avec les segments
    /// **absolus** déjà assemblés (§2.1). On les remet dans l'assemblage sous la forme d'une unité
    /// unique, décalage nul, horodatages déjà absolus : `TranscriptAssembly.merge` les trie, écarte
    /// les recouvrements à la frontière de la reprise et rend un flux unique — sans rejouer une
    /// unité déjà payée (règle 9 : l'assemblage reste le sien, rien n'est réécrit ici).
    private func previousUnits(from resume: Resume?) -> [TranscribedUnit] {
        guard let document = resume?.document, !document.segments.isEmpty else { return [] }
        let coverage = document.segments.map(\.end).max() ?? 0
        return [
            TranscribedUnit(
                boundary: TranscriptDocument.Boundary(start: 0, duration: coverage, quality: .forced),
                segments: document.segments)
        ]
    }

    /// Un document tel qu'il a été écrit : la valeur **relue sur disque** et le chemin de son
    /// `.json`. Relire plutôt que garder la valeur en mémoire, c'est ce qui donne au `id` la tige
    /// que la bibliothèque a réellement retenue (elle seule décide du suffixe de collision), et
    /// ce qui permet à ``verifyWritten(_:)`` de porter sur le fichier, pas sur une intention.
    struct Written {
        var document: TranscriptDocument
        var json: URL
    }

    /// Construit le document, l'écrit par la bibliothèque (qui décide de la tige, des deux formats
    /// et de l'atomicité) et rend ce qui a été écrit, `id` compris.
    ///
    /// **`title` est le titre déjà résolu** par `run` (`TranscriptJobTitle.resolve`, appelée une
    /// fois après l'acquisition) : cette fonction ne le recalcule ni ne le remplace. Le seul autre
    /// champ qui vient du document repris — `id` et `createdAt` — est ce que la reprise doit garder
    /// pour retomber sur la **même** tige (§2.4, arbitrage N1) ; le titre, lui, se **remplit** quand
    /// le document reprisable n'en portait pas (cas (e) du contrat du lot 8-T).
    private func persist(
        state: TranscriptJobState,
        resume: Resume?,
        source: TranscriptSource,
        title: String,
        duration: Double,
        language: String,
        forced: Bool,
        status: TranscriptStatus,
        units: [TranscribedUnit],
        completedAt: Date?
    ) throws -> Written {
        let segments = TranscriptAssembly.merge(units: units)
        let coverage = TranscriptCoverage.of(segments: segments, duration: duration)
        // Les frontières franchies : les coupes des unités terminées, dans l'ordre du plan. La
        // première unité n'en porte pas (elle commence à 0, ce n'est pas une coupe).
        let done = (state.lastCompletedUnit ?? -1) + 1
        let document = TranscriptDocument(
            id: resume?.document.id ?? "",
            // Le titre est celui **reçu**, tel quel : la résolution est faite une seule fois par
            // `run`, après l'acquisition (`TranscriptJobTitle.resolve`), et les cinq écritures d'un
            // travail reçoivent la même valeur. Recalculer ici `resume?.document.title ?? title`
            // faisait bien deux calculs d'un même titre — et c'est celui de la reprise, jamais celui
            // de la source, qui gagnait (nature du défaut du lot 8-T).
            title: title,
            source: source,
            duration: duration,
            language: language,
            languageWasForced: forced,
            model: configuration.model,
            createdAt: resume?.document.createdAt ?? Date(),
            completedAt: completedAt,
            status: status,
            segments: segments,
            coverage: .init(coveredSeconds: coverage.ratio * duration, ratio: coverage.ratio),
            boundaries: Array(state.units.prefix(done).dropFirst()))
        // L'échec de nommage **se rapporte**, il ne se propage pas brut : c'est le seul cas où la
        // bibliothèque refuse d'écrire (vingt tiges prises), et l'appelant a une chose à dire à
        // Louis — quelle tige, quel dossier, et quoi supprimer. Ni `try!` ni `fatalError` : une
        // passe ne meurt pas de ne pas avoir pu nommer un fichier (plan §4 lot 2/8-R).
        let url: URL
        do {
            url = try configuration.library.write(document)
        } catch TranscriptFilenameError.allNamesTaken(let base) {
            throw Failure.namingExhausted(base: base, folder: configuration.library.base.path)
        }
        logger.info(
            """
            \(status.rawValue, privacy: .public) document written (\(segments.count, privacy: .public) \
            segment(s), \(done, privacy: .public)/\(state.units.count, privacy: .public) unit(s))
            """)
        // Le `id` que le document porte **est** la tige retenue par la bibliothèque : on la relit
        // depuis le fichier écrit plutôt que de la recalculer (deux calculs de nommage, c'est un
        // calcul de trop).
        return Written(document: readDocument(at: url) ?? document, json: url)
    }

    /// Succès vérifié (R7) : les deux fichiers du transcript sont sur disque **et** le document
    /// relu est terminé. C'est ce contrôle qui autorise la suppression de l'audio, jamais le seul
    /// retour d'une écriture.
    private func verifyWritten(_ written: Written) throws {
        let markdown = written.json.deletingPathExtension().appendingPathExtension("md")
        guard FileManager.default.fileExists(atPath: written.json.path) else {
            throw Failure.writeNotVerified("missing \(written.json.path)")
        }
        guard FileManager.default.fileExists(atPath: markdown.path) else {
            throw Failure.writeNotVerified("missing \(markdown.path)")
        }
        guard let onDisk = readDocument(at: written.json), onDisk.status == .complete else {
            throw Failure.writeNotVerified("the document on disk does not read back as complete")
        }
    }

    // MARK: - Lecture et écriture du point de reprise

    /// Réécrit `progress.json` **entièrement**, par remplacement : un lecteur ne voit jamais un
    /// point de reprise tronqué, et une reprise qui lit l'ancien lit l'ancien **complet**.
    private func write(_ state: TranscriptJobState, to url: URL) throws {
        do {
            try Self.atomic(Self.encoder.encode(state), to: url)
        } catch {
            throw Failure.progressWriteFailed(error.localizedDescription)
        }
    }

    private func readState(at url: URL) -> TranscriptJobState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Un `progress.json` illisible n'est **pas** rattrapé en silence : il est traité comme
        // absent, et le plan est alors recalculé — déterministe sur le même audio — tandis que le
        // document, lui, garde la langue et la date de création. C'est le seul état dont on sait
        // qu'il est sûr à recalculer.
        return try? Self.decoder.decode(TranscriptJobState.self, from: data)
    }

    private func readDocument(at url: URL) -> TranscriptDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(TranscriptDocument.self, from: data)
    }

    private static func atomic(_ content: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaire = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        try content.write(to: temporaire, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaire)
    }

    /// Les dates du document sont ISO-8601 (contrainte du lot 1) : le même décodeur sert à relire
    /// un document reprisable et à vérifier ce qui vient d'être écrit.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - La durée du WAV décodé

    /// La durée du WAV **décodé** (16 kHz mono, PCM signé 16 bits), lue dans son en-tête.
    ///
    /// C'est la seule durée qui ait un sens ici : les coupes du lot 3 tombent sur la grille
    /// d'échantillons de **ce** fichier, et le recollage des horodatages se mesure contre lui. Une
    /// durée annoncée par la source (la métadonnée `yt-dlp`) n'est qu'à ± 1 s (critère 1) — assez
    /// pour décaler les horodatages de la fin d'une vidéo de 2 h.
    ///
    /// L'en-tête est le nôtre : c'est ffmpeg qui vient d'écrire ce fichier, sur un format demandé
    /// par `FfmpegCommand.decodeToWav16kMono` (lot 4). Rien n'est deviné, et tout ce qui ne colle
    /// pas est une **erreur** : un WAV stéréo ou 8 bits donnerait une grille fausse, donc des
    /// horodatages faux que personne ne verrait.
    static func duration(ofDecodedWav url: URL) throws -> Double {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Failure.malformedDecodedWav("unreadable: \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        let header: Data
        do {
            header = try handle.read(upToCount: 64 * 1024) ?? Data()
        } catch {
            throw Failure.malformedDecodedWav("unreadable: \(error.localizedDescription)")
        }
        guard header.count >= 12 else {
            throw Failure.malformedDecodedWav("shorter than a RIFF header")
        }
        func chaine(_ offset: Int) -> String {
            String(decoding: header[offset..<(offset + 4)], as: UTF8.self)
        }
        func uint32(_ offset: Int) -> Int {
            Int(UInt32(header[offset]) | UInt32(header[offset + 1]) << 8
                | UInt32(header[offset + 2]) << 16 | UInt32(header[offset + 3]) << 24)
        }
        func uint16(_ offset: Int) -> Int {
            Int(UInt16(header[offset]) | UInt16(header[offset + 1]) << 8)
        }
        guard chaine(0) == "RIFF", chaine(8) == "WAVE" else {
            throw Failure.malformedDecodedWav("not a RIFF/WAVE file")
        }

        var canaux = 0
        var bits = 0
        var position = 12
        while position + 8 <= header.count {
            let identifiant = chaine(position)
            let taille = uint32(position + 4)
            let charge = position + 8
            if identifiant == "fmt ", charge + 16 <= header.count {
                canaux = uint16(charge + 2)
                bits = uint16(charge + 14)
            }
            if identifiant == "data" {
                guard canaux == 1, bits == 16 else {
                    throw Failure.malformedDecodedWav(
                        "expected 16-bit mono, read \(bits)-bit \(canaux)-channel")
                }
                // La taille du bloc `data` est celle qu'ffmpeg a réécrite en refermant le fichier.
                // Quand elle ne l'est pas (0, ou la sentinelle 0xFFFFFFFF d'un flux), elle se
                // déduit de la taille du fichier — et si les deux se contredisent, on le dit.
                var octets = taille
                if octets <= 0 || octets == 0xFFFF_FFFF {
                    let attributs = try? FileManager.default.attributesOfItem(atPath: url.path)
                    let surDisque = (attributs?[.size] as? NSNumber)?.intValue
                    guard let surDisque, surDisque > charge else {
                        throw Failure.malformedDecodedWav(
                            "data chunk size absent and file size unusable")
                    }
                    octets = surDisque - charge
                }
                return Double(octets / (canaux * bits / 8)) / VideoTranscriptionPlan.sampleRate
            }
            position = charge + taille + (taille % 2)
        }
        throw Failure.malformedDecodedWav("no data chunk")
    }

    /// Le WAV décodé du répertoire de travail (§2.4 : « le silence est détecté sur la source
    /// décodée »). Une reprise le retrouve à ce nom et ne redécode rien.
    private static let decodedName = "source.wav"
    private static let decodeTimeout: TimeInterval = 3_600
    private static let excerptLimit = 2_000

    /// Ce qu'un document porte comme langue quand il n'y a **rien** à décoder (durée nulle) : aucun
    /// segment, donc aucune décision de langue à prendre, et surtout pas une détection inventée.
    static let undeterminedLanguage = "und"
}
