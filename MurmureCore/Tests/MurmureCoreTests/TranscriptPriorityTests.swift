import XCTest

@testable import MurmureCore

/// Contrat rouge du lot 12 : **la priorité dictée / vidéo** (plan §2.2, §4 lot 12 ; SPEC critère 1 ;
/// décision de Louis du 2026-09-21, `docs/specs/2026-09-21-decision-priorite-dictee-video.md`).
///
/// Ce que ces tests protègent, critère par critère :
///
/// | Ce qui est gelé | Où il est éprouvé |
/// |---|---|
/// | **critère 1 de la SPEC** — « la dictée est absolue : le raccourci doit toujours répondre, quelle que soit la charge ; la vidéo se suspend et reprend » | ``testCriteresContratLeRaccourciEstHonoreDepuisChaquePhaseEtSousChaquePolitique``, ``testCriteresContratUneDicteeArrivantSurUneVideoSuspendueEstServieToutDeSuitePartout`` |
/// | **cas obligatoire de la carte** — une dictée déclenchée pendant **chaque phase** : la transition attendue est calculée pour les trois politiques | ``testCriteresContratLAdmissionEstCelleQueChaquePolitiquePromet``, ``…DepuisChaquePhaseEtSousChaquePolitique``, ``…SurUneVideoSuspendue…`` |
/// | **cas obligatoire de la carte** — après reprise, l'unité en cours au moment de la pause est rejouée **une seule fois** | ``testCriteresContratLUniteInterrompueEstRejoueeUneSeuleFoisEtJamaisLesUnitesEcrites``, ``testCriteresContratUnePauseSurUneFrontiereSansUniteEnCoursNeRejoueRien`` |
/// | **cas obligatoire de la carte** — deux dictées déclenchées de suite ne perdent pas le travail vidéo | ``testCriteresContratDeuxDicteesDeclencheesDeSuiteNePerdentPasLeTravailVideo`` |
/// | **les trois mécanismes** (préemption à la frontière / unités de calcul séparées / file d'attente) restent **représentables en paramètre**, jamais une bifurcation | ``testCriteresContratLesTroisMecanismesSontRepresentablesEnParametreEtRestentDistincts``, plus les trois politiques dans les cas ci-dessus |
/// | **décision du 2026-09-21** — 1b (statu quo) est le **défaut câblé** | ``testCriteresContratLeDefautCableEstLeStatuQuoEtIlNeFaitJamaisCederLaVideo`` |
/// | **décision du 2026-09-21** — le contrat porte la **raison de l'élimination de 1a** (18,6 s à 93,1 s dérivés, 3 à 16 fois les 5,84 s mesurés) | ``testCriteresContratLeContratPorteLaMesureDuLot0QuiElimineLaPolitique1a`` |
/// | **reprise sans rejouer les unités déjà écrites** | ``…LUniteInterrompue…``, ``…UnePauseSurUneFrontiereSansUniteEnCours…`` |
/// | **la suspension et la reprise** de la vidéo, et sa fin | ``testCriteresContratLaFinDUneDicteeSurUneVideoSuspendueLaisseLaVideoEnPauseJusquALaReprise``, ``testCriteresContratLaFinDuTravailVideoNeCoupePasUneDicteeServie`` |
///
/// Ce que ces tests ne font pas : ils ne câblent rien. `TranscriptionStop`, `TranscriptJobRunner`,
/// `VideoTranscriber`, `WhisperKitEngine` et `DictationController` appartiennent à la carte `dev` —
/// ici, seules les **transitions** de la machine pure sont éprouvées, sur des entiers d'unité, sans
/// audio, sans disque, sans moteur.
///
/// **Aucun cas ne peut bloquer la suite** : tout est synchrone, aucune attente, aucune closure, donc
/// une machine non implémentée rend la main immédiatement (règle 11 du §7.1 : un motif qui
/// n'exécute rien n'est pas un vert, un motif qui ne rend pas la main n'est pas un rouge).
///
/// **Tous les cas ci-dessous échouent sur une assertion explicite** — jamais sur une erreur de
/// compilation, jamais sur un arrêt brutal — tant que les corps sentinelles de
/// `TranscriptPriority.swift` n'ont pas été remplacés par la carte `dev`. Deux précautions pour que
/// le rouge soit **discriminant** et pas seulement présent :
///
/// - aucun tableau n'est indexé (`[0]` sur un résultat vide ferait tomber tout le binaire de tests
///   et masquerait les autres cas, y compris les verts) : tout passe par `.map`, `.count` et des
///   boucles `for` ;
/// - chaque cas porte au moins **une assertion positive** — une valeur que des corps sentinelles ne
///   peuvent pas produire — en plus des assertions négatives : une assertion négative seule
///   (« ça ne cède pas ») serait verte sans aucune implémentation.
final class TranscriptPriorityTests: XCTestCase {
    /// Ce que porte chaque assertion rouge d'aujourd'hui.
    private let contrat = "contrat lot 12 : non implémenté"

    /// Les **trois mécanismes** que la carte doit rendre représentables : préemption à la frontière
    /// d'unité (1a), seconde instance à unités de calcul séparées (2), file d'attente (3).
    private let troisMecanismes: [TranscriptPriority.Policy] = [
        .dictationWaitsForUnitBoundary,
        .separateComputeUnits,
        .dictationQueuedForWindowEnd,
    ]

