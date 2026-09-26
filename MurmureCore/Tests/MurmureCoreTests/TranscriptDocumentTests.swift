import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 1 (plan §7.1) : la forme exacte du fichier `.json` de
/// `~/Documents/Murmure/Transcripts/`, gelée au §2.4 du plan et dans la carte QA L1.
///
/// Tous ces tests échouent sur une **assertion explicite** tant que les corps sentinelles de
/// `TranscriptDocument.swift` n'ont pas été remplacés : jamais sur une erreur de compilation, un
/// `skip` ou un `expectedFailure`, parce qu'un test qui ne compile pas casse la gate `swift test`
/// de toutes les cartes en parallèle.
///
/// **Pourquoi les fixtures sont du JSON écrit à la main** plutôt que des documents construits par
/// l'initialiseur : le fichier est le contrat avec l'extérieur — les agents lisent ces fichiers,
/// l'application les relit au rechargement (critères 14 et 21). Un test qui part de
/// l'initialiseur ne prouve que l'aller-retour du type avec lui-même ; celui-ci prouve que le
/// schéma **écrit par quelqu'un d'autre** est lisible.
final class TranscriptDocumentTests: XCTestCase {
    /// Le fichier d'un travail terminé, clé par clé tel que le plan §2.4 le décrit.
    private static let complet = """
    {
      "schemaVersion": 1,
      "id": "demonstration-2026-09-20-a1b2c3d4",
      "title": "Démonstration",
      "source": {
        "kind": "youtube",
        "url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "identity": "dQw4w9WgXcQ"
      },
      "duration": 2293.0,
      "language": "fr",
      "languageWasForced": false,
      "model": "large-v3-turbo",
      "createdAt": "2026-09-20T10:00:00Z",
      "completedAt": "2026-09-20T10:12:30Z",
      "status": "complete",
      "segments": [
        { "start": 0.0, "end": 2.5, "text": "Bonjour" },
        { "start": 2.6, "end": 5.0, "text": "tout le monde" }
      ],
      "coverage": { "coveredSeconds": 2276.0, "ratio": 0.9926 },
      "boundaries": [
        { "start": 0.0, "duration": 300.0, "quality": "silence" },
        { "start": 300.0, "duration": 300.0, "quality": "forced" }
      ]
    }
    """

    /// Le fichier d'un travail en cours, exactement tel que le plan §2.1 le décrit : le JSON est
    /// réécrit après chaque unité avec `"status": "inProgress"`, donc il doit être lisible sans
    /// date d'achèvement et sans segments.
    private static let enCours = """
    {
      "schemaVersion": 1,
      "id": "demonstration-2026-09-20-a1b2c3d4",
      "title": "Démonstration",
      "source": {
        "kind": "x",
        "url": "https://x.com/i/status/2099881645474029569",
        "identity": "2099881645474029569"
      },
      "duration": 84.0,
      "language": "fr",
      "languageWasForced": true,
      "model": "large-v3-turbo",
      "createdAt": "2026-09-20T10:00:00Z",
      "status": "inProgress",
      "segments": [],
      "coverage": { "coveredSeconds": 0.0, "ratio": 0.0 },
      "boundaries": []
    }
    """

    /// Une source locale : `path` renseigné, `url` absente (critère 3 : le fichier local ne doit
    /// aucun accès réseau, il n'a donc pas d'adresse).
    private static let local = """
    {
      "schemaVersion": 1,
      "id": "cours-2026-09-20-a1b2c3d4",
      "title": "Cours",
      "source": {
        "kind": "file",
        "path": "/Users/louiscourcier/Movies/cours.mp4",
        "identity": "9f2c41b7-12345"
      },
      "duration": 120.0,
      "language": "fr",
      "languageWasForced": false,
      "model": "large-v3-turbo",
      "createdAt": "2026-09-20T10:00:00Z",
      "completedAt": "2026-09-20T10:02:00Z",
      "status": "complete",
      "segments": [],
      "coverage": { "coveredSeconds": 120.0, "ratio": 1.0 },
      "boundaries": []
    }
    """

