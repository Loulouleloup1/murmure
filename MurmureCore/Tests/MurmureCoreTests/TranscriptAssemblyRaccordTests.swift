import XCTest
@testable import MurmureCore

/// Contrat rouge de la carte QA `t_f53c4c72` — **l'assemblage cesse de perdre du contenu sur un
/// ε-chevauchement** (règle 3 de `TranscriptAssembly`, contrat **gelé du lot 3**, amendé ici **par la
/// mesure** ; carte `dev` fille `t_a8613fec`).
///
/// **Le défaut mesuré.** La règle 3 écartait **le segment entier** dès que son `start` tombait avant
/// le `end` du segment gardé, quelle que soit la taille du chevauchement. WhisperKit horodate deux
/// segments voisins avec quelques microsecondes de recouvrement ; écartés en entier, ils laissent un
/// trou de la longueur du segment perdu. Sortie du harnais, **octets livrés du lot 3**, passe
/// `sonde-assemblage` (chaîne d'acquisition et de transcription réelle, vidéo A du plan) :
///
///     [sonde435e-assemblage] ecarte chevauchement=1.52587890625e-05 s \
///         segment=[1363.3999938964844, 1370.1599884033203) duree_ecartee=6.7599945068359375 \
///         garde=[1360.9400024414062, 1363.4000091552734)
///
/// **Ce que cela coûte, sur les cinq passes lien de la vidéo A** (documents `a1`, `sonde-assemblage`,
/// `sonde-l1`, `sonde-l2` de la carte `t_435e50b8`, et `f53-p1`, la passe rejouée par cette carte ;
/// `NwGHNdbw1Ts`, 2 292,544 s, `openai_whisper-large-v3-v20240930_turbo`) :
/// **13 trous ≥ 1,4 s** par passe, aux **mêmes bornes** dans les cinq
/// (`[81,700 → 85,560)`, `[228,400 → 230,640)`, `[472,400 → 475,720)`, `[513,900 → 516,280)`,
/// `[890,800 → 892,360)`, `[985,700 → 988,660)`, `[1098,900 → 1100,500)`, `[1363,400 → 1370,300)`,
/// `[1402,900 → 1407,600)`, `[1490,400 → 1494,240)`, `[1745,700 → 1749,580)`,
/// `[1863,800 → 1867,360)`, `[1966,900 → 1972,040)`). Ces treize trous cumulent **45,939812 s**
/// **dans chacune des cinq passes** ; ce que les treize raccords **ajoutent** réellement à la
/// couverture — le gain de la classe ε, mesuré sur les documents, pas déduit — vaut **45,099831 s**
/// dans les cinq (un peu moins que le cumul des trous : chaque trou se prolonge au-delà de la fin du
/// raccord, et ces **0,839981 s** restent ouverts). Les passes se lisent **0,967310 / 0,967327 /
/// 0,967449 / 0,967458 / 0,966394** et passent à **0,986982089 / 0,986999540 / 0,987121677 /
/// 0,987130403 / 0,986066082** : toutes au-dessus de **0,97**, la plus basse à **1,61 point** du
/// seuil. Le **plus grand trou résiduel** vaut alors **0,800003 s**
/// dans les quatre premières et **1,040000 s** dans la cinquième — le trou **naturel** de
/// `[13,120000 → 14,160000)`, que cette correction ne referme pas et ne prétend pas refermer. La
/// classe **franche** ne referme
/// **rien** (`gain de la classe franche = 0,000000 s`) : c'est bien la classe ε, et elle seule, qui
/// coûte la couverture. Le seuil du critère 9 (**97 %**) est **atteignable par cette seule
/// correction** — il n'est ni touché, ni contesté ici.
///
/// **La règle amendée** (texte neuf dans `TranscriptAssembly.swift`). Deux segments qui se chevauchent
/// ne sont la même phrase rendue deux fois **que si le chevauchement atteint la tolérance**
/// (``TranscriptAssembly/chevauchementEcartMinimal``, `1,0 s`) : au-delà, le premier est gardé et le
/// second écarté **dans son entier** — c'est le dédoublonnage des frontières, inchangé. En deçà,
/// c'est un **raccord** : le second est **gardé** et **rogné à `dernier.end`**, son texte reste
/// entier, et s'il ne reste rien il n'est pas rendu (règle 4). La tolérance sépare deux populations
/// **mesurées**, distantes d'un facteur ≈ 58 000 : les 13 chevauchements de 3,8 × 10⁻⁶ à 3,1 × 10⁻⁵ s
/// qui coûtaient 45,939812 s, et les 5 de 1,82 à 4,50 s qui ne coûtaient **rien** (leur intervalle
/// était **entièrement contenu** dans le gardé).
///
/// **Pourquoi le rognage, et pas deux segments qui se chevauchent.** Le rognage est ce qui garde
/// vraie la seconde moitié de la règle 3 — « aucune paire de segments qui se chevauchent » — et donc
/// les invariants que le reste du chantier consomme déjà : `verifierInvariants` du contrat du lot 3,
/// `croissanceStricte(sansRecouvrement:)` et la fait que « la somme des durées **est** l'union » du
/// harnais de mesure (`Fiabilite.swift`). Garder les deux segments sans rogner ferait tomber ces
/// trois contrôles : c'est la raison du rognage, pas une préférence de style.
///
/// **Les bornes sont mesurées, les textes sont synthétiques.** Le harnais ne journalise aucun texte
/// (AGENTS.md : jamais de transcription dans un journal) : les bornes des cas (a), (b), (c) et de la
/// tolérance sont **celles des octets livrés**, relevées dans la sortie du harnais, et les textes sont
/// fabriqués ici — ils ne servent qu'à vérifier qu'aucun segment n'a disparu et qu'aucun n'est
/// dupliqué. **Une exception, déclarée** : le cas limite du rognage (le dernier) porte un raccord
/// **construit**, parce qu'aucun couple mesuré n'est à la fois **sous** la tolérance et **entièrement
/// contenu** dans le gardé — son commentaire le dit, et donne sa raison d'être.
///
/// **Clause de bout en bout (couverture d'une passe lien ≥ 97 %).** Elle ne se mesure pas sur une
/// unité mais sur le **document** d'une passe réelle, et elle vit dans le vérificateur
/// `QA-7540-verifie-trous.py` livré avec ce contrat (clauses C1 `couverture ≥ 0,97`, C2 `aucun trou
/// de contenu hors silence > 5,0 s`, C3 `aucun trou ≥ 20 s`, plus la clause C4 ajoutée par cette
/// carte : `aucun trou ≥ 1,4 s`, l'observation documentaire du défaut corrigé ici — 1,4 s et non
/// 1,0 s, parce que la passe `f53-p1` porte un trou **naturel** de 1,040000 s que personne ne sait
/// fermer, quand le plus petit trou du défaut vaut 1,559967 s). Mesure du rouge, sur les **cinq**
/// documents des passes lien : C1 en échec cinq fois sur cinq (0,966394 / 0,967310 / 0,967327 /
/// 0,967449 / 0,967458 < 0,97) et C4 en échec cinq fois sur cinq (13 trous ≥ 1,4 s, cumul
/// **45,939812 s dans les cinq passes** — le gain que le raccord apporte à la couverture vaut, lui,
/// 45,099831 s dans les cinq). C4 ne remplace ni C2 ni C3 : la
/// borne de **5,0 s** livrée par `t_435e50b8` et le seuil de **20 s** du lot 8-R sont inchangés.
///
/// **Une observation que cette carte laisse au balayage.** La passe `f53-p1` porte un trou de
/// **1,040000 s** `[13,120000 → 14,160000)` qu'**aucun** segment écarté par la règle 3 n'explique :
/// c'est une perte hors de la classe corrigée ici (elle disparaît des quatre autres passes), et elle
/// est déclarée telle quelle, avec ses bornes, plutôt que fondue dans le seuil de C4.
///
/// **Chaque cas porte un contrôle positif**, dans le même test : un cas dont la seule assertion
/// attendue serait l'absence de trou serait **vert** avant toute implémentation (un `merge` rendant
/// `[]` le satisferait) et ne prouverait rien.
final class TranscriptAssemblyRaccordTests: XCTestCase {
    private let contrat = "contrat t_f53c4c72 : l'assemblage perd du contenu sur un ε-chevauchement"

