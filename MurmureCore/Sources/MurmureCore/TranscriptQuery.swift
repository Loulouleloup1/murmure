import Foundation

// CONTRAT lot 11 — **implémenté** (carte `dev` `t_6879ee2e`).
//
// Déclaration du contrat de **résolution d'un transcript** pour le CLI (plan §2.5 : `murmure read
// <id|chemin>` ; §4 lot 11 ; critère 20 « commande locale, retour 0 »). Écrite par la carte `qa`
// `t_874dd36d` avant l'implémentation : les corps étaient alors des sentinelles, et les tests
// rouges `TranscriptQueryTests.swift` échouaient sur une assertion explicite ; la carte `dev`
// `t_6879ee2e` a remplacé ces corps (sans toucher aux signatures, §7.1 règle 5).
//
// **Pourquoi ce type existe, et pourquoi il vit dans le cœur.** `read` et `list` doivent marcher
// **application fermée** (§2.5) : la résolution ne peut donc pas demander au socket, ni à un index.
// Elle lit le dossier — « l'index, c'est le dossier » (§2.4) — et c'est une décision pure, donc
// testable. Le CLI n'est que l'adaptateur qui imprime le résultat.
//
// **L'invariant qui tient tout le reste** (§2.4, révision 8) : l'`id` d'un document est la tige de
// son fichier. C'est ce qui autorise « résoudre par identifiant », « par tige de nom » et « par
// chemin » à désigner **le même transcript**, et ce qui interdit à un `murmure read <id>` de
// désigner autre chose que le fichier qu'on croit.
//
// **Ce que ce contrat ne gèle pas** : la règle de collision de tige (§2.4, révision 8 — la tige
// d'un travail reprisable est réutilisée telle quelle, une source a au plus un document reprisable).
// C'est ``TranscriptLibrary`` qui la décide à l'écriture ; la résolution ne fait que *lire* les
// fichiers présents, et une tige ambiguë est **refusée** plutôt qu'arbitrée.

/// L'échec d'une résolution. Quatre cas, tous distincts, parce que l'appelant en fait des codes de
/// sortie différents (``ControlProtocol/exitCode(for:)``) et des phrases différentes.
///
/// **Les charges portent la requête telle qu'elle a été donnée** (les blancs qui l'entourent ont
/// été retirés, rien d'autre) : c'est ce que l'appelant réaffiche, et c'est ce qui rend le refus
/// reconnaissable par un test comme par Louis.
public enum TranscriptQueryError: Error, Equatable {
    /// La requête est vide (ou ne contient que des blancs) : elle ne désigne rien.
    case emptyQuery
    /// Aucun transcript de la bibliothèque ne correspond — **y compris un fichier supprimé depuis**
    /// (un `read` d'un transcript disparu « échoue proprement », il ne plante pas et ne rend pas un
    /// document vide).
    case notFound(query: String)
    /// Plusieurs transcripts correspondent : la requête ne désigne pas **un** transcript. Les
    /// candidats sont listés (triés) pour que l'appelant puisse les montrer.
    case ambiguous(query: String, candidates: [String])
    /// La requête est un chemin qui **sortirait de la bibliothèque** (`../…`, chemin absolu
    /// ailleurs). Refus explicite : le CLI accepte un chemin venu de l'extérieur, et il n'écrit ni
    /// ne lit jamais hors de `~/Library/Application Support/Murmure/Transcripts/`.
    case outsideLibrary(query: String)
}

/// Ce qu'une résolution rend : de quoi lire le document, et de quoi lire son Markdown — **les deux
/// fichiers de la même tige** (critère 21 : un agent qui trouve l'un trouve l'autre sans index).
public struct TranscriptQueryTarget: Equatable {
    /// L'`id` du document, qui est la tige de son fichier.
    public let id: String
    /// Le `<tige>.json` : la source de vérité machine (§2.4). C'est ce fichier qui doit exister et
    /// se décoder pour que la résolution aboutisse.
    public let jsonURL: URL
    /// Le `<tige>.md` : la source de vérité humaine. **Sa présence n'est pas exigée** par la
    /// résolution (l'écriture du `.md` peut avoir été interrompue), mais son chemin est rendu.
    public let markdownURL: URL