    /// Les quatre cas de la politique, **dans l'ordre du plan** (§2.2 et décision du 2026-09-21).
    private let quatrePolitiques: [TranscriptPriority.Policy] = [
        .dictationWaitsForUnitBoundary,
        .sharedMachine,
        .separateComputeUnits,
        .dictationQueuedForWindowEnd,
    ]

    /// Les quatre phases, dans l'ordre de la carte (« idle | dictating | videoRunning | videoPaused »).
    private let quatrePhases: [TranscriptPriority.Phase] = [
        .idle, .dictating, .videoRunning, .videoPaused,
    ]

    // MARK: - Arrangement

    /// Une machine **déjà dans** la phase demandée, sous la politique demandée.
    ///
    /// Le même arrangement vaut pour toutes les politiques : arriver dans une phase n'utilise
    /// jamais une décision d'admission (sauf pour `.dictating`, qui n'a pas d'autre entrée — être
    /// dans `.dictating` **est** avoir servi une dictée). Une panne d'arrangement ne peut donc pas
    /// se lire comme une panne de transition.
    ///
    /// État de départ commun aux phases vidéo : unités **0 et 1 écrites**, unité **2 en cours**
    /// (jamais écrite) — de quoi rendre observable « l'unité en cours au moment de la pause ».
    private func machine(
        _ policy: TranscriptPriority.Policy, dans phase: TranscriptPriority.Phase
    ) -> TranscriptPriority {
        var m = TranscriptPriority(policy: policy)
        switch phase {
        case .idle:
            return m
        case .dictating:
            m.dictationBegan()
            return m
        case .videoRunning, .videoPaused:
            m.videoBegan()
            m.unitBegan(0)
            m.unitWritten(0)
            m.unitBegan(1)
            m.unitWritten(1)
            m.unitBegan(2)
            if phase == .videoPaused {
                m.videoStopped()
            }
            return m
        }
    }

    // MARK: - Cas obligatoire (a) : une dictée pendant chaque phase, sous chaque politique

    /// **Le cas obligatoire de la carte, et le critère 1 de la SPEC.**
    ///
    /// Depuis **chacune des quatre phases** et sous **chacune des quatre politiques**, un
    /// déclenchement de dictée est **honoré** : la machine entre en `.dictating` ou tient la dictée
    /// en attente explicite (``TranscriptPriority/dictationPending``). Il n'existe **aucun** état où
    /// le raccourci serait refusé, ignoré ou laissé « bloqué » : c'est la contrainte dure, et elle
    /// ne dépend pas de la politique.
    ///
    /// Le travail vidéo déjà écrit ne bouge pas d'un octet au déclenchement (``writtenUnits``) : la
    /// dictée ne fait perdre aucune unité.
    func testCriteresContratLeRaccourciEstHonoreDepuisChaquePhaseEtSousChaquePolitique() {
        for politique in quatrePolitiques {
            for phase in quatrePhases {
                var m = machine(politique, dans: phase)
                let ecrites = m.writtenUnits
                let enCours = m.inFlightUnit

                m.dictationBegan()

                let honoree = m.phase == .dictating || m.dictationPending
                XCTAssertTrue(
                    honoree,
                    "\(contrat) — \(politique.rawValue) / phase \(phase.rawValue) : une dictée "
                        + "déclenchée est honorée — servie (.dictating) ou en attente explicite —, "
                        + "jamais refusée (phase obtenue : \(m.phase.rawValue), en attente : "
                        + "\(m.dictationPending))")
                XCTAssertNotEqual(
                    m.phase, TranscriptPriority.Phase.idle,
                    "\(contrat) — \(politique.rawValue) / phase \(phase.rawValue) : la machine ne "
                        + "retombe pas à .idle sur une dictée déclenchée")
                XCTAssertEqual(
                    m.writtenUnits, ecrites,
                    "\(contrat) — \(politique.rawValue) / phase \(phase.rawValue) : le "
                        + "déclenchement d'une dictée ne touche pas aux unités déjà écrites")
                XCTAssertEqual(
                    m.inFlightUnit, enCours,
                    "\(contrat) — \(politique.rawValue) / phase \(phase.rawValue) : le "
                        + "déclenchement d'une dictée ne touche pas à l'unité en cours")

                // Ce qu'aucune politique ne peut imposer : attendre. Sans travail vidéo qui tourne
                // (rien ne tient la machine), la dictée est servie **tout de suite**.
                if phase == .idle || phase == .videoPaused {
                    XCTAssertEqual(
                        m.phase, TranscriptPriority.Phase.dictating,
                        "\(contrat) — \(politique.rawValue) / phase \(phase.rawValue) : sans "
                            + "travail vidéo qui tourne, la dictée est servie immédiatement")
                    XCTAssertFalse(
                        m.dictationPending,
                        "\(contrat) — \(politique.rawValue) / phase \(phase.rawValue) : rien à "
                            + "attendre quand la vidéo ne tourne pas")
                }
            }
        }
    }

