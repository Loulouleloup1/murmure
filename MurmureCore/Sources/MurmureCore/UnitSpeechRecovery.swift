import Foundation

/// **La décision pure qui empêche une fenêtre sautée par le moteur de coûter de la parole** (plan
/// §2.1 et §4 lot 8-R, révision 9 ; défaut **mesuré** au round 2 du lot 8, suivi `t_c844f772`).
///
/// **Le défaut, mesuré.** WhisperKit v1.1.0 saute une fenêtre entière de 30 s quand la probabilité de
/// non-parole du modèle pour cette fenêtre dépasse `noSpeechThreshold` — **0,6 par défaut**
/// (`Sources/WhisperKit/Core/Configurations.swift:216`) — sans que `avgLogProb` ne renverse la
/// décision (`Sources/WhisperKit/Core/Text/SegmentSeeker.swift:57-71` :
/// `if shouldSkip { seek += segmentSize; return (seek, nil) }`). Sur la vidéo A du plan, la fenêtre
/// sautée portait de la **parole** (RMS −19,4 dBFS sur `[300, 330)`, voisins −17,7 à −19,6 ; aucun
/// silence ≥ 1 s dans cet audio) : le trou vaut **24,4 s ou 30,0 s** selon la passe, et le critère 9 a
/// mesuré **0,9704** puis **0,9573 / 0,9680 / 0,9800** — une loterie du moteur, pas une propriété du
/// livrable.
///
/// **La décision, et ce qu'elle n'est pas.** Le seuil du critère 9 (97 %) ne bouge pas et la SPEC
/// n'est pas touchée ; désactiver le saut partout est écarté (sur un vrai silence, la boucle de repli
/// du décodeur redécode la fenêtre jusqu'à six fois pour n'en rien tirer, le silence se remplit de
/// texte inventé, et des segments inventés **couvrent** le silence — le critère 9 cesse alors de
/// mesurer quoi que ce soit, §2.1). Ce type ne connaît ni le moteur, ni l'audio, ni le disque : il
/// prend une liste de segments et des intervalles, et rend une décision — les intervalles à rejouer,
/// puis la liste recousue. C'est ce qui le rend testable, et c'est pour cela que la carte `qa` le
/// gèle avant que la carte `dev` ne l'implémente (règles 1 à 5 du §7.1).
///
/// **La borne est celle du plafond des pauses naturelles** (§2.1) : un trou qui porte plus de
/// **5,0 s** de parole est rejoué, un trou qui en porte moins peut rester — c'est une pause, et la
/// plus grande du document accepté fait exactement 5,0 s. La population visée était auparavant
/// aveugle : les passes **lien** mesurées portent 2 à 4 trous de **5 à 20 s** par passe (6,900 s
/// `[1363,400 → 1370,300)` dans les six passes, 12,040 à 42,840 s de cumul), que la borne de 20 s du
/// lot 8-R laissait perdre définitivement (carte QA `t_7540c725`, contrôle 4 du contrat observable).
/// Le coût du renoncement tombe avec elle : renoncer à rejouer un intervalle coûte au plus **5,0 s**,
/// soit **0,22 %** de 2 292,6 s — très à l'intérieur de la marge de 3 % (68,8 s) du critère 9.
/// Le garde-fou du §2.1 reste entier : la borne porte sur la **matière hors silence mesuré**, donc un
/// silence réel n'est jamais rejoué quelle que soit la valeur de la borne.
///
/// **L'ordre de la chaîne**, et c'est celui des appelants du lot 8 : ``rebased(silences:on:)`` (les
/// silences du lot 7 ramenés au temps de l'unité) → ``uncovered(segments:duration:)`` (le complément
/// de l'union, borné à l'unité) → ``toReplay(segments:duration:silences:minimum:)`` (les trous qui
/// valent la peine) → ``merging(unit:replayed:in:duration:)`` (la liste de l'unité, recousue).
public enum UnitSpeechRecovery {
    /// Le contenu hors silence, en secondes, à partir duquel un intervalle non couvert vaut la peine
    /// d'être rejoué : **5,0** — le **plafond des pauses naturelles** (plan §2.1 ; carte QA
    /// `t_7540c725`, contrôle 4 du contrat observable).
    ///
    /// **Pourquoi ce plafond, et pas un autre.** C'est la plus grande pause naturelle mesurée du
    /// document accepté : un trou qui la dépasse ne peut plus être une respiration du locuteur, donc
    /// il porte de la parole — et c'est exactement la population que la borne de 20 s du lot 8-R
    /// laissait perdre (2 à 4 trous de 5 à 20 s par passe **lien**, 12,040 à 42,840 s de cumul, quand
    /// la passe fichier du **même** dispositif ne portait aucun trou au-delà de 5,000 s).
    ///
    /// C'est la **seule** définition de ce nombre dans le module : aucun appelant ne le réécrit, et
    /// c'est le défaut de ``toReplay(segments:duration:silences:minimum:)``. La borne est
    /// **incluse** (`≥`) : un trou qui porte exactement 5,0 s d'audio hors silence est rejoué — la
    /// convention du bord est gelée **ici**, le contrat de la carte n'ayant figé que les deux
    /// populations qui l'encadrent (4,0 s : non rejoué, 6,0 s : rejoué).
    public static let minimumRecoverable: Double = 5.0

