import Foundation

/// Ce qu'une lecture du dossier rend : les transcripts lisibles, et **le nombre de fichiers
/// illisibles rencontrés**.
///
/// Le compte fait partie du résultat, il n'est pas un journal : la bibliothèque est l'index du
/// disque (plan §2.4), donc un JSON tronqué ou écrit par une version future ne doit ni disparaître
/// en silence ni faire échouer la lecture — mais il doit rester **comptable**, sans quoi personne
/// ne peut dire pourquoi une tuile manque (critère 14).
public struct TranscriptListing: Equatable {
    /// Les transcripts décodables, dans l'ordre où le dossier les rend. L'ordre n'est pas
    /// contractuel : c'est le panneau (lot 9) qui trie pour l'affichage.
    public let documents: [TranscriptDocument]

    /// Le nombre de `<...>.json` de la racine qui n'ont pas pu être décodés en
    /// ``TranscriptDocument`` — fichier tronqué, JSON valide mais étranger au schéma, fichier
    /// illisible. Ce qui n'est **pas** un transcript n'entre pas dans ce compte : un `.md`
    /// orphelin, le sous-dossier `work/`, un `.DS_Store` sont ignorés sans être comptés, sinon le
    /// premier fichier étranger déposé dans le dossier ressemblerait à un transcript abîmé.
    public let unreadableCount: Int

    public init(documents: [TranscriptDocument], unreadableCount: Int) {
        self.documents = documents
        self.unreadableCount = unreadableCount
    }
}

/// La bibliothèque des transcripts sur disque, dans
/// `~/Library/Application Support/Murmure/Transcripts/` (plan §2.4, décision R3 du tour 7).
///
/// **Le dossier est l'index.** Aucun fichier de liste, aucun index séparé : `list()` parcourt le
/// dossier et décode les JSON. C'est la seule forme sous laquelle « supprimer un fichier retire sa
/// tuile au rechargement » (critère 14) est vrai sans rien à resynchroniser — un index serait une
/// seconde source de vérité qui se désynchronise exactement dans ce cas.
///
/// **La base est injectable** (même motif que ``Storage``), et c'est le point du contrat : les
/// tests écrivent sous `NSTemporaryDirectory()`, jamais dans Application Support. La racine réelle
/// n'est nommée qu'une fois, par ``defaultBase`` ; c'est le câblage de l'app qui l'emploie (lot 8
/// pour le travail qui écrit, lot 9 pour le panneau qui lit).
///
/// **`write` est la seule opération qui peut échouer** : `list()`, `transcript(id:)` et
/// `delete(id:)` ne jettent pas. Une base absente est une bibliothèque vide (premier lancement),
/// un id inconnu est une tuile déjà disparue, et une suppression peut se répéter sans dommage —
/// le panneau et la ligne de commande peuvent viser la même tuile (R4).
public struct TranscriptLibrary {
    /// La racine : le dossier qui porte les `.json`, les `.md` et le sous-dossier `work/`.
    public let base: URL

    /// La racine réelle de l'incrément 1 : `Application Support/Murmure/Transcripts`.
    ///
    /// **Jamais `~/Documents`** (R3) : le dossier Documents demande une autorisation macOS, et un
    /// refus d'autorisation tuerait la fonctionnalité. La visibilité perçue est rendue autrement —
    /// « Révéler dans le Finder » au panneau (lot 9), chemin absolu imprimé par le CLI (critère 20).
    ///
    /// Passe par ``Storage`` et non par une composition de chemin écrite ici : c'est le seul
    /// endroit du module qui sait où est Application Support.
    public static var defaultBase: URL {
        // Passe par `Storage` et non par une composition de chemin écrite ici : c'est le seul
        // endroit du module qui sait où est Application Support (et la seule définition de
        // `Application Support/Murmure`).
        Storage.url(subfolder: "Transcripts")
    }

    public init(base: URL = TranscriptLibrary.defaultBase) {
        self.base = base
    }

