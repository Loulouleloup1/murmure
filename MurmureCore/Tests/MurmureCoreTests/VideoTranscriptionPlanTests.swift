import Foundation
import XCTest
@testable import MurmureCore

/// Contrat rouge du lot 3 : **le plan de morceaux** d'une transcription longue (plan §2.1 et §4
/// lot 3, critères 9 et 10 côté plan).
///
/// Ce que ces tests gèlent, c'est la réponse au piège n°1 de la SPEC : WhisperKit n'a aucune API de
/// pause/reprise, donc la reprise vit sur des unités découpées par Murmure. Les trois propriétés
/// dont dépend tout le reste y sont : une coupe tombe **dans un silence** quand il y en a un, elle
/// est **forcée et marquée** quand il n'y en a pas, et les frontières sont **échantillon-exactes**
/// pour que 48 unités ne dérivent pas (critère 9 : la couverture et la monotonie).
///
/// Tous ces tests échouent sur une **assertion explicite** (message « contrat lot 3 : non
/// implémenté ») tant que le corps sentinelle de `VideoTranscriptionPlan.swift` n'a pas été
/// remplacé — jamais sur une erreur de compilation (plan §7.1, règle 4).
final class VideoTranscriptionPlanTests: XCTestCase {
    private let pasNominal = VideoTranscriptionPlan.nominalStep

    // MARK: - Outils

    /// Une tolérance d'**un échantillon** : c'est la précision annoncée par le contrat (§2.1, la
    /// coupe s'applique au WAV décodé 16 kHz). Plus serré, on testerait l'arrondi flottant ; plus
    /// large, on ne testerait plus rien.
    private var unEchantillon: Double { 1 / VideoTranscriptionPlan.sampleRate }

    /// Une frontière est un multiple entier de la période d'échantillonnage.
    private func verifierEchantillonExact(_ valeur: Double, _ contexte: String) {
        let echantillons = valeur * VideoTranscriptionPlan.sampleRate
        XCTAssertEqual(
            echantillons, echantillons.rounded(), accuracy: 1e-6,
            "contrat lot 3 : non implémenté — \(contexte) : \(valeur) s n'est pas un multiple entier de 1/16 000 s")
    }

    /// Contiguïté et complétude : la somme des durées vaut la durée totale **et** le début de
    /// chaque unité est exactement la somme des précédentes. C'est l'invariant « aucune perte de
    /// temps » de la carte, et il est vérifié sur toute sortie non vide.
    private func verifierContiguite(_ units: [UnitBoundary], duree: Double) {
        XCTAssertEqual(
            units.first?.start ?? -1, 0, accuracy: unEchantillon,
            "contrat lot 3 : non implémenté — la première unité commence à \(units.first?.start ?? -1) s")
        var somme = 0.0
        for (index, unite) in units.enumerated() {
            XCTAssertGreaterThan(
                unite.duration, 0,
                "contrat lot 3 : non implémenté — l'unité \(index) a une durée nulle ou négative")
            if index > 0 {
                let precedente = units[index - 1]
                XCTAssertEqual(
                    unite.start, precedente.start + precedente.duration, accuracy: unEchantillon,
                    "contrat lot 3 : non implémenté — l'unité \(index) commence à \(unite.start) s, la précédente se termine à \(precedente.start + precedente.duration) s")
            }
            somme += unite.duration
        }
        XCTAssertEqual(
            somme, duree, accuracy: unEchantillon,
            "contrat lot 3 : non implémenté — \(somme) s couvertes par les unités pour \(duree) s d'audio")
    }

    // MARK: - Le cas de la carte : 4 h sans aucun silence

