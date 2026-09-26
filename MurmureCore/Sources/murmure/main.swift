import Darwin
import Foundation
import MurmureCore

// Le binaire `murmure` — l'adaptateur de transport du protocole de contrôle (plan §2.5, lot 11).
//
// **Ce fichier ne décide de rien.** La table de routage, les codes de sortie, la mise en ligne JSON
// et la traduction des arguments vivent dans `MurmureCore.ControlProtocol`, donc sous `swift test`
// (§2.5 : « le socket n'est qu'un adaptateur de transport »). Ici il n'y a que le processus : lire
// sa ligne de commande, servir les trois commandes **locales** sur le dossier — elles marchent
// application fermée, c'est le critère 20 — et parler au socket pour les deux qui appartiennent à
// l'application.
//
// **Trois variables d'environnement, qui servent la vérification et pas l'usage** :
// `MURMURE_TRANSCRIPTS_DIR` (la racine lue), `MURMURE_CONTROL_SOCKET` (le socket visé) et
// `MURMURE_NO_APP_LAUNCH` (ne pas ouvrir l'application). Sans elles,
// `scripts/checks/cli-end-to-end.sh` lirait et écrirait dans la bibliothèque **réelle** de
// l'utilisateur et lancerait une copie de Murmure.app : ni un test ni une gate ne font ça
// (AGENTS.md). Absentes, le binaire se comporte exactement comme §2.5 le décrit.

let arguments = Array(CommandLine.arguments.dropFirst())
let environnement = ProcessInfo.processInfo.environment

// MARK: - Où lire, à qui parler

/// La racine de la bibliothèque lue par ce processus : celle de l'application (R3) — c'est-à-dire
/// `~/Library/Application Support/Murmure/Transcripts/` — sauf redirection de vérification.
func racineLue() -> URL {
    guard let chemin = environnement["MURMURE_TRANSCRIPTS_DIR"], !chemin.isEmpty else {
        return TranscriptLibrary.defaultBase
    }
    return URL(fileURLWithPath: chemin)
}

/// Le socket visé : celui de R4 — `Application Support/Murmure/control.sock` — sauf redirection de
/// vérification.
func socketVise() -> URL {
    guard let chemin = environnement["MURMURE_CONTROL_SOCKET"], !chemin.isEmpty else {
        return ControlEndpoint.socketURL
    }
    return URL(fileURLWithPath: chemin)
}

// MARK: - Sortie

func imprimer(_ texte: String) {
    FileHandle.standardOutput.write(Data((texte + "\n").utf8))
}

func ecrireErreur(_ texte: String) {
    FileHandle.standardError.write(Data((texte + "\n").utf8))
}

/// Un objet du schéma, lisible : JSON indenté, dates ISO-8601, clés triées.
func jsonLisible<T: Encodable>(_ valeur: T) -> String? {
    let encodeur = JSONEncoder()
    encodeur.dateEncodingStrategy = .iso8601
    encodeur.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let donnees = try? encodeur.encode(valeur) else { return nil }
    return String(data: donnees, encoding: .utf8)
}

/// La phrase d'un refus du protocole : **tout échec est dit** (aucun échec silencieux).
func phrase(_ erreur: ControlProtocolError) -> String {
    switch erreur {
    case .emptyLine:
        return "The message was empty."
    case .notUTF8:
        return "The message was not UTF-8."
    case .truncatedLine:
        return "The message was truncated: it did not end with its newline, so it was not accepted."
    case .malformedLine(let raison):
        return "The message could not be read: \(raison)."
    case .unsupportedVersion(let version):
        return "Unsupported control protocol version \(version) (this CLI speaks \(ControlProtocol.version))."
    case .noCommand:
        return "No command given. Try « murmure version »."
    case .unknownCommand(let commande):
        return "Unknown command « \(commande) »."
    case .missingOperand(let commande):
        return "« \(commande.rawValue) » needs an argument."
    case .unknownOption(let option):
        return "Unknown option « \(option) »."
    case .optionRequiresValue(let option):
        return "« \(option) » needs a value."
    case .invalidValue(let option, let valeur):
        return "« \(option) » does not take « \(valeur) »."
    case .unexpectedOperand(let operande):
        return "Unexpected argument « \(operande) »."
    case .appUnreachable:
        return "Murmure is not running."
    }
}

