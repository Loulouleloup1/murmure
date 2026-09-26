import SwiftUI
import XCTest

@testable import MurmureCore

/// Contrat rouge du lot **10-O1** : **la pastille de barre de menu a deux états distincts** —
/// l'un pendant le travail, l'autre une fois qu'il est fini (critère 18 de la SPEC ; décision **O1**
/// adoptée par Louis le 22/09/2026 ; plan §4 lot 10-O1, §7.1 règles 1 à 5).
///
/// **Le défaut que ces tests rendent impossible.** Aujourd'hui la pastille du `MenuBarExtra` est un
/// point plein conditionné par `transcriptsModel.isWorking` (`MurmureApp.swift`, l.371-381) : une
/// **seule** forme pour tous les états non vides, donc « en cours » et « fini » se ressemblent, et
/// une fois le travail terminé la barre de menu revient au repos. Ces cas-ci gèlent la règle qui
/// remplace ce comportement (``TranscriptBadge/state(of:)``), les deux formes gelées
/// (``TranscriptBadgeState/symbol``, ``TranscriptBadgeState/pointSize``) et le fait qu'elles sont
/// **distinctes** — c'est-à-dire ce que le critère 18 demande et ce qu'aucune revue de code ne peut
/// garantir à la place d'une mesure.
///
/// **Ce que ces tests observent, et ce qu'ils ne peuvent pas dire.** Deux niveaux, et le second est
/// ajouté exprès : (1) la règle, en valeurs, sur la file d'attente réelle du lot 10 ; (2) le
/// **dessin** — `TranscriptBadgeLabel`, le composant que l'application appelle, rastérisé hors écran
/// par `ImageRenderer`. C'est ce second niveau qui prouve « deux états distincts » : deux glyphes
/// différents peuvent encore produire la même image, et une comparaison d'octets le voit. Ce que ces
/// tests **ne peuvent pas** dire : la barre de menu elle-même n'est observée par aucune capture
/// d'écran (aucune sonde de ce chantier ne la voit) ; l'observation à l'œil — point pendant le
/// travail, coche après la fin, rien au repos — reste la **gate humaine** du plan §6 risque 9.
///
/// **Comment le dessin est mesuré, et le piège qui l'a imposé.** Une vue qui ne dessine rien ne rend
/// pas une image vide : `ImageRenderer` rend alors **l'image du dernier rendu non vide du
/// processus** — mesuré le 22/09/2026 sur un `.idle` fidèle, qui se lisait comme le glyphe resté à
/// l'écran (revue round 1, F1 ; `Color.clear`, `EmptyView`, `Image().opacity(0)` et `ZStack {}`
/// tombent tous dans le même piège). La vacuité du repos n'est donc **pas** mesurable en comptant
/// les pixels d'un rendu vide : chaque état est rastérisé **sur un canevas opaque**, et ce que la
/// pastille dessine se lit comme l'écart entre « le canevas plus la pastille » et « le canevas
/// seul ». Le canevas, lui, se dessine toujours, donc sa référence est toujours fraîche, et la
/// mesure ne dépend ni de l'ordre des cas ni de l'historique du processus (voir
/// ``pixelsDessinesPar(_:)``).
///
/// **Tous les cas échouent sur une assertion explicite** tant que les corps sentinelles de
/// `TranscriptBadge.swift` n'ont pas été remplacés : jamais sur une erreur de compilation, jamais
/// par un `skip`, jamais par un `expectedFailure` (§7.1 règles 2 à 4). Le message porte toujours
/// « contrat L10-O1 : non implémenté ».
///
/// **Trois cas sont négatifs par nature** (``testUneFileSansTravailEstAuRepos`` le repos,
/// ``testUnEchecNEstPasUnTravailFini`` l'échec seul, ``testLEtatDeReposNeDessineRien`` le silence du
/// dessin), et une sentinelle qui rend toujours `.idle` ou ne dessine rien les satisferait **sans
/// qu'une ligne de la règle existe**. Chacun porte donc, dans **le même** cas, un **contrôle positif**
/// qui exerce la règle ou le dessin sur une autre entrée : c'est ce contrôle qui rougit aujourd'hui —
/// un cas négatif seul serait un vert d'avance, et un vert qui ne mesure rien est pire qu'un rouge.
///
/// Aucune image de référence n'est chargée depuis le disque : la comparaison des deux états est
/// **interne au run**, sur le même canevas, dans le même processus.
@MainActor
final class TranscriptBadgeTests: XCTestCase {

