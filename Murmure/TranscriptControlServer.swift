import Darwin
import Foundation
import MurmureCore
import os

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "control")

// Le serveur de contrôle local de l'application (plan §2.5, §4 lot 11, décision **R4** du §0).
//
// **R4 est une décision de sécurité, pas un détail de transport** : « socket dans
// `Application Support/Murmure/`, permissions `0600`, répertoire parent `0700`, et vérification du
// pair (`LOCAL_PEERPID` + UID identique) avant toute commande. Aucune écoute réseau
// (`127.0.0.1` TCP écarté). » Les trois exigences sont tenues ici, et pas seulement écrites : le
// dossier est resserré en `0700` **avant** que le socket y soit lié, le socket est `chmod`é en
// `0600` **après** le `bind` (le `umask` du processus ne décide pas de la surface d'écoute), et
// chaque connexion est refusée si son UID n'est pas le nôtre **avant même de lire la ligne**.
//
// **Aucune exécution de commande arbitraire.** Ce qui arrive du socket n'est jamais passé à un
// shell : c'est une **source** que l'acquisition connaît — une URL YouTube/X reconnue, ou un
// fichier local lisible (`ControlSource`) — et rien d'autre. Un opérande qui n'est ni l'un ni
// l'autre est refusé en code d'usage, avec sa phrase.
//
// **Ce que ce fichier n'est pas** : la file d'attente de l'application. Une seule `TranscriptQueue`
// existe, celle de `TranscriptsPaneModel` (lot 10-S) : ce serveur la **soumet** et la **lit**, sans
// ordre ni progression propres. C'est elle qui rend le résultat que `--wait` attend, par
// identifiant, donc jamais celui d'un autre travail.
//
// **Aucun moteur n'est construit ni reçu ici** (lot 10-S) : le travail, le runner et le modèle
// appartiennent au panneau, et le lot 11-S décidera quelle instance de `WhisperKitEngine` ils
// partagent. Ce serveur ne connaît que deux coutures injectées, donc pas de file de son côté.

/// La source d'une commande `transcribe`, résolue depuis l'opérande du CLI.
///
/// **Le refus est le sujet** : le socket accepte une URL `http`/`https` dont l'identité canonique
/// est reconnue (YouTube ou X) ou un fichier **local et lisible**. Tout le reste — un schéma
/// `file:`, un hôte non reconnu, un chemin qui n'existe pas — est une demande inexploitable, dite
/// en clair. Rien de ce qui vient du pair n'est exécuté : c'est une source, jamais une commande.
enum ControlSource {
    enum Failure: LocalizedError, Equatable {
        case empty
        case unsupportedURL(String)
        case unreadableFile(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                "No source given."
            case .unsupportedURL(let hote):
                "« \(hote) » is not a source Murmure can transcribe: use a YouTube or X link, "
                    + "or a local audio or video file."
            case .unreadableFile(let chemin):
                "No readable file at \(chemin)."
            }
        }
    }

    static func resolve(_ operande: String) throws -> TranscriptSource {
        // Le point de résolution est celui du cœur, pas une seconde lecture : chaque cas porte la
        // chaîne que ce serveur rend **déjà**, donc l'aplatissement des deux refus d'URL en un seul
        // est non exprimable plutôt que demandé (`file:`/`ftp:` lisent l'opérande, un `http` hors
        // familles lit l'hôte).
        switch TranscriptSource.resolve(operande) {
        case .source(let source):
            return source
        case .emptyEntry:
            throw Failure.empty
        case .unsupportedURL(let hote):
            throw Failure.unsupportedURL(hote)
        case .unsupportedScheme(let operande):
            throw Failure.unsupportedURL(operande)
        case .unreadableFile(let chemin):
            throw Failure.unreadableFile(chemin)
        }
    }
}

/// Le résultat d'un travail, tel que la réponse du socket le porte.
///
/// `@unchecked Sendable` : `TranscriptDocument` est une **valeur** (struct de `String`, `Date`,
/// `Double`, tableaux) — rien n'y est partagé mutablement — mais la conformité `Sendable` n'est pas
/// inférée pour un type `public` d'un autre module, et ce résultat traverse la frontière des
/// tâches. La revendication est étroite et vraie : un document écrit une fois n'est plus muté.
enum ControlJobOutcome: @unchecked Sendable {
    case complete(TranscriptDocument)
    case stopped(TranscriptDocument)
    case failed(String)
}