    /// Écrit un transcript sur disque et rend l'URL de son fichier `.json`.
    ///
    /// Quatre choses sont décidées ici et nulle part ailleurs :
    ///
    /// 1. **La tige** : `TranscriptFilenames.stem(title:date:identity:)`. L'appelant n'a pas à
    ///    connaître le nommage, et le champ `id` du document écrit **est** cette tige — c'est ce qui
    ///    permet à `transcript(id:)`, à la tuile (critère 16) et au `murmure read <id>` (critère 20)
    ///    de retrouver le fichier sans index.
    /// 2. **La collision** (plan §2.4, **révision 8**) : la tige part **du travail reprisable de la
    ///    même identité canonique** s'il en existe un (``resumable(identity:)``) — l'ancre du
    ///    travail en cours, quelle que soit sa tige ; sinon la tige de base, si elle est libre ;
    ///    sinon la première tige libre (`-2`, `-3`…). **Un transcript existant n'est jamais
    ///    écrasé** : relancer une source déjà transcrite produit un second transcript à côté du
    ///    premier. Ce que la révision 8 corrige : quand un `complete` occupait la tige de base,
    ///    **chaque** écriture du même travail suffixait une tige de plus (`-2`…`-20`) et laissait
    ///    un document `inProgress` par écriture — mesuré le 2026-09-22 dans la bibliothèque réelle
    ///    (31 `.json`, 28 `inProgress`, campagne de 2 h arrêtée à l'unité 17/31), jusqu'à
    ///    ``TranscriptFilenameError/allNamesTaken(base:)`` non rattrapée (suivi `t_dd566bf7`).
    /// 3. **Les deux formats** (critère 21) : le `.json` (schéma de ``TranscriptDocument``, dates
    ///    ISO-8601) et le `.md` (``TranscriptMarkdown/render(_:)``), sous la **même tige**, donc
    ///    trouvables l'un par l'autre.
    /// 4. **L'atomicité** : le contenu est écrit dans un fichier temporaire puis **remplacé**. Un
    ///    lecteur ne voit jamais un JSON tronqué, et un lecteur qui avait ouvert l'ancien fichier
    ///    continue de lire l'ancien transcript **complet** — c'est ce que « remplacement » veut
    ///    dire, et ce qu'une réécriture sur place ne fait pas.
    ///
    /// La racine et ses parents sont créés au passage : un premier transcript dans une installation
    /// neuve ne doit pas obliger le câblage de l'app à créer un dossier avant d'appeler.
    @discardableResult
    public func write(_ document: TranscriptDocument) throws -> URL {
        let tige = try tigeLibre(pour: document)

        // Point 1, seconde moitié : le document écrit porte **cette** tige dans son champ `id`.
        // Le lot 1 laisse l'id libre ; ici il est décidé, et c'est ce qui rend le transcript
        // retrouvable par `transcript(id:)` sans index.
        var ecrit = document
        ecrit.id = tige

        let json = try Self.encodeur(ecrit)
        // Point 3 : le Markdown est rendu depuis le document **à la tige retenue**, donc les deux
        // fichiers parlent bien du même transcript.
        let markdown = Data(TranscriptMarkdown.render(ecrit).utf8)

        // La racine et ses parents naissent ici : une installation neuve n'a pas de dossier
        // `Transcripts/`, et le câblage de l'app (lot 8) n'a pas à en créer un avant d'appeler.
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let fichierJSON = base.appendingPathComponent("\(tige).json")
        // L'ordre n'est pas indifférent : le `.md` d'abord, le `.json` **en dernier**. Le `.json`
        // est ce que `list()` parcourt ; le poser en dernier garantit qu'une écriture interrompue
        // entre les deux ne laisse jamais un transcript listé dont le Markdown n'existe pas (au
        // pire un `.md` orphelin, que `list()` ignore et ne compte pas, et qu'une écriture
        // ultérieure suffixera proprement).
        try Self.remplacer(contenu: markdown, a: base.appendingPathComponent("\(tige).md"))
        try Self.remplacer(contenu: json, a: fichierJSON)
        return fichierJSON
    }

