import Foundation

/// L'état d'un transcript, tel que le fichier JSON le porte dans `status`.
///
/// Trois valeurs, et trois seulement : un travail écrit sur disque est soit en cours
/// (« inProgress », le cas d'une reprise après interruption), soit terminé (« complete »), soit
/// abandonné (« failed »). C'est ce champ qui rend un travail interrompu **lisible** par
/// l'application et par un agent, sans index séparé (plan §2.1, §2.4).
public enum TranscriptStatus: String, Codable, Equatable, CaseIterable {
    case inProgress = "inProgress"
    case complete = "complete"
    case failed = "failed"
}

/// La provenance d'un transcript : une vidéo YouTube, un post X, ou un fichier local.
public enum TranscriptSourceKind: String, Codable, Equatable, CaseIterable, Sendable {
    case youtube = "youtube"
    case x = "x"
    case file = "file"
}

/// D'où vient le transcript, écrit tel quel dans le JSON.
///
/// **Deux clés optionnelles plutôt qu'une.** `url` est renseignée pour YouTube et X, `path` pour
/// un fichier local ; l'une des deux est toujours présente selon `kind`. Ce n'est pas une
/// élégance : c'est la forme la plus simple à décoder pour un agent, et elle laisse `kind` dire
/// laquelle des deux il faut lire. **La clé inutilisée n'est pas écrite** — comme `completedAt`
/// absente d'un travail en cours : `null` n'ajoute rien qu'un lecteur doive interpréter.
///
/// **`identity` est l'identité canonique de la source** (plan §2.4) : l'id de vidéo YouTube, l'id
/// de statut X, ou une empreinte de contenu pour un fichier local, produite par
/// ``TranscriptFilenames/identityFor(url:)`` / ``TranscriptFilenames/identityFor(path:)``. Elle
/// est rangée dans le document en plus du nom de fichier, parce que renommer un fichier ne doit
/// pas faire perdre de vue de quelle source il vient.
public struct TranscriptSource: Codable, Equatable, Sendable {
    public var kind: TranscriptSourceKind
    public var url: URL?
    public var path: String?
    public var identity: String

    public init(
        kind: TranscriptSourceKind, url: URL? = nil, path: String? = nil, identity: String
    ) {
        self.kind = kind
        self.url = url
        self.path = path
        self.identity = identity
    }
}

/// Les deux familles de sources distantes que Murmure sait nommer, et **la seule table d'hôtes du
/// dépôt**.
///
/// La table ne rend pas un `kind` : elle rend l'**identité**, ou `nil`. C'est ce qui rend un
/// désaccord entre le `kind` et l'identité **non exprimable** — il n'y a plus de variable où il
/// pourrait s'installer, puisque le `kind` est **la famille dont l'extraction a réussi**
/// (``TranscriptSource/resolve(_:)``). Une liste de `kind` par hôte, elle, resterait une seconde
/// liste, capable de diverger de celle-ci au prochain lot.
///
/// Le point d'ancrage vit dans l'**extraction** (`hote == $0 || hote.hasSuffix(".\($0)")`) et nulle
/// part ailleurs : c'est lui qui sépare `m.youtube.com` de `notyoutube.com`.
public enum TranscriptSourceFamily: String, CaseIterable, Sendable {
    case youtube
    case x

    /// Le `kind` qu'une tuile affiche, et qui décide si un horodatage peut porter un instant.
    public var kind: TranscriptSourceKind {
        switch self {
        case .youtube: .youtube
        case .x: .x
        }
    }

    /// L'identité que cette famille extrait de l'adresse, ou `nil` : l'adresse n'est pas de cette
    /// famille, ou n'y porte aucun identifiant. Les paramètres de partage (`&t=42s`, `&list=…`,
    /// `?si=…`) n'en font pas partie : ils décrivent le partage, pas la source.
    func identity(of url: URL) -> String? {
        guard let hote = url.host?.lowercased() else { return nil }
        let parties = Array(url.pathComponents.dropFirst())
        switch self {
        case .youtube:
            guard hote == "youtube.com" || hote.hasSuffix(".youtube.com")
                || hote == "youtu.be" || hote.hasSuffix(".youtu.be")
            else { return nil }
            if hote == "youtu.be" || hote.hasSuffix(".youtu.be") {
                return parties.first.flatMap { $0.isEmpty ? nil : $0 }
            }
            let composants = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let parametre = composants?.queryItems?.first(where: { $0.name == "v" })?.value,
                !parametre.isEmpty
            {
                return parametre
            }
            // `/shorts/<id>`, `/embed/<id>`, `/live/<id>` désignent la même vidéo que `/watch?v=<id>` :
            // ne pas les reconnaître produirait deux transcripts du même enregistrement.
            let formes = ["shorts", "embed", "live"]
            guard let index = parties.firstIndex(where: { formes.contains($0) }),
                parties.indices.contains(index + 1)
            else { return nil }
            return parties[index + 1]
        case .x:
            guard hote == "x.com" || hote.hasSuffix(".x.com")
                || hote == "twitter.com" || hote.hasSuffix(".twitter.com")
            else { return nil }
            guard let index = parties.firstIndex(of: "status"),
                parties.indices.contains(index + 1)
            else { return nil }
            return parties[index + 1]
        }
    }
}

