import CryptoKit
import Foundation

/// L'échec explicite de ``TranscriptFilenames/uniqueStem(in:base:)`` quand les vingt suffixes
/// sont pris (plan §2.4 : « borné à 20, sinon échec explicite »).
///
/// Un cas à part plutôt qu'une chaîne vide ou un `nil` : « je n'ai pas pu te donner un nom » et
/// « voici le nom » ne doivent pas se confondre, et l'appelant a une chose à dire à Louis — pas
/// vingt fichiers de plus.
public enum TranscriptFilenameError: Error, Equatable {
    case allNamesTaken(base: String)
}

/// Le nommage des deux fichiers d'un transcript dans `~/Documents/Murmure/Transcripts/`
/// (plan §2.4) :
///
/// ```
/// <slug>-<AAAA-MM-JJ>-<id8>.json      <- source de vérité machine
/// <slug>-<AAAA-MM-JJ>-<id8>.md        <- source de vérité humaine
/// ```
///
/// **Même tige pour les deux formats** (critère 21) : un agent qui trouve l'un trouve l'autre
/// sans index. C'est aussi ce qui fait qu'une acquisition relancée sur la même source **vise la
/// même tige** — c'est une reprise, pas un doublon.
///
/// **On n'écrase jamais un transcript existant** (plan §2.4) : d'où
/// ``uniqueStem(in:base:)``, qui est le seul point où le disque est consulté.
public enum TranscriptFilenames {
    /// La tige du nom de fichier, **pure** (aucun accès disque) : `slug-date-id8`.
    ///
    /// - `slug` : le titre replié en ASCII (les accents sont dépliés), mis en minuscules, chaque
    ///   caractère non alphanumérique devenant `-`, le tout **coupé à 60 caractères**. Un titre
    ///   vide n'est pas un slug vide : le repli est la source elle-même prise comme titre (plan
    ///   §2.4, « si le titre manque, repli sur l'hôte + identifiant de source ») — c'est-à-dire
    ///   exactement `stem(title: identity, date: date, identity: identity)`.
    /// - `date` : `AAAA-MM-JJ`, dans le fuseau courant.
    /// - `id8` : les 8 premiers caractères hexadécimaux d'un hachage de `identity`.
    ///
    /// **Fonction pure, et c'est un contrat** : deux appels avec les mêmes arguments rendent la
    /// même chaîne, et cette fonction ne regarde jamais le disque. C'est ``uniqueStem(in:base:)``
    /// qui arbitre les collisions.
    public static func stem(title: String, date: Date, identity: String) -> String {
        let replie = slug(title)
        // Un titre vide ne donne pas un slug vide : le repli est la source **prise comme
        // titre**, donc exactement le même chemin de repli. Le cas se produit aussi pour un
        // titre qui ne laisse rien après repli (`"///"`), d'où le test sur le slug et non sur le
        // titre.
        let slugRetenu = replie.isEmpty ? slug(identity) : replie
        return "\(slugRetenu)-\(jour(date))-\(identifiant8(identity))"
    }

    /// Le titre replié en ASCII : accents dépliés, minuscules, tout caractère non alphanumérique
    /// remplacé par `-`, coupé à 60 caractères.
    ///
    /// Le repli passe par `folding` plutôt que par une table de caractères : la même lettre
    /// écrite précomposée (`U+00E9`) ou décomposée (`e` + accent combinant) doit rendre la même
    /// chose, sinon deux écritures du même titre donnent deux tiges et la reprise ne reprend
    /// rien. Un caractère qui ne se replie pas (une lettre non latine) devient `-` lui aussi : la
    /// tige est un nom de fichier, et le Finder n'a pas à décider de sa normalisation Unicode.
    private static func slug(_ chaine: String) -> String {
        let repliee = chaine.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        let tirets = repliee.lowercased().map { caractere -> Character in
            caractere.isASCII && (caractere.isLetter || caractere.isNumber) ? caractere : "-"
        }
        return String(String(tirets).prefix(60))
    }

