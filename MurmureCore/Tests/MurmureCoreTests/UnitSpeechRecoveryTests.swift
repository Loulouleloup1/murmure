import XCTest
@testable import MurmureCore

/// Contrat rouge du lot **8-R** : **le trou d'une fenêtre sautée par le moteur est détecté, décidé et
/// recousu** (plan §2.1 et §4 lot 8-R, révision 9 ; suivi `t_c844f772`).
///
/// **Le défaut mesuré que ce fichier rend impossible.** WhisperKit v1.1.0 saute une fenêtre entière de
/// 30 s quand sa probabilité de non-parole dépasse `noSpeechThreshold` (0,6 par défaut,
/// `Configurations.swift:216`) sans que `avgLogProb` ne renverse la décision
/// (`SegmentSeeker.swift:57-71`). Sur la vidéo A du plan, la fenêtre sautée portait de la **parole**
/// (RMS −19,4 dBFS sur `[300, 330)`, aucun silence ≥ 1 s dans cet audio) : le trou fait **24,4 s ou
/// 30,0 s** selon la passe, et le critère 9 a mesuré 0,9704 puis 0,9573 / 0,9680 / 0,9800 — une
/// loterie du moteur, pas une propriété du livrable. La décision qui empêche la perte vit dans le
/// **cœur** (`UnitSpeechRecovery`, cible testable) ; la cible app n'a pas de bundle de tests.
///
/// **Ce que ces cas gèlent, un par critère de la carte** (a → f) :
/// - le trou est le **complément de l'union** des segments, jamais une somme de durées — c'est la
///   seule forme qui dit *où* rejouer (cas a) ;
/// - un trou de 30 s en fin d'unité, **sans silence mesuré**, est rejoué (cas b) ;
/// - un trou **entièrement dans un silence mesuré** ne l'est pas : on ne fabrique pas de texte sur
///   notre propre silence (cas c) ;
/// - la borne porte sur le **contenu hors silence** (`longueur(trou) − longueur(silences ∩ trou)`) et
///   **pas** sur la longueur du trou (cas d) — c'est ce que ce cas gèle, et c'est vrai quelle que soit
///   la valeur de la borne ; **cette valeur a changé depuis** : elle est passée du `minimumRecoverable`
///   du lot 8-R (**20 s**) au **plafond des pauses naturelles** (**5,0 s**, plan §2.1) par le contrat
///   de la carte QA `t_7540c725`, parce que les trous mesurés de 5 à 20 s portaient de la parole et
///   n'étaient rejoués par personne. Les cas de borne vivent désormais dans
///   `UnitSpeechRecoveryGapLimitTests` ; le cas (d) d'ici ne garde que la distinction matière/longueur ;
/// - le rognage à l'intervalle rejoué ne retire **rien** à l'unité et laisse le résultat strictement
///   croissant, sans aucune paire qui se chevauche (cas e) ;
/// - les silences du lot 7 sont ramenés **au temps de l'unité** (cas f) — sans quoi l'intersection
///   serait vide presque partout et *tous* les trous seraient rejoués, silences compris.
///
/// **Chaque cas porte au moins un contrôle positif.** Un cas dont la seule assertion attendue est
/// `[]` serait **vert** sur la sentinelle `return []` : il ne prouverait rien (le cas c est
/// exactement celui-là, et son contrôle positif est écrit dans le même test).
///
/// **Forme (règles 1 à 4 du §7.1).** Le rouge est prouvé par des **assertions explicites avec
/// message** — jamais par une erreur de compilation (un fichier de tests non compilable casserait la
/// gate `swift test` de *toutes* les cartes), jamais par un `skip`, jamais par un
/// `expectedFailure`. La carte `dev` remplace les corps sentinelles de `UnitSpeechRecovery` **sans
/// toucher aux signatures** (règle 5) : si une signature ne va pas, le contrat revient au `qa`.
final class UnitSpeechRecoveryTests: XCTestCase {
    private let contrat = "contrat lot 8-R : non implémenté"

