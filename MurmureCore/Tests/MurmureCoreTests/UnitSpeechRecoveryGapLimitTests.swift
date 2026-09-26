import XCTest
@testable import MurmureCore

/// Contrat rouge de la carte QA `t_7540c725` — **le rattrapage d'un trou de 5 à 20 s qui porte de la
/// parole** (critère 9 sous 97 % en chemin **lien** ; carte `dev` fille `t_435e50b8`).
///
/// **Le défaut mesuré, et pourquoi il n'était couvert par personne.** Le rattrapage du lot 8-R ne
/// rejoue que les trous dont le **contenu hors silence** atteint
/// ``UnitSpeechRecovery/minimumRecoverable`` (20 s). Or la borne haute des **pauses naturelles** est
/// **5,0 s** (plan §2.1) : tout trou entre 5,0 s et 20 s qui porte de la parole est perdu
/// **définitivement**. Mesuré sur la vidéo A du plan (`NwGHNdbw1Ts`, 2 292,544 s décodées en chemin
/// lien) : chaque passe **lien** porte **2 à 4 trous > 5,0 s et < 20 s** — 12,040 à 42,840 s par
/// passe que rien ne rattrape — et le trou de **6,900 s** `[1363,400 → 1370,300)` est **identique
/// dans les six passes** ; les 88,784 s de trous d'une passe portent **68,100 s** au-dessus de
/// −30 dB, c'est-à-dire de la parole. Le seuil du critère 9 (97 %) n'est pas en cause et n'est pas
/// touché : la couverture d'une passe **fichier local** atteint 97,0–98,1 % sur le même audio, avec
/// le même modèle (`openai_whisper-large-v3-v20240930_turbo`).
///
/// **La règle que ces cas gèlent** (elle vient de la carte `dev` `t_435e50b8`) : un trou qui porte
/// **plus de 5,0 s** de parole est rejoué ; un trou qui en porte **moins** peut rester — c'est une
/// pause naturelle. « Porte de la parole » garde le sens du §2.1, celui de la décision existante :
/// `longueur(trou) − longueur(silences ∩ trou)`, les silences du lot 7 (`-30 dB / 0,5 s`). Le
/// garde-fou du §2.1 reste donc entier : un trou de 30 s dont 27 s sont déclarées silence ne se
/// rejoue **pas** (on ne fabrique pas de texte sur notre propre silence).
///
/// **La borne exacte (5,0 s pile, incluse ou exclue) n'est pas gelée ici.** Le contrat gèle les deux
/// populations qui l'encadrent — `4,0 s` : non rejoué ; `6,0 s` : rejoué — et laisse la convention du
/// bord à l'implémentation. Trancher ce point ici déciderait à la place du `dev` d'un détail dont ni
/// le plan ni la carte ne disent rien ; ce qui est mesuré, c'est que **6,9 s** doit passer.
///
/// **Amendement du contrat 8-R, et pourquoi il est inévitable.** `UnitSpeechRecoveryTests` (carte QA
/// L8-R `t_e37a408c`, vert) gelait la borne à **20 s** et affirmait qu'un trou de **12 s** ne se
/// rejoue pas — l'exact contraire de la règle ci-dessus, et de la carte `dev` qui la consomme. Sa
/// clause (d) est donc **amendée, et elle seule** : elle ne garde que la distinction
/// **matière / longueur du trou**, que les deux valeurs de borne respectent. Deux contrats
/// contradictoires dans la même cible `swift test` ne sont pas un contrat : la carte `dev` ne peut
/// pas rendre vert ce que l'un gèle et ce que l'autre interdit.
///
/// **Chaque cas porte un contrôle positif**, dans le même test et sur la même unité : un cas dont la
/// seule assertion attendue est `[]` serait **vert** avant toute implémentation (une sentinelle
/// `return []` le satisfait) et ne prouverait rien.
///
/// **Clauses de bout en bout (couverture et trous d'une passe réelle).** Elles ne sont pas des tests
/// unitaires et ne vivent donc pas ici : elles se mesurent sur un **document** produit par une passe
/// réelle, avec le vérificateur `QA-7540-verifie-trous.py` livré avec ce contrat (trois clauses : C1
/// `couverture ≥ 0,97`, C2 `aucun trou de contenu hors silence > 5,0 s`, C3 `aucun trou ≥ 20 s`).
/// Mesure du rouge, sur les documents déjà sur disque : `l8-t6` (passe lien, octets livrés) →
/// couverture **0,961273**, trois trous > 5,0 s (14,160 / 6,900 / 5,140 s) → C1 et C2 **rouges** ;
/// `yt-wav-2026-09-22-66522b15` (passe fichier, même audio) → couverture 0,970410, un trou de
/// 24,400 s → C1 verte, C2 **rouge**. Aucun des deux ne porte de trou ≥ 20 s dans la passe lien :
/// C3 y est déjà verte, et le reste (non-régression du 30 s du lot 8-R).
final class UnitSpeechRecoveryGapLimitTests: XCTestCase {
    private let contrat = "contrat t_7540c725 : trou de 5 à 20 s non rattrapé"