    /// Les intervalles de `[0, duration]` qu'**aucun** segment ne couvre : le **complément de
    /// l'union** des segments, jamais une somme de durées.
    ///
    /// **Pourquoi le complément et pas un total.** Un trou est une *position*, pas un nombre : savoir
    /// qu'il manque 24 s ne dit pas **où** découper l'audio pour rejouer ces 24 s. La mesure du
    /// critère 9 (`TranscriptCoverage`, lot 2) répond à l'autre question — *combien* de l'audio est
    /// couvert. Les deux se ressemblent et ne se remplacent pas ; la seconde seule est appelée ici.
    ///
    /// **Contrat gelé** (carte QA L8-R `t_e37a408c`) :
    /// 1. chaque segment est **borné à `[0, duration]`** avant l'union — un segment qui dépasse la fin
    ///    de l'unité ne couvre pas plus que l'unité (segment `[65, 80]` sur 70 s → complément
    ///    `[0, 65]`) ;
    /// 2. deux segments qui se **chevauchent** ne comptent qu'une fois (`[0, 40]` et `[20, 60]` sur
    ///    70 s → un seul trou `[60, 70]`) ;
    /// 3. résultat **trié par début croissant**, et chacun **non dégénéré**
    ///    (`lowerBound < upperBound`) : un segment vide ou hors bornes ne rend pas d'intervalle
    ///    `[x, x]` ;
    /// 4. `duration <= 0` → `[]` ; **aucun** segment → `[0, duration]` (l'unité entière est un trou,
    ///    ce qui est le cas d'une unité que le moteur n'a pas transcrite du tout).
    public static func uncovered(segments: [TranscriptSegment], duration: Double)
        -> [ClosedRange<Double>]
    {
        guard duration > 0 else { return [] }
        // 1. chaque segment est ramené dans `[0, duration]` — un segment qui dépasse la fin de
        //    l'unité ne couvre pas plus que l'unité, et un segment négatif ne couvre rien avant 0.
        //    Puis on jette les dégénérés : un segment vide ne couvre rien et ne doit pas produire
        //    d'intervalle `[x, x]` dans le complément.
        let couverts = segments
            .map { (debut: max(0, min($0.start, duration)), fin: max(0, min($0.end, duration))) }
            .filter { $0.debut < $0.fin }
            .sorted { $0.debut < $1.debut }
        // 2. Complément de l'**union** : on avance un curseur sur les segments croissants, et chaque
        //    fois que le début suivant est au-delà du curseur, l'écart est un trou. `max` sur la fin
        //    est ce qui fait qu'un segment entièrement recouvert par le précédent ne compte qu'une
        //    fois (le cas `[0, 40]` + `[20, 60]` du contrat).
        var trous: [ClosedRange<Double>] = []
        var curseur = 0.0
        for couvert in couverts {
            if couvert.debut > curseur { trous.append(curseur...couvert.debut) }
            curseur = max(curseur, couvert.fin)
        }
        // 3. La queue de l'unité n'est un trou que si elle existe : une unité entièrement couverte
        //    (curseur == duration) ne rend pas `[duration, duration]`.
        if curseur < duration { trous.append(curseur...duration) }
        return trous
    }

