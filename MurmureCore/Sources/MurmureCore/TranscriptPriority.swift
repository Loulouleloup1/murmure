import Foundation

/// La machine de priorité **dictée / vidéo** — état **pur**, testé, sans dépendance à WhisperKit
/// ni à `Murmure/` (lot 12, plan §2.2, §4 lot 12).
///
/// ## Ce que la machine doit garantir (contrainte dure de la SPEC, critère 1)
///
/// > « La dictée est absolue : le raccourci doit toujours répondre, quelle que soit la charge ; la
/// > vidéo se suspend et reprend. Non négociable. »
///
/// Traduit en invariants que ce fichier doit rendre vrais :
///
/// 1. **Une dictée n'attend jamais un verrou pris par la vidéo.** ``dictationBegan()`` est
///    toujours honoré : la machine ne connaît **aucun** état « refusé » ni « bloqué », et une
///    dictée qui arrive alors que le travail vidéo est **suspendu** (`videoIsSuspended == true`,
///    phase ``Phase/videoPaused``) est servie **tout de suite, sous toutes les politiques** — un
///    travail suspendu ne tient aucun verrou.
/// 2. **Le travail vidéo ne perd rien.** Les unités **déjà écrites** (``writtenUnits``) ne sont
///    jamais rejouées et jamais perdues, quel que soit le nombre de dictées enchaînées ; la
///    reprise ne rejoue qu'**une seule fois** l'unité interrompue (``unitToReplay``, consommée par
///    ``videoResumed()``).
///
/// ## La politique est un PARAMÈTRE, jamais une bifurcation
///
/// Les quatre candidates mesurées par le lot 0 sont des **valeurs** (``Policy``) lues par la
/// machine, pas des `switch` cachés dans la logique : ajouter une candidate, c'est ajouter un cas
/// et ses attributs, sans toucher aux transitions.
///
/// - ``Policy/dictationWaitsForUnitBoundary`` — **(1a) la dictée attend la frontière d'unité**.
///   **ÉLIMINÉE par les mesures du lot 0** (décision de Louis du 2026-09-21) : l'attente
///   **dérivée** y vaut 18,6 s (unités de 2 min), 46,5 s (5 min) et 93,1 s (10 min), soit **3 à
///   16 fois** le coût **mesuré** de la contention (5,84 s, paire longue de la séance). Faire
///   attendre la voix coûte plus cher que la laisser souffrir la contention : la politique reste
///   représentable et testée, mais elle n'est **pas** câblée.
/// - ``Policy/sharedMachine`` — **(1b) le statu quo, la politique câblée par défaut** : rien
///   n'attend, les deux se partagent la machine (coût mesuré +5,84 s, non séparable de la
///   dispersion naturelle du corpus réel, n = 1).
/// - ``Policy/separateComputeUnits`` — **(2) seconde instance à unités de calcul séparées**
///   (`ModelComputeOptions`, WhiskerKit par instance). Non jugée par le lot 0 : sa cible (l'ANE)
///   n'est pas la ressource en cause ; son coût à chaud est ≈ +200 Mo.
/// - ``Policy/dictationQueuedForWindowEnd`` — **(3) file d'attente** : le travail vidéo n'est pas
///   interrompu, la dictée passe à la fin de la fenêtre en cours (≤ 30 s d'audio, ≈ 3,5 s de
///   calcul ; borne dérivée ≤ 4,65 s, jamais mesurée).
///
/// Aucune politique n'est « retenue » : la mesure qui décide est reportée au lot 8, où le moteur
/// vidéo tourne dans le processus de l'application. Le défaut câblé est **1b**.
///
/// ## Comment la couture se branche (aucune décision dans l'adaptateur)
///
/// - le travail vidéo appelle ``shouldYield(dictationPending:)`` à chacune de ses frontières
///   (avant une unité, et à chaque fenêtre du rappel de progression) : `true` veut dire **la vidéo
///   cède** — le rappel rend `false` et le frein `TranscriptionStop` est armé ;
/// - il annonce ensuite ``frontierReached()``, où la dictée en attente est admise selon la
///   politique ;
/// - il annonce ``unitBegan(_:)`` / ``unitWritten(_:)`` en entrant dans une unité et en la
///   persistent sur disque : c'est ce qui rend « les unités déjà écrites ne sont jamais rejouées »
///   observable sans lire de fichier ;
/// - ``TranscriptionStop`` et `TranscriptJobRunner.Event` ne changent pas : la politique est ce
///   que le runner consulte, elle n'ajoute aucun événement.
///
/// ## Ce que ce fichier ne fait pas
///
/// Il ne connaît ni WhisperKit, ni Ollama, ni le disque, ni le temps : il ne décide que des
/// **transitions**. Aucune de ses méthodes ne bloque, ne dort, ni n'attend quoi que ce soit.
///
/// **Toutes les transitions ci-dessous sont gelées par le contrat rouge `TranscriptPriorityTests`
/// (carte QA L12)** : la carte `dev` remplace les corps sentinelles, **sans toucher aux
/// signatures** (plan §7.1 règles 1 à 5).
public struct TranscriptPriority: Equatable, Sendable {