    // MARK: - Outils

    /// Une unité du plan portant des segments donnés en **temps absolus** (le passage en local, que
    /// fait le moteur, est appliqué ici : `local = absolu − début de l'unité`). Les bornes des cas
    /// restent ainsi **celles des octets livrés**, lisibles telles quelles.
    private func unite(
        depart: Double, duree: Double = 300, quality: UnitBoundary.Quality = .forced,
        segments: [(Double, Double, String)]
    ) -> TranscribedUnit {
        TranscribedUnit(
            boundary: UnitBoundary(start: depart, duration: duree, quality: quality),
            segments: segments.map { TranscriptSegment(start: $0.0 - depart, end: $0.1 - depart, text: $0.2) })
    }

    /// L'union des intervalles `[start, end)` — la « couverture » du critère 9, recalculée ici
    /// indépendamment de l'assemblage (elle ne somme **pas** les durées : deux segments qui se
    /// chevauchent ne comptent qu'une fois).
    private func couverture(_ segments: [TranscriptSegment]) -> Double {
        var total = 0.0
        var finCourante = -Double.infinity
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if segment.end <= finCourante { continue }
            total += segment.end - max(segment.start, finCourante)
            finCourante = segment.end
        }
        return total
    }

    /// Le **complément** de l'union des segments, borné à `[debut, fin)` : les intervalles non
    /// couverts, dans l'ordre. C'est la mesure des « trous » du document assemblé.
    private func trous(_ segments: [TranscriptSegment], de debut: Double, a fin: Double) -> [(Double, Double)] {
        var trous: [(Double, Double)] = []
        var curseur = debut
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if segment.start > curseur { trous.append((curseur, segment.start)) }
            curseur = max(curseur, segment.end)
        }
        if curseur < fin { trous.append((curseur, fin)) }
        return trous
    }

    private func description(_ segments: [TranscriptSegment]) -> String {
        segments.map { "[\($0.start), \($0.end)) « \($0.text) »" }.joined(separator: ", ")
    }

    /// Les invariants du critère 9 sur toute sortie de l'assemblage : `start < end`, débuts
    /// strictement croissants, et **aucune paire de segments qui se chevauchent** (règles 2 et 3 —
    /// la seconde moitié de la règle 3 n'est **pas** amendée).
    private func verifierInvariants(_ segments: [TranscriptSegment], contexte: String) {
        for (index, segment) in segments.enumerated() {
            XCTAssertTrue(
                segment.start < segment.end,
                "\(contrat) — \(contexte) : le segment \(index) va de \(segment.start) s à \(segment.end) s : \(description(segments))")
            if index > 0 {
                XCTAssertGreaterThan(
                    segment.start, segments[index - 1].start,
                    "\(contrat) — \(contexte) : le début du segment \(index) (\(segment.start) s) n'est pas strictement supérieur à celui du précédent (\(segments[index - 1].start) s) : \(description(segments))")
            }
        }
        for premier in 0..<segments.count where premier + 1 < segments.count {
            for suivant in (premier + 1)..<segments.count {
                XCTAssertFalse(
                    segments[suivant].start < segments[premier].end,
                    "\(contrat) — \(contexte) : les segments \(premier) et \(suivant) se chevauchent : \(description(segments))")
            }
        }
    }

    // MARK: - Les raccords mesurés sur les octets livrés

    /// Les **13 raccords** que la règle 3 écartait dans chaque passe lien de la vidéo A : pour
    /// chacun, l'unité du plan qui le porte (son début de frontière), le segment **gardé** et le
    /// segment **écarté**, en temps **absolus** — bornes relevées dans la sortie du harnais des
    /// octets livrés (13 lignes `ecarte chevauchement=… segment=[…] garde=[…]` par passe, avec
    /// `chevauchement < 1 s`).
    private static let raccordsMesures: [(unite: Double, garde: (Double, Double), raccord: (Double, Double))] = [
        (0, (79.06000518798828, 81.70000457763672), (81.69999694824219, 85.55999755859375)),
        (0, (226.5, 228.40000915527344), (228.39999389648438, 230.63999938964844)),
        (300, (470.760009765625, 472.40000915527344), (472.3999938964844, 475.7200012207031)),
        (300, (513.1800079345703, 513.9000091552734), (513.8999938964844, 516.0599975585938)),
        (600, (888.3999938964844, 890.8000183105469), (890.7999877929688, 892.2200012207031)),
        (900, (983.1600036621094, 985.7000045776367), (985.6999969482422, 988.6599960327148)),
        (900, (1096.8200073242188, 1098.9000091552734), (1098.8999938964844, 1100.5)),
        (1200, (1360.9400024414062, 1363.4000091552734), (1363.3999938964844, 1370.1599884033203)),
        (1200, (1400.3400115966797, 1402.9000091552734), (1402.8999938964844, 1407.3999938964844)),
        (1200, (1485.8800048828125, 1490.4000244140625), (1490.3999938964844, 1494.239990234375)),
        (1500, (1742.1000061035156, 1745.7000122070312), (1745.6999969482422, 1749.5800018310547)),
        (1800, (1860.9800033569336, 1863.8000030517578), (1863.7999992370605, 1867.3600006103516)),
        (1800, (1963.8600006103516, 1966.9000091552734), (1966.8999938964844, 1971.8999938964844)),
    ]

    /// Les **5 segments** que la règle 3 écartait sur un chevauchement **≥ 1 s** dans la même passe :
    /// leur intervalle était **entièrement contenu** dans le segment gardé — les écarter ne coûtait
    /// rien, et c'est ce que le dédoublonnage doit continuer de faire. Le segment gardé n'est donc
    /// écrit **qu'une fois** par unité (c'est un seul segment de la passe, que trois segments
    /// chevauchaient tour à tour).
    private static let doublonsMesures: [(unite: Double, garde: (Double, Double), ecartes: [(Double, Double)])] = [
        (0, (47.599998474121094, 52.0), [(47.619998931884766, 47.69999694824219)]),
        (0, (131.60000610351562, 136.12001037597656), [(131.6199951171875, 132.52000427246094)]),
        (1200, (1342.1000061035156, 1345.0400085449219),
         [
            (1342.1199951171875, 1342.1999969482422),
            (1342.2200012207031, 1343.2200012207031),
            (1343.2200012207031, 1344.2200012207031),
         ]),
    ]

    /// Les unités de la passe, portant chacune ses segments **absolus** convertis en temps locaux :
    /// exactement la forme sous laquelle le moteur les rend (elles sont transcrites une par une).
    private static func unites(
        _ couples: [(unite: Double, garde: (Double, Double), second: (Double, Double))]
    ) -> [TranscribedUnit] {
        var parUnite: [Double: [(Double, Double, String)]] = [:]
        for (index, couple) in couples.enumerated() {
            parUnite[couple.unite, default: []].append((couple.garde.0, couple.garde.1, "garde-\(index)"))
            parUnite[couple.unite, default: []].append((couple.second.0, couple.second.1, "second-\(index)"))
        }
        return parUnite.keys.sorted().map { depart in
            let duree = depart < 2100 ? 300.0 : 192.54399999999987
            return TranscribedUnit(
                boundary: UnitBoundary(start: depart, duration: duree, quality: .forced),
                segments: parUnite[depart, default: []].map {
                    TranscriptSegment(start: $0.0 - depart, end: $0.1 - depart, text: $0.2)
                })
        }
    }

    private static func unitesDoublons() -> [TranscribedUnit] {
        var parUnite: [Double: [(Double, Double, String)]] = [:]
        for (index, couple) in doublonsMesures.enumerated() {
            parUnite[couple.unite, default: []].append((couple.garde.0, couple.garde.1, "garde-\(index)"))
            for (rang, ecarte) in couple.ecartes.enumerated() {
                parUnite[couple.unite, default: []].append((ecarte.0, ecarte.1, "doublon-\(index)-\(rang)"))
            }
        }
        return parUnite.keys.sorted().map { depart in
            TranscribedUnit(
                boundary: UnitBoundary(start: depart, duration: 300, quality: .forced),
                segments: parUnite[depart, default: []]
                    .sorted { $0.0 < $1.0 }
                    .map { TranscriptSegment(start: $0.0 - depart, end: $0.1 - depart, text: $0.2) })
        }
    }

    private var unitesDesRaccords: [TranscribedUnit] {
        Self.unites(Self.raccordsMesures.map { (unite: $0.unite, garde: $0.garde, second: $0.raccord) })
    }

    private var unitesDesDoublons: [TranscribedUnit] { Self.unitesDoublons() }

    /// Ce que l'assemblage a **perdu** : l'union des intervalles d'entrée **moins** l'union de ses
    /// segments. C'est là que se lisent les écarts que la règle 3 laissait — `1,420013 s` à
    /// `6,899979 s` sur les quatre passes mesurées, `45,939812 s` en tout —, et c'est la mesure
    /// honnête : un flux assemblé peut avoir des trous légitimes là où l'entrée n'avait rien.
    private func pertes(_ entree: [TranscriptSegment], _ sortie: [TranscriptSegment]) -> [(Double, Double)] {
        var fusion: [(Double, Double)] = []
        for segment in entree.sorted(by: { $0.start < $1.start }) {
            if let dernier = fusion.last, segment.start <= dernier.1 {
                fusion[fusion.count - 1].1 = max(dernier.1, segment.end)
            } else {
                fusion.append((segment.start, segment.end))
            }
        }
        var perdu: [(Double, Double)] = []
        let couverts = sortie.sorted(by: { $0.start < $1.start })
        for (debut, fin) in fusion {
            var curseur = debut
            for couvert in couverts where couvert.end > debut && couvert.start < fin {
                if couvert.start > curseur { perdu.append((curseur, min(couvert.start, fin))) }
                curseur = max(curseur, min(couvert.end, fin))
                if curseur >= fin { break }
            }
            if curseur < fin { perdu.append((curseur, fin)) }
        }
        return perdu
    }

    // MARK: - (a) Un segment adjacent à un chevauchement < 1 s n'est pas écarté

    /// **Le cas obligatoire de la carte, et le plus gros.** Le segment écarté du `[1363,400 →
    /// 1370,160)` — **6,760 s** de contenu, chevauchement **1,52587890625e-05 s** — doit être rendu,
    /// rogné à la fin du segment gardé (donc sans chevauchement résiduel), texte entier, jusqu'à son
    /// `end` d'origine. Aujourd'hui il n'est pas rendu du tout : le trou de **6,900 s** du document
    /// assemblé n'est autre que cette disparition.
    func testUnRaccordSurUnChevauchementDeQuinzeMicrosecondesNEstPasEcarte() {
        let unites = unite(
            depart: 1200,
            segments: [
                (1360.9400024414062, 1363.4000091552734, "avant le raccord"),
                (1363.3999938964844, 1370.1599884033203, "le contenu perdu"),
            ])
        let segments = TranscriptAssembly.merge(units: [unites])

        guard segments.count == 2 else {
            XCTFail(
                "\(contrat) — le segment adjacent à un chevauchement de 1,52587890625e-05 s n'est pas rendu (2 segments attendus, obtenu \(segments.count)) : \(description(segments))")
            return
        }

        // Contrôle positif : le contenu est là, en entier, jusqu'à son `end` d'origine.
        XCTAssertEqual(
            segments.map { $0.text }, ["avant le raccord", "le contenu perdu"],
            "\(contrat) — textes rendus : \(description(segments))")
        XCTAssertEqual(
            segments[1].end, 1370.1599884033203, accuracy: 1e-9,
            "\(contrat) — le contenu perdu va jusqu'à 1370,1599884033203 s, obtenu \(segments[1].end) s : \(description(segments))")

        // Et il est rogné à la fin du segment gardé : aucun chevauchement ne subsiste.
        XCTAssertEqual(
            segments[1].start, 1363.4000091552734, accuracy: 1e-9,
            "\(contrat) — le raccord doit être rogné à la fin du segment gardé (1363,4000091552734 s), obtenu \(segments[1].start) s : \(description(segments))")
        verifierInvariants(segments, contexte: "raccord de 1,52587890625e-05 s")

        // Le trou de 6,900 s du document assemblé a disparu : [1360,940 ; 1370,160) est couvert.
        let restants = trous(segments, de: 1360.9400024414062, a: 1370.1599884033203)
        XCTAssertEqual(
            restants.count, 0,
            "\(contrat) — trous restants sur [1360,9400024414062 ; 1370,1599884033203) : \(restants.map { "[\($0.0), \($0.1)) = \($0.1 - $0.0) s" }.joined(separator: ", "))")
    }

    // MARK: - (b) Un ε-écart de 1,4 à 3,9 s n'apparaît plus dans le document assemblé

    /// **Les treize raccords de la passe y passent ensemble**, répartis dans leurs huit unités du
    /// plan comme dans la passe réelle. Le flux assemblé rend **26 segments** (13 gardés + 13
    /// raccords), ne porte **aucun trou ≥ 1,0 s** — les trous mesurés allaient de **1,420013 s** à
    /// **6,899979 s** — et ne perd, par rapport à l'union des unités d'entrée, que le rognage des
    /// treize raccords (**1,94549560546875 × 10⁻⁴ s** au total, soit 0,19 ms).
    func testLesTreizeRaccordsMesuresNeLaissentPlusDeTrouDuneSeconde() {
        let entrees = unitesDesRaccords
        let segments = TranscriptAssembly.merge(units: entrees)
        let entree = entrees.flatMap { unite in
            unite.segments.map {
                TranscriptSegment(start: unite.boundary.start + $0.start, end: unite.boundary.start + $0.end, text: $0.text)
            }
        }
        let attendus = Self.raccordsMesures.count * 2

        guard segments.count == attendus else {
            XCTFail(
                "\(contrat) — \(attendus) segments attendus (13 gardés + 13 raccords), obtenu \(segments.count) : \(segments.count) écarté(s) par un chevauchement inférieur à \(TranscriptAssembly.chevauchementEcartMinimal) s")
            return
        }

        verifierInvariants(segments, contexte: "treize raccords mesurés")

        // Le contrôle positif : la matière perdue est là — l'union de la sortie rattrape celle de
        // l'entrée à moins d'une milliseconde (le rognage des 13 raccords).
        let couvertureEntree = couverture(entree)
        let couvertureSortie = couverture(segments)
        XCTAssertLessThan(
            couvertureEntree - couvertureSortie, 1e-3,
            "\(contrat) — l'assemblage perd \(couvertureEntree - couvertureSortie) s d'union (entrée \(couvertureEntree) s, sortie \(couvertureSortie) s)")

        // Et l'observation documentaire : plus aucun écart ≥ 1,0 s, alors que les octets livrés en
        // laissent treize (1,420013 s à 6,899979 s, cumul 45,939812 s par passe). Ce qui se mesure
        // ici est **ce que l'assemblage perd** — l'union de l'entrée moins l'union de la sortie —,
        // pas les trous du flux : un flux assemblé a des trous légitimes là où l'entrée n'avait rien.
        let perdu = pertes(entree, segments)
        let gros = perdu.filter { $0.1 - $0.0 >= 1.0 }
        XCTAssertEqual(
            gros.count, 0,
            "\(contrat) — écart(s) ≥ 1,0 s perdus par l'assemblage : \(gros.map { "[\($0.0), \($0.1)) = \($0.1 - $0.0) s" }.joined(separator: ", "))")
        XCTAssertLessThan(
            perdu.map { $0.1 - $0.0 }.max() ?? 0, 1.0,
            "\(contrat) — plus grand écart perdu par l'assemblage : \(perdu.map { $0.1 - $0.0 }.max() ?? 0) s")
    }

    // MARK: - (c) Le dédoublonnage des frontières reste intact (non-régression)

    /// **Le dédoublonnage au-dessus de la tolérance ne bouge pas.** Les cinq écarts mesurés sur un
    /// chevauchement **≥ 1 s** sont toujours écartés **dans leur entier** — leur intervalle était
    /// entièrement contenu dans le gardé — et la phrase rendue deux fois à une frontière d'unité
    /// (le cas obligatoire du contrat du lot 3, chevauchement 5 s) n'est toujours rendue qu'une fois.
    /// Un « correctif » qui cesserait de dédoublonner passerait (b) et échouerait ici.
    func testUnChevauchementAuDessusDeLaToleranceEstToujoursEcarteEnEntier() {
        let mesures = TranscriptAssembly.merge(units: unitesDesDoublons)
        let gardes = Self.doublonsMesures.map { $0.garde }

        // Contrôle positif : chaque segment gardé est rendu, entier, à sa place.
        for (index, garde) in gardes.enumerated() {
            XCTAssertTrue(
                mesures.contains { $0.start == garde.0 && $0.end == garde.1 },
                "\(contrat) — le segment gardé \(index) [\(garde.0), \(garde.1)) n'est pas rendu, alors qu'il précède le doublon : \(description(mesures))")
        }
        XCTAssertEqual(
            mesures.count, gardes.count,
            "\(contrat) — les doublons mesurés (chevauchements de 1,82 à 4,50 s) doivent être écartés en entier : \(gardes.count) segments attendus, obtenu \(mesures.count) : \(description(mesures))")
        XCTAssertEqual(
            mesures.map { $0.text }, ["garde-0", "garde-1", "garde-2"],
            "\(contrat) — seuls les segments gardés doivent être rendus : \(description(mesures))")
        verifierInvariants(mesures, contexte: "doublons mesurés")

        // La frontière d'unité de toujours : la même phrase rendue deux fois, une seule fois rendue.
        let premiere = unite(depart: 0, segments: [(0, 5, "Bonjour"), (294, 305, "Et voilà la suite")])
        let seconde = unite(
            depart: 300, segments: [(300, 310, "Et voilà la suite"), (310.5, 320, "puis autre chose")])
        let frontieres = TranscriptAssembly.merge(units: [premiere, seconde])
        XCTAssertEqual(
            frontieres.map { $0.text }, ["Bonjour", "Et voilà la suite", "puis autre chose"],
            "\(contrat) — le dédoublonnage de frontière a perdu ou réordonné du texte : \(description(frontieres))")
        verifierInvariants(frontieres, contexte: "frontière dédoublonnée")
    }

    // MARK: - La tolérance, et les deux populations qu'elle sépare

    /// La tolérance **vaut 1,0 s** et elle est bien **entre** les deux populations mesurées : le plus
    /// grand chevauchement écarté par erreur (**3,0517578125e-05 s**) est un raccord, le plus petit
    /// chevauchement d'un vrai doublon (**1,82000732421875 s**) reste un doublon. La valeur n'est pas
    /// choisie : elle est à un facteur ≈ 58 000 des deux populations.
    func testLaToleranceVautUneSecondeEtSepareLesDeuxPopulationsMesurees() {
        XCTAssertEqual(
            TranscriptAssembly.chevauchementEcartMinimal, 1.0, accuracy: 1e-9,
            "\(contrat) — la tolérance de la règle 3 doit valoir 1,0 s (mesurée : elle sépare les chevauchements de 3,8e-06 à 3,1e-05 s des chevauchements de 1,82 à 4,50 s), obtenu \(TranscriptAssembly.chevauchementEcartMinimal) s")

        // Le plus grand chevauchement de la population des raccords : gardé et rogné.
        let raccord = unite(
            depart: 0, segments: [(888.3999938964844, 890.8000183105469, "gardé"), (890.7999877929688, 892.2200012207031, "raccord")])
        let renduRaccord = TranscriptAssembly.merge(units: [raccord])
        XCTAssertEqual(
            renduRaccord.count, 2,
            "\(contrat) — un chevauchement de 3,0517578125e-05 s est un raccord, ses deux segments doivent être rendus : \(description(renduRaccord))")

        // Le plus petit chevauchement de la population des doublons (1,82000732421875 s), sur un
        // segment qui **déborde** du gardé : les bornes sont construites, mais le chevauchement est
        // la **valeur mesurée**, et l'extension est ce qui rend le choix observable (un segment
        // contenu ne laisserait rien après rognage non plus). Écarté **en entier**, il n'apporte
        // rien à la couverture : c'est le dédoublonnage des frontières, inchangé.
        let doublon = unite(
            depart: 0, segments: [(1000, 1010, "gardé"), (1008.17999267578125, 1020, "doublon")])
        let renduDoublon = TranscriptAssembly.merge(units: [doublon])
        XCTAssertEqual(
            renduDoublon.map { $0.text }, ["gardé"],
            "\(contrat) — un chevauchement de 1,82000732421875 s reste un doublon écarté en entier : \(description(renduDoublon))")
        XCTAssertEqual(
            couverture(renduDoublon), 10.0, accuracy: 1e-9,
            "\(contrat) — le doublon écarté en entier n'apporte rien à la couverture (10,0 s attendues, obtenu \(couverture(renduDoublon)) s) : \(description(renduDoublon))")
    }

    // MARK: - Le cas limite : un raccord qui ne laisse rien après rognage

    /// Un raccord **sous la tolérance** et **entièrement contenu** dans le gardé ne laisse **rien**
    /// après rognage : il n'est pas rendu (règle 4, `start >= end`) et **rien n'est perdu** — sa
    /// matière était déjà couverte par le gardé.
    ///
    /// **Pourquoi ces bornes sont construites, et pas mesurées.** Aucun couple relevé dans le journal
    /// du harnais n'est dans cette classe : les 13 raccords mesurés (chevauchements de 3,8 × 10⁻⁶ à
    /// 3,1 × 10⁻⁵ s) **débordent** du gardé — c'est pourquoi leur perte laissait un trou de 1,42 à
    /// 6,90 s —, et les 5 couples francs mesurés (chevauchements de 1,82 à 4,50 s, dont
    /// **4,38000106812 s** pour le `[47,619998931884766 → 47,69999694824219)`) sont contenus mais
    /// **au-dessus** de la tolérance : ils restent écartés en entier, et c'est le cas (c) qui les
    /// couvre. Le gardé est donc la borne **mesurée** d'un couple franc
    /// (`[47,599998474121094 → 52,0)`), et le raccord `[51,98 → 51,999)` est **construit** :
    /// chevauchement **0,02 s** (< 1,0 s) et `raccord.end` (**51,999 s**) **strictement inférieur** à
    /// `garde.end` (**52,0 s**).
    ///
    /// **Ce que ce cas rend falsifiable.** Écrite telle quelle, la règle amendée prescrit « s'il ne
    /// reste rien, il n'est pas rendu » ; sans ce cas, ce chemin n'était exercé par **aucun** autre :
    /// un `merge` qui rognerait sans vérifier qu'il reste quelque chose reste **vert** sur les huit
    /// autres cas, et rend ici un second segment **dégénéré** `[52.0, 51.999)` — le contrôle du
    /// compte tombe le premier (« 1 segment attendu, obtenu 2 : [47.599998474121094, 52.0) « le
    /// gardé », [52.0, 51.999) « le contenu » »), puis `verifierInvariants` (`start < end`, règle 2).
    ///
    /// Ce cas est **vert avant comme après** l'amendement : c'est un cas de non-régression, et c'est
    /// écrit ici pour que personne ne le prenne pour un rouge.
    func testUnRaccordEntierementContenuNeLaisseRienApresRognageEtNePerdRien() {
        let seule = unite(
            depart: 0,
            segments: [
                (47.599998474121094, 52.0, "le gardé"), (51.98, 51.999, "le contenu"),
            ])
        let segments = TranscriptAssembly.merge(units: [seule])

        guard segments.count == 1 else {
            XCTFail(
                "\(contrat) — un segment contenu dans le gardé ne peut pas laisser de matière après rognage (1 segment attendu, obtenu \(segments.count)) : \(description(segments))")
            return
        }
        XCTAssertEqual(
            segments[0], TranscriptSegment(start: 47.599998474121094, end: 52.0, text: "le gardé"),
            "\(contrat) — le segment gardé obtenu : \(description(segments))")
        XCTAssertEqual(
            couverture(segments), 52.0 - 47.599998474121094, accuracy: 1e-9,
            "\(contrat) — rien ne doit être perdu : couverture obtenue \(couverture(segments)) s")
        verifierInvariants(segments, contexte: "raccord contenu")
    }
}