    /// La date au format `AAAA-MM-JJ`, dans le fuseau courant : la tige est lue par Louis dans le
    /// Finder, elle doit porter le jour où il a lancé l'acquisition, pas le jour UTC.
    private static func jour(_ date: Date) -> String {
        formateurDeJour.string(from: date)
    }

    /// Instance unique, partagée par tous les appels : `DateFormatter` est `Sendable` dans ce SDK,
    /// et documenté thread-safe pour le formatage depuis macOS 10.9 (l'implémentation
    /// `CFDateFormatter` moderne). Aucune précaution d'isolation n'est donc nécessaire ici.
    private static let formateurDeJour: DateFormatter = {
        let formateur = DateFormatter()
        formateur.locale = Locale(identifier: "en_US_POSIX")
        formateur.calendar = Calendar(identifier: .gregorian)
        formateur.timeZone = TimeZone.current
        formateur.dateFormat = "yyyy-MM-dd"
        return formateur
    }()

    /// Les 8 premiers hexadécimaux d'un hachage de l'identité canonique : la part de la tige qui
    /// fait converger deux acquisitions de la même source, indépendamment du titre et du jour.
    private static func identifiant8(_ identity: String) -> String {
        hexadecimal(SHA256.hash(data: Data(identity.utf8)).prefix(4))
    }

    private static func hexadecimal(_ octets: some Sequence<UInt8>) -> String {
        octets.map { String(format: "%02x", $0) }.joined()
    }

    /// L'identité canonique d'une source distante (plan §2.4) : l'id de la vidéo YouTube, ou
    /// l'id du statut X.
    ///
    /// **Deux écritures de la même source doivent donner la même identité**, parce que l'identité
    /// décide du nom de fichier : `youtube.com/watch?v=ID`, `youtu.be/ID` et la même adresse
    /// suivie de paramètres de partage (`&t=42s`) désignent la même vidéo et donc la même tige.
    /// Sans cela, Louis obtient deux transcripts du même enregistrement et une reprise ratée.
    ///
    /// **Ce qui sort du périmètre** : seules les adresses YouTube et X sont reconnues en
    /// incrément 1. Une adresse d'un autre hôte relève de la validation de source (lot 6) — cette
    /// fonction n'a pas à inventer une identité pour elle.
    /// Elle **délègue** à ``TranscriptSource/resolve(_:)`` — le point de résolution unique — et rend
    /// `""` pour tout ce que celui-ci refuse. Signature et comportement inchangés : c'est le
    /// contrat du lot 1, et une source que le cœur ne sait pas nommer n'a pas d'identité ici non
    /// plus.
    ///
    /// **La délégation ne franchit que la branche d'adresse** (`http`/`https`). `resolve` reconnaît
    /// aussi les fichiers locaux, et une URL qui désigne un fichier — un chemin absolu sans
    /// schéma, que `URL(string:)` accepte — y tomberait : elle rendrait alors une empreinte de
    /// contenu par une porte qui s'appelle `url:`, ce que cette fonction n'a jamais fait et ce que
    /// le paragraphe ci-dessus refuse. Le schéma est donc filtré ici, et `resolve` reste le seul
    /// endroit où la règle de résolution est écrite.
    public static func identityFor(url: URL) -> String {
        guard let schema = url.scheme?.lowercased(), schema == "http" || schema == "https" else {
            return ""
        }
        guard case .source(let source) = TranscriptSource.resolve(url.absoluteString) else {
            return ""
        }
        return source.identity
    }

