import Foundation

// CONTRAT lot 11 — **implémenté** (carte `dev` `t_6879ee2e`).
//
// Ce fichier est la **déclaration du contrat** du lot 11 (CLI `murmure`, plan §2.5, §4 lot 11,
// R4 du §0, critères 12, 20 et 21). Il a été écrit par la carte `qa` `t_874dd36d` **avant**
// l'implémentation : les corps étaient alors des sentinelles manifestement fausses, qui faisaient
// échouer les tests rouges `ControlProtocolTests.swift` / `TranscriptQueryTests.swift` sur une
// assertion explicite (« contrat lot 11 : non implémenté ») — jamais sur une erreur de compilation
// (plan §7.1, règle 4). La carte `dev` `t_6879ee2e` a remplacé ces corps : ce fichier est
// désormais l'implémentation sous `swift test`, et les sentinelles ont disparu.
//
// **Règle 5 du §7.1 : la carte `dev` remplace les corps sans toucher aux signatures.** Un
// changement de signature invalidé par le `dev` est un défaut de contrat et revient au `qa`.
//
// Ce que ce fichier gèle, et pourquoi c'est ici (plan §2.5 : « les types requête/réponse et la
// table de routage vivent dans `MurmureCore` (`ControlProtocol`), donc sous `swift test`. Le socket
// n'est qu'un adaptateur de transport. ») :
//
//  1. **Transport** : le socket UNIX `~/Library/Application Support/Murmure/control.sock`
//     (`ControlEndpoint`, R4), **JSON par ligne** — une requête par ligne, une réponse par ligne,
//     chaque ligne terminée par un saut de ligne. La terminaison fait partie du protocole : c'est
//     ce qui permet à un lecteur de **distinguer une ligne complète d'une ligne tronquée**, et
//     donc de **refuser** la seconde au lieu de l'accepter comme valide.
//  2. **Version** : `version` est un champ **obligatoire** des deux messages et vaut
//     `ControlProtocol.version`. Un message d'une autre version est **refusé**
//     (`.unsupportedVersion`), jamais interprété au mieux.
//  3. **Commandes** (les cinq du plan §2.5) : `transcribe`, `list`, `read`, `status`, `version`.
//     `list`, `read` et `version` **lisent le dossier directement** : elles ne demandent rien à
//     l'application (`ControlRoute.local`). `transcribe` et `status` passent par le socket
//     (`ControlRoute.app`) — les seules qui exigent l'app lancée.
//  4. **Codes de sortie** (plan §2.5, critère 20) : `0` succès, `1` travail en échec, `2` usage,
//     `3` app injoignable, avec les règles de `exitCode(for:)` ci-dessous.
//  5. **La langue optionnelle du critère 12** : la requête `transcribe` porte `language`, mappée
//     depuis `--language xx`. Absente = langue du document si reprise, sinon détection automatique
//     (plan §2.4/N1 : la langue vit dans le document et y est relue, jamais re-détectée).
//
// **Ce que ce contrat ne gèle pas** : la règle de collision de tige (plan §2.4, révision 8) — la
// tige d'un travail reprisable est réutilisée telle quelle ; c'est `TranscriptLibrary` qui la
// décide, et le CLI ne fait que lire ce qu'elle a écrit. Rien ici ne nomme ni ne compte les
// documents d'une source : le CLI lit le dossier (§2.4, « l'index, c'est le dossier »).

// MARK: - Commandes, formats, codes de sortie

/// Une commande du CLI (plan §2.5). Le `String` brut **est** ce qui circule sur la ligne JSON :
/// c'est la table de routage du lot, et c'est ce qui fait qu'une commande inconnue est un cas
/// nommé (`.unknownCommand`) plutôt qu'un `nil` silencieux.
public enum ControlCommand: String, Codable, Equatable, CaseIterable {
    case transcribe
    case list
    case read
    case status
    case version
}

/// Le format demandé à `read` et `transcribe` (plan §2.5 : `--format json|md`).
public enum ControlFormat: String, Codable, Equatable, CaseIterable {
    case json
    case md
}