    /// **La transition attendue, calculée pour chaque politique** — le second versant du cas (a).
    ///
    /// Une dictée déclenchée pendant que la vidéo **tourne**, puis la frontière :
    ///
    /// - (1a) la dictée attend (``dictationPending``) et la vidéo **s'arrête** à la frontière :
    ///   phase `.dictating`, vidéo **suspendue**, l'unité en cours (2) devient l'unité à rejouer ;
    /// - (1b) et (2) la dictée est servie **tout de suite** et la vidéo **n'est pas dérangée**
    ///   (``videoIsRunning`` vrai), rien n'est rejoué ;
    /// - (3) la dictée attend la **fin de fenêtre**, la vidéo **n'est pas interrompue** et rien
    ///   n'est rejoué : c'est ce qui la distingue de (1a).
    func testCriteresContratLAdmissionEstCelleQueChaquePolitiquePromet() {
        // (1a) : attend la frontière d'unité, et la paie d'une suspension.
        var frontier = machine(.dictationWaitsForUnitBoundary, dans: .videoRunning)
        frontier.dictationBegan()
        XCTAssertEqual(
            frontier.phase, TranscriptPriority.Phase.videoRunning,
            "\(contrat) — (1a) : la dictée attend la frontière d'unité, la vidéo tourne encore")
        XCTAssertTrue(
            frontier.dictationPending,
            "\(contrat) — (1a) : la dictée est en attente explicite jusqu'à la frontière")
        XCTAssertFalse(
            frontier.videoIsSuspended,
            "\(contrat) — (1a) : la vidéo n'est pas encore suspendue avant la frontière")
        frontier.frontierReached()
        XCTAssertEqual(
            frontier.phase, TranscriptPriority.Phase.dictating,
            "\(contrat) — (1a) : à la frontière, la dictée prend la main")
        XCTAssertTrue(
            frontier.videoIsSuspended,
            "\(contrat) — (1a) : à la frontière, la vidéo est suspendue")
        XCTAssertFalse(
            frontier.videoIsRunning,
            "\(contrat) — (1a) : la vidéo suspendue ne tourne plus")
        XCTAssertEqual(
            frontier.unitToReplay, 2,
            "\(contrat) — (1a) : l'unité interrompue (2) est celle qui sera rejouée")
        XCTAssertEqual(
            frontier.writtenUnits, [0, 1],
            "\(contrat) — (1a) : les unités écrites (0, 1) ne sont pas rejouées")

        // (1b) : servie tout de suite, la vidéo n'est pas dérangée.
        var partage = machine(.sharedMachine, dans: .videoRunning)
        partage.dictationBegan()
        XCTAssertEqual(
            partage.phase, TranscriptPriority.Phase.dictating,
            "\(contrat) — (1b) : la dictée est servie tout de suite")
        XCTAssertFalse(
            partage.dictationPending, "\(contrat) — (1b) : il n'y a rien à attendre")
        XCTAssertTrue(
            partage.videoIsRunning,
            "\(contrat) — (1b) : la vidéo continue de tourner pendant la dictée")
        XCTAssertFalse(
            partage.videoIsSuspended, "\(contrat) — (1b) : la vidéo n'est pas suspendue")

        // (2) : servie tout de suite, unités de calcul séparées.
        var separee = machine(.separateComputeUnits, dans: .videoRunning)
        separee.dictationBegan()
        XCTAssertEqual(
            separee.phase, TranscriptPriority.Phase.dictating,
            "\(contrat) — (2) : la dictée est servie tout de suite")
        XCTAssertTrue(
            separee.videoIsRunning,
            "\(contrat) — (2) : la vidéo n'est pas interrompue non plus")

        // (3) : attend la fin de fenêtre, mais la vidéo n'est jamais suspendue.
        var fileAttente = machine(.dictationQueuedForWindowEnd, dans: .videoRunning)
        fileAttente.dictationBegan()
        XCTAssertEqual(
            fileAttente.phase, TranscriptPriority.Phase.videoRunning,
            "\(contrat) — (3) : la dictée passe à la fin de la fenêtre, la vidéo tourne encore")
        XCTAssertTrue(
            fileAttente.dictationPending,
            "\(contrat) — (3) : la dictée est en attente explicite")
        fileAttente.frontierReached()
        XCTAssertEqual(
            fileAttente.phase, TranscriptPriority.Phase.dictating,
            "\(contrat) — (3) : à la fin de la fenêtre, la dictée passe")
        XCTAssertFalse(
            fileAttente.videoIsSuspended,
            "\(contrat) — (3) : le travail vidéo n'est pas interrompu")
        XCTAssertNil(
            fileAttente.unitToReplay,
            "\(contrat) — (3) : rien n'a été interrompu, rien n'est rejoué")
    }

