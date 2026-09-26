import XCTest

@testable import MurmureCore

/// Contrat rouge du lot 7 : la **carte de silence** (plan §4 lot 7 révision 6, §2.1 ; arbitrage
/// `t_e3167e58`).
///
/// **Ce que ce fichier gèle.** Le lot 4 sait *lire* la sortie d'`ffmpeg -af silencedetect`
/// (`FfmpegCommand.silenceIntervals`, transporté ici — règle 10) et le lot 3 sait *choisir* où
/// couper (`VideoTranscriptionPlan.units`, transporté et vert). Le maillon qui manque est la
/// **normalisation** entre les deux : des `FfmpegSilence` brutes (bornes non arrondies,
/// éventuellement au-delà de la fin du fichier, dans n'importe quel ordre) vers les intervalles
/// **fermés** du lot 3, sur la grille du WAV décodé 16 kHz mono et bornés à la durée du fichier.
///
/// **Pourquoi chaque cas est là.**
///
/// - le cas de **composition** est le seul qui prouve la propriété qui compte pour le plan : un
///   silence qui couvre exactement le pas nominal donne une coupe `.silence` sur le multiple, et
///   `start`/`duration` des unités tombent des multiples entiers de 1/16 000 (§2.1 : c'est ce qui
///   rend le recollage des horodatages exact) ;
/// - le passage par une **capture réelle d'`ffmpeg`** (volée au lot 4) est ce qui distingue un
///   normalisateur éprouvé sur des valeurs écrites par `ffmpeg` (`4.000063`) d'un normalisateur
///   écrit contre un flux idéalisé — et son second silence finit **exactement sur la fin du
///   fichier** (`6 → 7.5` sur 7,5 s) ;
/// - les deux cas **limites** qui ont déjà mordu le plan : plus aucun silence du tout (toutes les
///   coupes `.forced`, aucune seconde perdue), et un silence qui déborde de la fin ;
/// - les cas **dégénérés** et la **durée non positive** : rien à normaliser ne doit pas produire de
///   `ClosedRange` invalide (`début > fin` piège le programme), ni faire disparaître une unité.
///
/// **Deux tests portent une assertion qui, seule, serait verte sur la sentinelle** (`aucun
/// silence`, et `durée <= 0`) : la sentinelle rend `[]`, donc un cas qui attend `[]` passerait sans
/// qu'une ligne de `SilenceMap` ne soit exercée. Chacun de ces deux tests commence donc par un
/// **contrôle positif** qui exige de la normalisation qu'elle rende ce qu'elle doit rendre quand il
/// y a quelque chose à rendre. Sans lui, le test serait vert **avant** l'implémentation — c'est
/// exactement le travers que le contrat doit rendre impossible.
///
/// Tous ces tests échouent sur une **assertion explicite** (« contrat lot 7 : non implémenté »)
/// tant que le corps sentinelle de `SilenceMap.swift` n'a pas été remplacé : aucune erreur de
/// compilation, aucun `skip` (§7.1 règles 2 à 4 — un fichier de test non compilable casserait le
/// module de tests de toutes les cartes en parallèle).
final class SilenceMapTests: XCTestCase {
    // MARK: - Outils

    /// La plus petite frontière représentable de l'audio décodé : 1/16 000 s (§2.1, lot 3
    /// règle 5). Toute borne rendue par `SilenceMap` doit tomber sur cette grille.
    private let echantillon = 1 / VideoTranscriptionPlan.sampleRate

    /// La grille est vérifiée par son **produit** (un nombre entier d'échantillons), pas par une
    /// valeur attendue : c'est la propriété observable « au multiple d'échantillon près », sans
    /// épingler une écriture de flottant particulière.
    private func surLaGrille(
        _ borne: Double, _ quoi: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let enEchantillons = borne * VideoTranscriptionPlan.sampleRate
        XCTAssertEqual(
            enEchantillons, enEchantillons.rounded(), accuracy: 1e-6,
            "contrat lot 7 : non implémenté — \(quoi) hors grille 16 kHz : \(borne) (\(enEchantillons) échantillons)",
            file: file, line: line)
    }

