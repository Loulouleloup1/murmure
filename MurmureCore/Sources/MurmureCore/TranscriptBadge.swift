import SwiftUI

/// L'état de la **pastille de barre de menu** : au repos, en train de travailler, ou fini
/// (critère 18 de la SPEC — « la pastille de barre de menu a deux états distincts, l'un pendant le
/// travail, l'autre une fois qu'il est fini » ; décision **O1** du 22/09/2026 ; plan §4 lot 10-O1).
///
/// **Pourquoi la pastille vit ici, dans le cœur, et pas dans `Murmure/`.** La cible application n'a
/// **pas de bundle de tests** : une règle écrite dans `TranscriptsPaneModel` serait une décision que
/// rien ne peut exécuter. Or le critère 18 ne demande pas seulement qu'une pastille existe — il
/// demande que deux états soient **distincts**, c'est-à-dire observables. Le cœur porte déjà les
/// **mots** de l'interface pour cette raison exacte (`MenuText`, `TranscriptQueueText`) ; il porte
/// ici la **forme** de la pastille, et c'est le premier fichier du cœur qui dessine. Le dessin est
/// assumé : c'est la différence entre « ça travaille » et « c'est fini » qui compte, pas un ornement,
/// et c'est cette différence que la sonde de rastérisation du contrat peut mesurer hors écran.
///
/// **La règle des trois états, et pourquoi trois et pas deux.** Une pastille qui ne s'allume que
/// pendant le travail (le comportement du lot 10) ne peut pas dire « c'est fini » : l'utilisateur lit
/// la même absence de pastille après un travail terminé qu'avant tout travail, et il ne reste que la
/// notification — qui passe. D'où un état de plus, ``finished``, qui **tient** : la file garde tous
/// ses éléments pour la vie du processus (lot 10, règle 2 : `TranscriptQueue.entries` conserve les
/// éléments terminés), donc la marque de fin reste jusqu'au prochain lancement, qui repart de
/// ``idle`` — rien n'est restauré depuis le disque, la file naît vide.
///
/// **Pourquoi un échec seul ne vaut pas « fini ».** Un `failed` a ses propres surfaces — la
/// notification, la ligne du menu, le `problem` du panneau — et la marque de fin, elle, promet qu'un
/// transcript existe sur disque (critère 14 : l'application n'affiche que ce qui existe). Un échec
/// marquerait donc la fin d'un travail qui n'a rien produit. En revanche un échec **ne retire rien** :
/// un `done` déjà présent garde sa marque, il n'est pas annulé par l'échec d'un autre travail.
///
/// **La distinction est de forme, jamais de couleur.** La teinte d'un item de barre de menu n'est
/// prouvée par aucune mesure de ce chantier, et ne peut pas l'être : aucun test ne voit la barre de
/// menu. La forme, elle, est mesurée par le contrat (`shape`, pas `color`) — c'est le seul axe que
/// la sonde de rastérisation du fichier de tests peut rendre discriminant.
///
/// **Au repos, il n'y a aucune pastille** : seule l'icône de Murmure reste, et elle porte déjà
/// l'état de la dictée (`AppState.menuBarSymbol`). Une troisième marque pour dire « rien » ajouterait
/// du bruit à côté d'un état qui a déjà son propre glyphe.
public enum TranscriptBadgeState: CaseIterable, Equatable, Sendable {
    /// Rien en cours, rien de fini : la barre de menu ne montre que l'icône de Murmure.
    case idle
    /// Un travail attend ou tourne : la pastille marque le travail en cours.
    case working
    /// Un travail s'est terminé et un transcript existe sur disque : la pastille marque la fin.
    case finished
}