    /// La tige sous laquelle écrire : celle du travail **en cours** de cette source, sinon une tige
    /// libre.
    ///
    /// **Les trois règles du plan §2.4 (révision 8), dans cet ordre :**
    ///
    /// 1. **la tige du travail reprisable de la même identité canonique** — ``resumable(identity:)``,
    ///    le plus récent des documents `inProgress`/`failed` de cette source. Elle est prise
    ///    **telle quelle**, qu'elle soit la tige de base ou une tige suffixée, et **que la tige de
    ///    base soit libre ou non** : c'est l'ancre du travail en cours, et c'est ce qui garantit
    ///    **au plus un document reprisable par source** (contrat, cas (b) : un `inProgress` en
    ///    `<base>-2` avec une tige de base **libre** reste en `<base>-2`) ;
    /// 2. sinon **la tige de base, si elle est libre** — c'est la première itération de
    ///    ``TranscriptFilenames/uniqueStem(in:base:)``, qui rend la base quand elle est libre : les
    ///    règles 2 et 3 sont donc servies par un seul appel, et « libre » y a exactement le sens du
    ///    lot 1 (le `.json` **ou** le `.md` suffit à prendre la tige — un fichier illisible à la
    ///    tige visée compte comme pris, un `.md` orphelin aussi) ;
    /// 3. sinon le suffixe `-2`…`-20`, **inchangé**, et
    ///    ``TranscriptFilenameError/allNamesTaken(base:)`` au-delà.
    ///
    /// **Le chemin vers `allNamesTaken` n'est plus une suite d'écritures du même travail** : il faut
    /// désormais vingt transcripts **terminés** (ou étrangers) de la même source sous la même tige
    /// de base (contrat, cas (d), qui fige ce chemin comme le seul). C'est la règle 1 qui le
    /// garantit : sans elle, la tige de base occupée par un `complete` — le cas normal de la
    /// retranscription d'une vidéo déjà transcrite — renvoyait **chaque** écriture du travail en
    /// cours vers la règle 3.
    private func tigeLibre(pour document: TranscriptDocument) throws -> String {
        let tige = TranscriptFilenames.stem(
            title: document.title, date: document.createdAt, identity: document.source.identity)
        // Règle 1 : l'ancre du travail en cours, quelle que soit sa tige.
        if let enCours = resumable(identity: document.source.identity) { return enCours.id }
        // Règles 2 et 3 : la tige de base si elle est libre, sinon la première tige libre ensuite.
        return try TranscriptFilenames.uniqueStem(in: base, base: tige)
    }

    /// Le contenu du dossier, décodé (critère 14 : l'application n'affiche que ce qui existe sur
    /// disque). Ne jette pas.
    ///
    /// - un `<...>.json` illisible est **ignoré et compté** (jamais fatal) : un transcript abîmé ne
    ///   doit pas rendre toute la bibliothèque invisible ;
    /// - un `.md` orphelin, le sous-dossier `work/` et tout autre fichier sont ignorés **sans être
    ///   comptés** : ce ne sont pas des transcripts illisibles ;
    /// - une base absente rend une liste vide.
    public func list() -> TranscriptListing {
        // Une racine absente n'est pas une erreur, c'est le premier lancement : aucun transcript
        // n'a encore été écrit, et `list()` ne jette pas.
        guard let entrees = try? FileManager.default.contentsOfDirectory(atPath: base.path) else {
            return TranscriptListing(documents: [], unreadableCount: 0)
        }

        var documents: [TranscriptDocument] = []
        var illisibles = 0
        for entree in entrees where entree.hasSuffix(Self.extensionJSON) {
            // `contentsOfDirectory(atPath:)` est la variante **non récursive** : le parcours ne
            // descend pas dans `work/`, donc les tranches et `progress.json` ne sont jamais vus.
            // Ce qui ne finit pas par `.json` (un `.md` orphelin, un `.DS_Store`, un `.txt`) est
            // écarté ici même et n'entre pas dans le compte des illisibles.
            let tige = String(entree.dropLast(Self.extensionJSON.count))
            if let document = transcript(id: tige) {
                documents.append(document)
            } else {
                // JSON tronqué, JSON valide mais étranger au schéma, fichier illisible : compté,
                // jamais fatal — c'est ce qui explique une tuile manquante sans masquer les autres.
                illisibles += 1
            }
        }
        return TranscriptListing(documents: documents, unreadableCount: illisibles)
    }