    // MARK: - La politique (paramètre)

    /// Les quatre candidates du lot 0. **Représentables, jamais branchées dans la logique** : la
    /// machine lit ``admission`` et ``dedicatesComputeUnits``, elle ne teste pas le cas.
    public enum Policy: String, Equatable, CaseIterable, Sendable {
        /// (1a) la dictée attend la frontière d'unité — **éliminée** par la mesure du lot 0.
        case dictationWaitsForUnitBoundary
        /// (1b) la dictée démarre tout de suite, les deux se partagent la machine — **défaut**.
        case sharedMachine
        /// (2) seconde instance de modèle à unités de calcul séparées — non jugée par le lot 0.
        case separateComputeUnits
        /// (3) la vidéo n'est pas interrompue, la dictée passe à la fin de la fenêtre — survivante.
        case dictationQueuedForWindowEnd

        // MARK: Les attributs de la politique (des valeurs, jamais des branches)

        /// Quand cette politique admet une dictée déclenchée.
        ///
        /// **Des valeurs, jamais une branche** : la machine lit ``admission`` et
        /// ``dedicatesComputeUnits`` dans ses transitions, elle ne teste jamais le cas de
        /// politique. Ajouter une candidate, c'est ajouter un cas **et ses attributs ici**.
        public var admission: Admission {
            switch self {
            case .dictationWaitsForUnitBoundary:
                // (1a) : la voix attend que l'unité en cours soit finie ou interrompue.
                return .atUnitBoundary
            case .dictationQueuedForWindowEnd:
                // (3) : la voix attend la fin de la fenêtre de 30 s en cours, pas l'unité.
                return .atWindowEnd
            case .sharedMachine, .separateComputeUnits:
                // (1b) et (2) : la voix ne paie aucune attente, la vidéo n'est pas dérangée.
                return .immediately
            }
        }

        /// Cette politique exige-t-elle que le moteur vidéo soit construit sur **ses propres
        /// unités de calcul** (seconde instance, scénario 2) ? Vrai pour (2) seulement.
        public var dedicatesComputeUnits: Bool {
            switch self {
            case .separateComputeUnits:
                return true
            case .dictationWaitsForUnitBoundary, .sharedMachine, .dictationQueuedForWindowEnd:
                return false
            }
        }

        /// Cette politique a-t-elle été **éliminée** par les mesures du lot 0 ? Vrai pour (1a)
        /// seulement.
        public var isEliminatedByLot0Measure: Bool {
            switch self {
            case .dictationWaitsForUnitBoundary:
                return true
            case .sharedMachine, .separateComputeUnits, .dictationQueuedForWindowEnd:
                return false
            }
        }
    }

    /// **Quand une dictée déclenchée est admise** (quand elle obtient la machine).
    public enum Admission: Equatable, Sendable {
        /// Servie immédiatement, sans rien attendre : (1b) et (2).
        case immediately
        /// Servie à la fin de la fenêtre de transcription en cours : (3).
        case atWindowEnd
        /// Servie à la frontière de l'unité courante, qui est alors terminée ou interrompue : (1a).
        case atUnitBoundary
    }

    /// Une attente **dérivée** par le lot 0 (une durée d'unité → l'attente imposée à la voix).
    public struct DerivedWait: Equatable, Sendable {
        public let unitSeconds: Double
        public let waitSeconds: Double

        public init(unitSeconds: Double, waitSeconds: Double) {
            self.unitSeconds = unitSeconds
            self.waitSeconds = waitSeconds
        }
    }