    /// **Le cas obligatoire de la carte QA L3.** Un audio de 4 h dont aucun instant n'est silencieux
    /// n'a aucune coupe possible dans un silence : les 48 unités du pas de 5 min sont donc **toutes**
    /// marquées `forced`, et aucune seconde n'est perdue (c'est ce que la mesure de couverture du
    /// critère 9 exigera ensuite).
    func testQuatreHeuresSansSilenceDonnentQuaranteHuitUnitesToutesForcees() {
        let units = VideoTranscriptionPlan.units(duration: 14_400, silences: [])

        guard units.count == 48 else {
            XCTFail(
                "contrat lot 3 : non implémenté — 4 h au pas de 5 min doivent donner 48 unités, obtenu \(units.count)"
            )
            return
        }

        let forcees = units.filter { $0.quality == .forced }.count
        XCTAssertEqual(
            forcees, 48,
            "contrat lot 3 : non implémenté — \(forcees) unités sur 48 sont marquées forced ; sans silence, aucune coupe ne peut tomber dans un silence")
        XCTAssertEqual(
            units.filter { $0.quality == .silence }.count, 0,
            "contrat lot 3 : non implémenté — un silence a été trouvé dans un audio qui n'en contient aucun")

        // Le pas : 300, 600, … 14 100. Une coupe « au plus proche » qui dériverait d'une unité à
        // l'autre ferait échouer la première borne fausse, pas seulement la somme.
        for (index, unite) in units.enumerated() {
            XCTAssertEqual(
                unite.start, Double(index) * pasNominal, accuracy: unEchantillon,
                "contrat lot 3 : non implémenté — l'unité \(index) commence à \(unite.start) s au lieu de \(Double(index) * pasNominal) s")
            XCTAssertEqual(
                unite.duration, pasNominal, accuracy: unEchantillon,
                "contrat lot 3 : non implémenté — l'unité \(index) dure \(unite.duration) s au lieu de \(pasNominal) s")
        }
        verifierContiguite(units, duree: 14_400)
    }

    // MARK: - La coupe dans un silence

    /// **Le cas nominal.** Un silence à 15 s du multiple de 300 s : la coupe se déplace de 15 s,
    /// jusqu'au point du silence le plus proche du multiple (sa fin, 285 s), et elle est marquée
    /// `silence`. L'unité suivante reprend exactement là — c'est le début absolu que le recollage
    /// des horodatages utilisera.
    func testUneCoupeTombeDansLeSilenceLePlusProcheEtYEstMarquee() {
        let units = VideoTranscriptionPlan.units(duration: 600, silences: [270...285])

        guard units.count == 2 else {
            XCTFail(
                "contrat lot 3 : non implémenté — 600 s coupées à 285 s doivent donner 2 unités, obtenu \(units.count)"
            )
            return
        }
        XCTAssertEqual(
            units[0].duration, 285, accuracy: unEchantillon,
            "contrat lot 3 : non implémenté — la coupe est à \(units[0].start + units[0].duration) s au lieu de 285 s (le point du silence le plus proche du multiple de 300 s)")
        XCTAssertTrue(
            270 <= units[0].start + units[0].duration && units[0].start + units[0].duration <= 285,
            "contrat lot 3 : non implémenté — la coupe à \(units[0].start + units[0].duration) s n'est pas tombée dans le silence [270, 285]")
        XCTAssertEqual(
            units[0].quality, .silence,
            "contrat lot 3 : non implémenté — la coupe est dans un silence mais porte la qualité \(units[0].quality.rawValue)")
        XCTAssertEqual(
            units[1].start, 285, accuracy: unEchantillon,
            "contrat lot 3 : non implémenté — l'unité suivante commence à \(units[1].start) s au lieu de 285 s")
        verifierContiguite(units, duree: 600)
    }

    /// Quand le multiple tombe **dans** le silence, la coupe reste sur le multiple : on ne se
    /// déplace que du minimum nécessaire, et l'unité garde sa durée nominale (48 unités ne doivent
    /// pas dériver parce qu'un silence était large).
    func testUnMultipleDansLeSilenceGardeLaDureeNominale() {
        let units = VideoTranscriptionPlan.units(duration: 600, silences: [292...308])

        guard units.count == 2 else {
            XCTFail(
                "contrat lot 3 : non implémenté — 600 s au pas de 5 min doivent donner 2 unités, obtenu \(units.count)"
            )
            return
        }
        XCTAssertEqual(
            units[0].duration, pasNominal, accuracy: unEchantillon,
            "contrat lot 3 : non implémenté — le multiple tombe dans le silence [292, 308], la coupe doit rester à 300 s, obtenu \(units[0].duration) s")
        XCTAssertEqual(
            units[0].quality, .silence,
            "contrat lot 3 : non implémenté — la coupe à 300 s est dans un silence mais porte la qualité \(units[0].quality.rawValue)")
        verifierContiguite(units, duree: 600)
    }

