import Foundation

/// L'état d'un travail vidéo dans la file d'attente (plan §4 lot 10).
///
/// Quatre états, et quatre seulement : ils sont **gelés par le contrat** (carte QA L10), et le
/// panneau comme la notification lisent celui-ci. Ajouter un état est un changement de contrat,
/// pas un détail d'implémentation.
///
/// **Une annulation est un `failed`**, pas un cinquième état : le travail annulé n'a produit aucun
/// document, et `done` prétendrait qu'un transcript existe sur disque — le disque est la vérité
/// (critère 14, plan §2.4). Le compte rendu de cette carte le dit aussi : ce qui distingue une
/// annulation d'un échec est l'**absence de raison** (`TranscriptQueueEntry.error`), pas l'état.
public enum TranscriptQueueState: String, CaseIterable, Sendable {
    /// Ajouté, pas encore commencé.
    case waiting
    /// En cours de traitement — au plus un élément de la file porte cet état (critère 19).
    case running
    /// Terminé : le transcript est écrit sur disque.
    case done
    /// Terminé sans transcript : échec (avec raison) ou annulation (sans raison).
    case failed
}

/// Un travail vidéo dans la file : le lien ou le chemin **tel qu'il a été ajouté**, son état, et la
/// raison de son échec éventuel.
///
/// `source` est la valeur d'entrée conservée telle quelle, jamais un titre ni un chemin
/// reconstruit : c'est ce que le panneau affiche pour un travail qui n'a pas encore de document, et
/// c'est ce que le travail reçoit pour savoir quoi traiter.
///
/// `id` est l'identité d'affichage de l'élément (règle 7) : non vide, unique dans la file. Le
/// panneau et la notification s'en servent pour désigner le travail qui vient de finir plutôt que
/// de le retrouver par son rang — un rang change dès qu'un élément est retiré.
///
/// `documentID` est **la tige du fichier que ce travail a écrit**, vide tant qu'il n'en a pas
/// écrit. Elle vient du **document que le travail a rendu**, jamais d'un recalcul : la bibliothèque
/// est la seule autorité sur la tige (§2.4), et `TranscriptFilenames.stem` tient le titre, la date
/// et la suffixation `-2`/`-3` — deux écritures d'une même source donnent **deux tiges pour une
/// seule identité**, donc retrouver le document par son identité serait un pari qui choisit le
/// mauvais fichier une fois sur deux. C'est le **transport** qui rend cette lecture possible, et
/// non une table de correspondance à côté de la file : une seconde autorité ici serait la même
/// faute que celle que ce champ supprime.
public struct TranscriptQueueEntry: Identifiable, Equatable, Sendable {
    /// L'identité d'affichage, unique dans la file (règle 7).
    public let id: String
    /// Le lien ou le chemin tel qu'ajouté.
    public let source: String
    /// L'état courant (règle 3).
    public var state: TranscriptQueueState
    /// La raison de l'échec, `nil` tant qu'il n'y en a pas (règles 5 et 6).
    public var error: String?
    /// **La tige du transcript écrit**, vide tant que ce travail n'en a écrit aucun.
    ///
    /// Elle est écrite par ``drain()`` **dans la même transition** que `.done` : un élément `done`
    /// sans tige n'est donc pas improbable, il est **inconstructible** — le seul code qui produit
    /// `done` est celui qui vient de recevoir un document. La valeur vide reste honnête partout
    /// ailleurs : un travail qui a jeté, une annulation, un travail qui n'a pas encore tourné.
    public var documentID: String

    public init(
        id: String, source: String, state: TranscriptQueueState = .waiting, error: String? = nil,
        documentID: String = ""
    ) {
        self.id = id
        self.source = source
        self.state = state
        self.error = error
        self.documentID = documentID
    }
}

/// L'attente d'un élément qu'aucun identifiant ne désigne : une faute de l'appelant, dite comme
/// telle plutôt que suspendue pour toujours.
public enum TranscriptQueueWait: Error, CustomStringConvertible {
    case unknownEntry(String)

    public var description: String {
        switch self {
        case .unknownEntry(let id): "No queued transcription carries the identifier « \(id) »."
        }
    }
}

