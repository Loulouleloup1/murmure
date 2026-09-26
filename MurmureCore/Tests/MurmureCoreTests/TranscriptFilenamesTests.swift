import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 1 : le nommage des deux fichiers d'un transcript dans
/// `~/Documents/Murmure/Transcripts/` (plan §2.4).
///
/// Ce que ces tests protègent, au-delà de la forme des chaînes : **une acquisition relancée sur
/// la même source doit viser la même tige** (c'est une reprise, pas un doublon) et **aucun
/// transcript existant ne doit être écrasé**. Les deux se paient cher à l'usage — l'un par un
/// dossier plein de doublons, l'autre par une perte de données.
///
/// Tous ces tests échouent sur une **assertion explicite** tant que les corps sentinelles de
/// `TranscriptFilenames.swift` n'ont pas été remplacés.
final class TranscriptFilenamesTests: XCTestCase {
    /// Une tige déjà formée, comme celle que le lot 2 écrira sur disque.
    private let base = "demonstration-2026-09-20-a1b2c3d4"

    private var repertoire: URL!

    override func setUpWithError() throws {
        repertoire = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TranscriptFilenamesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repertoire, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repertoire)
    }

    // MARK: - Outils

    /// Midi, dans le calendrier et le fuseau courants : ni un décalage vers l'ouest ni un
    /// décalage vers l'est ne peuvent alors faire changer le jour écrit.
    private func jour(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var composants = DateComponents()
        composants.year = year
        composants.month = month
        composants.day = day
        composants.hour = 12
        return Calendar(identifier: .gregorian).date(from: composants)
            ?? Date(timeIntervalSince1970: 0)
    }

    private func adresse(_ chaine: String) -> URL {
        guard let url = URL(string: chaine) else {
            XCTFail("adresse de test invalide : \(chaine)")
            return URL(fileURLWithPath: "/dev/null")
        }
        return url
    }

    @discardableResult
    private func ecrire(_ tige: String, _ extensionFichier: String = "json", octets: [UInt8] = [0x41])
        throws -> String
    {
        let url = repertoire.appendingPathComponent("\(tige).\(extensionFichier)")
        try Data(octets).write(to: url)
        return url.path
    }

    private func ecrireFichier(_ nom: String, octets: [UInt8]) throws -> String {
        let url = repertoire.appendingPathComponent(nom)
        try Data(octets).write(to: url)
        return url.path
    }

    private func nomsSurDisque() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: repertoire.path).sorted()
    }

    /// Le suffixe `id8` : les 8 derniers caractères de la tige.
    private func id8(_ tige: String) -> String { String(tige.suffix(8)) }

    private func libre(_ tige: String) -> Bool {
        !FileManager.default.fileExists(
            atPath: repertoire.appendingPathComponent("\(tige).json").path)
            && !FileManager.default.fileExists(
                atPath: repertoire.appendingPathComponent("\(tige).md").path)
    }

    // MARK: - `stem(title:date:identity:)`

    /// La forme gelée : `<slug>-<AAAA-MM-JJ>-<id8>`. Le titre perd ses majuscules, ses accents et
    /// tout ce qui n'est pas alphanumérique.
    func testLaTigeEstLeSlugLaDateEtLIdentifiant() {
        let tige = TranscriptFilenames.stem(
            title: "Vidéo déjà vue à São Paulo", date: jour(2026, 9, 20), identity: "dQw4w9WgXcQ")

        XCTAssertTrue(
            tige.hasPrefix("video-deja-vue-a-sao-paulo-2026-09-20-"),
            "contrat lot 1 : non implémenté — tige obtenue : « \(tige) »")
        XCTAssertNotNil(
            id8(tige).range(of: #"^[0-9a-fA-F]{8}$"#, options: .regularExpression),
            "contrat lot 1 : non implémenté — id8 attendu sur 8 caractères hexadécimaux : « \(id8(tige)) »")
    }

    /// Tout caractère non alphanumérique devient `-`, un par un. Un titre réel contient ces
    /// caractères-là (« épisode 1.2 », « live/rediffusion »), et ils ne doivent ni disparaître ni
    /// devenir un caractère que le Finder ou un agent interpréterait autrement.
    func testLeSlugRemplaceLesCaracteresNonAlphanumeriques() {
        let cas: [(titre: String, slug: String)] = [
            ("un-titre-avec-des-espaces", "un-titre-avec-des-espaces"),
            ("un.titre", "un-titre"),
            ("un/titre", "un-titre"),
            ("un:titre", "un-titre"),
            ("Épisode 1.2 déjà vu", "episode-1-2-deja-vu"),
        ]

        for (titre, slug) in cas {
            let tige = TranscriptFilenames.stem(
                title: titre, date: jour(2026, 9, 20), identity: "a1b2c3d4")
            XCTAssertTrue(
                tige.hasPrefix("\(slug)-2026-09-20-"),
                "contrat lot 1 : non implémenté — tige obtenue pour « \(titre) » : « \(tige) »")
        }
    }

    /// Le slug est **coupé à 60 caractères**, et c'est le slug seul qui est coupé : la date et
    /// l'identifiant ne sont pas rognés pour rentrer dans une longueur totale.
    func testLeSlugEstCoupeACaracteresSoixante() {
        // 8 mots de 10 lettres séparés par une espace : 87 caractères avant repli. Le repli ne
        // change rien à ces caractères-là, donc la coupe à 60 tombe après 5 caractères du 6e mot.
        let titre = Array(repeating: "kangourou1", count: 8).joined(separator: " ")
        let slug = "kangourou1-kangourou1-kangourou1-kangourou1-kangourou1-kango"
        XCTAssertEqual(slug.count, 60, "le témoin du test lui-même")

        let tige = TranscriptFilenames.stem(
            title: titre, date: jour(2026, 9, 20), identity: "a1b2c3d4")

        XCTAssertTrue(
            tige.hasPrefix("\(slug)-2026-09-20-"),
            "contrat lot 1 : non implémenté — tige obtenue : « \(tige) »")
    }

    /// Un titre vide est le cas réel d'un fichier local sans titre : le repli se fait sur la
    /// source. Dire « le repli, c'est la source prise comme titre » plutôt que « le repli commence
    /// par la source » fixe la même chose sans figer la forme de l'identité, qui appartient à
    /// `identityFor`.
    func testUnTitreVideReplieSurLaSource() {
        let identite = "dQw4w9WgXcQ"
        let vide = TranscriptFilenames.stem(title: "", date: jour(2026, 9, 20), identity: identite)
        let repli = TranscriptFilenames.stem(
            title: identite, date: jour(2026, 9, 20), identity: identite)

        XCTAssertFalse(vide.isEmpty, "contrat lot 1 : non implémenté")
        XCTAssertEqual(
            vide, repli,
            "contrat lot 1 : non implémenté — le repli doit être la source prise comme titre")
        XCTAssertTrue(
            vide.hasPrefix("dq"),
            "contrat lot 1 : non implémenté — un titre vide ne donne pas une tige sans slug : « \(vide) »")
    }

    /// Même source, même titre, deux jours : deux tiges différentes, et la date est écrite en
    /// `AAAA-MM-JJ`.
    func testLaDateSepareDeuxAcquisitionsDeDeuxJours() {
        let lundi = TranscriptFilenames.stem(
            title: "Démonstration", date: jour(2026, 9, 20), identity: "a1b2c3d4")
        let mardi = TranscriptFilenames.stem(
            title: "Démonstration", date: jour(2026, 9, 21), identity: "a1b2c3d4")

        XCTAssertTrue(
            lundi.hasPrefix("demonstration-2026-09-20-"),
            "contrat lot 1 : non implémenté — tige obtenue : « \(lundi) »")
        XCTAssertTrue(
            mardi.hasPrefix("demonstration-2026-09-21-"),
            "contrat lot 1 : non implémenté — tige obtenue : « \(mardi) »")
        XCTAssertNotEqual(lundi, mardi, "contrat lot 1 : non implémenté")
    }

    /// `stem` est pure : deux appels avec les mêmes arguments rendent la même chaîne, et
    /// l'identifiant ne dépend que de l'identité de source — pas du titre ni de la date (c'est
    /// l'identité qui doit faire converger deux acquisitions vers la même tige).
    func testLIdentifiantNeDependQueDeLaSource() {
        let une = TranscriptFilenames.stem(
            title: "Démonstration", date: jour(2026, 9, 20), identity: "a1b2c3d4")
        let bis = TranscriptFilenames.stem(
            title: "Démonstration", date: jour(2026, 9, 20), identity: "a1b2c3d4")
        let autreTitre = TranscriptFilenames.stem(
            title: "Autre titre", date: jour(2026, 9, 21), identity: "a1b2c3d4")
        let autreSource = TranscriptFilenames.stem(
            title: "Démonstration", date: jour(2026, 9, 20), identity: "deadbeef")

        XCTAssertFalse(une.isEmpty, "contrat lot 1 : non implémenté")
        XCTAssertEqual(une, bis, "contrat lot 1 : non implémenté — `stem` doit être pure")
        XCTAssertEqual(
            id8(une), id8(autreTitre),
            "contrat lot 1 : non implémenté — l'id8 suit l'identité, pas le titre")
        XCTAssertNotEqual(
            id8(une), id8(autreSource),
            "contrat lot 1 : non implémenté — deux sources distinctes ne peuvent pas partager un id8")
    }

    // MARK: - `identityFor(url:)`

    /// **Le doublon le plus coûteux, évité** : la même vidéo collée sous trois écritures d'URL
    /// différentes doit donner une seule tige — sinon Louis transcrit deux fois la même vidéo et
    /// la reprise ne reprend rien.
    func testUneVideoYouTubeAUneSeuleIdentiteQuelleQueSoitSonEcriture() {
        let identites = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s&list=PLxx",
            "https://youtu.be/dQw4w9WgXcQ?si=abcdef",
        ].map { TranscriptFilenames.identityFor(url: adresse($0)) }

        XCTAssertFalse(
            identites[0].isEmpty, "contrat lot 1 : non implémenté — identité vide")
        XCTAssertTrue(
            identites[0].contains("dQw4w9WgXcQ"),
            "contrat lot 1 : non implémenté — l'identité d'une vidéo YouTube est l'id de la vidéo, obtenu : « \(identites[0]) »")
        XCTAssertEqual(
            identites[0], identites[1],
            "contrat lot 1 : non implémenté — les paramètres de partage ne changent pas la source")
        XCTAssertEqual(
            identites[0], identites[2],
            "contrat lot 1 : non implémenté — `youtu.be` et `youtube.com/watch?v=` désignent la même vidéo")
    }

    /// Et deux vidéos distinctes ne partagent pas d'identité.
    func testDeuxVideosYouTubeOntDeuxIdentites() {
        let une = TranscriptFilenames.identityFor(
            url: adresse("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        let autre = TranscriptFilenames.identityFor(
            url: adresse("https://www.youtube.com/watch?v=NwGHNdbw1Ts"))

        XCTAssertFalse(une.isEmpty, "contrat lot 1 : non implémenté — identité vide")
        XCTAssertNotEqual(une, autre, "contrat lot 1 : non implémenté")
    }

    /// Un post X : l'identité est l'id du statut, indépendante du compte qui l'a publié et des
    /// paramètres de partage (critère 2 : même chemin de code que YouTube).
    func testUnStatutXAUneSeuleIdentiteQuelleQueSoitSonEcriture() {
        let identite = TranscriptFilenames.identityFor(
            url: adresse("https://x.com/i/status/2099881645474029569"))
        let partage = TranscriptFilenames.identityFor(
            url: adresse("https://x.com/zach/status/2099881645474029569?s=20&t=xyz"))
        let autre = TranscriptFilenames.identityFor(
            url: adresse("https://x.com/i/status/1753399999999999999"))

        XCTAssertFalse(identite.isEmpty, "contrat lot 1 : non implémenté — identité vide")
        XCTAssertTrue(
            identite.contains("2099881645474029569"),
            "contrat lot 1 : non implémenté — l'identité d'un statut X est l'id du statut, obtenu : « \(identite) »")
        XCTAssertEqual(identite, partage, "contrat lot 1 : non implémenté")
        XCTAssertNotEqual(identite, autre, "contrat lot 1 : non implémenté")
    }

    // MARK: - `identityFor(path:)`

    /// L'identité vient du **contenu**, pas du chemin : le même enregistrement copié ou renommé
    /// garde son identité, donc sa tige — c'est ce qui distingue « la même source » de « le même
    /// fichier ».
    func testLIdentiteDunFichierLocalNeDependNiDuNomNiDuDossier() throws {
        let octets = [UInt8](repeating: 0x41, count: 4096)
        let premier = try ecrireFichier("cours.mp4", octets: octets)
        let dossier = repertoire.appendingPathComponent("copies")
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        let second = dossier.appendingPathComponent("tout-autre-nom.mp4").path
        try Data(octets).write(to: URL(fileURLWithPath: second))

        let identite = TranscriptFilenames.identityFor(path: premier)
        XCTAssertFalse(identite.isEmpty, "contrat lot 1 : non implémenté — identité vide")
        XCTAssertEqual(
            identite, TranscriptFilenames.identityFor(path: second),
            "contrat lot 1 : non implémenté — le contenu décide de l'identité, pas le chemin")
        XCTAssertFalse(
            identite.contains("cours"),
            "contrat lot 1 : non implémenté — le nom du fichier ne doit pas entrer dans l'identité")
    }

    /// Même taille, un octet qui change dans les 64 premiers Kio : deux identités. C'est le
    /// témoin qui prouve que les cas d'égalité ci-dessous ne passent pas par accident.
    func testDeuxFichiersQuiDifferentDansLesPremiersKioOntDeuxIdentites() throws {
        let un = [UInt8](repeating: 0x41, count: 4096)
        var deux = un
        deux[100] = 0x42

        let identite = TranscriptFilenames.identityFor(
            path: try ecrireFichier("un.mp4", octets: un))
        XCTAssertFalse(identite.isEmpty, "contrat lot 1 : non implémenté — identité vide")
        XCTAssertNotEqual(
            identite,
            TranscriptFilenames.identityFor(path: try ecrireFichier("deux.mp4", octets: deux)),
            "contrat lot 1 : non implémenté — deux contenus différents, deux identités")
    }

    /// **La taille fait partie de l'identité** : deux fichiers qui partagent leurs 64 premiers
    /// Kio mais pas leur longueur ne sont pas le même enregistrement (une reprise tronquée, un
    /// fichier complété).
    func testLaTailleFaitPartieDeLIdentite() throws {
        let tete = [UInt8](repeating: 0x41, count: 65_536)
        let court = try ecrireFichier("court.mp4", octets: tete)
        let long = try ecrireFichier(
            "long.mp4", octets: tete + [UInt8](repeating: 0x42, count: 4096))

        let identite = TranscriptFilenames.identityFor(path: court)
        XCTAssertFalse(identite.isEmpty, "contrat lot 1 : non implémenté — identité vide")
        XCTAssertNotEqual(
            identite, TranscriptFilenames.identityFor(path: long),
            "contrat lot 1 : non implémenté — la taille du fichier entre dans l'identité")
    }

    /// **L'empreinte porte sur les 64 premiers Kio seulement** : c'est ce qui rend l'identité
    /// d'un fichier de 4 h payée à un coût fixe. Deux fichiers de même longueur qui ne diffèrent
    /// qu'au-delà des 64 premiers Kio ont donc la même identité — une dégradation assumée du plan
    /// §2.4, écrite ici pour que personne ne la « corrige » par inadvertance en hachant le
    /// fichier entier.
    func testLEmpreinteNePorteQueSurLesSoixanteQuatrePremiersKio() throws {
        let entete = [UInt8](repeating: 0x41, count: 65_536)
        let queue = [UInt8](repeating: 0x42, count: 8192)
        var deux = entete + queue
        deux[70_000] = 0x43  // au-delà des 64 premiers Kio

        let identite = TranscriptFilenames.identityFor(
            path: try ecrireFichier("un.mp4", octets: entete + queue))
        XCTAssertFalse(identite.isEmpty, "contrat lot 1 : non implémenté — identité vide")
        XCTAssertEqual(
            identite,
            TranscriptFilenames.identityFor(path: try ecrireFichier("deux.mp4", octets: deux)),
            "contrat lot 1 : non implémenté — l'empreinte est bornée aux 64 premiers Kio, plus la taille")
    }

    // MARK: - `uniqueStem(in:base:)`

    /// Répertoire vide : la base elle-même est libre, et elle l'est des deux côtés (`.json` et
    /// `.md`).
    func testUniqueStemRendLaBaseQuandElleEstLibre() throws {
        let tige = try TranscriptFilenames.uniqueStem(in: repertoire, base: base)

        XCTAssertEqual(tige, base, "contrat lot 1 : non implémenté — tige obtenue : « \(tige) »")
        XCTAssertTrue(
            libre(tige), "contrat lot 1 : non implémenté — une tige rendue doit être libre")
    }

    /// **On n'écrase jamais un transcript existant.** Le `.md` seul suffit à rendre la tige prise
    /// — écraser l'un des deux formats perdrait la moitié du transcript —, et rien n'est écrit ni
    /// supprimé par cette fonction.
    func testUniqueStemNePrendJamaisUneTigePrise() throws {
        try ecrire(base)

        let deuxieme = try TranscriptFilenames.uniqueStem(in: repertoire, base: base)
        XCTAssertEqual(
            deuxieme, "\(base)-2", "contrat lot 1 : non implémenté — tige obtenue : « \(deuxieme) »")

        // Le `.md` seul suffit : l'instantané est pris après cette écriture, pour que l'assertion
        // porte sur ce que la fonction a touché et pas sur ce que le test vient d'écrire.
        try ecrire("\(base)-2", "md")
        let avant = try nomsSurDisque()

        let troisieme = try TranscriptFilenames.uniqueStem(in: repertoire, base: base)
        XCTAssertEqual(
            troisieme, "\(base)-3",
            "contrat lot 1 : non implémenté — un `.md` existant suffit à rendre la tige prise")

        XCTAssertEqual(
            try nomsSurDisque(), avant,
            "contrat lot 1 : non implémenté — `uniqueStem` nomme, elle n'écrit ni ne supprime")
    }

    /// Les suffixes sont bornés à `-20`, et l'échec est **explicite** : au-delà, l'application a
    /// une chose à dire à Louis plutôt que vingt fichiers de plus. Le témoin de reprise vérifie
    /// que le refus n'est pas un refus général — une place libérée et la tige est rendue.
    func testUniqueStemEchoueApresVingtSuffixesPuisRepart() throws {
        try ecrire(base)
        for suffixe in 2...20 { try ecrire("\(base)-\(suffixe)") }

        XCTAssertThrowsError(
            try TranscriptFilenames.uniqueStem(in: repertoire, base: base),
            "contrat lot 1 : non implémenté — 21 tiges prises doivent échouer explicitement"
        ) { erreur in
            XCTAssertEqual(
                erreur as? TranscriptFilenameError, .allNamesTaken(base: base),
                "contrat lot 1 : non implémenté — erreur obtenue : \(erreur)")
        }

        try FileManager.default.removeItem(
            at: repertoire.appendingPathComponent("\(base)-20.json"))
        XCTAssertEqual(
            try TranscriptFilenames.uniqueStem(in: repertoire, base: base), "\(base)-20",
            "contrat lot 1 : non implémenté — une place libérée doit être reprise")
    }
}