// MARK: - Le transport (socket UNIX, une requête par ligne — §2.5)

enum TransportError: LocalizedError {
    case injoignable(String)

    /// La phrase que le CLI imprime quand le socket ne répond pas : le chemin et le code POSIX, pas
    /// « une erreur est survenue ».
    var errorDescription: String? {
        switch self {
        case .injoignable(let raison): raison
        }
    }
}

/// Écrit tout le tampon, quitte à y revenir : une écriture partielle n'est pas un échec.
func ecrire(_ donnees: Data, sur descripteur: Int32) throws {
    var restant = donnees[...]
    while !restant.isEmpty {
        let ecrits = restant.withUnsafeBytes { tampon in
            write(descripteur, tampon.baseAddress, tampon.count)
        }
        guard ecrits > 0 else {
            throw TransportError.injoignable("write(2) failed (errno \(errno))")
        }
        restant = restant.dropFirst(ecrits)
    }
}

/// Lit **une ligne**, terminateur inclus. Si le pair ferme avant de l'avoir écrite, ce qui a été
/// reçu est rendu tel quel : le décodeur le refusera comme tronqué — c'est exactement la propriété
/// que le protocole demande (une réponse tronquée n'est jamais valide).
func lireUneLigne(sur descripteur: Int32) throws -> Data {
    var ligne = Data()
    var tampon = [UInt8](repeating: 0, count: 4096)
    while true {
        let lus = read(descripteur, &tampon, tampon.count)
        if lus == 0 { return ligne }
        guard lus > 0 else {
            throw TransportError.injoignable("read(2) failed (errno \(errno))")
        }
        if let position = tampon[0..<lus].firstIndex(of: 0x0A) {
            ligne.append(contentsOf: tampon[0...position])
            return ligne
        }
        ligne.append(contentsOf: tampon[0..<lus])
    }
}