    /// **La non-régression, dans sa forme la plus dure** : une dictée qui arrive alors que le
    /// travail vidéo est **suspendu** est servie **tout de suite, sous toutes les politiques**.
    ///
    /// Un travail suspendu ne tient aucun verrou : rien — pas même la politique éliminée (1a), la
    /// plus défavorable à la voix — ne peut faire attendre la dictée dans cet état. Et la reprise
    /// de la vidéo n'est pas perdue pour autant : l'unité interrompue (2) reste celle qui sera
    /// rejouée.
    func testCriteresContratUneDicteeArrivantSurUneVideoSuspendueEstServieToutDeSuitePartout() {
        for politique in quatrePolitiques {
            var m = machine(politique, dans: .videoPaused)
            XCTAssertEqual(
                m.phase, TranscriptPriority.Phase.videoPaused,
                "\(contrat) — \(politique.rawValue) : l'arrangement place la vidéo en pause")
            XCTAssertTrue(
                m.videoIsSuspended,
                "\(contrat) — \(politique.rawValue) : la vidéo est suspendue")
            XCTAssertEqual(
                m.unitToReplay, 2,
                "\(contrat) — \(politique.rawValue) : l'unité interrompue reste à rejouer")

            m.dictationBegan()

            XCTAssertEqual(
                m.phase, TranscriptPriority.Phase.dictating,
                "\(contrat) — \(politique.rawValue) : une dictée sur une vidéo suspendue est servie "
                    + "tout de suite — un travail suspendu ne tient aucun verrou")
            XCTAssertFalse(
                m.dictationPending,
                "\(contrat) — \(politique.rawValue) : rien ne peut la mettre en attente ici")
            XCTAssertTrue(
                m.videoIsSuspended,
                "\(contrat) — \(politique.rawValue) : la dictée ne reprend pas la vidéo à sa place")
            XCTAssertEqual(
                m.unitToReplay, 2,
                "\(contrat) — \(politique.rawValue) : le plan de rejeu de la vidéo est intact")
            XCTAssertEqual(
                m.writtenUnits, [0, 1],
                "\(contrat) — \(politique.rawValue) : les unités écrites sont intactes")
        }
    }

    // MARK: - La question de la boucle vidéo

    /// ``TranscriptPriority/shouldYield(dictationPending:)`` : la boucle vidéo demande si elle doit
    /// céder. Elle ne doit céder que là où la politique le dit — **jamais** sous (1b) le défaut,
    /// **jamais** sous (2), **jamais** sous (3) — et seulement tant que la vidéo tourne : la
    /// question est posée à chaque frontière, avec le signal « dictée en cours » injecté.
    func testCriteresContratShouldYieldNeRepondVraiQuePourLaPolitiqueElimineeEtSurUneVideoQuiTourne() {
        // (1a) : le seul cas où la vidéo cède — tant qu'une dictée est en attente et que la vidéo
        // tourne. C'est cette réponse que la boucle vidéo transforme en arrêt à la frontière.
        var eliminee = machine(.dictationWaitsForUnitBoundary, dans: .videoRunning)
        eliminee.dictationBegan()
        XCTAssertTrue(
            eliminee.shouldYield(dictationPending: true),
            "\(contrat) — (1a) : la vidéo cède quand une dictée est en attente et qu'elle tourne")
        XCTAssertFalse(
            eliminee.shouldYield(dictationPending: false),
            "\(contrat) — (1a) : sans dictée en attente, la vidéo ne cède pas")
        XCTAssertTrue(
            eliminee.dictationPending,
            "\(contrat) — (1a) : l'état de la machine confirme l'attente (la réponse ci-dessus "
                + "n'est pas un accident de paramètre)")
        XCTAssertEqual(
            eliminee.phase, TranscriptPriority.Phase.videoRunning,
            "\(contrat) — (1a) : la vidéo tourne encore, c'est ce qui rend la cession nécessaire")
        eliminee.frontierReached()
        XCTAssertEqual(
            eliminee.phase, TranscriptPriority.Phase.dictating,
            "\(contrat) — (1a) : la dictée est servie après la frontière")
        XCTAssertFalse(
            eliminee.shouldYield(dictationPending: true),
            "\(contrat) — (1a) : une fois la dictée servie, la vidéo n'a plus rien à céder")

        // Aucune autre politique ne fait jamais céder la vidéo, sur l'état où la question se pose
        // vraiment : la vidéo qui tourne, une dictée déclenchée.
        for politique in [TranscriptPriority.Policy.sharedMachine, .separateComputeUnits,
                          .dictationQueuedForWindowEnd] {
            var m = machine(politique, dans: .videoRunning)
            m.dictationBegan()
            XCTAssertFalse(
                m.shouldYield(dictationPending: true),
                "\(contrat) — \(politique.rawValue) : jamais la voix ne fait céder la vidéo")
            XCTAssertTrue(
                m.videoIsRunning,
                "\(contrat) — \(politique.rawValue) : et la vidéo tourne bien pendant ce temps")
            XCTAssertFalse(
                m.videoIsSuspended,
                "\(contrat) — \(politique.rawValue) : sans aucune suspension décidée")
        }

        // Sur les phases qui ne sont pas « la vidéo tourne » : jamais de cession, sous aucune
        // politique — c'est la forme la plus dure du « jamais attendre un verrou ».
        for politique in quatrePolitiques {
            for phase in [TranscriptPriority.Phase.idle, .dictating, .videoPaused] {
                let m = machine(politique, dans: phase)
                XCTAssertFalse(
                    m.shouldYield(dictationPending: true),
                    "\(contrat) — \(politique.rawValue) / phase \(phase.rawValue) : il n'y a pas "
                        + "de travail vidéo en cours à céder dans cet état")
            }
        }
    }

    // MARK: - La décision : 1b par défaut, et rien n'attend