    // MARK: - Outils

    private func segment(_ debut: Double, _ fin: Double, _ texte: String) -> TranscriptSegment {
        TranscriptSegment(start: debut, end: fin, text: texte)
    }

    /// L'unité telle que le plan de morceaux (lot 3) la produit : frontière absolue, coupe forcée
    /// (c'est le cas des 8 unités de la vidéo A, qui n'ont aucun silence ≥ 1 s).
    private func unite(debut: Double, duree: Double) -> UnitBoundary {
        UnitBoundary(start: debut, duration: duree, quality: .forced)
    }

    /// Le contrôle d'invariant du critère 9, appliqué à ce que la reprise rend : strictement
    /// croissant, aucune paire qui se chevauche. Il n'indexe rien (une collection vide ne doit pas
    /// faire tomber le binaire de tests entier).
    private func verifieCroissanceStricte(_ segments: [TranscriptSegment], _ contexte: String) {
        for (precedent, suivant) in zip(segments, segments.dropFirst()) {
            XCTAssertTrue(
                suivant.start >= precedent.end,
                "\(contrat) — \(contexte) : « \(suivant.text) » (\(suivant.start)) recule sur « \(precedent.text) » (\(precedent.end))")
            XCTAssertTrue(
                suivant.start < suivant.end,
                "\(contrat) — \(contexte) : « \(suivant.text) » n'a pas `début < fin` (\(suivant.start) … \(suivant.end))")
        }
    }

    // MARK: - (a) Le trou est le complément de l'union

    /// Un trou est une **position**, pas un nombre : le complément de l'union des segments, borné à
    /// `[0, duration]`. Le cas mesuré de référence est celui du lot 8 (unités de 300 s, trou de
    /// 24,4 s ou 30,0 s en fin d'unité).
    func testUnTrouEstLeComplémentDeLUnion() {
        // Deux segments disjoints laissent deux trous, plus la fin de l'audio.
        let disjoints = [
            segment(0, 10, "a"), segment(20, 30, "b"), segment(50, 60, "c"),
        ]
        XCTAssertEqual(
            UnitSpeechRecovery.uncovered(segments: disjoints, duration: 70),
            [10...20, 30...50, 60...70], contrat)

        // Deux segments qui se chevauchent couvrent **une fois** : un seul trou reste.
        let chevauchants = [segment(0, 40, "a"), segment(20, 60, "b")]
        XCTAssertEqual(
            UnitSpeechRecovery.uncovered(segments: chevauchants, duration: 70),
            [60...70], contrat)

        // Un segment hors bornes est borné à la durée : `[65, 80]` sur 70 s ne couvre que `[65, 70]`,
        // donc le trou va de 0 à 65 — et il n'y a **pas** de trou `[70, 80]` hors de l'audio.
        XCTAssertEqual(
            UnitSpeechRecovery.uncovered(segments: [segment(65, 80, "hors")], duration: 70),
            [0...65], contrat)

        // Aucun segment : l'unité entière est un trou (unité jamais transcrite).
        XCTAssertEqual(
            UnitSpeechRecovery.uncovered(segments: [], duration: 70), [0...70], contrat)

        // Durée nulle : aucune division, aucun intervalle dégénéré — `[]`, jamais `[0, 0]`.
        XCTAssertEqual(
            UnitSpeechRecovery.uncovered(segments: [segment(0, 10, "a")], duration: 0), [], contrat)
    }

    // MARK: - (b) Le trou d'une fenêtre sautée est rejoué