    /// Ce que porte chaque assertion rouge d'aujourd'hui.
    private let contrat = "contrat L10-O1 : non implémenté"

    // MARK: - La règle, en valeurs (critère 18)

    /// **Le cas obligatoire (a) de la carte.** Une file vide est au repos : la barre de menu ne
    /// porte que l'icône de Murmure.
    ///
    /// Contrôle positif (obligatoire ici, voir l'en-tête) : la même règle ne peut pas rendre le
    /// **même** état pour une file vide et pour une file qui vient de finir — c'est exactement la
    /// confusion que la décision O1 lève. Une sentinelle qui rend `.idle` dans tous les cas satisfait
    /// la première assertion et **échoue** à celle-ci.
    func testUneFileSansTravailEstAuRepos() {
        XCTAssertEqual(
            TranscriptBadge.state(of: []), .idle,
            "une file vide est au repos — \(contrat)")
        XCTAssertNotEqual(
            TranscriptBadge.state(of: [entree(.done)]), .idle,
            "une file sans travail et une file qui vient de finir ne sont pas le même état — \(contrat)"
        )
    }

    /// **Le cas obligatoire (b) de la carte.** Un élément en attente est du travail en cours : la
    /// pastille marque le travail, pas son démarrage.
    func testUnElementEnAttenteEstUnTravailEnCours() {
        XCTAssertEqual(
            TranscriptBadge.state(of: [entree(.waiting)]), .working,
            "un élément qui attend est du travail en cours — \(contrat)")
    }

    /// **Le cas obligatoire (c) de la carte.** Un élément en cours de traitement aussi.
    func testUnElementEnCoursEstUnTravailEnCours() {
        XCTAssertEqual(
            TranscriptBadge.state(of: [entree(.running)]), .working,
            "un élément en cours est du travail en cours — \(contrat)")
    }

    /// **Le cas obligatoire (d) de la carte.** Un travail fini, sans rien en cours, est un travail
    /// fini : c'est l'état que le lot 10 ne savait pas montrer.
    func testUnTravailFiniSansRienEnCoursEstUnTravailFini() {
        XCTAssertEqual(
            TranscriptBadge.state(of: [entree(.done)]), .finished,
            "un travail fini et rien en cours, c'est un travail fini — \(contrat)")
    }

    /// **Le cas obligatoire (e) de la carte.** Un nouveau travail reprend la main sur un travail
    /// fini : la marque de fin ne masque pas l'activité en cours (l'ordre des clauses de la règle).
    func testUnNouveauTravailReprendLaMainSurUnTravailFini() {
        XCTAssertEqual(
            TranscriptBadge.state(of: [entree(.done, "fini"), entree(.waiting, "suivant")]), .working,
            "un travail en attente reprend la main sur un travail fini — \(contrat)")
    }

    /// **Le cas obligatoire (f) de la carte.** Un échec n'est pas un travail fini : un `failed` seul
    /// laisse la barre de menu au repos, parce qu'aucun transcript n'existe sur disque (critère 14).
    ///
    /// Contrôle positif (obligatoire ici) : un échec ne masque pas non plus un travail en cours —
    /// conséquence directe de la règle gelée (`waiting` ou `running` → `.working`), et c'est ce qui
    /// rougit aujourd'hui.
    func testUnEchecNEstPasUnTravailFini() {
        XCTAssertEqual(
            TranscriptBadge.state(of: [entree(.failed)]), .idle,
            "un échec seul n'est pas un travail fini — \(contrat)")
        XCTAssertEqual(
            TranscriptBadge.state(of: [entree(.failed, "cassee"), entree(.running, "en-cours")]),
            .working,
            "un échec ne masque pas le travail en cours — \(contrat)")
    }

    /// **Le cas obligatoire (g) de la carte.** Un travail fini reste fini si un autre a échoué :
    /// l'échec d'un second travail ne retire pas la marque d'un transcript qui existe.
    func testUnTravailFiniResteFiniSiUnAutreAEchoue() {
        XCTAssertEqual(
            TranscriptBadge.state(of: [entree(.done, "fini"), entree(.failed, "cassee")]), .finished,
            "un échec ne retire pas la marque d'un travail fini — \(contrat)")
    }

