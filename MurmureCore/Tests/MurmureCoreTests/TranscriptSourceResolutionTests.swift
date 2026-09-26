import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 13 : un point de résolution unique « opérande → source », dans le cœur.
///
/// Ce que ces tests protègent, au-delà de la forme des chaînes : **une source exploitable porte
/// toujours une identité, et une entité que le cœur ne peut pas nommer n'est jamais une source**.
/// Les deux appelants appliquent aujourd'hui des règles **différentes au même fichier** : le CLI
/// refuse sur `!identite.isEmpty`, le panneau accepte sur le seul `fileExists`. Un dossier glissé
/// sur l'onglet est donc **mis en file avec une identité vide** — et `stem(...)` rend alors
/// `id8 = e3b0c442`, le SHA-256 de la chaîne vide, **le même pour tout dossier tout jour**.
///
/// **Tous ces tests échouent sur une assertion explicite** tant que le corps sentinelle de
/// `resolve(_:)` n'a pas été remplacé. Aucun n'échoue à la compilation : `resolve` retourne déjà
/// une valeur, et c'est l'**égalité de la raison** qui est fausse.
final class TranscriptSourceResolutionTests: XCTestCase {
    private var repertoire: URL!
    /// Le répertoire de travail avant que le cas 5 ne le déplace, restauré au `tearDown`.
    private var repertoireTravailPrecedent: String?