    /// **La tolérance est de 30 s et elle est inclusive.** Les deux cas sont dans le même test : sans
    /// le refus, un silence accepté à n'importe quelle distance passerait pour un succès.
    func testUnSilenceAlaToleranceEstAccepteEtAuDelaEstRefuse() {
        let aTolerance = VideoTranscriptionPlan.units(duration: 600, silences: [262...270])
        let auDela = VideoTranscriptionPlan.units(duration: 600, silences: [255...269])

        guard aTolerance.count == 2, auDela.count == 2 else {
            XCTFail(
                "contrat lot 3 : non implémenté — 600 s doivent donner 2 unités dans les deux cas, obtenu \(aTolerance.count) et \(auDela.count)")
            return
        }
        XCTAssertEqual(
            aTolerance[0].duration, 270, accuracy: unEchantillon,
            "contrat lot 3 : non implémenté — un silence à exactement 30 s du multiple (fin à 270 s) doit être accepté, coupe obtenue à \(aTolerance[0].start + aTolerance[0].duration) s")
        XCTAssertEqual(
            aTolerance[0].quality, .silence,
            "contrat lot 3 : non implémenté — le silence à 30 s pile doit être accepté, qualité obtenue \(aTolerance[0].quality.rawValue)")
        XCTAssertEqual(
            auDela[0].duration, pasNominal, accuracy: unEchantillon,
            "contrat lot 3 : non implémenté — un silence à 31 s du multiple ne doit pas être accepté, coupe obtenue à \(auDela[0].start + auDela[0].duration) s")
        XCTAssertEqual(
            auDela[0].quality, .forced,
            "contrat lot 3 : non implémenté — au-delà de la tolérance la coupe est forcée, qualité obtenue \(auDela[0].quality.rawValue)")
    }

    // MARK: - Le pas est un paramètre

    /// Le pas de 5 min est le **défaut**, pas une constante : le lot 0 doit pouvoir le re-mesurer.
    /// Le contrôle qui compte est la troisième assertion — si `nominal` n'était pas lu, les deux
    /// premières seraient satisfaites sans rien prouver.
    func testLePasNominalEstUnParametreQuiVautCinqMinutesParDefaut() {
        let parDefaut = VideoTranscriptionPlan.units(duration: 610, silences: [])
        let explicite = VideoTranscriptionPlan.units(duration: 610, silences: [], nominal: 300)
        let minute = VideoTranscriptionPlan.units(duration: 610, silences: [], nominal: 60)

        guard parDefaut.count == 3 else {
            XCTFail(
                "contrat lot 3 : non implémenté — 610 s au pas de 5 min doivent donner 3 unités (300, 300, 10), obtenu \(parDefaut.count)")
            return
        }
        XCTAssertEqual(
            parDefaut.map { $0.duration }, [300, 300, 10],
            "contrat lot 3 : non implémenté — durées obtenues : \(parDefaut.map { $0.duration })")
        XCTAssertEqual(
            parDefaut, explicite,
            "contrat lot 3 : non implémenté — le pas par défaut n'est pas 300 s : \(parDefaut.map { $0.duration }) contre \(explicite.map { $0.duration })")
        XCTAssertEqual(
            minute.count, 11,
            "contrat lot 3 : non implémenté — au pas d'une minute, 610 s doivent donner 11 unités, obtenu \(minute.count)")
    }

    // MARK: - Les cas courts

    /// Un audio plus court que le pas n'a aucune coupe à chercher : **un seul** morceau, forcé, qui
    /// va de 0 à la durée — y compris quand la durée vaut exactement le pas (le multiple égal à la
    /// durée n'est pas une coupe, c'est la fin du fichier).
    func testUnAudioPlusCourtQueLePasDonneUnSeulMorceau() {
        let court = VideoTranscriptionPlan.units(duration: 200, silences: [])
        let pileLePas = VideoTranscriptionPlan.units(duration: pasNominal, silences: [])
        let vide = VideoTranscriptionPlan.units(duration: 0, silences: [])

        guard court.count == 1, pileLePas.count == 1 else {
            XCTFail(
                "contrat lot 3 : non implémenté — 200 s et 300 s doivent donner 1 unité chacune, obtenu \(court.count) et \(pileLePas.count)")
            return
        }
        XCTAssertEqual(
            court[0].duration, 200, accuracy: unEchantillon,
            "contrat lot 3 : non implémenté — l'unique unité de 200 s dure \(court[0].duration) s")
        XCTAssertEqual(
            court[0].quality, .forced,
            "contrat lot 3 : non implémenté — sans coupe possible, l'unité est forcée, obtenu \(court[0].quality.rawValue)")
        XCTAssertEqual(
            pileLePas[0].duration, pasNominal, accuracy: unEchantillon,
            "contrat lot 3 : non implémenté — à 300 s pile, l'unique unité doit faire 300 s, obtenu \(pileLePas[0].duration) s")
        XCTAssertEqual(
            vide.count, 0,
            "contrat lot 3 : non implémenté — un audio de durée nulle n'a aucun morceau, obtenu \(vide.count)")
    }