/// La règle de la pastille : **ce que l'état d'une file dit de la barre de menu** (critère 18).
///
/// Une fonction pure, sans vue, sans acteur et sans horloge : elle prend les éléments tels que
/// `TranscriptQueue.entries` les rend et rend un état. C'est ce qui rend la règle exécutable par un
/// test, et c'est pour cette raison qu'elle n'est pas écrite dans le corps d'une `View`.
public enum TranscriptBadge {
    /// L'état de la pastille pour une file d'attente donnée.
    ///
    /// 1. ``TranscriptBadgeState/working`` si la file porte un élément `waiting` ou `running` — il y
    ///    a du travail en cours, et c'est ce que la pastille doit dire ;
    /// 2. sinon ``TranscriptBadgeState/finished`` si elle porte un élément `done` — un transcript
    ///    existe sur disque ;
    /// 3. sinon ``TranscriptBadgeState/idle``. Un `failed` **seul** ne donne jamais `finished` (voir
    ///    la documentation de ``TranscriptBadgeState``), et il ne change rien quand un `done` existe.
    ///
    /// L'ordre des deux premières clauses est la règle, pas un détail : un travail en cours reprend la
    /// main sur un travail fini (un deuxième lien ajouté après le premier repasse la pastille au
    /// travail), alors qu'un `done` plus ancien ne masque jamais le travail en cours.
    public static func state(of entries: [TranscriptQueueEntry]) -> TranscriptBadgeState {
        // Le travail en cours d'abord : c'est lui qui reprend la main sur une marque de fin plus
        // ancienne, jamais l'inverse.
        if entries.contains(where: { $0.state == .waiting || $0.state == .running }) {
            return .working
        }
        // Un `done` et lui seul : un `failed` ne promet aucun transcript sur disque.
        if entries.contains(where: { $0.state == .done }) {
            return .finished
        }
        return .idle
    }
}

/// La **forme** de la pastille, par état : deux valeurs par état, et rien d'autre (critère 18).
///
/// Les valeurs de ``working`` sont celles du lot 10, **inchangées** : le point plein de 6 pt que la
/// barre de menu portait déjà. ``finished`` a la sienne, et elle est différente par sa **forme** —
/// une coche de 8 pt, plus grande que le point, parce qu'elle signale un résultat et non une activité.
/// ``idle`` n'a rien : `symbol` vaut `nil` et aucune vue ne consulte `pointSize` dans ce cas
/// (`pointSize` vaut `0`, et c'est cette valeur qui rend l'oubli visible plutôt que silencieux).
///
/// Ajouter une couleur ici serait un changement de contrat sans preuve : aucune mesure de ce chantier
/// ne voit la barre de menu.
extension TranscriptBadgeState {
    /// Le nom du glyphe SF Symbol à dessiner, `nil` pour ``idle``.
    public var symbol: String? {
        switch self {
        case .idle: return nil
        case .working: return "circle.fill"
        case .finished: return "checkmark"
        }
    }

    /// La taille du glyphe en points. Jamais lue quand ``symbol`` est `nil`.
    public var pointSize: CGFloat {
        switch self {
        case .idle: return 0
        case .working: return 6
        case .finished: return 8
        }
    }
}

/// **Le dessin que l'application appelle** : la pastille, telle qu'elle apparaît à côté de l'icône de
/// Murmure dans l'étiquette du `MenuBarExtra`.
///
/// C'est **le seul endroit d'où une commande peut observer deux états distincts** : la barre de menu
/// elle-même n'est pas observable hors écran (aucune capture d'écran dans ce chantier), alors que ce
/// composant peut être rastérisé par `ImageRenderer` — c'est ce que fait le contrat
/// (`TranscriptBadgeTests`). L'application ne fait que le placer : une ligne dans `MurmureApp.swift`,
/// `TranscriptBadgeLabel(state: transcriptsModel.badge)`.
///
/// Au repos, la vue ne dessine **rien** : pas un glyphe vide, pas un espace réservé — rien.
public struct TranscriptBadgeLabel: View {
    /// L'état à dessiner, décidé par ``TranscriptBadge/state(of:)``.
    public let state: TranscriptBadgeState

    public init(state: TranscriptBadgeState) {
        self.state = state
    }

    public var body: some View {
        // Rien pour le repos : ni glyphe vide, ni espace réservé. La taille vient de l'état, et
        // `pointSize` n'est lu que quand `symbol` existe -- c'est l'axe unique de la distinction
        // (forme et taille), sans couleur et sans mot.
        if let symbol = state.symbol {
            Image(systemName: symbol).font(.system(size: state.pointSize))
        }
    }
}