/// La file d'attente des travaux vidéo : **un seul travail vidéo à la fois**, dans l'ordre d'ajout
/// (critère 19 ; SPEC « File d'attente : plusieurs liens ajoutés se traitent l'un après l'autre,
/// dans l'ordre »).
///
/// **Pourquoi la file est ici et pas dans `Murmure/`.** Le module de l'application n'a pas de
/// bundle de tests : une politique de file écrite dans `TranscriptsPaneModel` serait une décision
/// que rien ne peut exécuter. Or c'est exactement ce que le critère 19 demande de prouver — trois
/// liens, séquentiels, dans l'ordre — et le plan §7 range ce critère sous « tests de
/// `TranscriptQueue` (cœur) ». Le travail lui-même (télécharger, décoder, transcrire) reste dans
/// l'application : la file ne connaît de lui qu'une closure.
///
/// **Règles gelées par le contrat (carte QA L10)** — chacune est exécutée par
/// `TranscriptQueueTests` :
///
/// 1. **FIFO, un seul travail à la fois.** ``enqueue(source:)`` ajoute à la fin ; ``drain()``
///    traite les éléments en attente **un par un**, dans l'ordre d'ajout. Deux travaux vidéo ne
///    tournent **jamais** en parallèle (critère 19).
/// 2. **Ce que la file expose** : ``entries`` = tous les éléments, dans l'ordre d'ajout, jamais
///    réordonnés ; ``waiting`` = ceux qui n'ont pas commencé, dans l'ordre où ils partiront ;
///    ``running`` = celui qui tourne, `nil` sinon. Le panneau lit ces trois-là.
/// 3. **Cycle de vie d'un élément** : `waiting` → `running` (l'élément passé au travail porte cet
///    état, et son `id`) → `done` si le travail rend la main, `failed` s'il lance une erreur.
///    `done` et `failed` sont **terminaux** : un élément terminé est **retiré de la file** et ne
///    tourne plus jamais — un `drain()` de plus ne rejoue rien.
/// 4. ``drain()`` traite **tout** ce qui attend, **y compris ce qui a été ajouté pendant qu'elle
///    tourne**, et ne rend la main que lorsque plus rien n'attend. Appelée alors qu'un autre
///    `drain()` est en cours, elle **rend la main immédiatement sans démarrer de travail** : la
///    file ne devient jamais parallèle, et aucun appelant ne se bloque derrière un travail en
///    cours.
/// 5. **Un échec n'arrête pas la file.** Une erreur lancée par le travail marque l'élément
///    `failed` avec `erreur.localizedDescription`, et les suivants sont traités dans l'ordre
///    d'ajout. Un lien mort coûte un élément, pas la file.
/// 6. ``cancelCurrent()`` **annule la tâche du travail en cours** (`Task.isCancelled` est vrai
///    dans le travail, qui est donc arrêté coopérativement, comme la dictée), le marque `failed`
///    **sans raison** (`error == nil`) et **ne touche pas à l'ordre des suivants** : le travail
///    annulé ne repart pas, les suivants partent dans l'ordre d'ajout. Sans travail en cours,
///    c'est un non-événement.
/// 7. **Un identifiant par élément** : non vide, unique dans la file. Il ne change pas de la
///    naissance à la fin du travail, et il est propre à cette file (deux files ne se partagent
///    pas d'identité).
/// 8. **Les libellés de progression** sont dans ``TranscriptQueueText`` (motif `StatusPanelText` :
///    une phrase, dans le cœur, là où un test peut la lire).
/// 9. **Rien d'autre ici** : ce fichier n'écrit rien sur disque, ne journalise aucun contenu de
///    transcription (critère 15) et ne déclenche aucune notification. La notification macOS, la
///    pastille, le menu et les cibles de dépôt vivent dans `Murmure/` (cible sans bundle de
///    tests) ; les **mots** de l'interface vivent dans `MenuText`, où la règle de langue de
///    `MenuTextTests` les couvre tous.
public actor TranscriptQueue {
    /// Le travail d'un élément : ce que l'application sait faire d'un lien — acquérir, décoder,
    /// transcrire — et que la file ne connaît pas.
    ///
    /// Il reçoit l'élément au moment où il **commence** (donc `state == .running`), et il peut
    /// consulter `Task.isCancelled` : c'est ainsi que ``cancelCurrent()`` l'arrête.
    ///
    /// **Il rend le `TranscriptDocument` qu'il a écrit, et cette valeur n'est pas décorative.**
    /// Elle est l'unique chemin par lequel la tige du fichier écrit atteint l'élément : sans elle,
    /// la seule façon de savoir quel transcript un travail vient d'écrire serait de le **rechercher
    /// par son identité canonique** — et `transcript(id:)` attend une **tige**. Le défaut que cela
    /// produisait n'était pas une garde mal écrite, c'était une donnée que le **type jetait** :
    /// `-> Void` rendait toute re-dérivation obligatoire, donc forcée à être fausse. Rendre le
    /// document supprime la tentation en supprimant la possibilité.
    ///
    /// **Le document rendu est celui RELU SUR DISQUE**, jamais celui d'avant écriture :
    /// `TranscriptLibrary.write` re-dote le document de la tige qu'**elle** a choisie, donc le
    /// document en mémoire porte une `id` que la bibliothèque ne reconnaîtra jamais. C'est aussi ce
    /// que `TranscriptJobRunner.persist` rend déjà.
    public typealias Job = @Sendable (TranscriptQueueEntry) async throws -> TranscriptDocument

    /// Le travail, injecté à la construction : c'est ce qui rend la file exécutable par un test
    /// sans modèle, sans réseau et sans fichier.
    private let run: Job

    /// Le jeton de cette file, et le compteur de ses éléments : ensemble ils forment l'identité
    /// d'affichage (règle 7). Le jeton est **par file** — deux files ne se partagent aucune
    /// identité, donc un panneau qui retrouve un élément par son `id` ne peut pas tomber sur
    /// celui d'une autre file.
    private let token = UUID().uuidString
    private var rang = 0

    /// Les éléments, **dans l'ordre d'ajout, et jamais réordonnés** : un élément terminé y reste
    /// avec son état terminal (`done` ou `failed`), c'est ``waiting`` qui le perd. C'est ce qui
    /// permet au panneau de montrer ce qui vient de finir à côté de ce qui attend.
    private var elements: [TranscriptQueueEntry] = []

    /// Un seul `drain()` à la fois (règle 4). Le drapeau est ce qui répond « rends la main » à un
    /// second appelant au lieu de le laisser attendre la fin du travail en cours.
    private var drainage = false

    /// La tâche du travail en cours, et **rien d'autre** : c'est elle que ``cancelCurrent()``
    /// annule, et elle est mise à `nil` dès que le travail rend la main.
    private var travail: Task<TranscriptDocument, Error>?

    /// Les attentes en cours, par identifiant : une liste, parce que deux surfaces peuvent
    /// attendre le même travail (le panneau et le socket), et chacune rend ce qui la concerne.
    private var attentes: [String: [CheckedContinuation<TranscriptQueueEntry, Never>]] = [:]

    public init(run: @escaping Job) {
        self.run = run
    }

    /// Ajoute un travail vidéo à la fin de la file (règles 1 et 7) et rend l'élément créé, à
    /// l'état `waiting`. Rien ne démarre ici : c'est ``drain()`` qui traite.
    @discardableResult
    public func enqueue(source: String) -> TranscriptQueueEntry {
        rang += 1
        let element = TranscriptQueueEntry(id: "\(token)-\(rang)", source: source)
        elements.append(element)
        return element
    }

    /// Tous les éléments, dans l'ordre d'ajout, quel que soit leur état (règle 2).
    public var entries: [TranscriptQueueEntry] {
        elements
    }

    /// Les éléments qui n'ont pas encore commencé, dans l'ordre où ils partiront (règle 2).
    public var waiting: [TranscriptQueueEntry] {
        elements.filter { $0.state == .waiting }
    }

    /// Le travail en cours, `nil` si la file est au repos (règles 1 et 2).
    public var running: TranscriptQueueEntry? {
        elements.first { $0.state == .running }
    }

    /// Ce que la file dit d'elle-même en une ligne : `idle` sans rien à faire, sinon le travail
    /// courant et le nombre de ceux qui attendent leur tour.
    ///
    /// **Calculée, jamais stockée** : les éléments terminés ne comptent pas — un travail fini est
    /// sur le disque. Les libellés sont des **sources** (URL ou chemin), jamais du texte transcrit
    /// (critère 15) : c'est ce que le socket répond.
    public var status: String {
        let enAttente = elements.filter { $0.state == .waiting }.count
        switch running {
        case nil where enAttente == 0:
            return "idle"
        case nil:
            return "idle, \(enAttente) waiting"
        case let element? where enAttente == 0:
            return "running \(element.source)"
        case let element?:
            return "running \(element.source), \(enAttente) waiting"
        }
    }

    /// Attend la **terminaison de l'élément que cet identifiant désigne**, et rend cet élément.
    ///
    /// **L'attente suit l'identifiant, jamais le rang** : deux travaux peuvent être ajoutés pendant
    /// que le premier tourne, et une attente sur « le suivant » rendrait à un appelant le résultat
    /// d'un travail qui n'est pas le sien. Un élément **déjà terminé** rend immédiatement : un
    /// `--wait` peut arriver après la fin.
    ///
    /// - Throws: ``TranscriptQueueWait/unknownEntry(_:)`` si aucun élément de cette file ne porte
    ///   cet identifiant — une attente que rien ne reprend ne dirait rien.
    public func wait(for id: String) async throws -> TranscriptQueueEntry {
        guard let index = elements.firstIndex(where: { $0.id == id }) else {
            throw TranscriptQueueWait.unknownEntry(id)
        }
        if elements[index].state == .done || elements[index].state == .failed {
            return elements[index]
        }
        // La continuation est enregistrée AVANT toute suspension : c'est ce qui garantit qu'un
        // élément qui finit entre le garde ci-dessus et cet `await` n'est pas manqué.
        return await withCheckedContinuation { continuation in
            attentes[id, default: []].append(continuation)
        }
    }

    /// Réveille les attentes de cet élément, une fois son état terminal écrit.
    ///
    /// Appelé par ``drain()`` **après** l'écriture de l'état : une attente qui rendrait un élément
    /// encore `running` renverrait une fin qui n'a pas eu lieu. Les continuations sont retirées
    /// avant d'être rendues, donc un second passage ne les rendrait pas deux fois.
    private func terminer(_ element: TranscriptQueueEntry) {
        for continuation in attentes.removeValue(forKey: element.id) ?? [] {
            continuation.resume(returning: element)
        }
    }

    /// Traite la file jusqu'à ce que plus rien n'attende, un élément à la fois, dans l'ordre
    /// d'ajout, y compris ce qui a été ajouté pendant qu'elle tourne (règles 1 et 4).
    public func drain() async {
        // Règle 4 : un seul drainage. Le second appelant rend la main tout de suite — il ne
        // démarre rien et n'attend rien, sinon la file aurait deux travaux en parallèle.
        guard !drainage else { return }
        drainage = true
        defer { drainage = false }

        // Le premier qui attend, quel que soit son rang : la boucle reprend à chaque tour, donc un
        // élément ajouté pendant que le précédent tournait est vu ici, à sa place (règle 4).
        while let index = elements.firstIndex(where: { $0.state == .waiting }) {
            elements[index].state = .running
            let element = elements[index]

            // **Le travail ne tourne pas sur l'acteur de la file.** Une `Task` dérivée hériterait
            // de l'isolation : ses portions synchrones occuperaient l'acteur, donc `running` et
            // `cancelCurrent()` attendraient derrière elles — et l'annulation, qui doit être
            // réactive, arriverait après coup. Détachée, la file ne garde que le *handle*.
            let travail = Task.detached { [run] in try await run(element) }
            self.travail = travail
            let issue = await travail.result
            self.travail = nil

            // L'élément est retrouvé **par son identité**, pas par son rang : rien n'est réordonné,
            // mais un second `enqueue` pendant le travail a pu allonger la liste.
            guard let rang = elements.firstIndex(where: { $0.id == element.id }) else { continue }

            if travail.isCancelled {
                // Règle 6 : une annulation est un `failed` **sans raison** — c'est Louis qui l'a
                // arrêtée, il n'y a pas de défaut du média à lui montrer. Le cas est traité avant
                // l'issue, parce qu'une annulation coopérative peut aussi rendre la main en
                // réussissant ou en jetant `CancellationError` : ce qui la désigne est le drapeau
                // de la tâche, pas ce que le travail en a fait. **La tige reste vide** : un travail
                // annulé n'a pas écrit de transcript, et en dire un serait une annonce trompeuse.
                elements[rang].state = .failed
                elements[rang].error = nil
            } else {
                switch issue {
                case .success(let document):
                    // `done` et la tige, dans la MÊME transition : c'est ce qui rend un `done`
                    // sans tige **inconstructible** plutôt qu'improbable. Le raisonnement est sur
                    // ``TranscriptQueueEntry/documentID``.
                    elements[rang].state = .done
                    elements[rang].error = nil
                    elements[rang].documentID = document.id
                case .failure(let erreur):
                    // Règle 5 : la raison est conservée telle que le travail l'a donnée, et le
                    // suivant part quand même — un lien mort coûte un élément, pas la file. La
                    // tige reste vide : rien n'a été écrit.
                    elements[rang].state = .failed
                    elements[rang].error = erreur.localizedDescription
                }
            }
            // L'état terminal est écrit : c'est maintenant que les attentes de cet identifiant
            // peuvent rendre son résultat, et elles rendent l'ÉLÉMENT (donc son `id`, son état et
            // sa raison) — jamais un autre travail de la file.
            terminer(elements[rang])
        }
    }

    /// Annule le travail en cours (règle 6) : sa tâche est annulée, l'élément devient `failed`
    /// sans raison, et les suivants gardent leur place.
    public func cancelCurrent() {
        // Sans travail en cours, c'est un non-événement : il n'y a rien à annuler.
        travail?.cancel()
    }
}