    // MARK: - L'échantillon-exactitude

    /// **Aucune frontière n'est un nombre réel quelconque.** Ici le silence ne tombe pas sur une
    /// frontière d'échantillon (1 180,712345 s — 1 191,234567 s, soit 0,712345 s = 11 397,52
    /// échantillons) : la coupe doit être ramenée à l'échantillon le plus proche, rester **dans le
    /// silence**, et toutes les autres frontières tomber sur le multiple nominal. C'est cette
    /// propriété qui fait que 48 unités ne dérivent pas (plan §2.1 : la découpe s'applique au WAV
    /// décodé, jamais à la source compressée).
    func testLesFrontieresSontEchantillonExactes() {
        let units = VideoTranscriptionPlan.units(
            duration: 3_600, silences: [1_180.712345...1_191.234567], nominal: 600)

        guard units.count == 6 else {
            XCTFail(
                "contrat lot 3 : non implémenté — 3 600 s au pas de 10 min doivent donner 6 unités, obtenu \(units.count)")
            return
        }

        let coupe = units[1].start + units[1].duration
        XCTAssertTrue(
            1_180.712345 <= coupe && coupe <= 1_191.234567,
            "contrat lot 3 : non implémenté — la coupe à \(coupe) s n'est pas tombée dans le silence [1 180,712345 ; 1 191,234567]")
        XCTAssertEqual(
            coupe, 1_191.234567, accuracy: unEchantillon,
            "contrat lot 3 : non implémenté — la coupe doit être le point du silence le plus proche du multiple de 600 s, obtenu \(coupe) s")
        XCTAssertEqual(
            units[1].quality, .silence,
            "contrat lot 3 : non implémenté — la coupe est dans un silence mais porte la qualité \(units[1].quality.rawValue)")
        XCTAssertEqual(
            units.map { $0.quality },
            [.forced, .silence, .forced, .forced, .forced, .forced],
            "contrat lot 3 : non implémenté — qualités obtenues : \(units.map { $0.quality.rawValue })")

        for (index, unite) in units.enumerated() {
            verifierEchantillonExact(unite.start, "début de l'unité \(index)")
            verifierEchantillonExact(unite.duration, "durée de l'unité \(index)")
            if index != 2 {
                XCTAssertEqual(
                    unite.start, Double(index) * 600, accuracy: unEchantillon,
                    "contrat lot 3 : non implémenté — l'unité \(index) commence à \(unite.start) s au lieu de \(Double(index) * 600) s")
            }
        }
        verifierContiguite(units, duree: 3_600)
    }

    // MARK: - Plusieurs silences à portée du même multiple (complément QA L3-bis)