    /// Toutes les clés du schéma, au premier niveau.
    private static let clesDuDocument: Set<String> = [
        "schemaVersion", "id", "title", "source", "duration", "language", "languageWasForced",
        "model", "createdAt", "completedAt", "status", "segments", "coverage", "boundaries",
    ]

    // MARK: - Fixtures et outils

    /// Décode le fichier avec un décodeur configuré en ISO-8601 — la forme sous laquelle les
    /// fichiers sont écrits et relus par un agent (voir la note du type `TranscriptDocument`).
    ///
    /// Un échec de décodage est rapporté comme un échec d'assertion nommé : au moment où ce
    /// contrat est écrit, les valeurs brutes des énumérations sont des sentinelles, donc ce chemin
    /// d'erreur est celui qu'empruntent tous ces tests.
    private func document(_ json: String) -> TranscriptDocument? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(TranscriptDocument.self, from: Data(json.utf8))
        } catch {
            XCTFail("contrat lot 1 : non implémenté — le fichier gelé ne se décode pas (\(error))")
            return nil
        }
    }

    /// Encode avec la même stratégie ISO-8601, puis relit le JSON sans passer par le type : ce
    /// qui est vérifié ici est le **fichier**, pas la valeur en mémoire.
    private func json(_ document: TranscriptDocument) -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(document)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("contrat lot 1 : non implémenté — le document ne s'encode pas en objet JSON")
                return nil
            }
            return object
        } catch {
            XCTFail("contrat lot 1 : non implémenté — le document ne s'encode pas (\(error))")
            return nil
        }
    }

    private func dictionnaire(_ value: Any?) -> [String: Any]? {
        guard let value = value as? [String: Any] else {
            XCTFail("contrat lot 1 : non implémenté — objet JSON absent ou de mauvaise forme : \(String(describing: value))")
            return nil
        }
        return value
    }

    // MARK: - Le schéma

    /// La version de schéma est **1**, en constant et dans le fichier écrit : c'est elle qui
    /// permettra de relire un fichier d'une version antérieure sans deviner.
    func testLaVersionDeSchemaEstUn() {
        XCTAssertEqual(
            TranscriptDocument.schemaVersion, 1,
            "contrat lot 1 : non implémenté — la version de schéma gelée est 1")

        guard let document = document(Self.complet), let json = json(document) else { return }
        XCTAssertEqual(
            json["schemaVersion"] as? Int, 1,
            "contrat lot 1 : non implémenté — le fichier doit porter schemaVersion 1")
    }

    /// Le fichier gelé se décode champ par champ. C'est le critère 21 lu par l'autre bout :
    /// quelqu'un qui écrit ce JSON (une version antérieure de Murmure, un agent) doit être lu
    /// exactement.
    func testLeFichierFigeSeDecode() throws {
        let document = try XCTUnwrap(self.document(Self.complet), "contrat lot 1 : non implémenté")

        XCTAssertEqual(document.schemaVersion, 1, "contrat lot 1 : non implémenté")
        XCTAssertEqual(document.id, "demonstration-2026-09-20-a1b2c3d4", "contrat lot 1 : non implémenté")
        XCTAssertEqual(document.title, "Démonstration", "contrat lot 1 : non implémenté")
        XCTAssertEqual(document.source.kind, .youtube, "contrat lot 1 : non implémenté")
        XCTAssertEqual(
            document.source.url?.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "contrat lot 1 : non implémenté")
        XCTAssertEqual(document.source.identity, "dQw4w9WgXcQ", "contrat lot 1 : non implémenté")
        XCTAssertEqual(document.duration, 2293.0, "contrat lot 1 : non implémenté")
        XCTAssertEqual(document.language, "fr", "contrat lot 1 : non implémenté")
        XCTAssertFalse(document.languageWasForced, "contrat lot 1 : non implémenté")
        XCTAssertEqual(document.model, "large-v3-turbo", "contrat lot 1 : non implémenté")
        XCTAssertEqual(document.status, .complete, "contrat lot 1 : non implémenté")
        XCTAssertEqual(
            document.completedAt?.timeIntervalSince1970, 1_789_899_150,
            "contrat lot 1 : non implémenté — 2026-09-20T10:12:30Z attendu")
        XCTAssertEqual(document.segments.count, 2, "contrat lot 1 : non implémenté")
        XCTAssertEqual(document.coverage.coveredSeconds, 2276.0, "contrat lot 1 : non implémenté")
        XCTAssertEqual(document.coverage.ratio, 0.9926, "contrat lot 1 : non implémenté")
        XCTAssertEqual(document.boundaries.count, 2, "contrat lot 1 : non implémenté")
    }

    /// Une source locale est décrite par son **chemin** : pas d'adresse, et `kind` dit laquelle
    /// des deux clés lire. C'est le critère 3 côté schéma.
    func testUneSourceLocaleSeDecodeParSonChemin() throws {
        let document = try XCTUnwrap(self.document(Self.local), "contrat lot 1 : non implémenté")

        XCTAssertEqual(document.source.kind, .file, "contrat lot 1 : non implémenté")
        XCTAssertEqual(
            document.source.path, "/Users/louiscourcier/Movies/cours.mp4",
            "contrat lot 1 : non implémenté")
        XCTAssertNil(document.source.url, "contrat lot 1 : non implémenté — une source locale n'a pas d'URL")
        XCTAssertFalse(document.languageWasForced, "contrat lot 1 : non implémenté")
        XCTAssertEqual(document.coverage.ratio, 1.0, "contrat lot 1 : non implémenté")

        // La clé inutilisée n'est pas écrite, comme `completedAt` : une source locale porte
        // `path` et pas `url`, une source distante l'inverse.
        let json = try XCTUnwrap(self.json(document), "contrat lot 1 : non implémenté")
        let source = try XCTUnwrap(dictionnaire(json["source"]), "contrat lot 1 : non implémenté")
        XCTAssertEqual(
            Set(source.keys), ["kind", "path", "identity"],
            "contrat lot 1 : non implémenté — clés d'une source locale : \(Set(source.keys).sorted())")
    }

    /// Un travail interrompu reste lisible : `inProgress`, pas de date d'achèvement, pas encore
    /// de segments. C'est la reprise du plan §2.1 — sans index, un fichier écrit à moitié doit se
    /// lire tout de même.
    func testUnTravailEnCoursSeDecodeSansDateDAchevement() throws {
        let document = try XCTUnwrap(self.document(Self.enCours), "contrat lot 1 : non implémenté")

        XCTAssertEqual(document.status, .inProgress, "contrat lot 1 : non implémenté")
        XCTAssertNil(document.completedAt, "contrat lot 1 : non implémenté")
        XCTAssertEqual(document.source.kind, .x, "contrat lot 1 : non implémenté")
        XCTAssertTrue(document.languageWasForced, "contrat lot 1 : non implémenté")
        XCTAssertEqual(document.segments, [], "contrat lot 1 : non implémenté")
        XCTAssertEqual(document.boundaries, [], "contrat lot 1 : non implémenté")
    }

    /// Le fichier écrit porte exactement les clés du schéma, aux quatre niveaux. Une clé en trop
    /// ou en moins est un changement de schéma, donc une nouvelle `schemaVersion`.
    func testLeFichierEncodeLesClesDuSchemaFige() throws {
        let document = try XCTUnwrap(self.document(Self.complet), "contrat lot 1 : non implémenté")
        let json = try XCTUnwrap(self.json(document), "contrat lot 1 : non implémenté")

        XCTAssertEqual(
            Set(json.keys), Self.clesDuDocument,
            "contrat lot 1 : non implémenté — clés du document : \(Set(json.keys).sorted())")

        let source = try XCTUnwrap(dictionnaire(json["source"]), "contrat lot 1 : non implémenté")
        XCTAssertEqual(
            Set(source.keys), ["kind", "url", "identity"],
            "contrat lot 1 : non implémenté — clés d'une source distante : \(Set(source.keys).sorted())")

        let coverage = try XCTUnwrap(dictionnaire(json["coverage"]), "contrat lot 1 : non implémenté")
        XCTAssertEqual(
            Set(coverage.keys), ["coveredSeconds", "ratio"],
            "contrat lot 1 : non implémenté — clés de la couverture : \(Set(coverage.keys).sorted())")
    }

    /// Les segments sont `{start, end, text}`, dans l'ordre, avec les valeurs numériques : c'est
    /// la structure que le critère 9 (couverture, horodatages croissants) et le survol du critère
    /// 16 lisent.
    func testLesSegmentsOntLaFormeFigee() throws {
        let document = try XCTUnwrap(self.document(Self.complet), "contrat lot 1 : non implémenté")
        let json = try XCTUnwrap(self.json(document), "contrat lot 1 : non implémenté")

        let segments = try XCTUnwrap(json["segments"] as? [[String: Any]], "contrat lot 1 : non implémenté")
        XCTAssertEqual(segments.count, 2, "contrat lot 1 : non implémenté")

        XCTAssertEqual(Set(segments[0].keys), ["start", "end", "text"], "contrat lot 1 : non implémenté")
        XCTAssertEqual(segments[0]["start"] as? Double, 0.0, "contrat lot 1 : non implémenté")
        XCTAssertEqual(segments[0]["end"] as? Double, 2.5, "contrat lot 1 : non implémenté")
        XCTAssertEqual(segments[0]["text"] as? String, "Bonjour", "contrat lot 1 : non implémenté")
        XCTAssertEqual(segments[1]["start"] as? Double, 2.6, "contrat lot 1 : non implémenté")
        XCTAssertEqual(segments[1]["text"] as? String, "tout le monde", "contrat lot 1 : non implémenté")
    }

    /// La couverture est écrite en secondes **et** en proportion : la valeur que la SPEC nomme
    /// (≥ 97 %) ne doit pas être recalculée par chaque lecteur.
    func testLaCouvertureEncodeLesSecondesEtLaProportion() throws {
        let document = try XCTUnwrap(self.document(Self.complet), "contrat lot 1 : non implémenté")
        let json = try XCTUnwrap(self.json(document), "contrat lot 1 : non implémenté")
        let coverage = try XCTUnwrap(dictionnaire(json["coverage"]), "contrat lot 1 : non implémenté")

        XCTAssertEqual(coverage["coveredSeconds"] as? Double, 2276.0, "contrat lot 1 : non implémenté")
        XCTAssertEqual(coverage["ratio"] as? Double, 0.9926, "contrat lot 1 : non implémenté")
    }

    /// Les frontières d'unités gardent leur qualité : une coupe forcée (faute de silence) doit
    /// rester trouvable après coup — c'est la seule trace de la dégradation assumée du plan §2.1.
    func testLesBornesOntLaFormeFigee() throws {
        let document = try XCTUnwrap(self.document(Self.complet), "contrat lot 1 : non implémenté")
        let json = try XCTUnwrap(self.json(document), "contrat lot 1 : non implémenté")

        let bornes = try XCTUnwrap(json["boundaries"] as? [[String: Any]], "contrat lot 1 : non implémenté")
        XCTAssertEqual(bornes.count, 2, "contrat lot 1 : non implémenté")
        XCTAssertEqual(
            Set(bornes[0].keys), ["start", "duration", "quality"],
            "contrat lot 1 : non implémenté")
        XCTAssertEqual(bornes[0]["duration"] as? Double, 300.0, "contrat lot 1 : non implémenté")
        XCTAssertEqual(
            bornes[0]["quality"] as? String, "silence",
            "contrat lot 1 : non implémenté — qualité d'une coupe dans un silence : « silence »")
        XCTAssertEqual(
            bornes[1]["quality"] as? String, "forced",
            "contrat lot 1 : non implémenté — qualité d'une coupe forcée : « forced »")
    }

    /// Les chaînes des énumérations sont le schéma : ce sont elles qu'un agent lira. Elles sont
    /// donc gelées ici, une par une.
    func testLesStatutsEtLesSourcesOntLesChainesFigees() {
        XCTAssertEqual(TranscriptStatus.inProgress.rawValue, "inProgress", "contrat lot 1 : non implémenté")
        XCTAssertEqual(TranscriptStatus.complete.rawValue, "complete", "contrat lot 1 : non implémenté")
        XCTAssertEqual(TranscriptStatus.failed.rawValue, "failed", "contrat lot 1 : non implémenté")
        XCTAssertEqual(TranscriptSourceKind.youtube.rawValue, "youtube", "contrat lot 1 : non implémenté")
        XCTAssertEqual(TranscriptSourceKind.x.rawValue, "x", "contrat lot 1 : non implémenté")
        XCTAssertEqual(TranscriptSourceKind.file.rawValue, "file", "contrat lot 1 : non implémenté")
        XCTAssertEqual(
            TranscriptDocument.Boundary.Quality.silence.rawValue, "silence",
            "contrat lot 1 : non implémenté")
        XCTAssertEqual(
            TranscriptDocument.Boundary.Quality.forced.rawValue, "forced",
            "contrat lot 1 : non implémenté")
    }

    /// Le témoin de reprise : le fichier écrit est **relu** par la même version. C'est ce qui fait
    /// qu'un travail interrompu reprend au lieu d'être reperdu (plan §2.1).
    func testUnDocumentFaitUnAllerRetourComplet() throws {
        let document = try XCTUnwrap(self.document(Self.complet), "contrat lot 1 : non implémenté")
        let json = try XCTUnwrap(self.json(document), "contrat lot 1 : non implémenté")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let encoded = try JSONSerialization.data(withJSONObject: json)
            let relu = try decoder.decode(TranscriptDocument.self, from: encoded)
            XCTAssertEqual(relu, document, "contrat lot 1 : non implémenté — l'aller-retour perd des champs")
        } catch {
            XCTFail("contrat lot 1 : non implémenté — l'aller-retour échoue (\(error))")
        }
    }

    /// Un travail en cours s'écrit **sans** la clé `completedAt` — pas avec un `null`. C'est la
    /// même information, écrite une seule fois, et c'est la forme que les fichiers du plan §2.1
    /// doivent avoir sur disque.
    func testUnTravailEnCoursNAPasDeDateDAchevementDansLeFichier() throws {
        let enCours = try XCTUnwrap(self.document(Self.enCours), "contrat lot 1 : non implémenté")
        let json = try XCTUnwrap(self.json(enCours), "contrat lot 1 : non implémenté")

        XCTAssertEqual(
            Set(json.keys), Self.clesDuDocument.subtracting(["completedAt"]),
            "contrat lot 1 : non implémenté — clés du travail en cours : \(Set(json.keys).sorted())")
        XCTAssertEqual(json["status"] as? String, "inProgress", "contrat lot 1 : non implémenté")
        XCTAssertNotNil(json["segments"] as? [Any], "contrat lot 1 : non implémenté — tableau vide attendu, pas une clé absente")

        let complet = try XCTUnwrap(self.document(Self.complet), "contrat lot 1 : non implémenté")
        let fichierComplet = try XCTUnwrap(self.json(complet), "contrat lot 1 : non implémenté")
        let createdAt = try XCTUnwrap(
            fichierComplet["createdAt"] as? String,
            "contrat lot 1 : non implémenté — les dates sont écrites en ISO-8601, pas en secondes")
        XCTAssertTrue(
            createdAt.hasPrefix("2026-09-20T10:00:00"),
            "contrat lot 1 : non implémenté — createdAt écrit : \(createdAt)")
    }
}