/// Ce que la file montre : une phrase par état, pour la barre de progression et la ligne de la
/// file (critère 18, « une barre de progression suit le traitement »).
///
/// **Motif `StatusPanelText`**, et pour la même raison : c'est le cœur qui décide des phrases, pas
/// la vue — `Murmure/` n'a pas de bundle de tests, et une phrase écrite dans `TranscriptsPaneView`
/// est une décision que rien ne peut relire. Une phrase par état, jamais un `default` : un état
/// ajouté plus tard ne doit pas hériter silencieusement de la phrase d'un autre.
///
/// **Règles gelées par le contrat (carte QA L10)** :
///
/// 1. `waiting` → « Waiting », `running` → « Transcribing », `done` → « Done » : chaque état a sa
///    phrase, non vide, en anglais, et aucune ne peut se lire à la place d'une autre.
/// 2. **Le travail en cours dit le mot de la dictée** :
///    `label(for: running)` est `StatusPanelText.label(for: .transcribing)`. Transcrire une vidéo
///    et dicter sont la même activité ; deux mots seraient une différence que Louis devrait
///    apprendre pour rien (l'argument que `MenuText` fait déjà pour `AppAlert`).
/// 3. **L'échec porte sa raison** : `label(for:)` d'un élément `failed` qui a une raison vaut
///    `"Failed: <raison>"` — une phrase sans la raison renverrait Louis au journal d'un travail
///    qu'il a lancé la veille.
/// 4. **Une annulation se dit « Cancelled »**, le mot que les deux autres surfaces qui montrent
///    une annulation emploient déjà (`StatusPanelText.label(for: .cancelled)`, `HistoryRow`), et
///    seulement pour une `failed` **sans raison** : la file est la seule à produire un échec sans
///    raison, et c'est ``TranscriptQueue/cancelCurrent()``.
public enum TranscriptQueueText {
    /// La phrase d'un élément, par état (règles 1 à 4).
    public static func label(for entry: TranscriptQueueEntry) -> String {
        // Une phrase par état, sans `default` : un état ajouté plus tard ne peut pas hériter
        // silencieusement de la phrase d'un autre — il ne compilerait pas ici.
        switch entry.state {
        case .waiting:
            return "Waiting"
        case .running:
            // Le mot de la dictée, pas un second mot pour la même activité (règle 2).
            return StatusPanelText.label(for: .transcribing)
        case .done:
            return "Done"
        case .failed:
            // Une annulation est le **seul** échec sans raison (règle 4) : la file est la seule à
            // en produire un, et c'est `cancelCurrent()`. Une raison vide compte comme absente —
            // une chaîne vide n'est pas une cause à montrer.
            guard let raison = entry.error, !raison.isEmpty else {
                return StatusPanelText.label(for: .cancelled)
            }
            return "Failed: \(raison)"
        }
    }
}