    override func setUpWithError() throws {
        repertoire = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TranscriptSourceResolutionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repertoire, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Le répertoire de travail est rendu **avant** toute autre chose : le cas 5 le déplace, et
        // un répertoire temporaire supprimé alors qu'il est encore courant empoisonnerait tous les
        // tests suivants du processus.
        if let anterior = repertoireTravailPrecedent {
            FileManager.default.changeCurrentDirectoryPath(anterior)
            repertoireTravailPrecedent = nil
        }
        // Les fixtures illisibles sont rendues lisibles avant le retrait : un fichier en `chmod 000`
        // dans un répertoire temporaire ne se supprime pas, et la fuite polluerait les runs suivants.
        if let repertoire {
            let manager = FileManager.default
            for nom in ["illisible.m4a", "sous/illisible.m4a"] {
                try? manager.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: repertoire.appendingPathComponent(nom).path)
            }
            try? manager.removeItem(at: repertoire)
        }
    }

    // MARK: - Outils

    /// Un fichier ordinaire lisible, de `octets` octets tous égaux à `octet`.
    ///
    /// Le contenu est **uniforme** à dessein : deux fichiers de même contenu ont la même identité,
    /// et c'est ce que le cas 4 vérifie sur un lien symbolique.
    @discardableResult
    private func ecrire(_ nomRelatif: String, octets: Int = 4096, octet: UInt8 = 0x41) throws -> URL {
        let url = repertoire.appendingPathComponent(nomRelatif)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: url.path, contents: Data(repeating: octet, count: octets))
        return url
    }

    /// La source d'un `case .source`, ou un échec qui **nomme** le cas qu'on attendait.
    ///
    /// Extraire la source ici, et non dans chaque test, garde les messages d'échec parlants : un
    /// test qui compare un enum entier affiche `unsupportedScheme("…")` là où il attendait une
    /// source, et le lecteur doit pouvoir voir *quelle* raison est revenue.
    private func source(
        _ resolution: TranscriptSourceResolution, _ operande: String,
        fichier: StaticString = #filePath, ligne: UInt = #line
    ) throws -> TranscriptSource {
        switch resolution {
        case .source(let source):
            return source
        case .emptyEntry:
            XCTFail("« \(operande) » a rendu .emptyEntry, une source était attendue", file: fichier, line: ligne)
        case .unsupportedURL(let hote):
            XCTFail("« \(operande) » a rendu .unsupportedURL(\"\(hote)\"), une source était attendue", file: fichier, line: ligne)
        case .unsupportedScheme(let schema):
            XCTFail("« \(operande) » a rendu .unsupportedScheme(\"\(schema)\"), une source était attendue", file: fichier, line: ligne)
        case .unreadableFile(let chemin):
            XCTFail("« \(operande) » a rendu .unreadableFile(\"\(chemin)\"), une source était attendue", file: fichier, line: ligne)
        }
        // `XCTFail` ne termine pas le contrôle de flux : on rend une source hors contrat pour que
        // le test continue vers ses autres assertions au lieu de tomber sur un `fatalError` —
        // c'est à la fois le diagnostic le plus complet et la seule façon de ne pas tuer le run.
        return TranscriptSource(kind: .file, identity: "contrat-rompu")
    }

    // MARK: - Cas 1 — les sous-domaines passent (figé par le code livré, pas arbitré)

    /// Cas 1 — un sous-domaine de même famille est une source, au bon `kind` et à la bonne
    /// identité.
    ///
    /// La règle livrée est `hote == $0 || hote.hasSuffix(".\($0)")` pour
    /// `{youtube.com, youtu.be, x.com, twitter.com}`, **convergente sur les trois listes**. Ce
    /// n'est donc pas une décision à prendre : c'est une **constatation figée**, et ce cas
    /// l'épingle. Il porte le mutant (a) : une table de `kind(parHote:)` écrite à la main perd
    /// la clause sous-domaine, et ces adresses rougissent.
    func testCas1_sousDomainesDeMemeFamile_sontUneSourceAuBonKindEtALaBonneIdentite() throws {
        let youtube = [
            "https://m.youtube.com/watch?v=ID",
            "https://music.youtube.com/watch?v=ID",
            "https://youtu.be/ID",
            "https://youtube.com/shorts/ID",
        ]
        for operande in youtube {
            let source = try source(TranscriptSource.resolve(operande), operande)
            XCTAssertEqual(source.kind, .youtube, "« \(operande) » doit être une source YouTube")
            XCTAssertEqual(source.identity, "ID", "« \(operande) » doit porter l'id de la vidéo")
            XCTAssertEqual(source.url?.absoluteString, operande, "« \(operande) » doit conserver son URL")
            XCTAssertNil(source.path, "une source YouTube ne porte pas de chemin local")
        }

        let x = "https://mobile.twitter.com/i/status/ID"
        let sourceX = try source(TranscriptSource.resolve(x), x)
        XCTAssertEqual(sourceX.kind, .x, "« \(x) » doit être une source X")
        XCTAssertEqual(sourceX.identity, "ID", "« \(x) » doit porter l'id du statut")
    }

    // MARK: - Cas 2 — l'ancrage du suffixe, et t.co

    /// Cas 2 — un hôte qui **ressemble** à une famille n'en est pas un.
    ///
    /// Le point d'ancrage — le point avant le domaine dans `hasSuffix(".\($0)")` — est ce qui sépare
    /// `notyoutube.com` de `m.youtube.com`. C'est **l'ancrage dans l'extraction** qui rend ce cas
    /// discriminant : retiré de l'extraction, `notyoutube.com` et `xtwitter.com` rendent une
    /// identité ; retiré d'une table de `kind`, il ne casse rien, parce que la table ne rend jamais
    /// l'identité.
    ///
    /// `t.co` n'est un sous-domaine d'aucun des quatre domaines et les trois listes le refusent :
    /// il appartient donc ici, **pas** au cas 1.
    func testCas2_hoteQuiRessembleAUneFamilie_etRaccourcisseurRefuses() throws {
        let refuses = [
            "https://notyoutube.com/watch?v=ID",
            "https://youtube.com.evil.example/watch?v=ID",
            "https://xtwitter.com/i/status/ID",
            "https://t.co/ID",
        ]
        for operande in refuses {
            let resolution = TranscriptSource.resolve(operande)
            // `.unsupportedURL` porte **l'hôte** : c'est la charge utile que le CLI rend aujourd'hui
            // (`url.host ?? brut`), et elle est vérifiée au cas 6.
            XCTAssertEqual(
                resolution, .unsupportedURL(URL(string: operande)!.host!),
                "« \(operande) » n'est pas d'une famille connue : il doit être refusé par son hôte")
        }
    }

    // MARK: - Cas 3 — les trois classes illisibles, nommées

    /// Cas 3 — une entité que le cœur ne peut pas nommer est **refusée**, jamais une source.
    ///
    /// C'est le cas qui rend le rouge initial vrai **sans** dépendre de la couture applicative :
    /// les deux fichiers ci-dessous sont dans un répertoire temporaire du test, et aucun appelant
    /// n'est involved. Les trois classes meurent à deux endroits du garde de
    /// `identityFor(path:)`, et c'est ce qui les regroupe — un répertoire, un FIFO et un socket
    /// rendent `"` par le même maillon sans qu'un test les construise.
    func testCas3_entiteSansIdentiteLisible_estRefuseeJamaisSource() throws {
        // Un répertoire : `isRegularFile == false` → le maillon de la **taille** échoue.
        let directory = repertoire.appendingPathComponent("dossier.m4a")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Un fichier illisible : `isRegularFile == true` et `fileSize == 512` — les deux
        // maillons de la taille passent, et c'est l'**ouverture** qui échoue. Une règle par type
        // l'exclut, donc il est nommé à part.
        let illisible = try ecrire("illisible.m4a", octets: 512, octet: 0x42)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: illisible.path)

        // Un lien symbolique vers un répertoire : l'entité existe, et n'est pas un fichier.
        let lienVersRepertoire = repertoire.appendingPathComponent("lien-dossier.m4a")
        try FileManager.default.createSymbolicLink(at: lienVersRepertoire, withDestinationURL: directory)

        for entite in [directory, illisible, lienVersRepertoire] {
            let resolution = TranscriptSource.resolve(entite.path)
            XCTAssertEqual(
                resolution, .unreadableFile(entite.path),
                "« \(entite.lastPathComponent) » existe mais n'est pas un fichier ordinaire lisible : il doit être refusé par son chemin")
        }
    }

    // MARK: - Cas 4 — le lien symbolique vers un fichier valide

    /// Cas 4 — un lien symbolique vers un fichier valide est une source, à l'identité de sa
    /// **cible**, et au chemin que l'utilisateur a déposé.
    ///
    /// Les trois assertions sont nécessaires et aucune ne suffit. L'identité prouve que la
    /// résolution a lieu ; l'égalité avec la cible prouve qu'elle est faite sur le **contenu**,
    /// comme le cœur l'énonce ; le chemin déposé interdit de réécrire le chemin que l'utilisateur
    /// a choisi. C'est ce cas que le mutant (g) doit casser.
    func testCas4_lienSymboliqueVersFichierValide_sourceALaIdentiteDeLaCibleAuCheminDepose() throws {
        let cible = try ecrire("cible.m4a", octets: 4096, octet: 0x41)
        let lien = repertoire.appendingPathComponent("lien.m4a")
        try FileManager.default.createSymbolicLink(at: lien, withDestinationURL: cible)

        let source = try source(TranscriptSource.resolve(lien.path), lien.path)
        XCTAssertEqual(source.kind, .file, "un lien vers un fichier ordinaire est une source locale")
        XCTAssertFalse(
            source.identity.isEmpty,
            "l'identité d'une source n'est jamais vide : c'est l'invariant central du lot")
        XCTAssertEqual(
            source.identity, TranscriptFilenames.identityFor(path: cible.path),
            "le lien et sa cible ont le même contenu, donc la même identité")
        XCTAssertEqual(
            source.path, lien.path,
            "la source conserve le chemin déposé, pas le chemin résolu : c'est celui que le runner lit")
    }

    // MARK: - Cas 5 — le chemin relatif au schéma, et son complément

    /// Cas 5 — un chemin **relatif** dont le premier segment contient `:` est un schéma, pas un
    /// nom de fichier — **même quand le fichier existe**.
    ///
    /// `URL(string: "note:version2.m4a")?.scheme == "note"`, mesuré : l'identité est donc **non
    /// vide** et le cœur nomme le fichier — que le CLI refuse, parce que sa garde lit un nom de
    /// fichier comme un schéma d'URL. Le lot aligne le panneau sur ce refus. C'est la seule perte
    /// de capacité du lot, et elle est bornée : un dépôt produit toujours un chemin **absolu**.
    ///
    /// **La fixture et l'opérande désignent le même fichier, et c'est le cœur du cas.** La r6 §2.6
    /// borne la perte à « un chemin relatif tapé, et **seulement si le répertoire courant du
    /// processus contient un tel fichier** » : le monde qu'elle décrit est donc *le relatif
    /// présent*. Le test déplace le répertoire de travail du processus dans son répertoire
    /// temporaire — restauré au `tearDown` — pour exercer **ce** monde, et non le monde opposé où
    /// les deux implémentations convergeraient. Sans cela, une implémentation « si le fichier
    /// existe, c'est une source » passerait les sept cas : c'est la seule qui contredit la
    /// décision tracée, et elle doit rougir ici.
    ///
    /// Le complément est ce qui prouve qu'on a distingué le relatif de l'absolu : un chemin absolu
    /// contenant `:` rend `scheme == nil` (mesuré) et **doit** produire une source.
    func testCas5_cheminRelatifAvecDeuxPoints_estUnSchema_etUnCheminAbsoluNeLestPas() throws {
        let relatif = try ecrire("note:version2.m4a", octets: 512, octet: 0x43)

        // Le monde de §2.6 : le répertoire courant **contient** le fichier, et l'opérande relatif
        // est donc lisible par le processus. Le répertoire de travail est déplacé puis restauré.
        repertoireTravailPrecedent = FileManager.default.currentDirectoryPath
        XCTAssertTrue(
            FileManager.default.changeCurrentDirectoryPath(repertoire.path),
            "le test doit pouvoir déplacer le répertoire de travail : sans cela il n'exerce pas §2.6")

        // Contrôle positif, **sur la chaîne relative** que `resolve` reçoit — et non sur le chemin
        // absolu de la fixture, qui ne prouverait rien : ce sont deux chaînes différentes.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: "note:version2.m4a"),
            "l'opérande relatif doit désigner un fichier réellement présent : c'est la précondition de §2.6")

        XCTAssertEqual(
            TranscriptSource.resolve("note:version2.m4a"), .unsupportedScheme("note:version2.m4a"),
            "« note:version2.m4a » lit son `:` comme un schéma même s'il existe : il ne peut pas être une source")
        XCTAssertNotEqual(
            TranscriptSource.resolve("note:version2.m4a"), .source(
                TranscriptSource(kind: .file, path: relatif.path, identity: "x")),
            "« note:version2.m4a » ne doit jamais devenir une source, fichier présent ou non")

        // Le complément : le **même** nom de fichier, mais absolu, doit passer. Il est asserted
        // depuis le répertoire temporaire, donc le chemin est bien absolu et `scheme` est `nil`.
        let absolu = try source(TranscriptSource.resolve(relatif.path), relatif.path)
        XCTAssertEqual(absolu.kind, .file, "un chemin absolu contenant `:` reste un chemin de fichier")
        XCTAssertFalse(absolu.identity.isEmpty, "un fichier lisible a une identité")
        XCTAssertEqual(absolu.path, relatif.path, "la source conserve le chemin absolu déposé")
    }

    // MARK: - Cas 6 — les quatre branches d'URL, et la charge utile qu'elles portent

    /// Cas 6 — les quatre branches d'URL, séparément, et **la chaîne qu'elles portent**.
    ///
    /// Le CLI a **deux** `throw .unsupportedURL` à deux charges utiles distinctes : l'hôte
    /// (`url.host ?? brut`) d'un côté, l'opérande (`brut`) de l'autre. C'est pour cela que
    /// l'énumération a **cinq** cas et non quatre : avec la charge utile **dans** le cas, le
    /// `switch` du CLI ne la recalcule pas, et l'aplatissement devient non exprimable. Vérifier
    /// la chaîne rend la garantie « aucune chaîne ne change » **épinglée** au lieu d'affirmée.
    func testCas6_quatreBranchesDUrl_etLaChaineExacteQueLeCliRendAujourdhui() throws {
        // 4a-(a) — hôte hors familles : l'hôte.
        XCTAssertEqual(
            TranscriptSource.resolve("https://example.com/v/ID"), .unsupportedURL("example.com"),
            "un hôte hors familles porte l'hôte, comme `url.host ?? brut`")

        // 4a-(b) — hôte **dans** une famille mais sans identité extractible : le même hôte, et
        // **jamais** `.emptyEntry` ni `.unreadableFile`. C'est la moitié que « hors familles »
        // ne couvre pas, et le mutant (f) la casse en la traitant comme une entrée vide.
        for operande in ["https://youtube.com/@unCanal", "https://x.com/unUtilisateur"] {
            XCTAssertEqual(
                TranscriptSource.resolve(operande),
                .unsupportedURL(URL(string: operande)!.host!),
                "« \(operande) » est dans une famille mais sans identité : le refus reste un refus d'URL, jamais une entrée vide")
        }

        // 4b — un autre schéma porte **l'opérande**, jamais l'hôte : le mutant (e) casse ici.
        for operande in ["ftp://exemple.fr/v/ID", "file:///tmp/a.m4a", "mailto:a@b.fr"] {
            XCTAssertEqual(
                TranscriptSource.resolve(operande), .unsupportedScheme(operande),
                "« \(operande) » est un schéma non http : il porte l'opérande, jamais l'hôte")
        }

        // Le repli `?? brut` est **épinglé**, pas supposé : un `http` sans hôte rend l'opérande.
        XCTAssertEqual(
            TranscriptSource.resolve("http:///v/ID"), .unsupportedURL("http:///v/ID"),
            "un `http` sans hôte rend l'opérande : le repli `?? brut` est la chaîne d'aujourd'hui")

        // 4c — vide ou blanc : une entrée vide, pas un refus d'URL.
        for operande in ["", "   ", "\t\n "] {
            XCTAssertEqual(
                TranscriptSource.resolve(operande), .emptyEntry,
                "« \(operande) » est une entrée vide, pas une URL refusée")
        }
    }

    // MARK: - Cas 7 — non-régression de l'identité

    /// Cas 7 — la résolution ne change **rien** au cœur du nommage.
    ///
    /// `identityFor(url:)` rend exactement la même chaîne qu'avant pour un lot d'adresses, et
    /// `identityFor(path:)` n'est pas touchée : c'est le mutant (b) qui casse ce cas en faisant
    /// rendre `""` par `identityFor` sans passer par `resolve`. Le lot déplace la **décision**,
    /// pas la **dérivation** — si cette égalité bouge, c'est que la résolution a réécrit le
    /// nommage au lieu de s'y brancher.
    ///
    /// Le lien symbolique est ici la preuve que `identityFor(path:)` garde son comportement
    /// d'aujourd'hui, **refus compris** : elle rend toujours `""` sur le chemin brut. C'est
    /// `resolve` qui résout, pas elle — et c'est ce qui permet au cas 4 de passer sans la
    /// modifier.
    func testCas7_resolutionNeChangeRienAuNommage() throws {
        let lot: [(String, String)] = [
            ("https://www.youtube.com/watch?v=ID", "ID"),
            ("https://youtu.be/ID?t=42s", "ID"),
            ("https://x.com/i/status/ID", "ID"),
            ("https://twitter.com/i/status/ID", "ID"),
            // Hors familles : une chaîne vide, et **rien** d'autre.
            ("https://example.com/v/ID", ""),
            ("https://m.youtube.com/@unCanal", ""),
        ]
        for (adresse, attendue) in lot {
            let url = URL(string: adresse)!
            XCTAssertEqual(
                TranscriptFilenames.identityFor(url: url), attendue,
                "« \(adresse) » : `identityFor(url:)` doit rendre exactement la même chaîne qu'avant")
        }

        // `identityFor(path:)` n'est pas touchée — donc elle refuse toujours le lien brut.
        let cible = try ecrire("cible-nr.m4a", octets: 4096, octet: 0x41)
        let lien = repertoire.appendingPathComponent("lien-nr.m4a")
        try FileManager.default.createSymbolicLink(at: lien, withDestinationURL: cible)
        XCTAssertEqual(
            TranscriptFilenames.identityFor(path: lien.path), "",
            "`identityFor(path:)` garde son comportement d'aujourd'hui : c'est `resolve` qui résout le lien")
        XCTAssertEqual(
            TranscriptFilenames.identityFor(path: cible.path),
            TranscriptFilenames.identityFor(
                path: URL(fileURLWithPath: lien.path).resolvingSymlinksInPath().path),
            "la cible et le lien résolu portent le même contenu, donc la même identité")

        // **Contrôle positif, dans le même test.** Sans lui, ce cas serait vert sans jamais
        // appeler `resolve` : il constaterait que le nommage n'a pas bougé, ce qui est vrai même
        // si la résolution n'existe pas. Il doit donc prouver que `resolve` **passe par**
        // `identityFor` au lieu de le recalculer — c'est ce couplage qui fait de ce cas une
        // non-régression sur le *câblage*, et non sur du texte.
        for (adresse, _) in lot where !TranscriptFilenames.identityFor(url: URL(string: adresse)!).isEmpty {
            let source = try source(TranscriptSource.resolve(adresse), adresse)
            XCTAssertEqual(
                source.identity, TranscriptFilenames.identityFor(url: URL(string: adresse)!),
                "« \(adresse) » : `resolve` doit déléguer à `identityFor(url:)`, pas recalculer l'identité")
        }
    }
}