/// Les codes de sortie du CLI (plan §2.5, critère 20 « retourne 0 en succès »).
///
/// Ce sont des **valeurs brutes conventionnelles du processus**, pas un détail d'affichage : un
/// agent qui appelle `murmure` décide sur ce code, donc `ControlProtocol.exitCode(for:)` est la
/// seule autorité qui le produit.
public enum ControlExitCode: Int, Codable, Equatable, CaseIterable {
    /// Le travail demandé a été fait (critère 20 : « retourne 0 en succès »).
    case success = 0
    /// Le travail n'a pas abouti : transcript introuvable, transcription en échec.
    case jobFailed = 1
    /// La demande est mal formée — ligne illisible, commande inconnue, opérande manquant,
    /// option inconnue, tige ambiguë, chemin hors de la bibliothèque. **Jamais un plantage.**
    case usage = 2
    /// Commande servie par l'application, et l'application est injoignable (plan §2.5 :
    /// « socket absent → le CLI ouvre l'app, puis réessaie pendant 10 s avant d'échouer en code 3 »).
    case appUnreachable = 3
}

/// Où une commande est servie (plan §2.5 : « `mw` a 5 commandes, on en a 5 aussi mais **deux**
/// d'entre elles marchent sans l'app »).
public enum ControlRoute: String, Codable, Equatable {
    /// Le dossier des transcripts suffit : aucun socket, application fermée (critère 20).
    case local
    /// Le socket de contrôle est nécessaire (l'application doit tourner).
    case app
}

// MARK: - Messages

/// Une requête du CLI : **une par ligne**, JSON.
public struct ControlRequest: Codable, Equatable {
    /// Obligatoire, et refusée si elle ne vaut pas `ControlProtocol.version`.
    public var version: Int
    public var command: ControlCommand
    /// `transcribe` : l'URL ou le chemin de la source. `read` : l'id, la tige ou le chemin du
    /// transcript. Absent pour `list`, `status` et `version`.
    public var source: String?
    /// `transcribe --language xx` (critère 12). **Absente** = langue du document si c'est une
    /// reprise, sinon détection automatique — le CLI ne décide jamais à la place du document.
    public var language: String?
    /// `read --format json|md`, `transcribe --format json|md`. Absente = format par défaut du
    /// document (JSON pour `read`).
    public var format: ControlFormat?
    /// `transcribe --output DIR` : où poser les copies de sortie.
    public var output: String?
    /// `transcribe --wait` : ne pas rendre la main avant la fin du travail.
    public var wait: Bool
    /// `--json` : sortie machine (déjà le cas sur le fil ; c'est la sortie du processus).
    public var json: Bool

    public init(
        version: Int = ControlProtocol.version,
        command: ControlCommand,
        source: String? = nil,
        language: String? = nil,
        format: ControlFormat? = nil,
        output: String? = nil,
        wait: Bool = false,
        json: Bool = false
    ) {
        self.version = version
        self.command = command
        self.source = source
        self.language = language
        self.format = format
        self.output = output
        self.wait = wait
        self.json = json
    }
}

/// Un transcript tel que `list` le rend : de quoi désigner le fichier **sans index** (§2.4), et
/// les deux chemins de la même tige (critère 21 : un agent qui trouve l'un trouve l'autre).
public struct ControlTranscriptSummary: Codable, Equatable {
    /// L'`id` du document, qui **est** la tige de son fichier (invariant du §2.4, révision 8).
    public var id: String
    public var title: String
    public var status: TranscriptStatus
    public var createdAt: Date
    public var duration: Double
    /// Chemin **absolu** du `.json` — c'est ce que le CLI imprime pour un agent (§2.5, critère 20).
    public var jsonPath: String
    /// Chemin **absolu** du `.md` de la même tige.
    public var markdownPath: String

    public init(
        id: String, title: String, status: TranscriptStatus, createdAt: Date, duration: Double,
        jsonPath: String, markdownPath: String
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.duration = duration
        self.jsonPath = jsonPath
        self.markdownPath = markdownPath
    }
}

/// La réponse à `list` : ce que le dossier contient, et **ce qu'on n'a pas pu lire**.
///
/// Le compte des illisibles est celui de ``TranscriptLibrary/list()`` : il n'est pas recomposé ici,
/// sinon un `.json` tronqué disparaîtrait sans que personne ne puisse dire pourquoi (critère 14).
public struct ControlListing: Codable, Equatable {
    /// Le dossier lu — un chemin absolu, comme le reste de la réponse.
    public var directory: String
    public var transcripts: [ControlTranscriptSummary]
    public var unreadableCount: Int

    public init(directory: String, transcripts: [ControlTranscriptSummary], unreadableCount: Int) {
        self.directory = directory
        self.transcripts = transcripts
        self.unreadableCount = unreadableCount
    }
}