    // MARK: - Les deux formes gelées (critère 18)

    /// **Le cas obligatoire (h) de la carte.** Les deux états non vides ont des symboles
    /// **distincts**, et les tailles du lot 10 sont conservées : `.working` garde le point plein de
    /// 6 pt (`circle.fill`), `.finished` porte la coche de 8 pt (`checkmark`), `.idle` ne porte rien.
    ///
    /// C'est le cœur du critère 18 en valeurs : deux symboles qui seraient égaux, ou deux tailles
    /// égales pour un même symbole, rendraient deux états indiscernables — et la distinction est de
    /// **forme**, jamais de couleur (aucune mesure de ce chantier ne voit la teinte d'un item de
    /// barre de menu).
    func testLesDeuxEtatsOntDesSymbolesDistincts() {
        XCTAssertNil(
            TranscriptBadgeState.idle.symbol,
            "le repos ne porte aucun symbole — \(contrat)")
        XCTAssertEqual(
            TranscriptBadgeState.working.symbol, "circle.fill",
            "le travail en cours garde le point plein du lot 10 — \(contrat)")
        XCTAssertEqual(
            TranscriptBadgeState.finished.symbol, "checkmark",
            "la fin a sa propre forme — \(contrat)")

        // Comparés par `if let` plutôt que par indice : une sentinelle à `nil` ne doit pas faire
        // tomber tout le binaire de tests (un indice hors bornes masquerait tous les autres
        // résultats).
        if let enCours = TranscriptBadgeState.working.symbol,
            let fini = TranscriptBadgeState.finished.symbol
        {
            XCTAssertNotEqual(
                enCours, fini,
                "les deux états non vides ne peuvent pas partager un glyphe — \(contrat)")
        } else {
            XCTFail("les deux états non vides portent chacun un symbole — \(contrat)")
        }

        XCTAssertEqual(
            TranscriptBadgeState.working.pointSize, 6,
            "le point du travail en cours garde sa taille de 6 pt — \(contrat)")
        XCTAssertEqual(
            TranscriptBadgeState.finished.pointSize, 8,
            "la coche de la fin a sa propre taille, 8 pt — \(contrat)")
    }

    // MARK: - Le dessin, rastérisé hors écran (critère 18)

    /// **Le cas obligatoire (i) de la carte.** Au repos, `TranscriptBadgeLabel` ne dessine **rien** :
    /// posée sur un canevas opaque, elle n'y ajoute **aucun** pixel — pas un glyphe vide, pas un
    /// espace réservé.
    ///
    /// Contrôle positif (obligatoire ici) : **la même sonde** appliquée à `.working` trouve au moins
    /// un pixel dessiné. Sans lui, une sonde qui ne verrait jamais rien — ou une vue sentinelle qui ne
    /// dessine rien — rendrait ce cas vert sans qu'un seul état soit dessiné.
    ///
    /// Les deux mesures sont **ordonnées exprès** : le contrôle positif passe en premier, donc le
    /// repos est mesuré juste après un rendu non vide — exactement les conditions dans lesquelles un
    /// comptage de pixels d'un rendu vide lisait l'image du rendu précédent (revue round 1, F1, voir
    /// ``pixelsDessinesPar(_:)``). Un repos mesuré en premier ne prouverait pas cela.
    func testLEtatDeReposNeDessineRien() throws {
        let travail = try XCTUnwrap(
            pixelsDessinesPar(.working),
            "la sonde doit rendre un canevas mesurable — \(contrat)")
        XCTAssertGreaterThanOrEqual(
            travail, 1,
            "la même sonde doit voir le travail en cours se dessiner — \(contrat)")

        let repos = try XCTUnwrap(
            pixelsDessinesPar(.idle),
            "la sonde doit rendre un canevas mesurable — \(contrat)")
        XCTAssertEqual(
            repos, 0,
            "au repos, la pastille n'ajoute aucun pixel au canevas — \(contrat)")
    }