    /// **Décision de Louis du 2026-09-21** : le défaut câblé est **(1b) le statu quo** — « une
    /// dictée ne doit jamais attendre un verrou pris par la vidéo ». Le défaut est donc servi tout
    /// de suite, la vidéo n'est pas suspendue, et le travail déjà écrit ne bouge pas.
    func testCriteresContratLeDefautCableEstLeStatuQuoEtIlNeFaitJamaisCederLaVideo() {
        XCTAssertEqual(
            TranscriptPriority.defaultPolicy, .sharedMachine,
            "\(contrat) — la politique câblée est (1b), le statu quo")
        let neuve = TranscriptPriority()
        XCTAssertEqual(
            neuve.policy, TranscriptPriority.Policy.sharedMachine,
            "\(contrat) — une machine construite sans politique prend le défaut câblé")
        XCTAssertEqual(
            neuve.phase, TranscriptPriority.Phase.idle,
            "\(contrat) — une machine neuve est au repos")

        var m = machine(TranscriptPriority.defaultPolicy, dans: .videoRunning)
        m.dictationBegan()

        XCTAssertEqual(
            m.phase, TranscriptPriority.Phase.dictating,
            "\(contrat) — défaut (1b) : la dictée est servie tout de suite")
        XCTAssertFalse(
            m.dictationPending,
            "\(contrat) — défaut (1b) : la dictée n'attend rien, et surtout pas un verrou vidéo")
        XCTAssertTrue(
            m.videoIsRunning,
            "\(contrat) — défaut (1b) : la vidéo continue de tourner en parallèle")
        XCTAssertFalse(
            m.videoIsSuspended,
            "\(contrat) — défaut (1b) : aucune suspension n'est décidée pour la dictée")
        XCTAssertFalse(
            m.shouldYield(dictationPending: true),
            "\(contrat) — défaut (1b) : la vidéo ne cède pas")
        XCTAssertEqual(
            m.writtenUnits, [0, 1],
            "\(contrat) — défaut (1b) : le travail vidéo écrit est intact")
        XCTAssertEqual(
            m.inFlightUnit, 2,
            "\(contrat) — défaut (1b) : l'unité en cours reste en cours")

        m.dictationEnded()
        XCTAssertEqual(
            m.phase, TranscriptPriority.Phase.videoRunning,
            "\(contrat) — défaut (1b) : après la dictée, la machine retrouve la vidéo qui tourne")

        m.unitBegan(2)
        m.unitWritten(2)
        XCTAssertEqual(
            m.writtenUnits, [0, 1, 2],
            "\(contrat) — défaut (1b) : le travail vidéo va au bout, chaque unité une fois")
    }

    /// **Les trois mécanismes de la carte sont représentables en paramètre** — des **valeurs**
    /// lues par la machine, jamais une bifurcation dans le code — et restent **distincts** :
    /// préemption à la frontière (1a), unités de calcul séparées (2), file d'attente (3).
    func testCriteresContratLesTroisMecanismesSontRepresentablesEnParametreEtRestentDistincts() {
        XCTAssertEqual(
            TranscriptPriority.Policy.allCases.count, 4,
            "\(contrat) — les quatre candidates du lot 0 sont représentables, pas trois : le "
                + "statu quo (1b) en est une")

        // (1a) admet à la frontière d'unité — c'est le seul mécanisme qui fait céder la vidéo.
        XCTAssertEqual(
            TranscriptPriority.Policy.dictationWaitsForUnitBoundary.admission,
            TranscriptPriority.Admission.atUnitBoundary,
            "\(contrat) — (1a) admet à la frontière d'unité")
        XCTAssertFalse(
            TranscriptPriority.Policy.dictationWaitsForUnitBoundary.dedicatesComputeUnits,
            "\(contrat) — (1a) partage les unités de calcul")

        // (2) admet tout de suite, mais sur ses propres unités de calcul.
        XCTAssertEqual(
            TranscriptPriority.Policy.separateComputeUnits.admission,
            TranscriptPriority.Admission.immediately,
            "\(contrat) — (2) admet tout de suite")
        XCTAssertTrue(
            TranscriptPriority.Policy.separateComputeUnits.dedicatesComputeUnits,
            "\(contrat) — (2) exige une seconde instance à unités de calcul séparées, et c'est un "
                + "paramètre de construction lu par l'appelant")

        // (3) admet à la fin de la fenêtre, sur les mêmes unités de calcul.
        XCTAssertEqual(
            TranscriptPriority.Policy.dictationQueuedForWindowEnd.admission,
            TranscriptPriority.Admission.atWindowEnd,
            "\(contrat) — (3) admet à la fin de la fenêtre en cours")
        XCTAssertFalse(
            TranscriptPriority.Policy.dictationQueuedForWindowEnd.dedicatesComputeUnits,
            "\(contrat) — (3) partage les unités de calcul")

        // (1b) : le défaut n'est ni (1a), ni (2), ni (3).
        XCTAssertEqual(
            TranscriptPriority.Policy.sharedMachine.admission,
            TranscriptPriority.Admission.immediately,
            "\(contrat) — (1b) admet tout de suite")
        XCTAssertFalse(
            TranscriptPriority.Policy.sharedMachine.dedicatesComputeUnits,
            "\(contrat) — (1b) partage les unités de calcul")

        // Les trois mécanismes ne se confondent pas : chacun a son jeu d'attributs.
        var signatures: [String] = []
        for mecanisme in troisMecanismes {
            signatures.append("\(mecanisme.admission)/\(mecanisme.dedicatesComputeUnits)")
        }
        XCTAssertEqual(
            Set(signatures).count, troisMecanismes.count,
            "\(contrat) — les trois mécanismes restent distincts en paramètre "
                + "(signatures mesurées : \(signatures))")
    }

    // MARK: - La raison de l'élimination de (1a) voyage avec le contrat