    public init(id: String, jsonURL: URL, markdownURL: URL) {
        self.id = id
        self.jsonURL = jsonURL
        self.markdownURL = markdownURL
    }
}

/// La résolution d'une requête de transcript, **hors ligne** : elle ne connaît que la racine de la
/// bibliothèque et ce qu'elle contient.
///
/// Règles gelées par ce contrat :
///
/// 1. **Blancs** : la requête est d'abord débarrassée des blancs et sauts de ligne qui
///    l'entourent. S'il ne reste rien → ``TranscriptQueryError/emptyQuery``.
/// 2. **Nature de la requête**, dans cet ordre :
///    - elle contient un séparateur de chemin (`/`) ou commence par `~` → c'est un **chemin** ;
///    - sinon, elle se termine par `.json` ou `.md` → c'est un **nom de fichier** de la racine ;
///    - sinon → c'est un **identifiant ou une tige**.
/// 3. **Chemin** : un chemin relatif est résolu **depuis la racine de la bibliothèque** (jamais
///    depuis le répertoire courant : la même commande doit vouloir dire la même chose d'où qu'elle
///    soit lancée), `~` est développé, puis le chemin est **normalisé** (`.`, `..`). Le résultat
///    doit être **dans** la racine — sinon ``TranscriptQueryError/outsideLibrary(query:)``, et
///    c'est le refus explicite du `../`. Un chemin qui reste dans la racine mais ne désigne pas un
///    transcript de la racine (un fichier de `work/`, un nom qui n'existe pas, un dossier) →
///    ``TranscriptQueryError/notFound(query:)``.
/// 4. **Identifiant ou tige** : l'égalité avec l'`id` d'un document lisible l'emporte **toujours**
///    (même si d'autres ids le commencent). Sinon les ids dont la tige **commence** par la requête
///    forment les candidats : un seul → il est résolu ; plusieurs →
///    ``TranscriptQueryError/ambiguous(query:candidates:)`` avec les candidats **triés** ;
///    aucun → ``TranscriptQueryError/notFound(query:)``.
/// 5. Les comparaisons sont **sensibles à la casse** : la tige est un nom de fichier, et celui-ci
///    se recopie tel que `list` l'a imprimé (une requête à la casse approximative ne résout rien
///    plutôt que de résoudre le mauvais fichier).
/// 6. Ne lit **que** des fichiers de la racine de la bibliothèque : un `.json` illisible ne compte
///    pas comme un document (§2.4, invariant d'`id` et compte des illisibles).
public struct TranscriptQuery {
    /// La bibliothèque lue. Aucune autre racine n'est consultable par ce type.
    public let library: TranscriptLibrary

    public init(library: TranscriptLibrary) {
        self.library = library
    }

    /// La racine de la bibliothèque, injectable (même motif que ``TranscriptLibrary``) : les tests
    /// résolvent dans un dossier temporaire, **jamais** dans `Application Support`.
    public init(base: URL = TranscriptLibrary.defaultBase) {
        self.init(library: TranscriptLibrary(base: base))
    }

    /// La racine lue, telle quelle.
    public var base: URL {
        library.base
    }

    /// Résout `query` en **un** transcript, ou refuse en le disant (les règles sont sur le type).
    public func resolve(_ query: String) throws -> TranscriptQueryTarget {
        // Règle 1 : les blancs qui entourent la requête ne désignent rien, ils sont retirés — et
        // la charge d'un refus est la requête **telle qu'elle a été donnée**.
        let requete = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requete.isEmpty else { throw TranscriptQueryError.emptyQuery }

        // Règle 2 : la nature de la requête décide de la façon de la résoudre, dans cet ordre.
        if requete.contains("/") || requete.hasPrefix("~") {
            return try resoudreChemin(requete)
        }
        return try resoudreParTige(Self.tigeSansExtension(requete), requete: requete)
    }

    // MARK: - Détails d'implémentation

