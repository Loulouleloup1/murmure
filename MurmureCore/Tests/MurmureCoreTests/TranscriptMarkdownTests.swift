import Foundation
import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 1 : le rendu Markdown, la « source de vérité humaine » du transcript
/// (critère 21, plan §2.4).
///
/// Deux choses y sont gelées, et les deux sont des décisions produit prises aux tours 5 et 6 :
/// l'en-tête (titre, puis la source, qu'on peut rouvrir des mois plus tard) et le **découpage en
/// paragraphes aérés** — la lisibilité d'affilée passe devant la navigation ligne à ligne, donc
/// le corps ne porte **aucun horodatage**.
///
/// Tous ces tests échouent sur une **assertion explicite** tant que le corps sentinelle de
/// `TranscriptMarkdown.swift` n'a pas été remplacé.
final class TranscriptMarkdownTests: XCTestCase {
    private let adresse = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    // MARK: - Outils

    private func document(
        titre: String = "Démonstration", url: String? = nil, chemin: String? = nil,
        segments: [(start: Double, end: Double, text: String)]
    ) -> TranscriptDocument {
        // Une source distante porte son adresse, une source locale son chemin : c'est la même
        // distinction que `TranscriptSource` (lot 1) et le critère 3.
        let source =
            url.map {
                TranscriptSource(
                    kind: .youtube, url: URL(string: $0), path: nil, identity: "dQw4w9WgXcQ")
            }
            ?? TranscriptSource(kind: .file, url: nil, path: chemin, identity: "dQw4w9WgXcQ")

        return TranscriptDocument(
            id: "demonstration-2026-09-20-a1b2c3d4",
            title: titre,
            source: source,
            duration: 2293.0,
            language: "fr",
            languageWasForced: false,
            model: "large-v3-turbo",
            createdAt: Date(timeIntervalSince1970: 1_789_898_400),
            completedAt: nil,
            status: .inProgress,
            segments: segments.map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text) },
            coverage: TranscriptDocument.Coverage(coveredSeconds: 0, ratio: 0),
            boundaries: [])
    }

    /// Les paragraphes du corps : tout ce qui suit l'en-tête, découpé sur les **lignes vides**.
    ///
    /// Les lignes d'en-tête sont retirées par leur contenu (titre, ligne de source) plutôt que
    /// par leur rang : la seule obligation du contrat est « le titre, puis la ligne de source,
    /// puis des paragraphes », pas une ponctuation exacte de l'en-tête — les deux assertions qui
    /// portent sur l'en-tête lui-même sont dans ``testLEnTeteEstLeTitrePuisLaSource``.
    ///
    /// Un retour à la ligne **à l'intérieur** d'un paragraphe est replié en espace : le contrat
    /// porte sur le texte et sur les frontières de paragraphe, pas sur un éventuel repli
    /// typographique.
    private func corps(_ rendu: String, source: String) -> [String] {
        var lignes = rendu.components(separatedBy: "\n")
        while let premiere = lignes.first {
            let nue = premiere.trimmingCharacters(in: .whitespaces)
            guard
                nue.isEmpty || premiere.hasPrefix("#") || premiere.lowercased().hasPrefix("source")
                    || premiere.contains(source)
            else { break }
            lignes.removeFirst()
        }
        return lignes.joined(separator: "\n")
            .components(separatedBy: "\n\n")
            .map {
                $0.replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    // MARK: - L'en-tête

    /// Le titre écrit **tel quel** (pas le slug du nom de fichier), puis la ligne de source, qui
    /// porte l'adresse : c'est elle qui permet de rouvrir la vidéo, et c'est à ce clic que le
    /// critère 16 renvoie.
    func testLEnTeteEstLeTitrePuisLaSource() {
        let rendu = TranscriptMarkdown.render(
            document(url: adresse, segments: [(0, 2.5, "Bonjour")]))

        let lignes = rendu.components(separatedBy: "\n")
        XCTAssertEqual(
            lignes.first, "# Démonstration",
            "contrat lot 1 : non implémenté — première ligne obtenue : « \(lignes.first ?? "") »")
        XCTAssertTrue(
            lignes.count > 1 && lignes[1].contains(adresse),
            "contrat lot 1 : non implémenté — deuxième ligne obtenue : « \(lignes.count > 1 ? lignes[1] : "absente") »")
        XCTAssertTrue(
            rendu.hasSuffix("\n"),
            "contrat lot 1 : non implémenté — un fichier texte se termine par un retour à la ligne")
    }

    /// Pour un fichier local, l'adresse n'existe pas : c'est le **chemin** qui dit d'où vient le
    /// transcript.
    func testUneSourceLocaleEcritSonChemin() {
        let rendu = TranscriptMarkdown.render(
            document(chemin: "/Users/louiscourcier/Movies/cours.mp4", segments: [(0, 2.5, "Bonjour")]))

        let lignes = rendu.components(separatedBy: "\n")
        XCTAssertTrue(
            lignes.count > 1 && lignes[1].contains("/Users/louiscourcier/Movies/cours.mp4"),
            "contrat lot 1 : non implémenté — deuxième ligne obtenue : « \(lignes.count > 1 ? lignes[1] : "absente") »")
    }

    // MARK: - Les paragraphes

    /// Le cas nominal : trois segments qui se suivent, séparés par des pauses bien plus courtes
    /// que le seuil, forment **un seul** paragraphe, leurs textes joints par une espace.
    func testLesSegmentsConsecutifsFormentUnParagraphe() {
        let rendu = TranscriptMarkdown.render(
            document(
                url: adresse,
                segments: [(0, 2.5, "Bonjour"), (2.6, 5.0, "tout le monde"), (5.1, 7.0, "comment ça va")]))

        XCTAssertEqual(
            corps(rendu, source: adresse), ["Bonjour tout le monde comment ça va"],
            "contrat lot 1 : non implémenté — corps obtenu : « \(corps(rendu, source: adresse)) »")
    }

    /// Une pause d'au moins 1,2 s coupe le paragraphe : c'est là que l'orateur a repris son
    /// souffle, et c'est ce que « paragraphes aérés » veut dire.
    func testUnePauseCoupeLeParagraphe() {
        let rendu = TranscriptMarkdown.render(
            document(
                url: adresse,
                segments: [(0, 2.0, "Un"), (2.1, 4.0, "deux"), (6.0, 8.0, "Trois")]))

        XCTAssertEqual(
            corps(rendu, source: adresse), ["Un deux", "Trois"],
            "contrat lot 1 : non implémenté — corps obtenu : « \(corps(rendu, source: adresse)) »")
    }

    /// Le seuil est **1,2 s**, mesuré de la fin d'un segment au début du suivant : juste en dessous
    /// on fusionne, juste au-dessus on coupe. Les deux cas sont éprouvés dans le même test, sinon
    /// un seuil nul ferait passer le cas « on coupe » sans rien prouver.
    func testLeSeuilDePauseEstDeDouzeDixiemesDeSeconde() {
        let serre = TranscriptMarkdown.render(
            document(url: adresse, segments: [(0, 3.0, "Un"), (4.19, 6.0, "deux")]))
        let large = TranscriptMarkdown.render(
            document(url: adresse, segments: [(0, 3.0, "Un"), (4.21, 6.0, "deux")]))

        XCTAssertEqual(
            corps(serre, source: adresse), ["Un deux"],
            "contrat lot 1 : non implémenté — 1,19 s de pause doit fusionner : « \(corps(serre, source: adresse)) »")
        XCTAssertEqual(
            corps(large, source: adresse), ["Un", "deux"],
            "contrat lot 1 : non implémenté — 1,21 s de pause doit couper : « \(corps(large, source: adresse)) »")
    }

    /// Le second seuil, **480 caractères** : sans lui, une vidéo de 38 minutes sans vraie pause
    /// donnerait un unique pavé. Le plafond est vérifié sur un paragraphe long, et le contrôle
    /// qui compte est le dernier — **aucun texte n'est perdu ni réordonné** par le découpage.
    func testUnParagrapheNeDepasseJamais480Caracteres() {
        let segments = (0..<200).map { index in
            (start: Double(index) * 17, end: Double(index) * 17 + 16,
             text: String(repeating: "a", count: 12) + String(format: "%04d", index))
        }
        let rendu = TranscriptMarkdown.render(document(url: adresse, segments: segments))
        let paragraphes = corps(rendu, source: adresse)

        XCTAssertGreaterThanOrEqual(
            paragraphes.count, 2,
            "contrat lot 1 : non implémenté — 200 segments consécutifs doivent se découper")
        for paragraphe in paragraphes {
            XCTAssertLessThanOrEqual(
                paragraphe.count, 480,
                "contrat lot 1 : non implémenté — paragraphe de \(paragraphe.count) caractères : « \(paragraphe.prefix(40))… »")
        }
        // Deux assertions courtes plutôt qu'une comparaison de 3 400 caractères : la première dit
        // la quantité perdue, la seconde attrape le réordonnancement, et les deux restent
        // lisibles dans le journal de la gate.
        let attendu = segments.map { $0.text }.joined(separator: " ")
        let obtenu = paragraphes.joined(separator: " ")
        XCTAssertEqual(
            obtenu.count, attendu.count,
            "contrat lot 1 : non implémenté — \(obtenu.count) caractères rendus pour \(attendu.count) attendus")
        XCTAssertEqual(
            obtenu, attendu,
            "contrat lot 1 : non implémenté — texte rendu : « \(obtenu.prefix(60))… »")
    }

    /// **Aucun horodatage dans le corps** (tour 5). L'assertion porte sur le texte attendu *et*
    /// sur l'absence de motif horaire : les deux ensemble, parce qu'une absence constatée sur un
    /// corps vide ne prouve rien.
    func testLeCorpsNePorteAucunHorodatage() {
        let rendu = TranscriptMarkdown.render(
            document(
                url: adresse,
                segments: [(0, 2.5, "Bonjour"), (2.6, 5.0, "tout le monde"), (12.5, 15.0, "Trois")]))

        XCTAssertEqual(
            corps(rendu, source: adresse), ["Bonjour tout le monde", "Trois"],
            "contrat lot 1 : non implémenté — corps obtenu : « \(corps(rendu, source: adresse)) »")
        XCTAssertNil(
            rendu.range(of: #"\d{1,3}:\d{2}"#, options: .regularExpression),
            "contrat lot 1 : non implémenté — un horodatage apparaît dans le Markdown")
    }

    /// Un document sans segment — un travail en cours écrit avant sa première unité, ou un travail
    /// en échec — rend quand même son en-tête : le fichier doit être lisible à tout moment.
    func testUnDocumentSansSegmentRendQuandMemeSonEnTete() {
        let rendu = TranscriptMarkdown.render(document(url: adresse, segments: []))

        XCTAssertTrue(
            rendu.hasPrefix("# Démonstration\n"),
            "contrat lot 1 : non implémenté — rendu obtenu : « \(rendu.prefix(40)) »")
        XCTAssertEqual(
            corps(rendu, source: adresse), [],
            "contrat lot 1 : non implémenté — aucun segment, aucun paragraphe")
    }
}