    /// **Le cas obligatoire (j) de la carte, et le seul qui prouve « deux états distincts ».**
    /// Les rastérisations de `.working` et `.finished`, sur le **même canevas** (un cadre fixe est
    /// imposé aux deux), ont chacune au moins un pixel opaque **et diffèrent**.
    ///
    /// La comparaison porte sur les **octets** rendus, pas sur les symboles : deux états dont les
    /// symboles diffèrent peuvent encore rendre la même image (même taille, même dessin), et ce test
    /// est le seul endroit du chantier où cela se voie. Aucune image de référence n'est chargée : les
    /// deux rendus viennent du même run.
    func testLesDeuxEtatsDessinentEtDifferent() {
        let enCours = rasteriser(.working)
        let fini = rasteriser(.finished)

        XCTAssertGreaterThanOrEqual(
            enCours.pixelsOpaques, 1,
            "le travail en cours se dessine — \(contrat)")
        XCTAssertGreaterThanOrEqual(
            fini.pixelsOpaques, 1,
            "la fin se dessine — \(contrat)")

        // Les images doivent avoir la même taille pour qu'une comparaison d'octets veuille dire
        // quelque chose : c'est le canevas fixe qui le garantit, et le vérifier rend explicite
        // qu'un écart de taille serait signalé ici plutôt que comparé à l'aveugle.
        XCTAssertEqual(
            enCours.octets.count, fini.octets.count,
            "les deux états sont rastérisés sur le même canevas — \(contrat)")
        // Comparaison des octets par un booléen, jamais par `XCTAssertNotEqual` sur les tableaux :
        // l'échec afficherait alors 2 304 octets et noierait les autres assertions du run.
        let mêmesOctets = enCours.octets == fini.octets
        XCTAssertFalse(
            mêmesOctets,
            "les deux états ne peuvent pas rendre la même image (\(enCours.pixelsOpaques) et \(fini.pixelsOpaques) pixels opaques) — \(contrat)"
        )
    }

    // MARK: - Fixtures et sonde

    /// Un élément de file, réduit à ce que la règle lit : son état. L'identité et la source sont
    /// renseignées pour que l'élément soit valide, jamais pour porter la règle.
    private func entree(_ etat: TranscriptQueueState, _ nom: String = "element") -> TranscriptQueueEntry {
        TranscriptQueueEntry(id: nom, source: "https://exemple.test/\(nom)", state: etat)
    }

    /// Ce qu'une rastérisation rend : le nombre de pixels opaques et les octets RGBA prémultipliés
    /// (l'octet de poids fort de chaque pixel est donc son canal alpha).
    private struct Rasterisation {
        let pixelsOpaques: Int
        let octets: [UInt8]
    }

    /// Le canevas imposé à tous les rendus comparés entre eux : un cadre fixe, sans quoi deux rendus
    /// de tailles différentes ne seraient pas comparables.
    private static let canevas = CGSize(width: 24, height: 24)

    /// Le fond de la sonde de vacuité : une teinte qui ne peut se confondre ni avec le noir ni avec
    /// le blanc — donc avec aucun `Color.primary`, quelle que soit l'apparence du processus — et
    /// pleinement opaque, pour que le rendu du canevas soit **toujours** un rendu à dessiner.
    private static let fondDuCanevas = Color(red: 0.40, green: 0.65, blue: 0.35)

    /// Rastérise `TranscriptBadgeLabel` **seul**, hors écran, sur le canevas fixe, en RGBA
    /// prémultiplié.
    ///
    /// Une vue qui ne dessine rien du tout rend une image nulle ; elle est rapportée comme **zéro
    /// pixel opaque**. Cette forme ne sert qu'aux états qui **dessinent** (cas j) : pour le repos,
    /// c'est ``pixelsDessinesPar(_:)`` qui mesure, pour la raison qui y est écrite.
    private func rasteriser(_ state: TranscriptBadgeState) -> Rasterisation {
        let octets = octetsSurCanevas(TranscriptBadgeLabel(state: state))
        return Rasterisation(pixelsOpaques: pixelsOpaques(octets), octets: octets)
    }

    /// Le canevas **seul**, sans pastille : la référence de la mesure de vacuité.
    private func canevasSeul() -> [UInt8] {
        octetsSurCanevas(ZStack { Self.fondDuCanevas })
    }

    /// Le canevas **plus** la pastille d'un état, sur exactement le même fond et le même cadre : les
    /// deux rendus ne peuvent donc différer que par ce que la pastille a dessiné. Le glyphe est forcé
    /// en noir, pour que la mesure ne dépende pas de l'apparence (claire ou sombre) du processus.
    private func canevasAvecPastille(_ state: TranscriptBadgeState) -> [UInt8] {
        octetsSurCanevas(
            ZStack {
                Self.fondDuCanevas
                TranscriptBadgeLabel(state: state).foregroundStyle(Color.black)
            })
    }

