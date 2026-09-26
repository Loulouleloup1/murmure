import XCTest

@testable import MurmureCore

/// Contrat rouge du lot **10-O2** : **un dépôt de plusieurs fichiers les met tous en file** —
/// aucun n'est ignoré en silence (critère 19 de la SPEC, amendé le 22/09/2026 ; décision **O2**
/// adoptée par Louis le 22/09/2026 ; plan §4 lot 10-O2, §7.1 règles 1 à 5 et 11).
///
/// **Le défaut que ces cas rendent impossible.** Le dépôt de la fenêtre lit aujourd'hui
/// `guard windowController.section == .transcripts, let url = urls.first` (`Murmure/MurmureApp.swift`,
/// l.415-416) : trois fichiers lâchés sur la fenêtre en mettent **un** en file, le geste rend `true`,
/// et les deux autres disparaissent **sans un mot**. Ces cas gèlent la fonction qui remplace ce
/// `urls.first` — ``TranscriptDrop/sources(for:)`` —, c'est-à-dire le **nombre** d'entrées qu'un
/// dépôt produit et leur **ordre**. La file, elle, sait déjà traiter plusieurs éléments dans l'ordre
/// (critère 19, contrat `TranscriptQueueTests` du lot 10) : ce qui manquait est exactement ce qui est
/// mesuré ici.
///
/// **Ce que ces cas observent, et ce qu'ils ne peuvent pas dire.** Ils observent une fonction pure,
/// sur des URLs qui **n'existent pas sur le disque** : `URL(fileURLWithPath:)` ne lit rien, aucune
/// fixture n'est créée, aucun fichier réel n'est touché (AGENTS.md : jamais de données réelles, et
/// rien à nettoyer). Ce qu'ils ne peuvent pas dire : (i) le **geste** — trois fichiers lâchés sur la
/// fenêtre, puis trois lignes dans le menu — n'est pas simulable ici (gate humaine du plan §6
/// risque 9) ; (ii) le fait que la cible de dépôt **appelle** cette fonction et remet ses entrées à
/// la file se lit dans `MurmureApp.swift` (une seule `Task`, une boucle ordonnée d'ajouts, un seul
/// `drain()`) — `Murmure/` n'a pas de bundle de tests, c'est `scripts/checks/drop-multiple-files.sh`
/// qui le contrôle, par lecture de source.
///
/// **Deux cas sont négatifs par nature** — ``testAucuneUrlNeDonneAucuneEntree`` (aucune URL, aucune
/// entrée) et le premier tour de ``testLeNombreDEtreesEstToujoursCeluiDesUrls`` (N = 0), que la
/// sentinelle `[]` satisferait **sans qu'une ligne de la règle existe**. Le premier porte donc, dans
/// **le même** cas, un **contrôle positif** qui exerce la fonction sur une entrée ; le second est
/// couvert par les cinq tours suivants de la même boucle. Un cas négatif seul serait un vert
/// d'avance, et un vert qui ne mesure rien est pire qu'un rouge.
///
/// **Tous les cas qui peuvent rougir rougissent sur une assertion explicite** tant que le corps
/// sentinelle de `TranscriptDrop.swift` n'a pas été remplacé : jamais sur une erreur de compilation,
/// jamais par un `skip`, jamais par un `expectedFailure` (§7.1 règles 2 à 4). Le message porte
/// toujours « contrat L10-O2 : non implémenté ».
final class TranscriptDropTests: XCTestCase {

    /// Ce que porte chaque assertion rouge d'aujourd'hui.
    private let contrat = "contrat L10-O2 : non implémenté"

    // MARK: - Le nombre d'entrées et leur ordre (critère 19)

    /// **Le cas obligatoire (a) de la carte.** Trois fichiers déposés font trois entrées, dans
    /// l'ordre du dépôt : c'est le défaut constaté, mot pour mot.
    func testTroisFichiersDonnentTroisEntreesDansLOrdre() {
        let a = URL(fileURLWithPath: "/tmp/l10o2/a.mp4")
        let b = URL(fileURLWithPath: "/tmp/l10o2/b.mp4")
        let c = URL(fileURLWithPath: "/tmp/l10o2/c.mov")

        let rendues = TranscriptDrop.sources(for: [a, b, c])

        XCTAssertEqual(
            rendues.count, 3,
            "trois fichiers déposés font trois entrées — \(contrat)")
        XCTAssertEqual(
            rendues, [a.path, b.path, c.path],
            "les trois chemins, dans l'ordre du dépôt — \(contrat)")
    }

    /// **Le cas obligatoire (b) de la carte.** Un lien au milieu de deux fichiers : trois entrées,
    /// dans l'ordre, les chemins décodés et le lien **tel quel** (`absoluteString`, la forme
    /// `file://` n'atteint jamais la file).
    func testUnLienEtDesFichiersGardentLeurOrdreEtLeurForme() {
        let avant = URL(fileURLWithPath: "/tmp/l10o2/avant le lien.mp4")
        let lien = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let apres = URL(fileURLWithPath: "/tmp/l10o2/apres le lien.mov")

        let rendues = TranscriptDrop.sources(for: [avant, lien, apres])

        XCTAssertEqual(
            rendues.count, 3,
            "un lien et deux fichiers font trois entrées — \(contrat)")
        XCTAssertEqual(
            rendues, [avant.path, lien.absoluteString, apres.path],
            "l'ordre du dépôt est gardé, le chemin est décodé et le lien reste tel quel — \(contrat)")
        XCTAssertEqual(
            rendues.first, avant.path,
            "la première entrée est celle qui a été déposée en premier — \(contrat)")
    }