    /// Le cas mesuré : une unité de 300 s dont les segments couvrent `[0, 270)` — le moteur a sauté la
    /// dernière fenêtre — et **aucun silence** déclaré. Le trou vaut 30 s de contenu : il est rejoué,
    /// et il est rejoué **là où il est** (`[270, 300]`), pas « 30 secondes quelque part ».
    func testUnTrouDeFenetreSauteeEstRejoue() {
        let couvre270 = [segment(0, 135, "début"), segment(135, 270, "milieu")]

        XCTAssertEqual(
            UnitSpeechRecovery.uncovered(segments: couvre270, duration: 300),
            [270...300],
            "\(contrat) — le trou d'une unité de 300 s couverte jusqu'à 270 vaut `[270, 300]`")

        XCTAssertEqual(
            UnitSpeechRecovery.toReplay(segments: couvre270, duration: 300, silences: []),
            [270...300],
            "\(contrat) — un trou de 30 s SANS silence mesuré doit être rejoué")
    }

    // MARK: - (c) Un trou entièrement dans un silence mesuré n'est pas rejoué

    /// Le **garde-fou** du §2.1 : le même trou, couvert par un silence du lot 7 (`[265, 300]`) — ici
    /// 30 s de silence déclaré sur 30 s de trou — n'est pas rejoué. Le moteur a raison de sauter, et
    /// rejouer un silence ne rend pas de parole : il rend le texte inventé que la boucle de repli du
    /// décodeur produit à température haute.
    func testUnTrouEntierementDansUnSilenceMesureNEstPasRejoue() {
        let couvre270 = [segment(0, 135, "début"), segment(135, 270, "milieu")]
        let silence = [265.0...300.0]

        XCTAssertEqual(
            UnitSpeechRecovery.toReplay(segments: couvre270, duration: 300, silences: silence), [],
            "\(contrat) — un trou de 30 s couvert par 30 s de silence mesuré ne se rejoue pas")

        // Contrôle positif du MÊME cas, dans le MÊME test : la sentinelle `return []` ne peut pas
        // passer pour un vert ici. Sans lui, ce test serait vert avant toute implémentation.
        XCTAssertEqual(
            UnitSpeechRecovery.toReplay(segments: couvre270, duration: 300, silences: []),
            [270...300],
            "\(contrat) — le même trou, sans silence mesuré, doit être rejoué (contrôle positif)")
    }

    // MARK: - (d) La borne porte sur le contenu hors silence, pas sur la longueur du trou

    /// La borne du §2.1 porte sur la **matière** (`longueur(trou) − longueur(silences ∩ trou)`) et
    /// **pas** sur la longueur du trou : c'est ce que ce cas gèle, et c'est vrai quelle que soit la
    /// valeur de la borne.
    ///
    /// **Amendement (carte QA `t_7540c725`).** Ce cas s'appelait `testLaBorneEstVingtSecondesDeContenuHorsSilence`
    /// et affirmait deux choses aujourd'hui fausses : qu'un trou de **12 s** ne se rejoue pas, et
    /// qu'un trou de 30 s dont 15 s sont déclarées silence non plus (15 < 20). Le PM a ramené la borne
    /// au **plafond des pauses naturelles** — il faut rejouer tout trou qui porte **plus de 5,0 s** de
    /// parole — parce que les trous mesurés de 5 à 20 s de la vidéo A portaient de la parole et
    /// n'étaient rejoués par personne (12,040 à 42,840 s par passe lien). Les deux cas de borne
    /// (`12 s` rejoué, `15 s` de matière rejoué) vivent désormais dans
    /// `UnitSpeechRecoveryGapLimitTests`, avec la règle complète et ses contrôles positifs ; ce cas-ci
    /// ne garde que la **distinction matière / longueur**, que les deux valeurs de borne respectent —
    /// et il reste vert avant comme après le changement, ce qui est le but d'un amendement de borne.
    func testLaBornePorteSurLeContenuHorsSilencePasSurLaLongueurDuTrou() {
        // 30 s sans silence : 30 s de matière → rejoué, quelle que soit la borne.
        XCTAssertEqual(
            UnitSpeechRecovery.toReplay(
                segments: [segment(0, 270, "couvre")], duration: 300, silences: []),
            [270...300],
            "\(contrat) — un trou de 30 s sans silence mesuré est rejoué")

        // 30 s dont 27 s déclarées silence : 3 s de matière → non rejoué. La décision a beau porter sur
        // un trou de 30 s, elle porte sur ce qu'il **contient** : on ne fabrique pas de texte sur notre
        // propre silence (§2.1).
        XCTAssertEqual(
            UnitSpeechRecovery.toReplay(
                segments: [segment(0, 270, "couvre")], duration: 300, silences: [270...297]),
            [],
            "\(contrat) — 3 s de contenu hors silence ne déclenchent aucun rejeu, même sur 30 s de trou")
    }