    /// **Décision du 2026-09-21** : (1a) est **éliminée** parce que l'attente qu'elle impose à la
    /// voix — 18,6 s (unités de 2 min), 46,5 s (5 min), 93,1 s (10 min) **dérivés** — vaut 3 à
    /// 16 fois le coût **mesuré** de la contention (5,84 s). Ces nombres voyagent avec le contrat :
    /// sans eux, la prochaine carte ne saura plus pourquoi la candidat la plus « propre » pour la
    /// vidéo n'est pas câblée.
    func testCriteresContratLeContratPorteLaMesureDuLot0QuiElimineLaPolitique1a() {
        let mesure = TranscriptPriority.Lot0.measuredContentionSeconds
        XCTAssertEqual(
            mesure, 5.84,
            "\(contrat) — le coût mesuré de la contention est 5,84 s (paire longue de la séance "
                + "du 2026-09-21) ; valeur lue : \(mesure)")

        let attentes = TranscriptPriority.Lot0.derivedWaits
        XCTAssertEqual(
            attentes.count, 3,
            "\(contrat) — trois durées d'unité ont été dérivées (2, 5 et 10 min) ; "
                + "\(attentes.count) lue(s)")
        XCTAssertEqual(
            attentes.map(\.unitSeconds), [120, 300, 600],
            "\(contrat) — unités de 2, 5 et 10 minutes, en secondes")
        XCTAssertEqual(
            attentes.map(\.waitSeconds), [18.6, 46.5, 93.1],
            "\(contrat) — attentes dérivées de (1a), en secondes")

        for attente in attentes {
            let rapport = attente.waitSeconds / mesure
            XCTAssertGreaterThanOrEqual(
                rapport, 3,
                "\(contrat) — l'attente dérivée (\(attente.waitSeconds) s pour des unités de "
                    + "\(attente.unitSeconds) s) vaut au moins 3 fois le coût mesuré ; rapport lu : "
                    + "\(rapport)")
            XCTAssertLessThanOrEqual(
                rapport, 16,
                "\(contrat) — et au plus 16 fois ; rapport lu : \(rapport)")
        }

        XCTAssertTrue(
            TranscriptPriority.Policy.dictationWaitsForUnitBoundary.isEliminatedByLot0Measure,
            "\(contrat) — (1a) est la politique éliminée par la mesure")
        for politique in [TranscriptPriority.Policy.sharedMachine, .separateComputeUnits,
                          .dictationQueuedForWindowEnd] {
            XCTAssertFalse(
                politique.isEliminatedByLot0Measure,
                "\(contrat) — \(politique.rawValue) n'est pas éliminée : la décision du "
                    + "2026-09-21 ne retient aucune politique unique")
        }
    }

    // MARK: - Cas obligatoire (b) : l'unité interrompue est rejouée une seule fois

    /// **Le cas obligatoire de la carte.** Une dictée interrompt le travail vidéo : l'unité **en
    /// cours** (2) devient la seule unité à rejouer, les unités **déjà écrites** (0 et 1) ne le
    /// sont jamais. À la reprise, l'unité 2 est rejouée **une fois** — pas zéro (le travail serait
    /// perdu), pas deux (la reprise repartirait de trop loin) — et un second passage ne rejoue
    /// plus rien.
    func testCriteresContratLUniteInterrompueEstRejoueeUneSeuleFoisEtJamaisLesUnitesEcrites() {
        var m = machine(.dictationWaitsForUnitBoundary, dans: .videoRunning)
        XCTAssertEqual(
            m.writtenUnits, [0, 1],
            "\(contrat) — avant la dictée : unités 0 et 1 écrites")
        XCTAssertEqual(
            m.inFlightUnit, 2,
            "\(contrat) — avant la dictée : l'unité 2 est en cours, pas écrite")

        m.dictationBegan()
        m.frontierReached()

        XCTAssertEqual(
            m.unitToReplay, 2,
            "\(contrat) — la pause interrompt l'unité en cours (2) : c'est elle qui sera rejouée")
        XCTAssertEqual(
            m.writtenUnits, [0, 1],
            "\(contrat) — les unités déjà écrites ne sont pas candidates au rejeu")
        XCTAssertTrue(
            m.videoIsSuspended, "\(contrat) — la vidéo est suspendue pendant la dictée")

        m.dictationEnded()
        XCTAssertEqual(
            m.phase, TranscriptPriority.Phase.videoPaused,
            "\(contrat) — la fin de la dictée laisse la vidéo en pause, à reprendre")

        m.videoResumed()
        XCTAssertEqual(
            m.phase, TranscriptPriority.Phase.videoRunning,
            "\(contrat) — la vidéo reprend")
        XCTAssertFalse(
            m.videoIsSuspended, "\(contrat) — la vidéo n'est plus suspendue après la reprise")
        XCTAssertNil(
            m.unitToReplay,
            "\(contrat) — le rejeu est consommé par la reprise : l'unité interrompue est rejouée "
                + "une seule fois")
        XCTAssertEqual(
            m.inFlightUnit, 2,
            "\(contrat) — l'unité 2 est de nouveau en traitement")
        XCTAssertEqual(
            m.writtenUnits, [0, 1],
            "\(contrat) — la reprise ne rejoue pas les unités déjà écrites")

        m.unitBegan(2)
        m.unitWritten(2)
        XCTAssertEqual(
            m.writtenUnits, [0, 1, 2],
            "\(contrat) — chaque unité est écrite une fois, et une seule")

        // Un second passage ne rejoue rien : le rejeu n'est pas cumulatif.
        m.videoStopped()
        m.videoResumed()
        XCTAssertEqual(
            m.writtenUnits, [0, 1, 2],
            "\(contrat) — une seconde reprise ne réécrit aucune unité")
        XCTAssertNil(
            m.unitToReplay,
            "\(contrat) — une seconde reprise n'a rien à rejouer")
    }