    // MARK: - Outils

    private func segment(_ debut: Double, _ fin: Double, _ texte: String) -> TranscriptSegment {
        TranscriptSegment(start: debut, end: fin, text: texte)
    }

    /// La reprise telle que la décision de ``UnitSpeechRecovery/toReplay(segments:duration:silences:minimum:)``
    /// l'alimente : chaque intervalle décidé est rejoué, et le moteur rend **un** segment qui couvre
    /// cet intervalle (c'est le cas nominal de la seconde passe du §2.1, bornée par la taille de
    /// l'intervalle). Aucun indexage : une décision vide ne doit pas faire tomber le binaire de tests
    /// entier, elle doit rendre l'unité inchangée — donc son trou.
    private func recousu(
        unite: [TranscriptSegment], rejoues: [ClosedRange<Double>], duree: Double
    ) -> [TranscriptSegment] {
        rejoues.reduce(unite) { liste, intervalle in
            UnitSpeechRecovery.merging(
                unit: liste,
                replayed: [segment(intervalle.lowerBound, intervalle.upperBound, "récupéré")],
                in: intervalle,
                duration: duree)
        }
    }

    // MARK: - Cas nominal : une fenêtre sautée de 6, 12 ou 19 s est rejouée

    /// Le plus proche du mesuré : le trou `[1363,400 → 1370,300)` de la vidéo A fait **6,900 s** et
    /// porte de la parole. Ici un trou de **6,0 s** en fin d'unité, sans silence déclaré (sur cette
    /// vidéo, `silencedetect` `-30 dB / 0,5 s` rend **0 silence** sur les deux décodages : la carte de
    /// silence est vide). Le trou est décidé, puis **il disparaît** de l'unité recousue.
    func testUnTrouDe6SecondesQuiPorteDeLaParoleEstRejoue() {
        let duree = 300.0
        let unite = [segment(0, 294, "couvre")]

        XCTAssertEqual(
            UnitSpeechRecovery.uncovered(segments: unite, duration: duree), [294...300],
            "\(contrat) — cette unité porte un seul trou, `[294, 300]`, de 6,0 s")

        let rejoues = UnitSpeechRecovery.toReplay(segments: unite, duration: duree, silences: [])
        XCTAssertEqual(
            rejoues, [294...300],
            "\(contrat) — un trou de 6,0 s sans silence mesuré porte de la parole : il doit être rejoué")

        XCTAssertEqual(
            UnitSpeechRecovery.uncovered(
                segments: recousu(unite: unite, rejoues: rejoues, duree: duree), duration: duree),
            [],
            "\(contrat) — après reprise, le trou de 6,0 s a disparu : `uncovered` rend `[]`")
    }

    /// Le même cas à **12,0 s**. La passe lien mesurée porte 2 à 4 trous par passe entre 5,0 s et
    /// 20 s, dont plusieurs de cet ordre : c'est la population que le contrat doit rendre impossible.
    func testUnTrouDe12SecondesQuiPorteDeLaParoleEstRejoue() {
        let duree = 300.0
        let unite = [segment(0, 288, "couvre")]

        let rejoues = UnitSpeechRecovery.toReplay(segments: unite, duration: duree, silences: [])
        XCTAssertEqual(
            rejoues, [288...300],
            "\(contrat) — un trou de 12,0 s sans silence mesuré porte de la parole : il doit être rejoué")

        XCTAssertEqual(
            UnitSpeechRecovery.uncovered(
                segments: recousu(unite: unite, rejoues: rejoues, duree: duree), duration: duree),
            [],
            "\(contrat) — après reprise, le trou de 12,0 s a disparu : `uncovered` rend `[]`")
    }

    /// Le même cas à **19,0 s** : le haut de la population aveugle, juste sous `minimumRecoverable`
    /// (20 s) que le lot 8-R ne franchissait pas.
    func testUnTrouDe19SecondesQuiPorteDeLaParoleEstRejoue() {
        let duree = 300.0
        let unite = [segment(0, 281, "couvre")]

        let rejoues = UnitSpeechRecovery.toReplay(segments: unite, duration: duree, silences: [])
        XCTAssertEqual(
            rejoues, [281...300],
            "\(contrat) — un trou de 19,0 s sans silence mesuré porte de la parole : il doit être rejoué")

        XCTAssertEqual(
            UnitSpeechRecovery.uncovered(
                segments: recousu(unite: unite, rejoues: rejoues, duree: duree), duration: duree),
            [],
            "\(contrat) — après reprise, le trou de 19,0 s a disparu : `uncovered` rend `[]`")
    }