    /// Le transcript dont **l'`id` est la tige du nom de fichier** (`<tige>.json`), ou `nil` quand
    /// aucun fichier décodable ne porte cette tige, **ou que le champ `id` du fichier décodé n'est
    /// pas `<id>`**. Ne jette pas.
    ///
    /// **L'invariant du schéma (§2.4) est vérifié ici, et nulle part ailleurs** : « l'`id` d'un
    /// document est la tige de son fichier ». C'est ce qui autorise la règle 1 des collisions à
    /// désigner un fichier **par son `id`** sans index, et ce qui interdit à une tuile (critère 16)
    /// ou à un `murmure read <id>` (critère 20) de désigner autre chose que le fichier qu'on croit.
    /// Un `<tige>.json` qui déclare un autre identifiant n'est pas « le transcript `<tige>` » : il
    /// est **étranger**, donc `list()` le compte comme illisible sans une ligne de plus.
    public func transcript(id: String) -> TranscriptDocument? {
        guard Self.estUneTige(id) else { return nil }
        // Absent, tronqué, ou écrit par une version future du schéma : `nil`, et l'appelant
        // (panneau, CLI) traite l'id inconnu comme une tuile déjà disparue.
        guard let donnees = try? Data(contentsOf: base.appendingPathComponent("\(id).json")),
            let document = try? Self.decodeur().decode(TranscriptDocument.self, from: donnees),
            document.id == id
        else { return nil }
        return document
    }

    /// Le travail **reprisable** de cette identité canonique : le plus récent des documents de
    /// cette source dont le travail n'est pas fini (statut `inProgress` ou `failed`), `nil` quand
    /// il n'y en a aucun.
    ///
    /// **« Le plus récent »** se lit sur `createdAt`, puis sur `segments.last?.end` à date égale :
    /// deux documents d'une même source peuvent partager leur date de création (le rejeu d'une
    /// reprise, une écriture interrompue), et c'est alors le travail **le plus avancé** qui est
    /// l'ancre — celui dont la reprise coûte le moins.
    ///
    /// **La règle 1 des collisions du plan §2.4 s'appuie sur cette fonction** : l'écriture d'un
    /// travail reprend la tige de ce document, qu'elle soit la tige de base ou une tige suffixée,
    /// **et que la tige de base soit libre ou non**. C'est ce qui garantit qu'une source a **au plus
    /// un document reprisable** — sans quoi chaque écriture du même travail suffixerait une tige de
    /// plus (`-2`…`-20`) jusqu'à `TranscriptFilenameError.allNamesTaken(base:)`, laissant un
    /// document `inProgress` par écriture (défaut mesuré le 2026-09-22 sur la bibliothèque réelle :
    /// 31 `.json` à la racine, 28 `inProgress`).
    ///
    /// **La sélection n'existe qu'ici** : le runner (`TranscriptJobRunner.resumable(source:)`)
    /// délègue, il ne la réécrit pas (plan §4 lot 2/8-R).
    public func resumable(identity: String) -> TranscriptDocument? {
        list().documents
            .filter {
                $0.source.identity == identity
                    && ($0.status == .inProgress || $0.status == .failed)
            }
            .max { gauche, droite in
                // Le plus récent ; à date égale (l'horodatage ISO-8601 est à la seconde, deux
                // écritures d'un même travail peuvent y tomber), celui qui va le plus loin dans
                // l'audio. Ce départage n'est pas cosmétique : départager par l'ordre du listing
                // ferait choisir un document qui porte moins d'unités que son voisin, donc
                // disparaître de la reprise l'intervalle que celui-ci ne porte pas — la perte
                // silencieuse que la reprise existe pour éviter.
                if gauche.createdAt != droite.createdAt { return gauche.createdAt < droite.createdAt }
                return (gauche.segments.last?.end ?? 0) < (droite.segments.last?.end ?? 0)
            }
    }

    /// Supprime **les deux fichiers** d'un transcript (`.json` et `.md`), sous la même tige. Ne
    /// jette pas.
    ///
    /// Un id qui ne correspond à aucune tige présente est un **no-op** : la tuile a déjà disparu,
    /// et supprimer deux fois n'est pas une erreur (le panneau et le CLI peuvent se croiser, R4).
    ///
    /// **Ne sort jamais de la base** : l'id est une tige, jamais un chemin. Un id qui contiendrait
    /// un séparateur de chemin ne désigne aucun fichier de la racine et ne supprime rien ailleurs.
    public func delete(id: String) {
        // L'id est validé avant d'être composé en chemin : c'est la garde qui fait qu'un
        // `../hors-base` venu du CLI (R4) n'atteint aucun fichier hors de la racine.
        guard Self.estUneTige(id) else { return }
        for extensionFichier in [Self.extensionJSON, Self.extensionMarkdown] {
            // `try?` : un fichier déjà absent — ou absent des deux, si la suppression se répète —
            // n'est pas une erreur, c'est l'état visé.
            try? FileManager.default.removeItem(
                at: base.appendingPathComponent("\(id)\(extensionFichier)"))
        }
    }