/// Une soumission remise à la file unique, et l'attente de **cette** soumission.
///
/// Le serveur ne tient pas la file : il reçoit cette poignée du submitteur injecté et, avec
/// `--wait`, attend ce que la file rend pour CET identifiant — jamais le résultat d'un travail
/// soumis par le panneau, ni celui d'un autre client.
struct ControlJobHandle: Sendable {
    /// Le libellé que la file affiche pour ce travail (une source, jamais un texte transcrit).
    let libelle: String
    /// L'attente, résolue par la file à l'état terminal de cette soumission.
    let attendu: @Sendable () async -> ControlJobOutcome
}

/// Le serveur de contrôle : écoute sur `control.sock`, sert une ligne par connexion.
///
/// **Le démarrage appartient au câblage de l'application** (`MurmureApp.swift` / `AppDelegate.swift`,
/// lot 10) : ce type est branché, il ne s'auto-démarre pas. C'est la raison pour laquelle il prend
/// ses dépendances en paramètre — un serveur construit à la demande ne peut pas être le chemin de
/// démarrage de qui que ce soit.
///
/// **Il ne possède pas de file (lot 10-S).** Une seule `TranscriptQueue` existe, celle de
/// `TranscriptsPaneModel`, et ce serveur ne fait que la **soumettre** et en **lire** l'état : deux
/// chemins d'ordre étaient deux autorités. Le submitteur et le status provider sont **injectés**,
/// et `ControlJobBoard`, `enchainer` et la chaîne de tâches ont disparu.
final class TranscriptControlServer: @unchecked Sendable {
    private let library: TranscriptLibrary

    /// La file unique, atteinte par deux coutures et jamais construite ici : `transcribe` SOUMET,
    /// `status` LIT. C'est la file qui rend le résultat que `--wait` attend, par identifiant.
    private let submitteur: @Sendable (String) async -> ControlJobHandle
    private let fournisseurStatut: @Sendable () async -> String

    /// **La boucle d'acceptation** — et rien d'autre : un travail à la fois est la file unique qui
    /// l'assure, pas une chaîne de tâches que ce serveur tiendrait en propre.
    private let acceptation = DispatchQueue(label: "com.louiscourcier.Murmure.control.accept")
    private var descripteurDEcoute: Int32 = -1

    init(
        library: TranscriptLibrary = TranscriptLibrary(),
        submitteur: @escaping @Sendable (String) async -> ControlJobHandle,
        fournisseurStatut: @escaping @Sendable () async -> String
    ) {
        self.library = library
        self.submitteur = submitteur
        self.fournisseurStatut = fournisseurStatut
    }

    // MARK: - Démarrage et arrêt

    /// Prépare le dossier (`0700`), lie le socket (`0600`) et écoute. Ne jette pas : un serveur de
    /// contrôle qui ne démarre pas ne doit pas empêcher la dictée de fonctionner — la raison est
    /// journalisée, la fonctionnalité reste disponible au prochain lancement.
    func start() {
        do {
            try preparerDossier()
            let descripteur = try lierEtEcouter()
            descripteurDEcoute = descripteur
            logger.info("control: listening on the control socket")
            accepter(descripteur)
        } catch {
            logger.error("control: server not started: \(String(describing: error), privacy: .public)")
        }
    }

    /// Ferme l'écoute et **retire le nom du socket** : un socket sans écouteur ferait échouer le
    /// `connect` du CLI avec `ECONNREFUSED` au lieu de lui dire que l'application n'est pas là.
    func stop() {
        let descripteur = descripteurDEcoute
        descripteurDEcoute = -1
        if descripteur >= 0 { close(descripteur) }
        unlink(ControlEndpoint.socketURL.path)
    }