    /// Un chemin (règle 3) : relatif, il se résout **depuis la racine** — jamais depuis le
    /// répertoire courant, sans quoi la même commande ne voudrait pas dire la même chose d'où elle
    /// est lancée ; `~` est développé ; le chemin est normalisé (`.`, `..`) ; et il doit
    /// **rester dans** la racine, sinon c'est le refus explicite du `../`.
    ///
    /// Un chemin qui reste dans la racine sans désigner un transcript de la racine (un fichier de
    /// `work/`, une extension étrangère, un nom qui n'existe pas, un dossier) n'est pas un refus de
    /// périmètre : c'est une **absence**.
    private func resoudreChemin(_ requete: String) throws -> TranscriptQueryTarget {
        let developpe = (requete as NSString).expandingTildeInPath
        let absolu = developpe.hasPrefix("/")
            ? developpe
            : base.appendingPathComponent(developpe).path
        let normalise = URL(fileURLWithPath: absolu).standardizedFileURL.path
        let racine = base.standardizedFileURL.path

        guard normalise.hasPrefix(racine + "/") else {
            throw TranscriptQueryError.outsideLibrary(query: requete)
        }
        let relatif = String(normalise.dropFirst(racine.count + 1))
        // Un seul niveau : `work/<tranche>.wav` est un fichier de travail, pas un transcript de la
        // racine — et un chemin sans extension n'en est pas un non plus.
        guard let tige = Self.tigeDeNomDeFichier(relatif), library.transcript(id: tige) != nil else {
            throw TranscriptQueryError.notFound(query: requete)
        }
        return cible(pour: tige)
    }

    /// Un identifiant ou une tige (règle 4) : l'égalité exacte avec l'`id` d'un document lisible
    /// l'emporte **toujours**, même si d'autres ids le commencent ; sinon les ids dont la tige
    /// **commence** par la requête sont les candidats — un seul se résout, plusieurs se refusent en
    /// les nommant, aucun est une absence.
    ///
    /// Les comparaisons sont **sensibles à la casse** (règle 5) : la tige est un nom de fichier, et
    /// un nom se recopie tel que `list` l'a imprimé.
    private func resoudreParTige(_ tige: String, requete: String) throws -> TranscriptQueryTarget {
        let identifiants = library.list().documents.map(\.id)
        if identifiants.contains(tige) { return cible(pour: tige) }
        guard !tige.isEmpty else { throw TranscriptQueryError.notFound(query: requete) }
        let candidats = identifiants.filter { $0.hasPrefix(tige) }.sorted()
        switch candidats.count {
        case 0:
            throw TranscriptQueryError.notFound(query: requete)
        case 1:
            return cible(pour: candidats[0])
        default:
            throw TranscriptQueryError.ambiguous(query: requete, candidates: candidats)
        }
    }

    /// La cible d'une tige **déjà vérifiée lisible** : ses deux fichiers, la même tige (critère 21).
    /// Le Markdown n'a pas à exister — l'écriture du `.md` peut avoir été interrompue (règle 6).
    private func cible(pour tige: String) -> TranscriptQueryTarget {
        TranscriptQueryTarget(
            id: tige,
            jsonURL: base.appendingPathComponent("\(tige).json"),
            markdownURL: base.appendingPathComponent("\(tige).md"))
    }

    /// `ma-tige.json` / `ma-tige.md` désignent la tige `ma-tige` (règle 2, second cas). Toute
    /// autre chaîne est rendue telle quelle.
    private static func tigeSansExtension(_ requete: String) -> String {
        for extensionConnue in [".json", ".md"] where requete.hasSuffix(extensionConnue) {
            return String(requete.dropLast(extensionConnue.count))
        }
        return requete
    }

    /// La tige d'un **nom de fichier** de la racine, `nil` pour tout le reste : un chemin d'un
    /// sous-dossier, une extension étrangère, un nom vide.
    private static func tigeDeNomDeFichier(_ relatif: String) -> String? {
        guard !relatif.contains("/") else { return nil }
        let tige = tigeSansExtension(relatif)
        guard !tige.isEmpty, tige != relatif else { return nil }
        return tige
    }
}