    // MARK: - Détails d'implémentation

    /// L'encodage du `.json` : schéma du lot 1 et dates ISO-8601, comme les agents les lisent.
    ///
    /// Un encodeur **neuf par écriture** plutôt qu'une instance partagée : deux écritures
    /// concurrentes (le lot 10 peut transcrire deux vidéos en parallèle) ne doivent partager aucun
    /// état d'encodage. `sortedKeys` rend les octets reproductibles pour un même document, ce qui
    /// rend `diff` et une future empreinte utilisables sur ces fichiers.
    private static func encodeur(_ document: TranscriptDocument) throws -> Data {
        let encodeur = JSONEncoder()
        encodeur.dateEncodingStrategy = .iso8601
        encodeur.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encodeur.encode(document)
    }

    /// Le décodeur des fichiers écrits ci-dessus — même stratégie de dates, sinon un transcript
    /// écrit par la bibliothèque ne se relirait pas par elle.
    private static func decodeur() -> JSONDecoder {
        let decodeur = JSONDecoder()
        decodeur.dateDecodingStrategy = .iso8601
        return decodeur
    }

    /// Écrit `contenu` à `destination` **en un remplacement atomique** : le contenu va d'abord dans
    /// un fichier temporaire du même dossier, puis `rename(2)` le pose à la place de la cible.
    ///
    /// Deux conséquences, et ce sont les deux que le contrat mesure :
    /// - un lecteur qui parcourt le dossier ne voit **jamais** un JSON partiel : la cible n'est
    ///   jamais réécrite sur place, elle est remplacée d'un seul coup ;
    /// - un lecteur qui avait **ouvert** l'ancien fichier continue de lire l'ancien transcript
    ///   complet — l'ancien inode survit au renommage pour les descripteurs déjà ouverts.
    ///
    /// `rename(2)` et non `FileManager.replaceItemAt` : ce dernier commence par écarter l'ancien
    /// fichier avant de poser le nouveau, ce qui laisse un instant où le chemin est **vide** — un
    /// lecteur qui arrive là ne verrait rien du tout, alors que le remplacement, lui, ne laisse
    /// jamais le chemin vacant.
    ///
    /// Le temporaire porte un nom **terminé par `.tmp-<UUID>`**, jamais `.json` : un temporaire
    /// qu'un arrêt brutal laisserait derrière lui est ignoré par `list()` (il n'est pas un
    /// transcript illisible) et ne bloque aucune tige pour `uniqueStem` — il ne peut pas non plus
    /// être pris pour un transcript par un agent qui parcourt le dossier.
    private static func remplacer(contenu: Data, a destination: URL) throws {
        let temporaire = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try contenu.write(to: temporaire)
        guard rename(temporaire.path, destination.path) == 0 else {
            // Le code POSIX est remonté tel quel (`ENOSPC`, `EACCES`…) : l'appelant a une chose à
            // dire à Louis, et ce n'est pas « une erreur est survenue ».
            let code = errno
            try? FileManager.default.removeItem(at: temporaire)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    /// Un id est une **tige**, jamais un chemin : il ne peut pas sortir de la racine.
    ///
    /// Le CLI accepte un id venu de l'extérieur (R4) et le panneau peut en tenir un d'un document
    /// périmé ; un id qui porte un séparateur, `.` ou `..` ne désigne aucun fichier de la racine et
    /// n'est donc jamais composé en chemin. `:` est refusé avec eux : c'est un séparateur de chemin
    /// historique de macOS, que Foundation traduit volontiers en `/`.
    private static func estUneTige(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains(":")
    }

    private static let extensionJSON = ".json"
    private static let extensionMarkdown = ".md"
}