/// Une réponse du CLI : **une par ligne**, JSON, terminée par un saut de ligne.
public struct ControlResponse: Codable, Equatable {
    /// Obligatoire, et refusée si elle ne vaut pas `ControlProtocol.version`.
    public var version: Int
    /// Le code avec lequel le processus sortira. **Il est dans le message** : une réponse qui
    /// porte un document et un code de succès ne peut pas être confondue avec une réponse d'échec.
    public var exitCode: ControlExitCode
    /// Réponse à `list`.
    public var listing: ControlListing?
    /// Réponse à `read --format json` : le document tel qu'il est sur disque.
    public var document: TranscriptDocument?
    /// Réponse à `read --format md` (le Markdown du fichier `.md`) et à `version` (la version du
    /// CLI). `read` sans `--format` rend `document`, jamais `text`.
    public var text: String?
    /// Le message d'échec, quand il y en a un. **Renseigné dès que `exitCode` n'est pas `.success`** :
    /// un échec sans phrase est un échec silencieux.
    public var error: String?

    public init(
        version: Int = ControlProtocol.version,
        exitCode: ControlExitCode,
        listing: ControlListing? = nil,
        document: TranscriptDocument? = nil,
        text: String? = nil,
        error: String? = nil
    ) {
        self.version = version
        self.exitCode = exitCode
        self.listing = listing
        self.document = document
        self.text = text
        self.error = error
    }
}

/// Les échecs **du protocole et de la ligne de commande** (pas ceux de la bibliothèque, qui sont
/// ``TranscriptQueryError``).
///
/// Chaque cas existe pour être **nommé** : « ligne illisible » et « commande inconnue » ne se
/// confondent pas, et `exitCode(for:)` décide du code de sortie de chacun. Un cas supplémentaire,
/// plutôt qu'une chaîne, parce que c'est ce qui rend le refus explicite vérifiable.
public enum ControlProtocolError: Error, Equatable {
    /// Ligne vide : le pair a écrit un saut de ligne seul (le socket se ferme souvent ainsi).
    case emptyLine
    /// Les octets de la ligne ne sont pas de l'UTF-8.
    case notUTF8
    /// La ligne n'est pas terminée par son saut de ligne : elle a été **tronquée** (pair mort au
    /// milieu d'une écriture, lecture partielle). Une réponse tronquée n'est **jamais** valide.
    case truncatedLine
    /// Le contenu de la ligne est là mais n'est pas un message exploitable.
    case malformedLine(reason: String)
    /// La version du message n'est pas celle du protocole.
    case unsupportedVersion(Int)
    /// Aucune commande n'a été donnée (`murmure` sans argument).
    case noCommand
    /// La commande n'existe pas dans la table de routage.
    case unknownCommand(String)
    /// La commande exige un opérande (`read`, `transcribe`) et il manque.
    case missingOperand(ControlCommand)
    /// Une option n'existe pas.
    case unknownOption(String)
    /// Une option exige une valeur (`--language`, `--format`, `--output`) et il manque.
    case optionRequiresValue(String)
    /// La valeur d'une option n'est pas dans les valeurs admises (`--format xml`).
    case invalidValue(option: String, value: String)
    /// Une commande sans opérande en a reçu un (`list foo`).
    case unexpectedOperand(String)
    /// Commande servie par l'application, application injoignable (code 3).
    case appUnreachable
}

// MARK: - Le protocole

/// Le protocole de contrôle : version, table de routage, codes de sortie, et la mise en ligne
/// JSON des messages.
public enum ControlProtocol {
    /// La version du protocole, écrite dans chaque message. Elle ne change pas sans que les deux
    /// côtés changent ensemble : un message d'une autre version est refusé, pas interprété.
    public static let version = 1

    /// Où la commande est servie — la table de routage du plan §2.5.
    ///
    /// `list`, `read` et `version` sont **locales** : elles lisent le dossier, donc elles marchent
    /// **application fermée** (critère 20 : « commande locale, retour 0 »). `transcribe` et
    /// `status` passent par le socket : sans application lancée, elles valent `.appUnreachable`.
    public static func route(for command: ControlCommand) -> ControlRoute {
        switch command {
        case .list, .read, .version:
            // Le dossier suffit : ces trois commandes ne parlent à personne.
            return .local
        case .transcribe, .status:
            // Il faut l'application : la première lui remet un travail, la seconde décrit sa file.
            return .app
        }
    }