    /// Un trou **au milieu** de l'unité — la forme mesurée (`[1363,400 → 1370,300)` est encadré de
    /// segments) : la décision rend **l'intervalle où le trou est**, jamais « une douzaine de secondes
    /// quelque part ». C'est la propriété qui rend la reprise chirurgicale.
    func testUnTrouDe12SecondesAuMilieuDUneUniteEstRejoueALEndroitOuIlEst() {
        let duree = 300.0
        let unite = [segment(0, 135, "avant"), segment(147, 300, "apres")]

        XCTAssertEqual(
            UnitSpeechRecovery.uncovered(segments: unite, duration: duree), [135...147],
            "\(contrat) — le trou de cette unité vaut `[135, 147]`, pas la queue de l'unité")

        let rejoues = UnitSpeechRecovery.toReplay(segments: unite, duration: duree, silences: [])
        XCTAssertEqual(
            rejoues, [135...147],
            "\(contrat) — le trou est rejoué **là où il est** : `[135, 147]`, et rien d'autre")

        let recousus = recousu(unite: unite, rejoues: rejoues, duree: duree)
        XCTAssertEqual(
            UnitSpeechRecovery.uncovered(segments: recousus, duration: duree), [],
            "\(contrat) — après reprise, aucun trou ne subsiste dans l'unité")
        XCTAssertEqual(
            recousus.map { $0.start }, [0, 135, 147],
            "\(contrat) — le segment récupéré se place **entre** les deux segments de l'unité")
    }

    // MARK: - Cas limite : la pause naturelle, sous le plafond de 5,0 s

    /// La borne du plan §2.1 : la plus grande **pause naturelle** du document accepté fait 5,0 s.
    /// Un trou de 4,0 s peut donc rester. Les deux assertions de ce cas vont **ensemble** : la
    /// première empêche la règle de dégénérer en « on rejoue tout » (ce qui remplirait les pauses de
    /// texte inventé et ferait cesser le critère 9 de mesurer quoi que ce soit, §2.1), la seconde
    /// empêche la borne de rester à 20 s — c'est le défaut même.
    func testUnePauseNaturelleDe4SecondesPeutResterEtUnTrouDe6SecondesEstRejoue() {
        let duree = 300.0
        let pauseNaturelle = [segment(0, 296, "couvre")]
        let trouDUneFenetre = [segment(0, 294, "couvre")]

        XCTAssertEqual(
            UnitSpeechRecovery.toReplay(
                segments: pauseNaturelle, duration: duree, silences: []),
            [],
            "\(contrat) — un trou de 4,0 s est une pause naturelle (plafond 5,0 s) : il peut rester")

        XCTAssertEqual(
            UnitSpeechRecovery.toReplay(
                segments: trouDUneFenetre, duration: duree, silences: []),
            [294...300],
            "\(contrat) — un trou de 6,0 s, lui, n'est pas une pause naturelle : il doit être rejoué")
    }

    // MARK: - Non-régression : le trou de 30 s du lot 8-R et le garde-fou du silence restent

    /// **Aucune régression du lot 8-R.** Le cas mesuré qui a motivé `UnitSpeechRecovery` : une unité
    /// de 300 s dont les segments couvrent `[0, 270)` — le moteur a sauté la dernière fenêtre — et
    /// **aucun silence** déclaré. Le trou de 30,0 s reste rejoué.
    func testLeTrouDe30SecondesDuLot8RResteRejoue() {
        let duree = 300.0
        let couvre270 = [segment(0, 135, "début"), segment(135, 270, "milieu")]

        XCTAssertEqual(
            UnitSpeechRecovery.toReplay(segments: couvre270, duration: duree, silences: []),
            [270...300],
            "\(contrat) — le trou de 30,0 s du lot 8-R reste rejoué : aucune régression")
    }

    /// **Le garde-fou du §2.1 reste entier.** La décision porte sur la **matière** hors silence, pas
    /// sur la longueur du trou : passer la borne de 20 s à 5,0 s ne doit pas se mettre à rejouer des
    /// trous qui sont du silence. Le contrôle positif du même cas est dans le même test : le **même**
    /// trou de 30 s, avec 10 s de silence déclaré au lieu de 27, porte 20 s de matière et se rejoue.
    func testUnTrouDe30SecondesDont27SecondesSontDuSilenceNEstPasRejoue() {
        let duree = 300.0
        let couvre270 = [segment(0, 270, "couvre")]

        XCTAssertEqual(
            UnitSpeechRecovery.toReplay(
                segments: couvre270, duration: duree, silences: [270...297]),
            [],
            "\(contrat) — 3,0 s de matière hors silence ne déclenchent aucun rejeu, même sur 30,0 s de trou")

        XCTAssertEqual(
            UnitSpeechRecovery.toReplay(
                segments: couvre270, duration: duree, silences: [270...280]),
            [270...300],
            "\(contrat) — le même trou, avec 20,0 s de matière hors silence, est rejoué (contrôle positif)")
    }
}