    /// Les trous de ``uncovered(segments:duration:)`` qui portent **au moins `minimum` secondes
    /// d'audio que la carte de silence du lot 7 ne déclare pas silence** : c'est la décision de
    /// rejouer, et rien d'autre.
    ///
    /// **Pourquoi la borne est sur le contenu hors silence, pas sur la longueur du trou.** Un trou de
    /// 30 s dont 25 s sont un vrai silence mesuré est le cas où **le moteur a raison de sauter** : le
    /// rejouer ne rendrait pas de parole et risquerait, sur ce silence, le texte inventé que le §2.1
    /// décrit. Le critère porte donc sur la matière : `longueur(trou) − longueur(silences ∩ trou) ≥
    /// minimum`.
    ///
    /// **Contrat gelé** (carte QA L8-R `t_e37a408c`, dont la clause (d) a été amendée par la carte
    /// QA `t_7540c725` — elle ne garde que la distinction **matière contre longueur de trou**, seule
    /// vérité indépendante de la valeur de la borne) :
    /// 1. `minimum` vaut ``minimumRecoverable`` (**5,0** s) par défaut, et la comparaison est **`≥`** :
    ///    un trou de 30 s dont 27 s sont déclarées silence ne l'est pas (3,0 < 5,0), un trou de 30 s
    ///    dont 15 s sont déclarées silence l'est (15,0 ≥ 5,0), et un trou de 30 s sans silence mesuré
    ///    aussi (30,0 ≥ 5,0) ;
    /// 2. `silences` est **dans le temps de l'unité**, pas dans le temps absolu de l'audio : c'est
    ///    ``rebased(silences:on:)`` qui fait la conversion, et un appelant qui l'oublierait comparerait
    ///    des silences absolus à des trous locaux (les intersections seraient alors vides presque
    ///    partout — un trou de parole rejoué par erreur, jamais l'inverse) ;
    /// 3. l'intersection est celle des **intervalles fermés** : un silence qui ne fait que toucher le
    ///    bord du trou (`[265, 270]` contre un trou `[270, 300]`) vaut **0** s de recouvrement ;
    /// 4. résultat **trié par début croissant**, tel que ``uncovered(segments:duration:)`` l'a rendu —
    ///    seuls des trous sont écartés, jamais réordonnés ni rognés ;
    /// 5. `duration <= 0` ou aucun trou → `[]` (même convention que ``uncovered(segments:duration:)``).
    public static func toReplay(
        segments: [TranscriptSegment],
        duration: Double,
        silences: [ClosedRange<Double>],
        minimum: Double = UnitSpeechRecovery.minimumRecoverable
    ) -> [ClosedRange<Double>] {
        // Aucun trou, ou une unité de durée nulle : la décision n'a rien à examiner. On passe par
        // `uncovered` plutôt que de refaire le calcul, pour qu'il n'existe qu'une définition du trou.
        let trous = uncovered(segments: segments, duration: duration)
        guard !trous.isEmpty else { return [] }
        // La borne porte sur la **matière** : `longueur(trou) − longueur(silences ∩ trou) ≥ minimum`.
        // L'intersection est mesurée sur l'**union** des recouvrements (et non par une somme naïve) :
        // une carte de silence du lot 7 est normalisée et disjointe, mais deux entrées qui se
        // chevaucheraient ne doivent pas compter deux fois le même silence — ce serait un silence
        // gonflé, donc un trou de parole écarté à tort.
        return trous.filter { trou in
            let recouvrements = silences
                .map {
                    (debut: max($0.lowerBound, trou.lowerBound),
                     fin: min($0.upperBound, trou.upperBound))
                }
                .filter { $0.debut < $0.fin }
                .sorted { $0.debut < $1.debut }
            var silence = 0.0
            var curseur = trou.lowerBound
            for recouvrement in recouvrements {
                if recouvrement.fin > curseur {
                    silence += recouvrement.fin - max(recouvrement.debut, curseur)
                    curseur = recouvrement.fin
                }
            }
            return (trou.upperBound - trou.lowerBound) - silence >= minimum
        }
    }