    /// Le code de sortie d'un échec (plan §2.5 : `0` succès, `1` travail en échec, `2` usage,
    /// `3` app injoignable).
    ///
    /// - `.appUnreachable` → `.appUnreachable`, et c'est le **seul** cas qui rend 3 ;
    /// - tout ``ControlProtocolError`` → `.usage` : la demande n'est pas exécutable telle quelle
    ///   (ligne illisible, commande inconnue, opérande manquant, option inconnue, version inconnue) ;
    /// - ``TranscriptQueryError/notFound(query:)`` → `.jobFailed` : la demande est bien formée, la
    ///   chose demandée n'existe pas — un `read` d'un transcript supprimé n'est pas une faute d'usage ;
    /// - ``TranscriptQueryError/ambiguous(query:candidates:)``,
    ///   ``TranscriptQueryError/outsideLibrary(query:)`` et ``TranscriptQueryError/emptyQuery`` →
    ///   `.usage` : la requête elle-même ne désigne pas un transcript unique et légal ;
    /// - **toute autre erreur** → `.jobFailed` : un échec inconnu n'est jamais un succès.
    public static func exitCode(for error: Error) -> ControlExitCode {
        if let erreur = error as? ControlProtocolError {
            // Un seul cas rend 3 : l'application injoignable. Tout le reste de ce type est une
            // demande inexploitable telle quelle — ligne illisible, commande inconnue, opérande
            // manquant, option inconnue, version inconnue : c'est un usage, code 2.
            return erreur == .appUnreachable ? .appUnreachable : .usage
        }
        if let erreur = error as? TranscriptQueryError {
            switch erreur {
            case .notFound:
                // La demande est bien formée, la chose demandée n'existe pas : un `read` d'un
                // transcript supprimé n'est pas une faute d'usage.
                return .jobFailed
            case .ambiguous, .outsideLibrary, .emptyQuery:
                // La requête elle-même ne désigne pas un transcript unique et légal.
                return .usage
            }
        }
        // Un échec inconnu n'est jamais un succès.
        return .jobFailed
    }

    /// Met une requête en ligne : un objet JSON, **terminé par un saut de ligne**, sans autre saut
    /// de ligne à l'intérieur. Jamais joliment indenté (une ligne = un message).
    public static func encodeRequest(_ request: ControlRequest) throws -> Data {
        try Self.miseEnLigne(Self.encodeurJSON.encode(request))
    }

    /// Lit une requête à partir d'une ligne **complète** (terminateur inclus).
    ///
    /// Refuse, sans jamais planter, **dans cet ordre** : la ligne vide (`.emptyLine`), l'absence de
    /// terminateur (`.truncatedLine`), l'UTF-8 invalide (`.notUTF8`), un saut de ligne à l'intérieur
    /// (`.malformedLine`), du JSON qui n'est pas un objet ou auquel il manque `version`/`command`
    /// (`.malformedLine`), une version inconnue (`.unsupportedVersion`) et une commande hors de la
    /// table (`.unknownCommand`). L'ordre compte : c'est lui qui décide du **cas nommé** que
    /// reçoit un octet illisible.
    public static func decodeRequest(line: Data) throws -> ControlRequest {
        let texte = try contenuDeLigne(line)
        let dictionnaire = try objet(texte, champsObligatoires: ["version", "command"])
        let version = try entier(dictionnaire, "version")
        guard version == Self.version else {
            throw ControlProtocolError.unsupportedVersion(version)
        }
        let commandeBrute = try chaineObligatoire(dictionnaire, "command")
        guard let commande = ControlCommand(rawValue: commandeBrute) else {
            throw ControlProtocolError.unknownCommand(commandeBrute)
        }
        let format: ControlFormat?
        if let valeur = try chaine(dictionnaire, "format") {
            guard let valeurConnue = ControlFormat(rawValue: valeur) else {
                throw ControlProtocolError.malformedLine(reason: "format inconnu : \(valeur)")
            }
            format = valeurConnue
        } else {
            format = nil
        }
        // Les champs facultatifs absents retombent sur les valeurs par défaut de la requête :
        // c'est ce qui rend la ligne `{"version":1,"command":"list"}` un message valide.
        return ControlRequest(
            version: version,
            command: commande,
            source: try chaine(dictionnaire, "source"),
            language: try chaine(dictionnaire, "language"),
            format: format,
            output: try chaine(dictionnaire, "output"),
            wait: try booleen(dictionnaire, "wait") ?? false,
            json: try booleen(dictionnaire, "json") ?? false)
    }