/// Le verdict d'un point de résolution : une **raison**, pas un optionnel.
///
/// Un optionnel unique `(kind, identity)?` aplatirait deux diagnostics que le CLI rend
/// aujourd'hui séparément (`Failure.unsupportedURL(hôte)`, `Failure.unreadableFile(chemin)`) en un
/// seul, et ferait perdre à l'agent un message qu'il lit aujourd'hui. Chaque cas porte donc la
/// charge utile que l'appelant rend **déjà**, ce qui rend leur convergence non exprimable plutôt
/// que demandée.
public enum TranscriptSourceResolution: Equatable, Sendable {
    /// Une source exploitable : son `identity` n'est **jamais** vide, c'est la seule façon d'en
    /// produire une. Le cas est donc non constructible avec une identité vide, pas corrigé.
    case source(TranscriptSource)
    /// Une entrée vide ou blanche.
    case emptyEntry
    /// Un `http`/`https` dont **aucune** famille ne fournit d'identité — hôte hors familles, ou hôte
    /// d'une famille sans identifiant extractible. La charge utile est l'hôte, comme
    /// `url.host ?? brut` : les deux causes rendent le même refus.
    case unsupportedURL(String)
    /// Un autre schéma (`ftp:`, `file:`, `mailto:`) : la charge utile est l'opérande entier.
    case unsupportedScheme(String)
    /// Un chemin qui existe mais dont le cœur ne produit aucune identité : la charge utile est le
    /// chemin.
    case unreadableFile(String)
}

extension TranscriptSource {
    /// Le point de résolution unique du dépôt : un opérande, et la **raison** de son verdict.
    ///
    /// Les deux appelants — le panneau et le CLI — passent par ici, donc une source ne peut pas
    /// être nommée par l'un et refusée par l'autre : c'était la divergence que ce lot supprime
    /// (un dossier glissé sur l'onglet était mis en file avec une identité vide, pendant que le
    /// CLI le refusait).
    public static func resolve(_ texte: String) -> TranscriptSourceResolution {
        let brut = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brut.isEmpty else { return .emptyEntry }

        if let url = URL(string: brut), let schema = url.scheme?.lowercased(),
            schema == "http" || schema == "https"
        {
            // Le `kind` est **la famille dont l'extraction a réussi** : jamais un second test d'hôte.
            for famille in TranscriptSourceFamily.allCases {
                if let identite = famille.identity(of: url) {
                    return .source(
                        TranscriptSource(kind: famille.kind, url: url, identity: identite))
                }
            }
            return .unsupportedURL(url.host ?? brut)
        }
        if URL(string: brut)?.scheme != nil, !brut.hasPrefix("/"), !brut.hasPrefix("~") {
            // Un schéma autre que `http`/`https` (`file:`, `ftp:`…) n'est pas une source reconnue.
            return .unsupportedScheme(brut)
        }

        // `~` est déployé parce qu'un chemin tapé à la main s'écrit comme le Finder le montre.
        let chemin = (brut as NSString).expandingTildeInPath
        // L'identité se lit sur le chemin **résolu** : l'empreinte porte sur le contenu, et le
        // code lit déjà la cible à travers un lien symbolique (`enteteDuFichier(_:)`) — il refusait
        // seulement de la nommer, parce que `tailleDuFichier(_:)` lit `isRegularFile` sur l'URL
        // non résolue. Le chemin **déposé** reste celui que le runner lit et que l'utilisateur a
        // choisi.
        let resolu = URL(fileURLWithPath: chemin).resolvingSymlinksInPath().path
        let identite = TranscriptFilenames.identityFor(path: resolu)
        guard !identite.isEmpty else { return .unreadableFile(chemin) }
        return .source(TranscriptSource(kind: .file, path: chemin, identity: identite))
    }
}