    /// **La borne qui rend la règle utile** : quand la pause tombe sur une **frontière d'unité**
    /// (aucune unité en cours), il n'y a **rien** à rejouer — le travail reprend exactement où il
    /// s'est arrêté, sans réécrire une seule unité.
    func testCriteresContratUnePauseSurUneFrontiereSansUniteEnCoursNeRejoueRien() {
        var m = TranscriptPriority(policy: .dictationWaitsForUnitBoundary)
        m.videoBegan()
        m.unitBegan(0)
        m.unitWritten(0)
        m.unitBegan(1)
        m.unitWritten(1)
        XCTAssertNil(
            m.inFlightUnit,
            "\(contrat) — arrangement : la boucle vidéo est arrêtée sur une frontière d'unité")

        m.dictationBegan()
        m.frontierReached()

        XCTAssertEqual(
            m.phase, TranscriptPriority.Phase.dictating,
            "\(contrat) — la dictée est servie à la frontière")
        XCTAssertTrue(
            m.videoIsSuspended, "\(contrat) — (1a) suspend la vidéo à la frontière d'unité")
        XCTAssertNil(
            m.unitToReplay,
            "\(contrat) — aucune unité n'était en cours : rien à rejouer")
        XCTAssertEqual(
            m.writtenUnits, [0, 1],
            "\(contrat) — les unités écrites sont intactes")

        m.dictationEnded()
        m.videoResumed()

        XCTAssertEqual(
            m.phase, TranscriptPriority.Phase.videoRunning,
            "\(contrat) — la vidéo reprend après la dictée")
        XCTAssertEqual(
            m.writtenUnits, [0, 1],
            "\(contrat) — le travail reprend sans rejouer les unités déjà écrites")
        XCTAssertNil(
            m.unitToReplay, "\(contrat) — et sans rien programmer de plus")

        m.unitBegan(2)
        m.unitWritten(2)
        XCTAssertEqual(
            m.writtenUnits, [0, 1, 2],
            "\(contrat) — la suite du travail s'écrit normalement")
    }

    // MARK: - Cas obligatoire (c) : deux dictées de suite

    /// **Le cas obligatoire de la carte.** Deux dictées déclenchées **de suite** — un double appui
    /// sur le raccourci, une dictée qui commence pendant la précédente — ne changent rien de plus
    /// que la première : le travail vidéo ne perd aucune unité écrite, l'unité en cours reste la
    /// même, et la seconde dictée n'ajoute ni attente supplémentaire ni rejeu.
    func testCriteresContratDeuxDicteesDeclencheesDeSuiteNePerdentPasLeTravailVideo() {
        for politique in quatrePolitiques {
            var m = machine(politique, dans: .videoRunning)
            m.dictationBegan()
            m.dictationBegan()

            XCTAssertEqual(
                m.writtenUnits, [0, 1],
                "\(contrat) — \(politique.rawValue) : deux dictées de suite ne perdent aucune "
                    + "unité écrite")
            XCTAssertEqual(
                m.inFlightUnit, 2,
                "\(contrat) — \(politique.rawValue) : l'unité en cours est toujours la même")

            let servieToutDeSuite = politique == .sharedMachine || politique == .separateComputeUnits
            if servieToutDeSuite {
                XCTAssertEqual(
                    m.phase, TranscriptPriority.Phase.dictating,
                    "\(contrat) — \(politique.rawValue) : la dictée est servie tout de suite, "
                        + "la seconde n'y change rien")
                XCTAssertFalse(
                    m.dictationPending,
                    "\(contrat) — \(politique.rawValue) : aucune attente ne s'ajoute")
            } else {
                XCTAssertEqual(
                    m.phase, TranscriptPriority.Phase.videoRunning,
                    "\(contrat) — \(politique.rawValue) : la dictée attend sa frontière, la "
                        + "vidéo tourne toujours")
                XCTAssertTrue(
                    m.dictationPending,
                    "\(contrat) — \(politique.rawValue) : une seule attente, la même pour les "
                        + "deux déclenchements")
            }

            m.frontierReached()
            XCTAssertEqual(
                m.phase, TranscriptPriority.Phase.dictating,
                "\(contrat) — \(politique.rawValue) : à la frontière, la dictée est servie")
            m.dictationEnded()
            m.dictationEnded()

            if politique == .dictationWaitsForUnitBoundary {
                // (1a) : la vidéo a été suspendue par la dictée, elle attend sa reprise — et
                // l'unité interrompue reste **une seule** unité à rejouer, malgré les deux dictées.
                XCTAssertEqual(
                    m.phase, TranscriptPriority.Phase.videoPaused,
                    "\(contrat) — (1a) : la vidéo attend la reprise après la dictée")
                XCTAssertEqual(
                    m.unitToReplay, 2,
                    "\(contrat) — (1a) : deux dictées ne font pas deux unités à rejouer")
                m.videoResumed()
                XCTAssertNil(
                    m.unitToReplay,
                    "\(contrat) — (1a) : le rejeu est consommé par la reprise")
            } else {
                // (1b), (2) et (3) : la vidéo n'a jamais été interrompue par la dictée.
                XCTAssertEqual(
                    m.phase, TranscriptPriority.Phase.videoRunning,
                    "\(contrat) — \(politique.rawValue) : la vidéo tournait déjà, elle continue")
                XCTAssertFalse(
                    m.videoIsSuspended,
                    "\(contrat) — \(politique.rawValue) : la vidéo n'a jamais été suspendue")
                XCTAssertNil(
                    m.unitToReplay,
                    "\(contrat) — \(politique.rawValue) : aucune unité n'a été interrompue, rien "
                        + "n'est rejoué — le travail n'a jamais cessé")
            }

            XCTAssertEqual(
                m.phase, TranscriptPriority.Phase.videoRunning,
                "\(contrat) — \(politique.rawValue) : la vidéo travaille après les deux dictées")
            m.unitBegan(2)
            m.unitWritten(2)
            XCTAssertEqual(
                m.writtenUnits, [0, 1, 2],
                "\(contrat) — \(politique.rawValue) : le travail vidéo est complet après les deux "
                    + "dictées, chaque unité écrite une seule fois")
            XCTAssertNil(
                m.unitToReplay,
                "\(contrat) — \(politique.rawValue) : plus rien à rejouer, le travail est écrit")
        }
    }