    /// **La règle 3 dit « le plus proche », pas « le premier de la liste ».** En production (lot 7,
    /// `SilenceMap`) la liste des silences en contient des dizaines : plusieurs peuvent tomber à au
    /// plus `silenceTolerance` du **même** multiple du pas, et un balayage qui retiendrait le
    /// premier silence accepté couperait au mauvais endroit **sans que rien ne le signale** — la
    /// coupe resterait `silence`, donc « trouvable » et invisible au contrôle qualité.
    ///
    /// Ici, par ordre de début, le premier silence (`[269,5 ; 271]`) est à **29 s** du multiple de
    /// 300 s et le second (`[298 ; 302]`) **contient** ce multiple (distance 0). La coupe doit
    /// tomber dans le second, à 300 s : une coupe à 271 s est le symptôme exact de « le premier à
    /// portée gagne », et elle allongerait l'unité 0 de 29 s.
    func testParmiPlusieursSilencesALaPorteeLePlusProcheDuMultipleGagne() {
        let units = VideoTranscriptionPlan.units(
            duration: 600, silences: [269.5...271, 298...302])

        guard units.count == 2 else {
            XCTFail(
                "contrat lot 3 : non implémenté — 600 s coupées près du multiple de 300 s doivent donner 2 unités, obtenu \(units.count)")
            return
        }

        let coupe = units[0].start + units[0].duration
        XCTAssertEqual(
            units[0].duration, 300, accuracy: unEchantillon,
            "contrat lot 3 : non implémenté — l'unité 0 est coupée à \(coupe) s au lieu de 300 s : parmi les silences à au plus 30 s du multiple (269,5-271 à 29 s, 298-302 à 0 s), c'est le plus proche qui doit gagner, pas le premier")
        XCTAssertTrue(
            298 <= coupe && coupe <= 302,
            "contrat lot 3 : non implémenté — la coupe à \(coupe) s n'est pas tombée dans le silence [298, 302] qui contient le multiple de 300 s")
        XCTAssertFalse(
            269.5 <= coupe && coupe <= 271,
            "contrat lot 3 : non implémenté — la coupe à \(coupe) s est tombée dans le silence le plus éloigné du multiple ([269,5 ; 271], à 29 s) : le premier silence à portée a gagné")
        XCTAssertEqual(
            units[0].quality, .silence,
            "contrat lot 3 : non implémenté — la coupe à \(coupe) s est dans un silence mais porte la qualité \(units[0].quality.rawValue)")
        XCTAssertEqual(
            units[1].start, 300, accuracy: unEchantillon,
            "contrat lot 3 : non implémenté — l'unité suivante commence à \(units[1].start) s au lieu de 300 s")
        verifierContiguite(units, duree: 600)
    }

    /// **À distance égale, le silence qui commence le plus tôt gagne** (règle 3, clause d'égalité).
    /// C'est la seule clause du contrat qui n'était couverte par aucun cas : tous les cas existants
    /// ne fournissent qu'un silence, donc aucune comparaison n'a jamais lieu entre deux candidats
    /// équidistants.
    ///
    /// Deux silences à **10 s** du multiple de 300 s : `[280 ; 290]` (coupe à 290 s) et
    /// `[310 ; 320]` (coupe à 310 s). Le choix est observable — la coupe doit tomber à **290 s** —
    /// et il est déterministe : une comparaison qui remplacerait aussi à distance égale
    /// (`distance <= meilleure.distance`) déplacerait la coupe de 20 s en avant, ce qu'aucune
    /// assertion vague du genre « une coupe a eu lieu dans un silence » ne verrait.
    func testADistanceEgaleLeSilenceQuiCommenceLePlusTotGagne() {
        let units = VideoTranscriptionPlan.units(duration: 600, silences: [280...290, 310...320])

        guard units.count == 2 else {
            XCTFail(
                "contrat lot 3 : non implémenté — 600 s coupées près du multiple de 300 s doivent donner 2 unités, obtenu \(units.count)")
            return
        }

        let coupe = units[0].start + units[0].duration
        XCTAssertEqual(
            units[0].duration, 290, accuracy: unEchantillon,
            "contrat lot 3 : non implémenté — l'unité 0 est coupée à \(coupe) s au lieu de 290 s : [280, 290] et [310, 320] sont à 10 s du multiple de 300 s, à distance égale c'est le silence qui commence le plus tôt qui gagne")
        XCTAssertTrue(
            280 <= coupe && coupe <= 290,
            "contrat lot 3 : non implémenté — la coupe à \(coupe) s n'est pas tombée dans le silence [280, 290]")
        XCTAssertFalse(
            310 <= coupe && coupe <= 320,
            "contrat lot 3 : non implémenté — la coupe à \(coupe) s est tombée dans le silence le plus tardif ([310 ; 320]) alors que les deux candidats sont équidistants du multiple : à distance égale, le silence qui commence le plus tôt gagne")
        XCTAssertEqual(
            units[0].quality, .silence,
            "contrat lot 3 : non implémenté — la coupe à \(coupe) s est dans un silence mais porte la qualité \(units[0].quality.rawValue)")
        XCTAssertEqual(
            units[1].start, 290, accuracy: unEchantillon,
            "contrat lot 3 : non implémenté — l'unité suivante commence à \(units[1].start) s au lieu de 290 s")
        verifierContiguite(units, duree: 600)
    }
}