    /// Les silences du lot 7 ramenés **au temps de l'unité** : c'est le seul endroit où les deux
    /// horloges se rencontrent.
    ///
    /// **Pourquoi cette conversion existe.** `SilenceMap.intervals(from:duration:)` (lot 7) rend des
    /// intervalles en secondes de **l'audio décodé** — le temps absolu du fichier. Les segments d'une
    /// unité sont, eux, horodatés depuis **son** début (`TranscriptAssembly`, règle 1 : c'est la forme
    /// sous laquelle WhisperKit les rend, chaque unité est un appel `transcribe` séparé sur son propre
    /// WAV). Comparer les uns aux autres sans conversion est l'erreur silencieuse la plus coûteuse de
    /// ce lot : l'intersection serait vide et *tous* les trous seraient rejoués, silences compris.
    ///
    /// **Contrat gelé** (carte QA L8-R `t_e37a408c`) :
    /// 1. chaque silence est **intersecté** avec `[unit.start, unit.start + unit.duration]` : un
    ///    silence à cheval sur le début de l'unité (`[250, 320]` pour une unité qui commence à 300)
    ///    est **rogné**, pas écarté ;
    /// 2. l'intervalle rogné est **translaté de `−unit.start`** : mêmes bornes relatives, même
    ///    longueur (`[250, 320]` → `[0, 20]`, un silence intérieur `[400, 450]` → `[100, 150]`) ;
    /// 3. un silence **entièrement avant ou après** l'unité disparaît, et un intervalle qui devient
    ///    **dégénéré** après l'intersection aussi (un silence `[200, 300]` qui ne touche l'unité
    ///    qu'en `300` → `[0, 0]` → écarté : une rencontre de bord vaut 0 s de silence) ;
    /// 4. résultat **trié par début croissant**, comme ``SilenceMap`` le rend déjà et comme
    ///    ``toReplay(segments:duration:silences:minimum:)`` en a besoin.
    public static func rebased(silences: [ClosedRange<Double>], on unit: UnitBoundary)
        -> [ClosedRange<Double>]
    {
        // Deux horloges, une seule conversion : on **rogne** chaque silence à l'emprise de l'unité
        // (un silence à cheval sur le début est rogné, pas écarté), puis on translate de `−start`.
        // Rogner avant de translater est ce qui distingue « rogné » de « dégénéré » : un silence qui
        // ne touche l'unité qu'en un point devient `[x, x]` après translation, et il disparaît —
        // une rencontre de bord vaut 0 s de silence, elle ne doit pas compter dans `toReplay`.
        let debut = unit.start
        let fin = unit.start + unit.duration
        return silences
            .map { (debut: max($0.lowerBound, debut), fin: min($0.upperBound, fin)) }
            .filter { $0.debut < $0.fin }
            .map { ($0.debut - debut)...($0.fin - debut) }
            .sorted { $0.lowerBound < $1.lowerBound }
    }