    /// Le dossier du socket, en `0700` (R4).
    ///
    /// Le dossier existe déjà — il porte la base et les transcripts (§2.4) — donc il est **resserré**
    /// et non seulement créé : les permissions sont posées explicitement après la création, parce
    /// que le `umask` du processus ne décide pas de cette surface-là.
    private func preparerDossier() throws {
        let dossier = ControlEndpoint.directory
        try FileManager.default.createDirectory(
            at: dossier, withIntermediateDirectories: true,
            attributes: [.posixPermissions: ControlEndpoint.directoryPermissions])
        guard chmod(dossier.path, mode_t(ControlEndpoint.directoryPermissions)) == 0 else {
            throw TransportFailure("chmod \(dossier.path): errno \(errno)")
        }
    }

    /// `bind` + `chmod 0600` + `listen`. Un socket laissé par une exécution précédente est retiré
    /// d'abord : sinon `bind` échoue en `EADDRINUSE` alors que personne n'écoute.
    private func lierEtEcouter() throws -> Int32 {
        let chemin = ControlEndpoint.socketURL.path
        unlink(chemin)

        let descripteur = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descripteur >= 0 else { throw TransportFailure("socket(2): errno \(errno)") }

        var adresse = sockaddr_un()
        adresse.sun_family = sa_family_t(AF_UNIX)
        guard chemin.utf8.count + 1 <= MemoryLayout.size(ofValue: adresse.sun_path) else {
            close(descripteur)
            throw TransportFailure("control socket path too long: \(chemin)")
        }
        withUnsafeMutablePointer(to: &adresse.sun_path) { pointeur in
            pointeur.withMemoryRebound(to: CChar.self, capacity: chemin.utf8.count + 1) {
                destination in
                _ = chemin.utf8CString.withUnsafeBufferPointer { source in
                    memcpy(destination, source.baseAddress!, source.count)
                }
            }
        }
        adresse.sun_len = UInt8(MemoryLayout.size(ofValue: adresse))

        let lie = withUnsafePointer(to: &adresse) { pointeur in
            pointeur.withMemoryRebound(to: sockaddr.self, capacity: 1) { brut in
                bind(descripteur, brut, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard lie == 0 else {
            let code = errno
            close(descripteur)
            throw TransportFailure("bind(2) \(chemin): errno \(code)")
        }
        // Après le `bind`, jamais avant : c'est le fichier qui vient de naître que R4 borne.
        guard chmod(chemin, mode_t(ControlEndpoint.socketPermissions)) == 0 else {
            let code = errno
            close(descripteur)
            throw TransportFailure("chmod(2) \(chemin): errno \(code)")
        }
        guard listen(descripteur, 8) == 0 else {
            let code = errno
            close(descripteur)
            throw TransportFailure("listen(2): errno \(code)")
        }
        return descripteur
    }

    private func accepter(_ descripteur: Int32) {
        acceptation.async { [weak self] in
            while let self, self.descripteurDEcoute == descripteur {
                let connexion = accept(descripteur, nil, nil)
                if connexion < 0 {
                    if errno == EINTR { continue }
                    // Le descripteur d'écoute a été fermé par `stop()` : la boucle s'arrête là.
                    return
                }
                Task { await self.servir(connexion) }
            }
        }
    }

    // MARK: - Une connexion, une ligne

    private func servir(_ connexion: Int32) async {
        defer { close(connexion) }
        // R4 : l'UID du pair est vérifié **avant** de lire quoi que ce soit. Un autre compte de la
        // machine n'obtient même pas une phrase d'erreur.
        guard accepterLePair(connexion) else { return }
        guard let ligne = lireUneLigne(sur: connexion) else { return }

        let reponse = await repondre(a: ligne)
        if let texte = try? ControlProtocol.encodeResponse(reponse) {
            do {
                try ecrire(texte, sur: connexion)
            } catch {
                logger.error("control: response not written: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Le pair a-t-il le droit de commander ? **Uniquement le même UID** (`getpeereid(2)`), et la
    /// décision elle-même est celle du contrat (`ControlEndpoint.acceptsPeer`), pas une seconde
    /// copie de la règle.
    private func accepterLePair(_ connexion: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(connexion, &uid, &gid) == 0 else {
            logger.error("control: peer identity unavailable, command refused")
            return false
        }
        guard ControlEndpoint.acceptsPeer(ownUID: getuid(), peerUID: uid) else {
            logger.error("control: command from another UID refused")
            return false
        }
        return true
    }

    /// La réponse à une ligne : décodée, routée, et **jamais un plantage** — un refus est une
    /// réponse avec son code (plan §2.5, `exitCode(for:)`).
    private func repondre(a ligne: Data) async -> ControlResponse {
        do {
            let requete = try ControlProtocol.decodeRequest(line: ligne)
            return await servir(requete)
        } catch let erreur as ControlProtocolError {
            return ControlResponse(
                exitCode: ControlProtocol.exitCode(for: erreur), error: Self.phrase(pour: erreur))
        } catch {
            return ControlResponse(exitCode: .jobFailed, error: "\(error)")
        }
    }

    /// La phrase d'un refus du protocole, côté pair. Le CLI ne peut pas produire ces lignes-là — il
    /// les construit par `ControlProtocol` — donc ce texte sert le cas d'un pair écrit à la main :
    /// il est court, il nomme le refus, et il est **toujours renseigné** (aucun échec silencieux).
    private static func phrase(pour erreur: ControlProtocolError) -> String {
        switch erreur {
        case .emptyLine: "The control line was empty."
        case .notUTF8: "The control line was not UTF-8."
        case .truncatedLine: "The control line was truncated."
        case .malformedLine(let raison): "The control line could not be read: \(raison)."
        case .unsupportedVersion(let version):
            "Unsupported control protocol version \(version) (this app speaks \(ControlProtocol.version))."
        case .noCommand: "No command given."
        case .unknownCommand(let commande): "Unknown command « \(commande) »."
        case .missingOperand(let commande): "« \(commande.rawValue) » needs an operand."
        case .unknownOption(let option): "Unknown option « \(option) »."
        case .optionRequiresValue(let option): "« \(option) » needs a value."
        case .invalidValue(let option, let valeur): "« \(option) » does not take « \(valeur) »."
        case .unexpectedOperand(let operande): "Unexpected operand « \(operande) »."
        case .appUnreachable: "The application is not reachable."
        }
    }

    private func servir(_ requete: ControlRequest) async -> ControlResponse {
        switch ControlProtocol.route(for: requete.command) {
        case .local:
            // Le CLI sert `list`, `read` et `version` sans nous (critère 20). Un pair qui nous les
            // demande obtient **la même réponse**, par le même chemin — la table de routage est la
            // seule autorité, ici comme là.
            return ControlProtocol.respondLocally(to: requete, library: library)

        case .app:
            switch requete.command {
            case .status:
                // La file unique, lue par le provider injecté — jamais une file de ce serveur, et
                // aucun transcript lu (critère 15).
                return ControlResponse(exitCode: .success, text: await fournisseurStatut())
            case .transcribe:
                return await transcrire(requete)
            case .list, .read, .version:
                // Inatteignable : `route(for:)` les a envoyées en local. Un `switch` exhaustif plutôt
                // qu'un `default` qui masquerait une commande future.
                return ControlResponse(exitCode: .usage, error: "« \(requete.command.rawValue) » is served locally.")
            }
        }
    }

    // MARK: - `transcribe`

    private func transcrire(_ requete: ControlRequest) async -> ControlResponse {
        guard let operande = requete.source else {
            return ControlResponse(exitCode: .usage, error: "« transcribe » needs a source.")
        }
        let source: TranscriptSource
        do {
            source = try ControlSource.resolve(operande)
        } catch {
            return ControlResponse(exitCode: .usage, error: "\(error.localizedDescription)")
        }

        // L'invalidation par une langue explicite différente (plan §2.4, arbitrage du round 2 de
        // `t_65c7d4df`) se décide **ici** : c'est le point d'entrée du CLI, et la langue est son
        // option. Aucun fichier des lots 8 et 10 n'est touché : le travail repart simplement sans
        // document, comme un lancement neuf.
        invaliderRepriseSiBesoin(source: source, language: requete.language)

        let libelle = source.url?.absoluteString ?? source.path ?? operande
        // **La remise à la file est celle du panneau** (submitteur injecté) : le socket ne démarre
        // rien, il prend place dans la même FIFO — impossible d'avoir deux travaux vidéo en
        // parallèle (critère 19).
        let travail = await submitteur(libelle)

        guard requete.wait else {
            // Sans `--wait` la réponse dit **que** le travail est remis à la file, et rien de plus :
            // annoncer un résultat qui n'existe pas encore serait un mensonge.
            return ControlResponse(exitCode: .success, text: "queued \(libelle)")
        }
        switch await travail.attendu() {
        case .complete(let document):
            return ControlResponse(exitCode: .success, document: document, text: "completed \(document.id)")
        case .stopped(let document):
            return ControlResponse(
                exitCode: .jobFailed,
                document: document,
                error: "The transcription of « \(document.id) » was stopped before the end.")
        case .failed(let phrase):
            return ControlResponse(exitCode: .jobFailed, error: phrase)
        }
    }

    /// **L'invalidation d'une reprise par une langue explicite différente** (plan §2.4, décision du
    /// round 2 de `t_65c7d4df`) : un `--language` explicite **prime** sur la langue du document, et
    /// s'il en **diffère**, les unités déjà transcrites sont invalidées —
    ///
    /// - le document en cours est abandonné, et avec lui son point de reprise (`progress.json`) :
    ///   la relance suit donc le chemin « pas de document » de §2.4 et repart de l'unité 0 ;
    /// - **l'audio conservé et le répertoire de travail restent en place** (R7 : aucun
    ///   re-téléchargement ; seule la passe ASR déjà effectuée est refaite) — c'est pourquoi le
    ///   point de reprise est retiré **fichier par fichier** et non par `remove()`, qui emporterait
    ///   `source.<ext>`, le WAV décodé et les tranches ;
    /// - une langue **égale** ou **absente** ne déclenche rien : la reprise est normale et la
    ///   langue du document fait foi, jamais re-détectée (§2.1).
    private func invaliderRepriseSiBesoin(source: TranscriptSource, language: String?) {
        guard let language, !language.isEmpty,
            let enCours = library.resumable(identity: source.identity),
            enCours.language != language
        else { return }

        let travail = TranscriptWorkDirectory(base: library.base, jobID: enCours.id)
        try? FileManager.default.removeItem(at: travail.progressURL)
        library.delete(id: enCours.id)
        logger.info(
            """
            control: « \(enCours.id, privacy: .public) » invalidated by an explicit language: \
            the pass restarts from unit 0 on the same stem, the audio is kept
            """)
    }
}

// MARK: - Le transport (copie du binaire du CLI, même protocole)

/// L'échec du serveur lui-même — un `bind` refusé, un dossier non resserré. Jamais un échec de
/// commande : ceux-là partent dans la réponse, avec leur code.
struct TransportFailure: LocalizedError {
    let errorDescription: String?

    init(_ description: String) { self.errorDescription = description }
}

/// Écrit tout le tampon, quitte à y revenir.
func ecrire(_ donnees: Data, sur descripteur: Int32) throws {
    var restant = donnees[...]
    while !restant.isEmpty {
        let ecrits = restant.withUnsafeBytes { tampon in
            write(descripteur, tampon.baseAddress, tampon.count)
        }
        guard ecrits > 0 else { throw TransportFailure("write(2): errno \(errno)") }
        restant = restant.dropFirst(ecrits)
    }
}

/// Lit **une ligne**, terminateur inclus. Une fermeture du pair avant le terminateur rend ce qui a
/// été reçu : le décodeur le refusera comme tronqué — c'est la propriété que le protocole demande,
/// et elle vaut dans les deux sens.
func lireUneLigne(sur descripteur: Int32) -> Data? {
    var ligne = Data()
    var tampon = [UInt8](repeating: 0, count: 4096)
    while true {
        let lus = read(descripteur, &tampon, tampon.count)
        if lus == 0 { return ligne.isEmpty ? nil : ligne }
        guard lus > 0 else { return nil }
        if let position = tampon[0..<lus].firstIndex(of: 0x0A) {
            ligne.append(contentsOf: tampon[0...position])
            return ligne
        }
        ligne.append(contentsOf: tampon[0..<lus])
    }
}