    /// L'identité canonique d'un fichier local (plan §2.4) : SHA-256 des **64 premiers Kio** plus
    /// la taille du fichier.
    ///
    /// **L'empreinte porte sur le contenu, pas sur le chemin ni sur le nom** : le même
    /// enregistrement déplacé ou renommé garde son identité, donc sa tige. Et elle est
    /// volontairement bornée aux 64 premiers Kio — un fichier de 4 h pèse plusieurs centaines de
    /// Mo, l'identité doit coûter une lecture de 64 Kio ; la taille est ajoutée à l'empreinte
    /// précisément pour distinguer deux fichiers qui partageraient ces 64 Kio.
    ///
    /// Un chemin illisible rend `""` : une identité vide n'est jamais un composant de nom de
    /// fichier utilisable, et l'appelant (lot 6) vérifie la lisibilité de sa source avant
    /// d'arriver ici.
    public static func identityFor(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        // Un chemin illisible (absent, dossier, droits) rend `""` : l'appelant du lot 6 vérifie la
        // lisibilité de sa source, cette fonction ne l'invente pas.
        guard let taille = tailleDuFichier(url), let entete = enteteDuFichier(url) else {
            return ""
        }
        var hachage = SHA256()
        hachage.update(data: entete)
        // La taille est **dans** l'empreinte, pas à côté : deux fichiers qui partagent leurs
        // 64 premiers Kio mais pas leur longueur sont deux enregistrements distincts, et un
        // séparateur les empêche de se confondre avec un entête qui finirait par ces chiffres.
        hachage.update(data: Data("\u{0}\(taille)".utf8))
        return hexadecimal(hachage.finalize())
    }

    /// La taille d'un fichier **ordinaire** — un dossier ou un lien mort n'est pas une source.
    private static func tailleDuFichier(_ url: URL) -> Int? {
        guard let valeurs = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            valeurs.isRegularFile == true,
            let taille = valeurs.fileSize
        else { return nil }
        return taille
    }

    /// Les 64 premiers Kio, lus par blocs : un fichier de 4 h pèse des centaines de Mo, et
    /// l'identité doit coûter une lecture bornée, pas un parcours complet.
    private static func enteteDuFichier(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var donnees = Data()
        while donnees.count < kioDEntete {
            guard let bloc = try? handle.read(upToCount: kioDEntete - donnees.count),
                !bloc.isEmpty
            else { break }
            donnees.append(bloc)
        }
        return donnees
    }

    /// 64 Kio : la borne du plan §2.4, écrite une fois.
    private static let kioDEntete = 64 * 1024

    /// La tige réellement libre dans `directory`, à partir de `base`.
    ///
    /// Renvoie `base` si elle est libre, sinon `base-2`, `base-3`… jusqu'à `base-20`, et
    /// **échoue** au-delà (``TranscriptFilenameError/allNamesTaken(base:)``). Une tige est prise
    /// dès qu'**un** des deux fichiers `.json` / `.md` existe : n'écraser que l'un des deux
    /// laisserait deux transcripts sous la même tige.
    ///
    /// **Ce que cette fonction ne fait pas** : elle n'écrit rien, ne crée rien et ne supprime
    /// rien. Elle nomme un emplacement libre ; c'est l'appelant qui écrit (lot 2).
    public static func uniqueStem(in directory: URL, base: String) throws -> String {
        // Borné à 20 suffixes : au-delà, l'application a une chose à dire à Louis plutôt que
        // vingt fichiers de plus (plan §2.4).
        for rang in 0...19 {
            let candidat = rang == 0 ? base : "\(base)-\(rang + 1)"
            if !estPrise(candidat, dans: directory) { return candidat }
        }
        throw TranscriptFilenameError.allNamesTaken(base: base)
    }

    /// Une tige est prise dès qu'**un** des deux fichiers existe : n'écraser que le `.json`
    /// laisserait le `.md` de l'ancien transcript et le nouveau sous la même tige.
    private static func estPrise(_ tige: String, dans directory: URL) -> Bool {
        let manager = FileManager.default
        return ["json", "md"].contains { extensionFichier in
            manager.fileExists(
                atPath: directory.appendingPathComponent("\(tige).\(extensionFichier)").path)
        }
    }
}