/// Une connexion, une requête, une réponse, fermée. Aucune écoute, aucun port réseau : un socket
/// UNIX local (R4 écarte `127.0.0.1`).
func echanger(_ ligne: Data, avec chemin: URL, delai: TimeInterval?) throws -> Data {
    let descripteur = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descripteur >= 0 else {
        throw TransportError.injoignable("socket(2) failed (errno \(errno))")
    }
    defer { close(descripteur) }

    // Un délai de lecture borne l'attente d'une commande servie par l'application. `transcribe
    // --wait` n'en a pas : le travail peut prendre des heures, et le pair qui meurt est détecté par
    // la fermeture de sa connexion, pas par une horloge.
    if let delai {
        var attente = timeval(tv_sec: Int(delai), tv_usec: 0)
        setsockopt(descripteur, SOL_SOCKET, SO_RCVTIMEO, &attente, socklen_t(MemoryLayout<timeval>.size))
    }

    var adresse = sockaddr_un()
    adresse.sun_family = sa_family_t(AF_UNIX)
    let cheminAbsolu = chemin.path
    guard cheminAbsolu.utf8.count + 1 <= MemoryLayout.size(ofValue: adresse.sun_path) else {
        throw TransportError.injoignable("control socket path too long: \(cheminAbsolu)")
    }
    withUnsafeMutablePointer(to: &adresse.sun_path) { pointeur in
        pointeur.withMemoryRebound(to: CChar.self, capacity: cheminAbsolu.utf8.count + 1) {
            destination in
            _ = cheminAbsolu.utf8CString.withUnsafeBufferPointer { source in
                memcpy(destination, source.baseAddress!, source.count)
            }
        }
    }
    adresse.sun_len = UInt8(MemoryLayout.size(ofValue: adresse))

    let connecte = withUnsafePointer(to: &adresse) { pointeur in
        pointeur.withMemoryRebound(to: sockaddr.self, capacity: 1) { brut in
            connect(descripteur, brut, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connecte == 0 else {
        throw TransportError.injoignable("no control socket at \(cheminAbsolu) (errno \(errno))")
    }

    try ecrire(ligne, sur: descripteur)
    return try lireUneLigne(sur: descripteur)
}

/// Ouvre l'application quand le socket est absent (plan §2.5 : « socket absent → le CLI ouvre
/// l'app, puis réessaie pendant 10 s avant d'échouer en code 3 »).
///
/// L'application ouverte est **celle qui porte ce binaire** : `murmure` est copié dans
/// `Murmure.app/Contents/MacOS/` (project.yml), donc `Bundle.main.bundleURL` **est** le bundle.
/// Un binaire lancé depuis `.build/` n'est dans aucun bundle et n'ouvre rien — le CLI ne devine
/// pas l'emplacement d'une installation, et `MURMURE_NO_APP_LAUNCH` désarme ce chemin.
func ouvrirApplication() {
    guard environnement["MURMURE_NO_APP_LAUNCH"] == nil else { return }
    let bundle = Bundle.main.bundleURL
    guard bundle.pathExtension == "app" else { return }
    let ouverture = Process()
    ouverture.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    ouverture.arguments = ["-gj", bundle.path]
    try? ouverture.run()
}

/// Une requête au socket : la ligne écrite, la ligne lue, décodée.
func demander(_ ligne: Data, au chemin: URL, delai: TimeInterval?) throws -> ControlResponse {
    let reponseLigne = try echanger(ligne, avec: chemin, delai: delai)
    return try ControlProtocol.decodeResponse(line: reponseLigne)
}

/// Sert une commande qui appartient à l'application : le socket, ou le code 3.
func parlerAuSocket(_ requete: ControlRequest) -> ControlResponse {
    guard let ligne = try? ControlProtocol.encodeRequest(requete) else {
        return ControlResponse(exitCode: .usage, error: "The request could not be encoded.")
    }
    let chemin = socketVise()
    let delai: TimeInterval? = requete.wait ? nil : 30
    do {
        return try demander(ligne, au: chemin, delai: delai)
    } catch let erreur as ControlProtocolError {
        // Le pair a répondu, et sa réponse est refusée : c'est un usage, pas une absence.
        return ControlResponse(exitCode: ControlProtocol.exitCode(for: erreur), error: phrase(erreur))
    } catch {
        ouvrirApplication()
        var derniere = error
        let echeance = Date().addingTimeInterval(10)
        while Date() < echeance {
            Thread.sleep(forTimeInterval: 0.25)
            do {
                return try demander(ligne, au: chemin, delai: delai)
            } catch let erreur as ControlProtocolError {
                return ControlResponse(
                    exitCode: ControlProtocol.exitCode(for: erreur), error: phrase(erreur))
            } catch {
                derniere = error
            }
        }
        return ControlResponse(
            exitCode: .appUnreachable,
            error: "Murmure could not be reached at \(chemin.path): \(derniere).")
    }
}

// MARK: - La sortie de la commande

/// `transcribe --output DIR` : poser les copies de sortie (§2.5).
///
/// **Le code vient d'abord de la réponse.** Une réponse qui dit l'échec (1) ou l'application
/// injoignable (3) rend **son** code et ne copie rien : il n'y a pas de document à copier, et
/// annoncer « `--output` needs `--wait` » serait faux (le `--wait` **a** été demandé) — deux
/// raisons contradictoires sur la même sortie d'erreur. C'est le défaut corrigé après la revue
/// round 1 (F1) : `--output` écrasait le code de sortie de la réponse.
///
/// **Un succès sans document, oui** : sans `--wait` le travail est mis à la file et la réponse
/// revient avant qu'un transcript existe. Demander une copie qui ne peut pas exister est une
/// demande inexploitable telle quelle — code d'usage (2), dit sur la sortie d'erreur.
func copierSortie(_ reponse: ControlResponse, vers dossier: String?, depuis racine: URL) -> ControlExitCode {
    guard let dossier else { return reponse.exitCode }
    // Le refus du pair est le code de la réponse : le remplacer par un 2 ferait d'un « injoignable »
    // un « usage », et noierait la raison que la réponse porte.
    guard reponse.exitCode == .success else { return reponse.exitCode }
    guard let document = reponse.document else {
        ecrireErreur(
            "nothing to copy to \(dossier): the response carries no transcript yet "
                + "(`--output` needs `--wait`).")
        return .usage
    }
    let destination = URL(fileURLWithPath: dossier, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for extensionFichier in [".json", ".md"] {
            let source = racine.appendingPathComponent("\(document.id)\(extensionFichier)")
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let cible = destination.appendingPathComponent("\(document.id)\(extensionFichier)")
            try? FileManager.default.removeItem(at: cible)
            try FileManager.default.copyItem(at: source, to: cible)
        }
        return reponse.exitCode
    } catch {
        ecrireErreur("the transcript was not copied to \(dossier): \(error).")
        return .jobFailed
    }
}

/// Imprime ce que la commande a produit, copie les sorties demandées, et sort avec le code de la
/// réponse. Le code **est** la décision (plan §2.5 : `0` succès, `1` échec, `2` usage, `3` app
/// injoignable), et il vient toujours de la réponse ou du refus — jamais d'un défaut.
func rendre(_ reponse: ControlResponse, requete: ControlRequest, racine: URL) -> Never {
    if let erreur = reponse.error { ecrireErreur(erreur) }

    if requete.json, let ligne = try? ControlProtocol.encodeResponse(reponse) {
        // Le fil est déjà du JSON : `--json` imprime la réponse elle-même, terminateur retiré.
        if let texte = String(data: ligne.dropLast(), encoding: .utf8) { imprimer(texte) }
    } else {
        switch requete.command {
        case .version:
            if let texte = reponse.text { imprimer(texte) }

        case .list:
            if let listing = reponse.listing {
                imprimer("\(listing.transcripts.count) transcript(s) in \(listing.directory)")
                for resume in listing.transcripts {
                    imprimer(
                        "\(resume.id)\t\(resume.status.rawValue)\t"
                            + "\(String(format: "%.1f", resume.duration))s\t\(resume.jsonPath)")
                }
                if listing.unreadableCount > 0 {
                    imprimer("unreadable: \(listing.unreadableCount)")
                }
            }

        case .read:
            if let texte = reponse.text {
                // `read --format md` : le contenu du fichier, tel quel.
                FileHandle.standardOutput.write(Data(texte.utf8))
            } else if let document = reponse.document, let texte = jsonLisible(document) {
                imprimer(texte)
            }

        case .transcribe, .status:
            if let texte = reponse.text { imprimer(texte) }
            if let document = reponse.document {
                imprimer("\(document.id)\t\(document.status.rawValue)\t\(document.coverage.ratio)")
            }
        }
    }

    exit(Int32(copierSortie(reponse, vers: requete.output, depuis: racine).rawValue))
}

// MARK: - Le processus

do {
    let requete = try ControlProtocol.request(fromArguments: arguments)
    let racine = racineLue()
    let reponse =
        ControlProtocol.route(for: requete.command) == .local
        ? ControlProtocol.respondLocally(to: requete, library: TranscriptLibrary(base: racine))
        : parlerAuSocket(requete)
    rendre(reponse, requete: requete, racine: racine)
} catch {
    // Un argument mal formé rend un code d'usage, jamais un plantage (plan §2.5 : `2` usage).
    if let erreur = error as? ControlProtocolError {
        ecrireErreur(phrase(erreur))
    } else {
        ecrireErreur("\(error)")
    }
    exit(Int32(ControlProtocol.exitCode(for: error).rawValue))
}