    /// Les nombres du lot 0 que le contrat porte, pour que la raison d'une élimination ne se perde
    /// pas entre deux cartes (décision du 2026-09-21, §1 et §3).
    public enum Lot0 {
        /// Le coût **mesuré** de la contention dictée/vidéo : paire longue de la séance du
        /// 2026-09-21 (15,905 s perçus sous charge contre 10,067 s seule), en secondes.
        public static let measuredContentionSeconds: Double = 5.84
        /// L'attente **dérivée** par la politique (1a), pour les unités de 2, 5 et 10 minutes. Ces
        /// trois nombres sont ceux de la décision du 2026-09-21 (§3) : ils sont ce qui permet à une
        /// carte aval de constater, sans relire la campagne, que l'attente imposée vaut 3 à 16 fois
        /// le coût mesuré — et donc pourquoi (1a) n'est pas câblée.
        public static let derivedWaits: [DerivedWait] = [
            DerivedWait(unitSeconds: 120, waitSeconds: 18.6),
            DerivedWait(unitSeconds: 300, waitSeconds: 46.5),
            DerivedWait(unitSeconds: 600, waitSeconds: 93.1),
        ]
    }

    /// La politique **câblée** : (1b) le statu quo (décision de Louis du 2026-09-21, tour 8).
    /// Aucune politique unique n'a été retenue par la mesure.
    public static let defaultPolicy: Policy = .sharedMachine

    // MARK: - Les quatre phases

    /// L'état de la machine. **Quatre cas, aucun autre** : il n'existe ni ``waiting`` ni
    /// ``blocked`` — une dictée ne peut pas être « en attente d'un verrou ».
    ///
    /// - ``idle`` : ni dictée servie, ni travail vidéo ;
    /// - ``dictating`` : une dictée est servie (elle a la machine). Sous (1b) et (2), le travail
    ///   vidéo continue en parallèle : c'est ``videoIsSuspended`` qui dit ce que fait la vidéo ;
    /// - ``videoRunning`` : le travail vidéo tourne, aucune dictée servie ;
    /// - ``videoPaused`` : le travail vidéo est suspendu, aucune dictée servie — il attend
    ///   ``videoResumed()``.
    public enum Phase: String, Equatable, CaseIterable, Sendable {
        case idle
        case dictating
        case videoRunning
        case videoPaused
    }

    // MARK: - L'état observé

    /// La politique appliquée par cette machine.
    public let policy: Policy
    /// La phase courante.
    public private(set) var phase: Phase
    /// Une dictée a été déclenchée et **n'est pas encore servie** : c'est le seul sens de cette
    /// valeur, et elle n'existe que sous une politique qui admet à une frontière ((1a) et (3)).
    public private(set) var dictationPending: Bool
    /// Le travail vidéo **tourne** (il n'est ni terminé, ni suspendu). Sous (1b), (2) et (3) il
    /// tourne pendant que la dictée est servie ; sous (1a) il est suspendu pendant ce temps.
    public private(set) var videoIsRunning: Bool
    /// Le travail vidéo est **suspendu** : préempté par une dictée ((1a)), ou arrêté par son
    /// pilote. Il reprendra par ``videoResumed()``.
    public private(set) var videoIsSuspended: Bool
    /// Les unités **déjà écrites** sur disque, dans l'ordre : jamais rejouées, jamais perdues.
    public private(set) var writtenUnits: [Int]
    /// L'unité commencée et non écrite — celle qu'une préemption interrompt, `nil` sinon.
    public private(set) var inFlightUnit: Int?
    /// L'unité à rejouer à la reprise : **au plus une** (l'unité interrompue), consommée par
    /// ``videoResumed()``. Jamais une unité de ``writtenUnits``.
    public private(set) var unitToReplay: Int?

    // MARK: - Construction

    public init(policy: Policy = TranscriptPriority.defaultPolicy) {
        self.policy = policy
        self.phase = .idle
        self.dictationPending = false
        self.videoIsRunning = false
        self.videoIsSuspended = false
        self.writtenUnits = []
        self.inFlightUnit = nil
        self.unitToReplay = nil
    }

    // MARK: - Le travail vidéo

    /// Le travail vidéo commence : ``videoIsRunning`` devient vrai, ``videoIsSuspended`` faux, et la
    /// phase ``Phase/videoRunning`` — sauf si une dictée est servie, qui garde la main
    /// (``Phase/dictating``, la vidéo tournant alors en parallèle).
    public mutating func videoBegan() {
        videoIsRunning = true
        videoIsSuspended = false
        // Une dictée **servie** garde la main : la vidéo reprend son travail *à côté* d'elle
        // (c'est l'état de (1b), (2) et (3) — sous (1a) la vidéo est suspendue, donc dans
        // ``Phase/videoPaused``, et une reprise passe par ``videoResumed()``).
        if phase != .dictating {
            phase = .videoRunning
        }
    }