    /// Le garde-fou des unités du lot 3, réutilisé tel quel : contiguïté, durées strictement
    /// positives, `start`/`duration` sur la grille.
    private func verifierUnites(
        _ unites: [UnitBoundary], _ quoi: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        var precedent = 0.0
        for (index, unite) in unites.enumerated() {
            XCTAssertGreaterThan(
                unite.duration, 0,
                "contrat lot 7 : non implémenté — \(quoi) : l'unité \(index) est vide (durée \(unite.duration))",
                file: file, line: line)
            XCTAssertEqual(
                unite.start, precedent, accuracy: echantillon / 2,
                "contrat lot 7 : non implémenté — \(quoi) : l'unité \(index) ne reprend pas où finit la précédente (\(unite.start) contre \(precedent))",
                file: file, line: line)
            surLaGrille(unite.start, "le début de l'unité \(index) de \(quoi)", file: file, line: line)
            surLaGrille(
                unite.duration, "la durée de l'unité \(index) de \(quoi)", file: file, line: line)
            precedent = unite.start + unite.duration
        }
    }

    private func chaineFixture(_ nom: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: nom, withExtension: "txt", subdirectory: "Fixtures"),
            "fixture absente du bundle de tests : Fixtures/\(nom).txt")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func qualites(_ unites: [UnitBoundary]) -> [String] {
        unites.map { $0.quality.rawValue }
    }

    // MARK: - Composition avec le lot 3

    /// **Le cas qui porte la propriété du §2.1.** Un silence qui couvre le pas nominal (300 s,
    /// 40 min d'audio) : la coupe tombe **dans le silence**, sur le multiple, elle est marquée
    /// `.silence`, et toutes les frontières des unités sont des multiples entiers de 1/16 000.
    func testUnSilenceQuiCouvreLeNominalDonneUneCoupeSilenceSurLaGrille() {
        let duration = 2400.0  // 40 min : 8 unités de 5 min

        let rendus = SilenceMap.intervals(
            from: [FfmpegSilence(start: 295, end: 305)], duration: duration)

        XCTAssertEqual(
            rendus.count, 1,
            "contrat lot 7 : non implémenté — intervalles normalisés : \(rendus)")
        guard rendus.count == 1 else { return }
        XCTAssertEqual(
            rendus[0].lowerBound, 295, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne basse rendue : \(rendus[0].lowerBound)")
        XCTAssertEqual(
            rendus[0].upperBound, 305, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne haute rendue : \(rendus[0].upperBound)")
        surLaGrille(rendus[0].lowerBound, "la borne basse du silence rendu")
        surLaGrille(rendus[0].upperBound, "la borne haute du silence rendu")

        let unites = VideoTranscriptionPlan.units(duration: duration, silences: rendus)

        XCTAssertEqual(
            unites.count, 8,
            "contrat lot 7 : non implémenté — unités obtenues : \(unites.count) (\(qualites(unites)))")
        guard unites.count == 8 else { return }
        XCTAssertEqual(
            unites[0].quality, .silence,
            "contrat lot 7 : non implémenté — la coupe de 300 s est tombée hors du silence couvrant [295, 305] : qualité rendue « \(unites[0].quality.rawValue) »")
        XCTAssertEqual(
            unites[0].duration, 300, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — durée de la première unité : \(unites[0].duration) (le multiple est à 300 s)")
        XCTAssertEqual(
            unites.filter { $0.quality == .silence }.count, 1,
            "contrat lot 7 : non implémenté — une seule coupe doit tomber dans le silence, qualités rendues : \(qualites(unites))")
        XCTAssertEqual(
            unites.dropFirst().filter { $0.quality != .forced }.count, 0,
            "contrat lot 7 : non implémenté — les coupes sans silence doivent être marquées « forced » : \(qualites(unites))")

        verifierUnites(unites, "le silence couvrant [295, 305]")
        XCTAssertEqual(
            unites.reduce(0) { $0 + $1.duration }, duration, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — la somme des durées ne couvre pas la durée totale : \(unites.reduce(0) { $0 + $1.duration })")
    }

    // MARK: - Aucun silence

    /// **Une source sans silence ne perd aucune seconde.** Toutes les coupes sont `.forced`,
    /// aucune unité n'est vide ni de durée nulle, et la somme des durées couvre le fichier.
    ///
    /// Le contrôle positif du début est indispensable : la sentinelle rend `[]`, donc la seconde
    /// moitié de ce test serait verte avant l'implémentation (voir l'en-tête du fichier).
    func testAucunSilenceDonneDesCoupesForceesSansUniteVideNiNulle() {
        let duration = 2400.0

        // Contrôle positif : quand il y a quelque chose à normaliser, et qu'une seule des trois
        // entrées est un vrai silence, c'est celui-là et lui seul qui sort — sur la grille.
        let rendus = SilenceMap.intervals(
            from: [
                FfmpegSilence(start: 300, end: 300),  // dégénéré : fin == début
                FfmpegSilence(start: 620, end: 610),  // inversé : dégénéré après normalisation
                FfmpegSilence(start: 590, end: 610),  // le seul vrai silence
            ],
            duration: duration)
        XCTAssertEqual(
            rendus.count, 1,
            "contrat lot 7 : non implémenté — intervalles normalisés : \(rendus) (un intervalle dégénéré doit être écarté, « fin <= début »)")
        guard rendus.count == 1 else { return }
        XCTAssertEqual(
            rendus[0].lowerBound, 590, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne basse rendue : \(rendus[0].lowerBound)")
        XCTAssertEqual(
            rendus[0].upperBound, 610, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne haute rendue : \(rendus[0].upperBound)")

        // Le cas de la carte : aucun silence exploitable, donc plus aucun intervalle à donner au
        // lot 3.
        let aucun = SilenceMap.intervals(
            from: [
                FfmpegSilence(start: 300, end: 300),
                FfmpegSilence(start: 620, end: 610),
            ],
            duration: duration)
        XCTAssertEqual(
            aucun.count, 0,
            "contrat lot 7 : non implémenté — intervalles rendus pour des entrées toutes dégénérées : \(aucun)")

        let unites = VideoTranscriptionPlan.units(duration: duration, silences: aucun)
        XCTAssertEqual(
            unites.count, 8,
            "contrat lot 7 : non implémenté — unités obtenues : \(unites.count) (\(qualites(unites)))")
        guard unites.count == 8 else { return }
        XCTAssertEqual(
            unites.filter { $0.quality != .forced }.count, 0,
            "contrat lot 7 : non implémenté — sans silence, toutes les coupes sont forcées : \(qualites(unites))")
        verifierUnites(unites, "une source sans silence")
        XCTAssertEqual(
            unites.reduce(0) { $0 + $1.duration }, duration, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — aucune seconde ne doit être perdue : \(unites.reduce(0) { $0 + $1.duration }) pour \(duration)")
    }

    // MARK: - Bornes hors fichier

    /// Un silence **à cheval sur la fin du fichier** est ramené à `duration` : ni écarté en bloc
    /// (le silence existe, il porte la dernière coupe), ni laissé hors fichier (une borne au-delà
    /// de `duration` produirait une tranche négative au lot 7 aval). Un silence entièrement hors
    /// fichier, lui, se réduit à `[0, 0]` et disparaît.
    func testUnSilenceQuiDepasseLaFinDuFichierEstRameneeALaDuree() {
        let duration = 100.0

        let rendus = SilenceMap.intervals(
            from: [
                FfmpegSilence(start: 98, end: 130),  // déborde après la fin
                FfmpegSilence(start: -5, end: 1),  // commence avant le début
                FfmpegSilence(start: -5, end: -1),  // entièrement avant le fichier
            ],
            duration: duration)

        XCTAssertEqual(
            rendus.count, 2,
            "contrat lot 7 : non implémenté — intervalles rendus : \(rendus) (le silence qui déborde est ramené à la durée et conservé ; celui qui est entièrement hors fichier disparaît)")
        guard rendus.count == 2 else { return }
        XCTAssertEqual(
            rendus[0].lowerBound, 0, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne basse rendue : \(rendus[0].lowerBound) (le silence commence avant le fichier)")
        XCTAssertEqual(
            rendus[0].upperBound, 1, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne haute rendue : \(rendus[0].upperBound)")
        XCTAssertEqual(
            rendus[1].lowerBound, 98, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne basse rendue : \(rendus[1].lowerBound)")
        XCTAssertEqual(
            rendus[1].upperBound, duration, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne haute rendue : \(rendus[1].upperBound) (la durée du fichier est \(duration), une coupe au-delà n'existe pas)")

        for (index, intervalle) in rendus.enumerated() {
            XCTAssertGreaterThanOrEqual(
                intervalle.lowerBound, 0,
                "contrat lot 7 : non implémenté — borne \(index) avant le début du fichier : \(intervalle.lowerBound)")
            XCTAssertLessThanOrEqual(
                intervalle.upperBound, duration,
                "contrat lot 7 : non implémenté — borne \(index) après la fin du fichier : \(intervalle.upperBound) pour une durée de \(duration)")
            XCTAssertLessThanOrEqual(
                intervalle.lowerBound, intervalle.upperBound,
                "contrat lot 7 : non implémenté — intervalle inversé rendu : \(intervalle)")
        }
    }

    // MARK: - Grille 16 kHz

    /// Les bornes réelles d'une capture d'`ffmpeg` (`4.000063`) sont ramenées à l'**échantillon le
    /// plus proche** de la grille 16 kHz : 2,000063 s et 4,000063 s valent 32 001 et 64 001
    /// échantillons. C'est la propriété dont dépend l'exactitude du recollage des horodatages
    /// (§2.1), et elle ne se voit que sur des valeurs qu'`ffmpeg` écrit vraiment.
    func testLesBornesHorsGrilleSontRameesSurLEchantillonLePlusProche() {
        let rendus = SilenceMap.intervals(
            from: [FfmpegSilence(start: 2.000063, end: 4.000063)], duration: 7.5)

        XCTAssertEqual(
            rendus.count, 1,
            "contrat lot 7 : non implémenté — intervalles rendus : \(rendus)")
        guard rendus.count == 1 else { return }
        XCTAssertEqual(
            rendus[0].lowerBound, 32001 / VideoTranscriptionPlan.sampleRate, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne basse rendue : \(rendus[0].lowerBound) (2,000063 s = 32 001 échantillons à 16 kHz)")
        XCTAssertEqual(
            rendus[0].upperBound, 64001 / VideoTranscriptionPlan.sampleRate, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne haute rendue : \(rendus[0].upperBound) (4,000063 s = 64 001 échantillons à 16 kHz)")
        surLaGrille(rendus[0].lowerBound, "la borne basse du silence rendu")
        surLaGrille(rendus[0].upperBound, "la borne haute du silence rendu")
    }

    // MARK: - Tri

    /// Les intervalles sortent **triés par début croissant**, quel que soit l'ordre dans lequel
    /// `ffmpeg` les a écrits (l'ordre de la sortie de `ffmpeg` n'est pas contractuel).
    func testLesIntervallesRendusSontTriesParDebutCroissant() {
        let rendus = SilenceMap.intervals(
            from: [
                FfmpegSilence(start: 600, end: 610),
                FfmpegSilence(start: 100, end: 110),
                FfmpegSilence(start: 300, end: 305),
            ],
            duration: 900)

        XCTAssertEqual(
            rendus.count, 3,
            "contrat lot 7 : non implémenté — intervalles rendus : \(rendus)")
        guard rendus.count == 3 else { return }
        XCTAssertEqual(
            rendus.map(\.lowerBound), [100.0, 300.0, 600.0],
            "contrat lot 7 : non implémenté — débuts rendus : \(rendus.map(\.lowerBound))")
        XCTAssertEqual(
            rendus.map(\.upperBound), [110.0, 305.0, 610.0],
            "contrat lot 7 : non implémenté — fins rendues : \(rendus.map(\.upperBound))")
    }

    // MARK: - Rien à normaliser

    /// `duration <= 0` : il n'y a pas de fichier, donc rien à normaliser — et rien à couper.
    ///
    /// Le contrôle positif du début est indispensable pour la même raison qu'au cas « aucun
    /// silence » : un normalisateur qui rendrait toujours `[]` passerait la seconde moitié.
    func testDureeNonPositiveOuSilencesVidesNeNormalisentRien() {
        // Contrôle positif : sur un fichier de 60 s, le silence [10, 20] sort tel quel.
        let rendus = SilenceMap.intervals(
            from: [FfmpegSilence(start: 10, end: 20)], duration: 60)
        XCTAssertEqual(
            rendus.count, 1,
            "contrat lot 7 : non implémenté — un fichier de 60 s avec un silence [10, 20] doit rendre un intervalle, rendu : \(rendus)")
        guard rendus.count == 1 else { return }
        XCTAssertEqual(
            rendus[0].lowerBound, 10, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne basse rendue : \(rendus[0].lowerBound)")
        XCTAssertEqual(
            rendus[0].upperBound, 20, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne haute rendue : \(rendus[0].upperBound)")

        XCTAssertEqual(
            SilenceMap.intervals(from: [], duration: 60).count, 0,
            "contrat lot 7 : non implémenté — aucun silence lu doit rendre aucun intervalle")
        XCTAssertEqual(
            SilenceMap.intervals(from: [FfmpegSilence(start: 10, end: 20)], duration: 0).count, 0,
            "contrat lot 7 : non implémenté — durée nulle : il n'y a pas de fichier à normaliser")
        XCTAssertEqual(
            SilenceMap.intervals(from: [FfmpegSilence(start: 10, end: 20)], duration: -5).count, 0,
            "contrat lot 7 : non implémenté — durée négative : il n'y a pas de fichier à normaliser")
        XCTAssertTrue(
            VideoTranscriptionPlan.units(
                duration: 0, silences: SilenceMap.intervals(from: [], duration: 0)
            ).isEmpty,
            "contrat lot 7 : non implémenté — une durée nulle ne doit produire aucune unité")
    }

    // MARK: - La capture réelle d'ffmpeg (transport du lot 4)

    /// **La carte de silence part d'une sortie réelle d'`ffmpeg`**, lue par l'analyseur du lot 4
    /// (`FfmpegCommand.silenceIntervals`, transporté ici — règle 10) : la fixture
    /// `Fixtures/silencedetect-silences.txt` est une capture `stderr` véritable de 7,5 s de WAV,
    /// avec son en-tête, ses adresses `[silencedetect @ 0x…]`, ses deux silences et ses décimales
    /// exactes (`4.000063`).
    ///
    /// Le second silence finit **exactement sur la fin du fichier** (`6 → 7.5` sur 7,5 s) : le cas
    /// « borne haute = durée » n'est donc pas une hypothèse de laboratoire, il vient de la capture.
    /// Et la composition avec le lot 3 (pas nominal rabaissé à 5 s pour que la coupe cherchée tombe
    /// dans le premier silence) montre ce que le plan utilise vraiment : une coupe `.silence` sur
    /// la grille, une coupe forcée à la fin, aucune seconde perdue.
    func testLaCarteDeSilencePartDUneSortieReelleDffmpeg() throws {
        let lus = FfmpegCommand.silenceIntervals(
            inFfmpegOutput: try chaineFixture("silencedetect-silences"))
        XCTAssertEqual(
            lus.count, 2,
            "transport lot 4 manqué (règle 10) — silences lus dans la capture : \(lus)")
        guard lus.count == 2 else { return }

        let duration = 7.5
        let rendus = SilenceMap.intervals(from: lus, duration: duration)

        XCTAssertEqual(
            rendus.count, 2,
            "contrat lot 7 : non implémenté — intervalles normalisés : \(rendus)")
        guard rendus.count == 2 else { return }
        XCTAssertEqual(
            rendus[0].lowerBound, 2, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne basse du premier silence : \(rendus[0].lowerBound) (capture : 2)")
        XCTAssertEqual(
            rendus[0].upperBound, 64001 / VideoTranscriptionPlan.sampleRate, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne haute du premier silence : \(rendus[0].upperBound) (capture : 4.000063)")
        XCTAssertEqual(
            rendus[1].lowerBound, 6, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne basse du second silence : \(rendus[1].lowerBound) (capture : 6)")
        XCTAssertEqual(
            rendus[1].upperBound, duration, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — borne haute du second silence : \(rendus[1].upperBound) (la capture finit ce silence à 7,5 s, la fin du fichier)")

        let unites = VideoTranscriptionPlan.units(duration: duration, silences: rendus, nominal: 5)
        XCTAssertEqual(
            unites.count, 2,
            "contrat lot 7 : non implémenté — unités obtenues : \(unites.count) (\(qualites(unites)))")
        guard unites.count == 2 else { return }
        XCTAssertEqual(
            unites[0].quality, .silence,
            "contrat lot 7 : non implémenté — la coupe de 5 s doit tomber dans le silence [2, 4.000063] déplacé sur la grille : qualité rendue « \(unites[0].quality.rawValue) »")
        XCTAssertEqual(
            unites[0].duration, 64001 / VideoTranscriptionPlan.sampleRate, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — durée de la première unité : \(unites[0].duration) (la coupe est la borne haute du premier silence)")
        XCTAssertEqual(
            unites[1].quality, .forced,
            "contrat lot 7 : non implémenté — la dernière unité finit sur le fichier : qualité rendue « \(unites[1].quality.rawValue) »")
        XCTAssertEqual(
            unites[1].start, unites[0].duration, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — l'unité suivante ne reprend pas à la coupe : \(unites[1].start) contre \(unites[0].duration)")
        XCTAssertEqual(
            unites.reduce(0) { $0 + $1.duration }, duration, accuracy: 1e-9,
            "contrat lot 7 : non implémenté — la somme des durées : \(unites.reduce(0) { $0 + $1.duration }) pour \(duration)")
        verifierUnites(unites, "la capture réelle d'ffmpeg")
    }
}