    /// Met une réponse en ligne : un objet JSON, **terminé par un saut de ligne**.
    public static func encodeResponse(_ response: ControlResponse) throws -> Data {
        try Self.miseEnLigne(Self.encodeurJSON.encode(response))
    }

    /// Lit une réponse à partir d'une ligne **complète** (terminateur inclus). Mêmes refus que
    /// ``decodeRequest(line:)``.
    ///
    /// **C'est ici que se joue la troncature** : une réponse dont la ligne n'est pas terminée, ou
    /// dont une partie seulement a été reçue, est refusée (`.truncatedLine` / `.malformedLine`) —
    /// elle n'est **jamais** acceptée comme valide, même si son début est un JSON bien formé.
    public static func decodeResponse(line: Data) throws -> ControlResponse {
        let texte = try contenuDeLigne(line)
        let dictionnaire = try objet(texte, champsObligatoires: ["version", "exitCode"])
        let version = try entier(dictionnaire, "version")
        guard version == Self.version else {
            throw ControlProtocolError.unsupportedVersion(version)
        }
        let codeBrut = try entier(dictionnaire, "exitCode")
        guard let exitCode = ControlExitCode(rawValue: codeBrut) else {
            throw ControlProtocolError.malformedLine(
                reason: "code de sortie inconnu : \(codeBrut)")
        }
        return ControlResponse(
            version: version,
            exitCode: exitCode,
            listing: try sousObjet(dictionnaire, "listing", ControlListing.self),
            document: try sousObjet(dictionnaire, "document", TranscriptDocument.self),
            text: try chaine(dictionnaire, "text"),
            error: try chaine(dictionnaire, "error"))
    }

    /// Traduit les arguments du processus en requête — **le seul point de décision** du CLI sur sa
    /// propre ligne de commande (plan §2.5).
    ///
    /// Règles gelées :
    /// - `arguments[0]` est le nom de la commande ; absent, c'est ``ControlProtocolError/noCommand`` ;
    ///   hors table, c'est ``ControlProtocolError/unknownCommand(_:)`` ;
    /// - une option peut précéder ou suivre l'opérande (`read --format md <id>`) ; le **premier
    ///   argument qui n'est pas une option** est l'opérande ;
    /// - `read` et `transcribe` exigent un opérande (``ControlProtocolError/missingOperand(_:)``) ;
    ///   `list`, `status` et `version` n'en prennent pas (``ControlProtocolError/unexpectedOperand(_:)``) ;
    /// - options connues : `--language VALEUR` (critère 12), `--wait`, `--json`,
    ///   `--format json|md`, `--output DIR` ; une option sans sa valeur est
    ///   ``ControlProtocolError/optionRequiresValue(_:)``, une valeur hors des valeurs admises est
    ///   ``ControlProtocolError/invalidValue(option:value:)``, une option inconnue est
    ///   ``ControlProtocolError/unknownOption(_:)``.
    ///
    /// L'unité exécutable **doit** passer par ici : c'est ce qui garantit qu'un argument mal formé
    /// rend un code d'usage (`2`) au lieu d'un plantage ou d'une requête inventée.
    public static func request(fromArguments arguments: [String]) throws -> ControlRequest {
        guard let premiere = arguments.first else { throw ControlProtocolError.noCommand }
        guard let commande = ControlCommand(rawValue: premiere) else {
            throw ControlProtocolError.unknownCommand(premiere)
        }

        var source: String?
        var language: String?
        var format: ControlFormat?
        var output: String?
        var wait = false
        var json = false

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            // Une option peut précéder ou suivre l'opérande : le **premier** argument qui n'est pas
            // une option est l'opérande, quel que soit son rang (`read --format md ma-tige`).
            guard argument.hasPrefix("--") else {
                guard source == nil else { throw ControlProtocolError.unexpectedOperand(argument) }
                source = argument
                index += 1
                continue
            }
            switch argument {
            case "--wait":
                wait = true
            case "--json":
                json = true
            case "--language", "--format", "--output":
                // La valeur suit l'option, et son absence est un cas nommé — pas un opérande vide.
                guard index + 1 < arguments.count else {
                    throw ControlProtocolError.optionRequiresValue(argument)
                }
                let valeur = arguments[index + 1]
                switch argument {
                case "--language":
                    language = valeur
                case "--output":
                    output = valeur
                default:
                    guard let valeurConnue = ControlFormat(rawValue: valeur) else {
                        throw ControlProtocolError.invalidValue(option: argument, value: valeur)
                    }
                    format = valeurConnue
                }
                index += 1
            default:
                throw ControlProtocolError.unknownOption(argument)
            }
            index += 1
        }