    // MARK: - La vie de la suspension

    /// La **suspension et la reprise** de la vidéo (critère 1 : « la vidéo se suspend et
    /// reprend »), et sa **fin** : une dictée finie laisse une vidéo suspendue en
    /// ``TranscriptPriority/Phase/videoPaused`` — c'est le pilote qui la reprend —, et la fin
    /// normale du travail ne laisse ni unité en cours ni rejeu derrière elle.
    func testCriteresContratLaFinDUneDicteeSurUneVideoSuspendueLaisseLaVideoEnPauseJusquALaReprise() {
        var m = machine(.dictationWaitsForUnitBoundary, dans: .videoRunning)
        m.dictationBegan()
        m.frontierReached()
        XCTAssertEqual(
            m.phase, TranscriptPriority.Phase.dictating,
            "\(contrat) — la dictée est servie après la préemption")
        XCTAssertTrue(m.videoIsSuspended, "\(contrat) — la vidéo est suspendue")

        m.dictationEnded()

        XCTAssertEqual(
            m.phase, TranscriptPriority.Phase.videoPaused,
            "\(contrat) — la fin de la dictée laisse la vidéo en pause, à reprendre explicitement")
        XCTAssertFalse(
            m.dictationPending, "\(contrat) — plus aucune dictée en attente")
        XCTAssertTrue(
            m.videoIsSuspended, "\(contrat) — la vidéo n'a pas redémarré toute seule")
        XCTAssertFalse(
            m.videoIsRunning, "\(contrat) — la vidéo ne tourne pas tant qu'elle est suspendue")

        m.videoResumed()
        XCTAssertEqual(
            m.phase, TranscriptPriority.Phase.videoRunning,
            "\(contrat) — la reprise remet la vidéo en marche")
        XCTAssertTrue(m.videoIsRunning, "\(contrat) — la vidéo tourne de nouveau")
        XCTAssertFalse(m.videoIsSuspended, "\(contrat) — et elle n'est plus suspendue")

        m.unitBegan(2)
        m.unitWritten(2)
        m.videoEnded()
        XCTAssertEqual(
            m.phase, TranscriptPriority.Phase.idle,
            "\(contrat) — travail vidéo fini, aucune dictée servie : la machine est au repos")
        XCTAssertEqual(
            m.writtenUnits, [0, 1, 2],
            "\(contrat) — la fin du travail ne touche pas aux unités écrites")
        XCTAssertNil(m.inFlightUnit, "\(contrat) — plus aucune unité en cours")
        XCTAssertNil(m.unitToReplay, "\(contrat) — plus rien à rejouer")
        XCTAssertFalse(m.videoIsRunning, "\(contrat) — le travail vidéo ne tourne plus")
    }

    /// La fin du travail vidéo **ne coupe pas** une dictée servie : la dictée garde la main
    /// jusqu'à sa fin, la machine ne retombe pas à ``TranscriptPriority/Phase/idle`` sous elle.
    func testCriteresContratLaFinDuTravailVideoNeCoupePasUneDicteeServie() {
        var m = machine(.sharedMachine, dans: .videoRunning)
        m.dictationBegan()
        XCTAssertEqual(
            m.phase, TranscriptPriority.Phase.dictating,
            "\(contrat) — la dictée est servie pendant que la vidéo tourne")

        m.videoEnded()

        XCTAssertEqual(
            m.phase, TranscriptPriority.Phase.dictating,
            "\(contrat) — la fin du travail vidéo ne coupe pas la dictée en cours")
        XCTAssertFalse(
            m.videoIsRunning, "\(contrat) — mais le travail vidéo est bien terminé")
        XCTAssertEqual(
            m.writtenUnits, [0, 1],
            "\(contrat) — les unités écrites restent écrites")

        m.dictationEnded()
        XCTAssertEqual(
            m.phase, TranscriptPriority.Phase.idle,
            "\(contrat) — la dictée finie, sans travail vidéo, la machine est au repos")
    }
}