    /// La liste de l'unité, **recousue** avec les segments rejoués : les rejoués sont **rognés à
    /// `interval`**, ceux qui deviennent vides sont écartés, et le résultat reste strictement
    /// croissant.
    ///
    /// **Pourquoi rogner au lieu d'appliquer la règle 3 de `TranscriptAssembly`.** L'assemblage
    /// écarte le second segment **en entier** quand deux segments se chevauchent (règle 3, gelée par
    /// la carte QA L3) — c'est correct à une frontière d'unité, où le doublon est la même phrase
    /// rendue deux fois par un moteur sans contexte. Ici, la règle jetterait **le texte récupéré**
    /// dès qu'il touche un segment existant, c'est-à-dire exactement la parole que la reprise est
    /// allée chercher. Le rognage est donc une règle **locale et nouvelle** (§2.1, révision 9), et
    /// elle ne s'applique qu'aux segments **rejoués**.
    ///
    /// **Invariant porté par la sortie** : strictement croissante et sans aucune paire qui se
    /// chevauche (`start[i] >= end[i−1]`) — c'est l'invariant du critère 9, et il doit survivre à la
    /// reprise. Il tient par construction : les rejoués tombent dans un trou de l'union de l'unité,
    /// donc après rognage aucun ne peut recouvrir un segment de l'unité.
    ///
    /// **Contrat gelé** (carte QA L8-R `t_e37a408c`) :
    /// 1. un segment de `unit` n'est **jamais** rogné ni écarté — la reprise ajoute, elle ne retire
    ///    rien ;
    /// 2. un segment rejoué est rogné à `interval` (`max(start, interval.lowerBound)`,
    ///    `min(end, interval.upperBound)`) puis **borné à `[0, duration]`** ; s'il devient vide, il
    ///    disparaît ;
    /// 3. les rejoués sont **dédoublonnés entre eux** — même début ou chevauchement : **le premier
    ///    gardé**, c'est la règle 3 de `TranscriptAssembly` appliquée à la seule population rejouée ;
    /// 4. l'ordre du résultat est celui des **débuts croissants** (tri par `start`). Deux rejoués au
    ///    **même début** sont indiscernables dans le résultat : le contrat gèle qu'**un seul** des deux
    ///    est gardé, pas lequel — le tri de `Array.sorted` n'est pas garanti stable, et exiger un texte
    ///    précis ferait dépendre le vert d'une propriété non promise.
    public static func merging(
        unit: [TranscriptSegment],
        replayed: [TranscriptSegment],
        in interval: ClosedRange<Double>,
        duration: Double
    ) -> [TranscriptSegment] {
        // 1. Le rognage — **local et nouveau**, et appliqué aux seuls rejoués. La règle 3 de
        //    `TranscriptAssembly` écarterait le second segment en entier dès qu'il touche un segment
        //    de l'unité, c'est-à-dire exactement le texte que la reprise est allée chercher. Ici on
        //    ramène le segment dans l'intervalle rejoué, puis dans `[0, duration]`, et on jette ce
        //    qui devient vide (`end <= start`) — un rejoué entièrement hors de l'intervalle disparaît.
        let candidats = replayed.compactMap { segment -> TranscriptSegment? in
            let debut = max(0, min(max(segment.start, interval.lowerBound), duration))
            let fin = max(0, min(min(segment.end, interval.upperBound), duration))
            guard fin > debut else { return nil }
            return TranscriptSegment(start: debut, end: fin, text: segment.text)
        }
        // 2. Le dédoublonnage **entre rejoués** — là, c'est la règle 3 de `TranscriptAssembly` telle
        //    quelle : triés par début croissant, un rejoué qui commence avant la fin du dernier gardé
        //    (même début, ou chevauchement) est écarté, le **premier** gardé. C'est ce qui rend la
        //    sortie strictement croissante sans aucune paire qui se chevauche — l'invariant du
        //    critère 9 — alors que les rejoués, eux, peuvent se recouvrir.
        var gardes: [TranscriptSegment] = []
        for segment in candidats.sorted(by: { $0.start < $1.start }) {
            if let dernier = gardes.last, segment.start < dernier.end { continue }
            gardes.append(segment)
        }
        // 3. La recousue : les segments de l'unité sont rendus **intacts** (jamais rognés ni
        //    écartés — la reprise ajoute, elle ne retire rien), et l'ordre du résultat est celui des
        //    débuts croissants. Les rejoués tombent dans un trou de l'union de l'unité : après
        //    rognage à l'intervalle, aucun ne peut recouvrir un segment déjà présent.
        return (unit + gardes).sorted { $0.start < $1.start }
    }
}