    /// **Le cas obligatoire (c) de la carte.** Le cas d'aujourd'hui ne change pas : une seule URL
    /// déposée fait **une** entrée — un fichier comme un lien.
    func testUneSeuleUrlDonneUneSeuleEntree() {
        let fichier = URL(fileURLWithPath: "/tmp/l10o2/seul.mp4")
        let lien = URL(string: "https://x.com/un/status/1")!

        XCTAssertEqual(
            TranscriptDrop.sources(for: [fichier]), [fichier.path],
            "un seul fichier déposé fait une seule entrée, son chemin — \(contrat)")
        XCTAssertEqual(
            TranscriptDrop.sources(for: [lien]), [lien.absoluteString],
            "un seul lien déposé fait une seule entrée, le lien tel quel — \(contrat)")
    }

    /// **Le cas obligatoire (d) de la carte.** Aucune URL déposée, aucune entrée : la règle
    /// `count == urls.count` appliquée à zéro élément.
    ///
    /// Contrôle positif, obligatoire ici (voir l'en-tête) : une sentinelle qui rend `[]` dans tous
    /// les cas satisfait l'assertion d'ensemble vide et **échoue** à celle-ci, qui exerce la
    /// fonction sur une entrée réelle.
    func testAucuneUrlNeDonneAucuneEntree() {
        XCTAssertEqual(
            TranscriptDrop.sources(for: []), [],
            "aucune URL déposée, aucune entrée — \(contrat)")

        let temoin = URL(fileURLWithPath: "/tmp/l10o2/temoin.mp4")
        XCTAssertEqual(
            TranscriptDrop.sources(for: [temoin]), [temoin.path],
            "la même fonction, sur une entrée, ne rend pas la valeur de la sentinelle — \(contrat)")
    }

    /// **Le cas obligatoire (e) de la carte.** Deux fois la même URL font deux entrées : aucun
    /// élément n'est écarté « parce qu'il est déjà là ». Deux dépôts du même fichier sont deux
    /// gestes, la file les traite séquentiellement (critère 19), et le dépôt n'a pas à décider à la
    /// place de la personne.
    func testUnDoublonNEstPasFusionne() {
        let lien = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let fichier = URL(fileURLWithPath: "/tmp/l10o2/double.mp4")

        let liens = TranscriptDrop.sources(for: [lien, lien])
        let fichiers = TranscriptDrop.sources(for: [fichier, fichier])

        XCTAssertEqual(
            liens.count, 2,
            "le même lien deux fois fait deux entrées — \(contrat)")
        XCTAssertEqual(
            liens, [lien.absoluteString, lien.absoluteString],
            "et les deux entrées sont la même forme, dans l'ordre — \(contrat)")
        XCTAssertEqual(
            fichiers.count, 2,
            "le même fichier deux fois fait deux entrées — \(contrat)")
        XCTAssertEqual(
            fichiers, [fichier.path, fichier.path],
            "et les deux entrées sont le même chemin — \(contrat)")
    }

    /// **Le cas obligatoire (f) de la carte.** Un chemin avec espaces et accents est rendu
    /// **décodé**, tel que `URL.path` le rend : c'est la forme que `transcribe(_:)` reçoit, celle
    /// qu'une personne aurait collée, et non la forme pourcent-encodée d'une `absoluteString`.
    func testUnCheminAvecEspacesEtAccentsEstRenduDecode() {
        let chemin = "/tmp/l10o2/café des transcriptions/vidéo d'été, épisode 2.mov"
        let url = URL(fileURLWithPath: chemin)

        let rendues = TranscriptDrop.sources(for: [url])

        XCTAssertEqual(
            rendues, [url.path],
            "le chemin est rendu tel que URL.path le rend — \(contrat)")
        XCTAssertEqual(
            rendues.first, chemin,
            "les espaces et les accents ne sont pas encodés dans l'entrée — \(contrat)")
    }

    /// **Le cas obligatoire (g) de la carte — la garde de classe.** Pour N = 0 à 5 URLs distinctes,
    /// `sources(for:).count == N` : c'est **exactement** ce que `urls.first` interdit, sur toutes
    /// les tailles de dépôt. Un seul fichier, deux, trois (le défaut constaté), quatre, cinq — le
    /// nombre d'entrées est celui des URLs, jamais un.
    func testLeNombreDEtreesEstToujoursCeluiDesUrls() {
        // Cinq URLs distinctes, plus une sixième jamais atteinte : les tours de la boucle les
        // ajoutent une par une, donc chaque N mesure une taille de dépôt différente.
        let reserve: [URL] = [
            URL(fileURLWithPath: "/tmp/l10o2/1-a.mp4"),
            URL(fileURLWithPath: "/tmp/l10o2/2-b.mp4"),
            URL(fileURLWithPath: "/tmp/l10o2/3-c.mov"),
            URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!,
            URL(fileURLWithPath: "/tmp/l10o2/4-d.m4a"),
            URL(string: "https://x.com/un/status/1")!,
        ]
        var deposees: [URL] = []
        var taillesMesurees: [Int] = []

        for n in 0...5 {
            let rendues = TranscriptDrop.sources(for: deposees)
            XCTAssertEqual(
                rendues.count, n,
                "N = \(n) : le dépôt fait N entrées, jamais moins — \(contrat)")
            XCTAssertEqual(
                rendues.count, deposees.count,
                "N = \(n) : le nombre d'entrées est celui des URLs déposées — \(contrat)")
            taillesMesurees.append(deposees.count)
            if n < reserve.count { deposees.append(reserve[n]) }
        }

        XCTAssertEqual(
            taillesMesurees, [0, 1, 2, 3, 4, 5],
            "la boucle mesure bien les six tailles de dépôt, de 0 à 5 URLs distinctes — \(contrat)")
    }
}