    // MARK: - (e) Le rognage ne perd rien et ne régresse pas

    /// La règle **locale et nouvelle** du §2.1 : les segments rejoués sont rognés à l'intervalle
    /// rejoué ; un segment de l'unité, lui, n'est **jamais** rogné ni écarté. La règle 3 de
    /// `TranscriptAssembly` (le second écarté **en entier**) jetterait ici le texte récupéré dès qu'il
    /// touche un segment existant — d'où une règle distincte, appliquée aux seuls rejoués.
    ///
    /// **Trois armes dans un seul cas, et pourquoi.** Un rejoué rogné des **deux** côtés de
    /// l'intervalle le recouvre en entier : plus aucun autre rejoué gardé ne peut tenir à côté de lui
    /// dans le même appel. Demander dans **un seul** `merging` le rognage des deux côtés *et* un
    /// jumeau gardé au milieu de l'intervalle demande donc deux choses incompatibles — le résultat
    /// contiendrait une paire qui se chevauche, ce que le même cas interdit deux lignes plus bas
    /// (c'est le finding 1 de la revue du round 1). Les trois propriétés sont donc exercées par trois
    /// appels, chacun recousu et vérifié strictement croissant.
    func testLeRognageNePerdRienEtNeRegressePas() {
        let unites = [segment(0, 100, "avant"), segment(200, 300, "apres")]
        // Le trou de l'unité est `[100, 200]` : c'est l'intervalle qu'on a décidé de rejouer.
        XCTAssertEqual(
            UnitSpeechRecovery.uncovered(segments: unites, duration: 300), [100...200],
            "\(contrat) — le trou de l'unité de ce cas vaut `[100, 200]`")

        // ARME 1 — un rejoué qui déborde des **deux** côtés est rogné aux bornes de l'intervalle, et
        // un rejoué entièrement hors de l'intervalle devient vide : il disparaît.
        let debordants = [
            segment(90, 210, "recouvre"),  // 90 < 100 et 210 > 200 → rogné à `(100, 200)`
            segment(250, 280, "hors"),  // entièrement après l'intervalle → vide, écarté
        ]
        let rognes = UnitSpeechRecovery.merging(
            unit: unites, replayed: debordants, in: 100...200, duration: 300)

        XCTAssertEqual(
            rognes.map { $0.text }, ["avant", "recouvre", "apres"],
            "\(contrat) — « hors » (vide après rognage) doit disparaître, « recouvre » rester")
        XCTAssertEqual(
            rognes.map { $0.start }, [0, 100, 200],
            "\(contrat) — « recouvre » commence à 100 : son débordement gauche est rogné")
        XCTAssertEqual(
            rognes.map { $0.end }, [100, 200, 300],
            "\(contrat) — « recouvre » finit à 200 : son débordement droit est rogné")

        // Les segments de l'unité sont **intacts** : bornes d'origine, ni rognés ni écartés.
        let avant = rognes.first { $0.text == "avant" }
        XCTAssertEqual(avant?.start ?? -1, 0, "\(contrat) — « avant » ne se rogne pas")
        XCTAssertEqual(avant?.end ?? -1, 100, "\(contrat) — « avant » ne se rogne pas")
        let apres = rognes.first { $0.text == "apres" }
        XCTAssertEqual(apres?.start ?? -1, 200, "\(contrat) — « apres » ne se rogne pas")
        XCTAssertEqual(apres?.end ?? -1, 300, "\(contrat) — « apres » ne se rogne pas")

        // L'invariant du critère 9 survit à la reprise — et c'est lui qui rend l'ancien attendu
        // du cas (e) impossible (voir la doc de ce test).
        verifieCroissanceStricte(rognes, "après recousage (rognage des deux côtés)")

        // ARME 2 — deux rejoués au **même début** : un seul est gardé (règle 3). Le texte gardé
        // n'est pas gelé : le tri de `Array.sorted` n'est pas garanti stable, et exiger une chaîne
        // précise ferait dépendre le vert d'une propriété non promise.
        let jumeaux = [segment(150, 160, "premier"), segment(150, 160, "second")]
        let recousus = UnitSpeechRecovery.merging(
            unit: unites, replayed: jumeaux, in: 100...200, duration: 300)

        XCTAssertEqual(
            recousus.count, 3,
            "\(contrat) — deux rejoués au même début n'en laissent qu'un (ici, plus les 2 unités)")
        XCTAssertEqual(recousus.map { $0.start }, [0, 150, 200], contrat)
        XCTAssertEqual(recousus.map { $0.end }, [100, 160, 300], contrat)
        let gardes = recousus.filter { $0.start == 150 }
        XCTAssertEqual(gardes.count, 1, "\(contrat) — un seul des deux jumeaux est gardé")
        XCTAssertTrue(
            ["premier", "second"].contains(gardes.first?.text ?? ""),
            "\(contrat) — le gardé est l'un des deux jumeaux (\(gardes.first?.text ?? "aucun"))")
        verifieCroissanceStricte(recousus, "après recousage (jumeaux au même début)")

        // ARME 3 — deux rejoués qui se **chevauchent** à débuts différents : le premier gardé, l'autre
        // écarté (règle 3 gelée : « même début **ou** chevauchement »). Sans cette arme, les deux
        // lectures de la règle restent indistinguables et le contrat ne dit plus rien d'observable
        // sur le chevauchement — tout en gardant la croissance stricte en sortie.
        let chevauchants = [segment(120, 180, "long"), segment(150, 160, "court")]
        let recoususChevauchants = UnitSpeechRecovery.merging(
            unit: unites, replayed: chevauchants, in: 100...200, duration: 300)

        XCTAssertEqual(
            recoususChevauchants.map { $0.text }, ["avant", "long", "apres"],
            "\(contrat) — « court » recule sur « long » : le premier gardé, le second écarté")
        XCTAssertEqual(recoususChevauchants.map { $0.start }, [0, 120, 200], contrat)
        XCTAssertEqual(recoususChevauchants.map { $0.end }, [100, 180, 300], contrat)
        verifieCroissanceStricte(recoususChevauchants, "après recousage (rejoués qui se chevauchent)")
    }