    /// Une unité **entre en traitement** : ``inFlightUnit`` la nomme jusqu'à ce qu'elle soit écrite.
    /// C'est l'unité qu'une préemption interrompt, et la seule qui pourra être rejouée.
    public mutating func unitBegan(_ index: Int) {
        inFlightUnit = index
    }

    /// Une unité est **persistée** : elle entre dans ``writtenUnits`` **une seule fois** (un index
    /// déjà écrit n'y entre pas deux fois) et ``inFlightUnit`` retombe à `nil` si c'était elle.
    /// Une unité écrite n'est **jamais** rejouée.
    public mutating func unitWritten(_ index: Int) {
        // « une seule fois » est l'invariant, pas une coquetterie : la boucle vidéo peut annoncer
        // deux fois la même unité (reprise qui la retrouve écrite, par exemple), et un doublon
        // dans ``writtenUnits`` ferait dire à la machine qu'il reste du travail là où il n'y en a
        // plus.
        if !writtenUnits.contains(index) {
            writtenUnits.append(index)
        }
        if inFlightUnit == index {
            inFlightUnit = nil
        }
        // Une unité écrite n'est **jamais** rejouée (invariant 2) : si elle était programmée pour
        // l'être, le rejeu est annulé ici plutôt que de laisser les deux champs se contredire.
        if unitToReplay == index {
            unitToReplay = nil
        }
    }

    /// La boucle vidéo atteint une **frontière** : avant une unité, ou à chaque fenêtre du rappel de
    /// progression — c'est là que `TranscriptionStop` est consulté.
    ///
    /// - aucune dictée en attente → non-événement ;
    /// - une dictée est en attente → elle est **servie** (``Phase/dictating``, ``dictationPending``
    ///   faux). Si la politique admet à la frontière d'unité ((1a)), la vidéo est **suspendue**
    ///   (``videoIsSuspended`` vrai) et l'unité **non écrite** en cours devient ``unitToReplay`` ;
    ///   si elle admet à la fin de fenêtre ((3)), la vidéo **continue** et rien n'est rejoué.
    public mutating func frontierReached() {
        // Sans dictée en attente, une frontière n'est pas un événement : c'est le cas courant, à
        // chaque unité et à chaque fenêtre, et il ne doit rien coûter.
        guard dictationPending else { return }
        dictationPending = false

        // La **seule** suspension de la vidéo, et elle vient de la politique, jamais du cas : (1a)
        // admet à la frontière d'unité, donc la vidéo cède et l'unité non écrite en cours devient
        // celle qui sera rejouée. (3) admet à la fin de fenêtre : la vidéo ne s'arrête pas, rien
        // n'est interrompu, rien n'est rejoué.
        if videoIsRunning, policy.admission == .atUnitBoundary {
            videoIsRunning = false
            videoIsSuspended = true
            unitToReplay = inFlightUnit
        }
        phase = .dictating
    }

    /// Le travail vidéo **s'arrête** là où il en est, pour une cause extérieure à la priorité
    /// (arrêt demandé, échec, relance de l'application) : ``videoIsSuspended`` devient vrai,
    /// ``videoIsRunning`` faux. L'unité non écrite en cours devient ``unitToReplay``.
    ///
    /// Un travail qui s'arrête **ne tient plus rien** : une dictée en attente est servie
    /// immédiatement, quelle que soit la politique.
    public mutating func videoStopped() {
        videoIsRunning = false
        videoIsSuspended = true
        unitToReplay = inFlightUnit

        // « Un travail qui s'arrête ne tient plus rien » : la dictée en attente est servie ici,
        // sans attendre de frontière — la boucle vidéo, elle, ne tournera plus jamais.
        if dictationPending {
            dictationPending = false
            phase = .dictating
        } else if phase != .dictating {
            phase = .videoPaused
        }
    }

    /// Le travail vidéo **reprend** : ``videoIsSuspended`` faux, ``videoIsRunning`` vrai, phase
    /// ``Phase/videoRunning`` — et ``unitToReplay`` est **consommé** (remis à `nil`) : l'unité
    /// interrompue est rejouée **une seule fois**, jamais une unité déjà écrite.
    public mutating func videoResumed() {
        videoIsSuspended = false
        videoIsRunning = true
        // Le rejeu **et lui seul** : l'unité interrompue redevient l'unité en traitement, puis
        // ``unitToReplay`` est consommé — une seconde reprise n'a plus rien à rejouer.
        if let toReplay = unitToReplay {
            inFlightUnit = toReplay
        }
        unitToReplay = nil
        if phase != .dictating {
            phase = .videoRunning
        }
    }