    /// Le nombre de pixels que la pastille d'un état **ajoute** au canevas — `nil` quand la mesure
    /// n'est pas possible : référence ou rendu absent, tailles différentes, ou référence qui n'est pas
    /// un canevas uniforme et opaque. Un `nil` fait **échouer** le cas qui l'appelle — une sonde qui
    /// ne peut pas mesurer ne rend jamais un vert.
    ///
    /// **Pourquoi cette mesure et pas un comptage de pixels.** `ImageRenderer` rend **l'image du
    /// dernier rendu non vide du processus** quand la vue ne dessine rien (mesuré le 22/09/2026, revue
    /// round 1, F1) : compter les pixels d'un rendu vide ne dit donc rien de sa vacuité, et un `.idle`
    /// fidèle se mesurait comme le glyphe resté à l'écran. Le canevas, lui, se dessine toujours : la
    /// référence est fraîche quel que soit l'ordre des cas, et c'est l'écart entre les deux rendus —
    /// jamais le contenu d'un seul — qui dit ce que la pastille a dessiné.
    ///
    /// Mesuré : 0 pixel d'écart pour un `.idle` qui ne dessine rien, même après un rendu non vide et
    /// autant de fois qu'on répète la mesure ; 35 pour `.working` ; et un `.idle` auquel on fait
    /// dessiner un glyphe (mutant d'une ligne) est vu (35 pixels d'écart) — c'est ce que le contrat
    /// doit rendre impossible.
    private func pixelsDessinesPar(_ state: TranscriptBadgeState) -> Int? {
        let reference = canevasSeul()
        let rendu = canevasAvecPastille(state)
        guard !reference.isEmpty, reference.count == rendu.count else { return nil }
        // Sans cette garde, une référence qui porterait autre chose qu'un canevas uni attribuerait à
        // la pastille un écart qui ne vient pas d'elle : la mesure ne veut rien dire, et elle le dit.
        guard estUniforme(reference) else { return nil }

        var dessines = 0
        for debut in stride(from: 0, to: reference.count, by: 4) {
            if reference[debut] != rendu[debut]
                || reference[debut + 1] != rendu[debut + 1]
                || reference[debut + 2] != rendu[debut + 2]
                || reference[debut + 3] != rendu[debut + 3]
            {
                dessines += 1
            }
        }
        return dessines
    }

    /// Rend une vue hors écran, sur le canevas fixe, en RGBA prémultiplié. Tableau vide quand aucune
    /// image n'a pu être rendue.
    private func octetsSurCanevas<V: View>(_ vue: V) -> [UInt8] {
        let renderer = ImageRenderer(
            content: vue.frame(width: Self.canevas.width, height: Self.canevas.height))
        renderer.scale = 1

        guard let image = renderer.cgImage else { return [] }

        let largeur = image.width
        let hauteur = image.height
        guard
            let contexte = CGContext(
                data: nil,
                width: largeur,
                height: hauteur,
                bitsPerComponent: 8,
                bytesPerRow: largeur * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let base = contexte.data
        else { return [] }

        contexte.draw(
            image, in: CGRect(x: 0, y: 0, width: largeur, height: hauteur))
        return [UInt8](
            UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: UInt8.self), count: largeur * hauteur * 4))
    }

    /// Le nombre de pixels dont le canal alpha n'est pas nul.
    private func pixelsOpaques(_ octets: [UInt8]) -> Int {
        stride(from: 3, to: octets.count, by: 4).reduce(into: 0) { compte, alpha in
            if octets[alpha] > 0 { compte += 1 }
        }
    }

    /// Vrai quand tous les pixels portent la même couleur, pleinement opaque.
    private func estUniforme(_ octets: [UInt8]) -> Bool {
        guard octets.count >= 4, octets[3] == 255 else { return false }
        let rouge = octets[0]
        let vert = octets[1]
        let bleu = octets[2]
        for debut in stride(from: 0, to: octets.count, by: 4) {
            if octets[debut] != rouge || octets[debut + 1] != vert || octets[debut + 2] != bleu
                || octets[debut + 3] != 255
            {
                return false
            }
        }
        return true
    }
}