        switch commande {
        case .read, .transcribe:
            guard source != nil else { throw ControlProtocolError.missingOperand(commande) }
        case .list, .status, .version:
            if let source { throw ControlProtocolError.unexpectedOperand(source) }
        }

        return ControlRequest(
            version: Self.version,
            command: commande,
            source: source,
            language: language,
            format: format,
            output: output,
            wait: wait,
            json: json)
    }

    /// Sert une commande **locale** (`list`, `read`, `version`) à partir du dossier seul.
    ///
    /// - `version` → `.success`, `text` non vide ;
    /// - `list` → `.success`, `listing` renseigné (`directory` = la racine lue, un résumé par
    ///   document lisible, `unreadableCount` = le compte de ``TranscriptLibrary/list()``) ;
    /// - `read` → `.success` et `document` renseigné (format JSON, ou format absent) ; `text`
    ///   renseigné et égal au contenu du `<tige>.md` pour `--format md` ;
    /// - `read` d'un transcript disparu → `.jobFailed`, `document` **nil**, `error` renseigné ;
    /// - une requête que ``route(for:)`` envoie à l'application (`transcribe`, `status`) →
    ///   `.appUnreachable` : cette fonction ne parle pas au socket, donc elle ne peut pas la servir,
    ///   et elle le dit au lieu de rendre un succès vide.
    ///
    /// Ne jette pas : l'échec est dans la réponse, avec son code de sortie (le README du lot 10,
    /// §4 : un `read` d'un transcript supprimé « échoue proprement »).
    public static func respondLocally(to request: ControlRequest, library: TranscriptLibrary) -> ControlResponse {
        switch request.command {
        case .version:
            return ControlResponse(
                exitCode: .success, text: "murmure \(Self.version) (control protocol \(Self.version))")

        case .list:
            let listing = library.list()
            let resumes = listing.documents.map { document in
                ControlTranscriptSummary(
                    id: document.id,
                    title: document.title,
                    status: document.status,
                    createdAt: document.createdAt,
                    duration: document.duration,
                    jsonPath: library.base.appendingPathComponent("\(document.id).json").path,
                    markdownPath: library.base.appendingPathComponent("\(document.id).md").path)
            }
            return ControlResponse(
                exitCode: .success,
                listing: ControlListing(
                    directory: library.base.path,
                    transcripts: resumes,
                    unreadableCount: listing.unreadableCount))

        case .read:
            do {
                let cible = try TranscriptQuery(library: library).resolve(request.source ?? "")
                if request.format == .md {
                    // Le Markdown est la source de vérité humaine : on rend son contenu, pas un
                    // rendu recalculé — sinon `read --format md` ne dirait pas ce que le fichier dit.
                    guard let contenu = try? String(contentsOf: cible.markdownURL, encoding: .utf8)
                    else {
                        return ControlResponse(
                            exitCode: .jobFailed,
                            error: "No Markdown file for « \(cible.id) » at \(cible.markdownURL.path).")
                    }
                    return ControlResponse(exitCode: .success, text: contenu)
                }
                guard let document = library.transcript(id: cible.id) else {
                    return ControlResponse(
                        exitCode: .jobFailed,
                        error: "The transcript « \(cible.id) » could not be read.")
                }
                return ControlResponse(exitCode: .success, document: document)
            } catch {
                return ControlResponse(exitCode: exitCode(for: error), error: message(for: error))
            }

        case .transcribe, .status:
            // Cette fonction ne parle pas au socket : elle ne peut pas servir une commande qui
            // appartient à l'application, et elle le dit au lieu de rendre un succès vide.
            return ControlResponse(
                exitCode: .appUnreachable,
                error: "Murmure is not running: « \(request.command.rawValue) » needs the application.")
        }
    }

    // MARK: - Détails d'implémentation

    /// L'encodeur des messages : JSON **compact** (une ligne = un message, jamais joliment
    /// indenté) et dates ISO-8601. La stratégie de dates est celle du reste du projet — un
    /// transcript relu par un agent doit se lire comme `murmure read` l'affiche.
    private static let encodeurJSON: JSONEncoder = {
        let encodeur = JSONEncoder()
        encodeur.dateEncodingStrategy = .iso8601
        return encodeur
    }()

    /// Le décodeur des sous-objets du schéma (`listing`, `document`) : même stratégie de dates que
    /// l'encodeur, sans quoi une réponse ne se relirait pas par l'autre bout.
    private static func decodeurJSON() -> JSONDecoder {
        let decodeur = JSONDecoder()
        decodeur.dateDecodingStrategy = .iso8601
        return decodeur
    }

    /// La mise en ligne du protocole : un objet JSON **terminé par son saut de ligne**.
    ///
    /// Le terminateur fait partie du message — c'est lui qui rend la troncature détectable, et
    /// c'est pourquoi il est ajouté ici et nulle part ailleurs. Un encodeur compact garantit qu'il
    /// n'y en a pas d'autre à l'intérieur.
    private static func miseEnLigne(_ charge: Data) throws -> Data {
        var ligne = charge
        ligne.append(0x0A)
        return ligne
    }

    /// Le contenu d'une ligne **complète**, validé dans l'ordre gelé par le contrat : vide,
    /// sans terminateur (tronquée), non-UTF-8, saut de ligne à l'intérieur. L'ordre compte :
    /// c'est lui qui décide du cas nommé que reçoit un octet illisible.
    private static func contenuDeLigne(_ ligne: Data) throws -> String {
        guard !ligne.isEmpty else { throw ControlProtocolError.emptyLine }
        guard ligne.last == 0x0A else { throw ControlProtocolError.truncatedLine }
        let corps = ligne.dropLast()
        // Un saut de ligne seul : le pair a fermé la ligne sans rien écrire.
        guard !corps.isEmpty else { throw ControlProtocolError.emptyLine }
        guard let texte = String(data: corps, encoding: .utf8) else {
            throw ControlProtocolError.notUTF8
        }
        guard !texte.contains("\n"), !texte.contains("\r") else {
            throw ControlProtocolError.malformedLine(reason: "un message tient sur une seule ligne")
        }
        return texte
    }

    /// L'objet JSON de la ligne, ses champs obligatoires vérifiés. Un tableau, un scalaire ou du
    /// texte ne sont pas des messages.
    private static func objet(
        _ texte: String, champsObligatoires: [String]
    ) throws -> [String: Any] {
        guard let donnees = texte.data(using: .utf8),
            let valeur = try? JSONSerialization.jsonObject(with: donnees),
            let dictionnaire = valeur as? [String: Any]
        else {
            throw ControlProtocolError.malformedLine(reason: "le message n'est pas un objet JSON")
        }
        for champ in champsObligatoires
        where dictionnaire[champ] == nil || dictionnaire[champ] is NSNull {
            throw ControlProtocolError.malformedLine(reason: "champ obligatoire absent : \(champ)")
        }
        return dictionnaire
    }

    /// Un champ de la ligne, quand il doit être là et entier.
    private static func entier(_ dictionnaire: [String: Any], _ cle: String) throws -> Int {
        guard let valeur = dictionnaire[cle] as? Int else {
            throw ControlProtocolError.malformedLine(reason: "« \(cle) » n'est pas un entier")
        }
        return valeur
    }

    /// Un champ de la ligne, quand il doit être là et textuel.
    private static func chaineObligatoire(_ dictionnaire: [String: Any], _ cle: String) throws -> String {
        guard let valeur = try chaine(dictionnaire, cle) else {
            throw ControlProtocolError.malformedLine(reason: "champ obligatoire absent : \(cle)")
        }
        return valeur
    }

    /// Un champ facultatif de la ligne. Absent → `nil` ; présent mais d'un autre type → refus :
    /// une requête dont un champ a la mauvaise forme ne doit pas être interprétée au mieux.
    private static func chaine(_ dictionnaire: [String: Any], _ cle: String) throws -> String? {
        guard let valeur = dictionnaire[cle], !(valeur is NSNull) else { return nil }
        guard let texte = valeur as? String else {
            throw ControlProtocolError.malformedLine(reason: "« \(cle) » n'est pas du texte")
        }
        return texte
    }

    /// Un champ booléen facultatif de la ligne, absent → `nil` (l'appelant applique son défaut).
    private static func booleen(_ dictionnaire: [String: Any], _ cle: String) throws -> Bool? {
        guard let valeur = dictionnaire[cle], !(valeur is NSNull) else { return nil }
        guard let drapeau = valeur as? Bool else {
            throw ControlProtocolError.malformedLine(reason: "« \(cle) » n'est pas un booléen")
        }
        return drapeau
    }

    /// Un sous-objet du schéma du protocole (`listing`, `document`), décodé par le décodeur du
    /// module : c'est ce qui fait qu'un document écrit sur disque se relit ici sans détour.
    private static func sousObjet<T: Decodable>(
        _ dictionnaire: [String: Any], _ cle: String, _ type: T.Type
    ) throws -> T? {
        guard let valeur = dictionnaire[cle], !(valeur is NSNull) else { return nil }
        guard let donnees = try? JSONSerialization.data(withJSONObject: valeur) else {
            throw ControlProtocolError.malformedLine(reason: "« \(cle) » n'est pas un objet JSON")
        }
        do {
            return try decodeurJSON().decode(type, from: donnees)
        } catch {
            throw ControlProtocolError.malformedLine(
                reason: "« \(cle) » n'a pas le schéma attendu")
        }
    }

    /// La phrase d'un échec : **tout échec est dit**. La charge d'un refus de requête est
    /// réaffichée telle qu'elle a été donnée, parce que c'est ce qui rend le refus reconnaissable.
    private static func message(for error: Error) -> String {
        guard let erreur = error as? TranscriptQueryError else { return "\(error)" }
        switch erreur {
        case .emptyQuery:
            return "No transcript was named."
        case .notFound(let query):
            return "No transcript matches « \(query) »."
        case .ambiguous(let query, let candidates):
            return "Several transcripts match « \(query) »: \(candidates.joined(separator: ", "))."
        case .outsideLibrary(let query):
            return "« \(query) » is outside the transcript library."
        }
    }
}