    /// Le travail vidéo est **terminé** : ``inFlightUnit`` et ``unitToReplay`` à `nil`,
    /// ``videoIsRunning`` faux, et ``writtenUnits`` ne bouge pas. La phase est ``Phase/dictating``
    /// si une dictée est servie, ``Phase/idle`` sinon.
    public mutating func videoEnded() {
        inFlightUnit = nil
        unitToReplay = nil
        videoIsRunning = false
        // Un travail **terminé** n'est ni en marche ni en pause : il ne reprendra pas. Laisser la
        // suspension armée ferait dire à la machine qu'une reprise est due pour un travail fini.
        videoIsSuspended = false
        if phase != .dictating {
            phase = .idle
        }
    }

    // MARK: - La dictée

    /// Une dictée est déclenchée : **toujours honorée** (contrainte dure de la SPEC — aucun état
    /// « refusé », aucun état « bloqué »).
    ///
    /// 1. le travail vidéo ne **tourne pas** (rien ne tient la machine) → servie **tout de suite**,
    ///    sous **toutes** les politiques : ``Phase/dictating``, ``dictationPending`` faux ;
    /// 2. sinon, la politique décide : admission immédiate ((1b), (2)) → servie tout de suite ;
    ///    admission à une frontière ((1a), (3)) → ``dictationPending`` vrai, la phase ne bouge pas ;
    /// 3. une dictée déjà servie ou déjà en attente n'est **pas un second événement** : rien ne
    ///    change — deux dictées déclenchées de suite ne perdent rien.
    public mutating func dictationBegan() {
        // 3. Rien à ajouter : une dictée déjà servie ou déjà en attente n'est pas un second
        //    événement (deux appuis de suite ne doivent ni payer deux fois, ni s'additionner).
        guard phase != .dictating, !dictationPending else { return }

        // 1. Rien ne tient la machine (aucun travail vidéo qui tourne, donc pas de verrou) : la
        //    dictée est servie **tout de suite**, sous **toutes** les politiques — y compris (1a),
        //    la plus défavorable à la voix. C'est la contrainte dure de la SPEC, et elle est
        //    structurelle : l'attente n'existe que sous une politique à frontière *et* une vidéo
        //    qui tourne.
        guard videoIsRunning else {
            phase = .dictating
            return
        }

        // 2. La politique décide — par sa **valeur** d'admission, pas par son cas.
        switch policy.admission {
        case .immediately:
            phase = .dictating
        case .atUnitBoundary, .atWindowEnd:
            dictationPending = true
        }
    }

    /// La dictée est finie : ``dictationPending`` retombe à faux. Si la vidéo avait été suspendue
    /// pour elle, elle **reste suspendue** et la phase devient ``Phase/videoPaused`` (c'est son
    /// pilote qui appelle ``videoResumed()``) ; si le travail vidéo tournait, la phase redevient
    /// ``Phase/videoRunning`` ; s'il n'y a plus de travail vidéo, ``Phase/idle``.
    public mutating func dictationEnded() {
        dictationPending = false
        // Idempotent, et c'est voulu : deux `dictationEnded` de suite (le double appui de la
        // carte) ne doivent pas faire retomber la machine d'un cran de plus.
        guard phase == .dictating else { return }
        phase = videoIsSuspended ? .videoPaused : (videoIsRunning ? .videoRunning : .idle)
    }

    // MARK: - La question de la boucle vidéo

    /// **Le travail vidéo doit-il céder ?** Appelé par la boucle vidéo à chaque frontière, avec le
    /// signal « dictée en cours » que le `DictationController` injecte.
    ///
    /// Vrai **seulement** quand la politique admet à la frontière d'unité ((1a)), qu'une dictée
    /// est en attente, et que le travail vidéo tourne encore. Sous (1b) — le défaut —, sous (2) et
    /// sous (3), c'est **toujours faux** : jamais la voix ne fait céder la vidéo.
    public func shouldYield(dictationPending: Bool) -> Bool {
        // Trois conditions, et chacune a un sens : la voix réclame (paramètre injecté), la vidéo
        // tourne réellement (une vidéo suspendue ou finie ne tient rien), et aucune dictée n'est
        // déjà servie (il n'y a plus rien à céder). Le **paramètre** est lu, pas
        // ``self.dictationPending`` : c'est le signal que le `DictationController` injecte, et la
        // boucle vidéo n'a ainsi aucune décision à prendre.
        guard dictationPending, videoIsRunning, phase != .dictating else { return false }
        return policy.admission == .atUnitBoundary
    }
}