/// Un segment horodaté du transcript : le contrat d'agent (critère 9 de la SPEC).
///
/// `start` et `end` sont des secondes depuis le début de l'audio source, jamais des chaînes
/// formatées : l'affichage au survol (critère 16) et la vérification de couverture (critère 9)
/// ont tous deux besoin de la valeur numérique.
public struct TranscriptSegment: Codable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Le document de transcript : la forme exacte du fichier `.json` de
/// `~/Documents/Murmure/Transcripts/` (plan §2.4).
///
/// **C'est le schéma qui est gelé ici, pas son implémentation.** Les noms de clés JSON, les
/// valeurs brutes des énumérations et la version de schéma sont ce que liront les agents et les
/// versions futures de Murmure ; ils ne bougent pas sans une nouvelle `schemaVersion`.
///
/// **La version de schéma n'est pas un paramètre.** Elle sort toujours à
/// ``TranscriptDocument/schemaVersion`` : un appelant ne doit pas pouvoir écrire un fichier qui
/// ment sur sa propre version.
///
/// **`Coverage` et `Boundary` sont imbriqués, et c'est délibéré.** Le lot 2 introduit un
/// `TranscriptCoverage` de premier niveau qui est *une autre chose* — la mesure (`of(segments:
/// duration:)` → `ratio`, `isMonotonic`, `segmentsPer30s`), pas la case du document. Deux types
/// de même nom dans un même module ne compilent pas ; imbriquer ce qui appartient au document
/// laisse le nom libre pour la mesure.
///
/// **Les dates.** Le document ne fixe pas lui-même le format : il doit s'encoder et se décoder
/// avec un `JSONEncoder`/`JSONDecoder` dont la stratégie de dates est `.iso8601`, parce que c'est
/// la forme sous laquelle les fichiers seront écrits et relus par un agent. C'est une contrainte
/// réelle : une conformité `Codable` écrite à la main qui imposerait son propre format de date
/// échouerait aux tests du lot 1.
public struct TranscriptDocument: Codable, Equatable {
    /// Où en est un travail, en secondes et en proportion de la durée audio (critère 9).
    public struct Coverage: Codable, Equatable {
        /// Secondes d'audio effectivement couvertes par les segments.
        public var coveredSeconds: Double
        /// `coveredSeconds / duration` (0…1). Rangé à part parce que c'est la valeur que la
        /// SPEC nomme (≥ 97 %) et qu'un agent ne doit pas avoir à refaire la division.
        public var ratio: Double

        public init(coveredSeconds: Double, ratio: Double) {
            self.coveredSeconds = coveredSeconds
            self.ratio = ratio
        }
    }

    /// Une frontière entre deux unités transcrites (plan §2.1) : où la coupe a été faite, sur
    /// quelle durée, et si elle est tombée dans un silence ou a été forcée. Une coupe forcée est
    /// une dégradation assumée, et elle doit rester trouvable après coup.
    public struct Boundary: Codable, Equatable {
        /// Qualité de la coupe. `forced` est le seul nom que le plan écrit noir sur blanc
        /// (« si un silence manque, la coupe est forcée et **marquée** `boundaryQuality:
        /// "forced"` ») ; `silence` est le complément retenu ici. Un amendement de l'architecte
        /// sur ce second nom est un changement de schéma, donc une nouvelle version.
        public enum Quality: String, Codable, Equatable, CaseIterable {
            case silence = "silence"
            case forced = "forced"
        }

        /// Début absolu de l'unité, en secondes.
        public var start: Double
        /// Durée de l'unité, en secondes.
        public var duration: Double
        public var quality: Quality

        public init(start: Double, duration: Double, quality: Quality) {
            self.start = start
            self.duration = duration
            self.quality = quality
        }
    }

    /// La version du schéma écrite dans tout fichier de cette version du type.
    public static let schemaVersion = 1

    /// La version du schéma, telle qu'elle est écrite dans le fichier. Elle vaut toujours
    /// ``schemaVersion`` : voir la note du type.
    public var schemaVersion: Int
    /// L'identifiant du transcript. Il n'est pas gelé au-delà du fait d'être une chaîne non vide
    /// qui survit à un aller-retour — c'est le lot 2 qui décide s'il s'agit de la tige du nom de
    /// fichier ou d'autre chose.
    public var id: String
    /// Le titre **tel qu'il a été écrit**, pas le slug : le Markdown et les tuiles affichent
    /// celui-ci (critères 16 et 21).
    public var title: String
    public var source: TranscriptSource
    /// Durée de l'audio source, en secondes. C'est la référence de la couverture (critère 9).
    public var duration: Double
    /// Langue détectée ou forcée, sous la forme que WhisperKit rend (par exemple `"fr"`).
    public var language: String
    /// Vrai quand la langue a été forcée pour cette transcription (critère 12).
    public var languageWasForced: Bool
    /// Le modèle de transcription qui a produit le texte, tel qu'il est nommé dans Murmure.
    public var model: String
    public var createdAt: Date
    /// Absente tant que le travail n'est pas terminé — une clé `completedAt` **n'est pas
    /// écrite** quand elle vaut `nil`. Un travail en cours porte donc exactement les mêmes clés
    /// que le schéma, moins celle-là.
    public var completedAt: Date?
    public var status: TranscriptStatus
    /// Les segments **absolus** (recollés entre unités, lot 3), strictement croissants.
    public var segments: [TranscriptSegment]
    public var coverage: Coverage
    /// Vide tant qu'aucune frontière n'a été franchie.
    public var boundaries: [Boundary]

    public init(
        id: String, title: String, source: TranscriptSource, duration: Double, language: String,
        languageWasForced: Bool, model: String, createdAt: Date, completedAt: Date? = nil,
        status: TranscriptStatus, segments: [TranscriptSegment], coverage: Coverage,
        boundaries: [Boundary]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.id = id
        self.title = title
        self.source = source
        self.duration = duration
        self.language = language
        self.languageWasForced = languageWasForced
        self.model = model
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.status = status
        self.segments = segments
        self.coverage = coverage
        self.boundaries = boundaries
    }
}