    // MARK: - (f) Les silences du lot 7 sont ramenés au temps de l'unité

    /// Les silences sont en secondes de **l'audio décodé** (temps absolu, lot 7) ; les segments d'une
    /// unité sont horodatés depuis **son** début. Sans cette conversion, l'intersection de
    /// ``UnitSpeechRecovery/toReplay(segments:duration:silences:minimum:)`` serait vide presque partout
    /// et *tous* les trous seraient rejoués, silences compris.
    func testLesSilencesSontRamènesAuTempsDeLUnité() {
        let uniteTestee = unite(debut: 300, duree: 300)  // temps unité = [300, 600] absolu
        let silences = [
            250.0...320.0,  // à cheval sur le début → rogné puis translaté : `[0, 20]`
            100.0...200.0,  // entièrement avant l'unité → disparaît
            700.0...800.0,  // entièrement après l'unité → disparaît
            400.0...450.0,  // intérieur → mêmes bornes relatives : `[100, 150]`
            580.0...700.0,  // à cheval sur la fin → rogné : `[280, 300]`
            200.0...300.0,  // ne touche l'unité qu'en 300 → dégénéré après intersection → écarté
        ]

        XCTAssertEqual(
            UnitSpeechRecovery.rebased(silences: silences, on: uniteTestee),
            [0...20, 100...150, 280...300], contrat)
    }
}