/// Le point d'écoute du CLI : où est le socket, et **ce qui garantit qu'il n'est pas ouvert à tout
/// le monde** (plan §0, décision **R4**).
///
/// R4 est une décision de sécurité, pas un détail de transport : « socket dans
/// `Application Support/Murmure/`, permissions `0600`, répertoire parent `0700`, et vérification du
/// pair (`LOCAL_PEERPID` + UID identique) avant toute commande. Aucune écoute réseau
/// (`127.0.0.1` TCP écarté). »
///
/// Les trois exigences vérifiables sans ouvrir de socket sont gelées ici : les deux chemins, les
/// deux modes, et le prédicat d'UID du pair. Ce qui reste au câblage (lot 11, `Murmure/
/// TranscriptControlServer.swift`) est l'appel à `LOCAL_PEERPID` lui-même — c'est l'adaptateur de
/// transport, hors de ce contrat.
public enum ControlEndpoint {
    /// Le répertoire du socket : `~/Library/Application Support/Murmure/`, celui de l'application
    /// (§2.4 : la même racine que les transcripts et que la base, jamais `~/Documents`).
    /// Il doit être en **0700** : le nom d'un socket n'est lisible que par qui peut entrer.
    public static var directory: URL {
        // Passe par `Storage`, comme `TranscriptLibrary.defaultBase` : c'est le seul endroit du
        // module qui sait où est Application Support, et le socket doit vivre dans **le même**
        // dossier que la base et les transcripts (§2.4).
        Storage.url(in: Storage.applicationSupport)
    }

    /// Le socket de contrôle : `~/Library/Application Support/Murmure/control.sock` (plan §2.5).
    public static var socketURL: URL {
        directory.appendingPathComponent("control.sock")
    }

    /// Le mode exigé du socket (R4 : `0600`, en octal — `384` en décimal).
    public static let socketPermissions = 0o600

    /// Le mode exigé du répertoire parent (R4 : `0700`, en octal — `448` en décimal).
    public static let directoryPermissions = 0o700

    /// Le pair a-t-il le droit de commander ? **Uniquement s'il a le même UID que nous.**
    ///
    /// C'est la moitié de R4 qui se vérifie sans socket : le serveur lit l'UID du pair (par
    /// `LOCAL_PEERPID`) et n'exécute la commande que si ce prédicat est vrai. Un autre compte de la
    /// machine — et, sur un système multi-utilisateur, c'est le cas qui compte — est refusé.
    public static func acceptsPeer(ownUID: uid_t, peerUID: uid_t) -> Bool {
        ownUID == peerUID
    }
}
