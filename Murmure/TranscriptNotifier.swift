import Foundation
import MurmureCore
import UserNotifications

/// La notification macOS qui annonce la fin d'un travail vidéo (critère 18, décision R6).
///
/// **Les mots ne sont pas ici.** `transcriptionFinished`, `transcriptionFailed` et
/// `notificationBody(_:)` vivent dans `MenuText`, où `MenuTextTests` les gèle et les marche : la
/// cible `Murmure/` n'a pas de bundle de tests, donc une phrase écrite dans ce fichier serait une
/// décision que rien ne peut relire.
///
/// **Ce qui est décidé ici est le moment, et rien d'autre** : l'autorisation est demandée **au
/// premier traitement lancé** (R6) — jamais à l'ouverture de l'application, qui la demanderait à
/// quelqu'un qui n'a rien demandé —, et une notification est postée quand un travail se termine.
///
/// **Un refus ne coûte que la notification** (R6). Rien ici ne touche la pastille ni la barre de
/// progression, qui vivent dans la barre de menus et le panneau ; et un refus n'est pas un chemin
/// d'erreur : macOS ne redemande jamais, donc ce type ne redemande jamais non plus, il cesse
/// simplement de poster — silencieusement, parce qu'il n'y a rien à dire à Louis de plus.
@MainActor
final class TranscriptNotifier {
    private let center = UNUserNotificationCenter.current()

    /// L'autorisation a déjà été demandée dans ce processus. Une seule fois par processus, parce
    /// que l'invite système est unique : la poser à chaque travail serait une invite qui ne
    /// s'affiche qu'une fois de toute façon, et un état que personne ne lit.
    private var asked = false

    /// Demande l'autorisation, **une fois**, au premier traitement lancé (R6).
    ///
    /// Appelée par le lancement d'un travail vidéo, jamais par `init` ni par le lancement de
    /// l'application. L'issue n'est pas lue : refusée, elle ne prive que de la notification.
    func askAtFirstJob() {
        guard !asked else { return }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Un travail s'est terminé : le titre dit ce qui a fini, le corps dit lequel (criterion 18).
    func finished(title: String) {
        post(title: MenuText.transcriptionFinished, body: MenuText.notificationBody(title))
    }

    /// Un travail a échoué. **Sa propre phrase, et pas celle du dessus** : les deux envoient Louis
    /// à deux endroits différents — le transcript, ou la raison. Le corps passe la raison telle
    /// quelle, comme `notificationBody(_:)` passe le titre : c'est le texte du travail, pas un mot
    /// que Murmure possède (« failed to fetch: HTTP 403 » ne se traduit pas).
    ///
    /// **Une annulation n'arrive pas ici** : c'est la décision de l'appelant (le panneau), parce
    /// qu'un arrêt demandé par Louis n'est pas une fin de traitement à lui annoncer.
    func failed(reason: String) {
        post(title: MenuText.transcriptionFailed, body: MenuText.notificationBody(reason))
    }

    /// Poste une notification immédiate (pas de déclencheur : il n'y a rien à planifier).
    ///
    /// `add` échoue sans bruit quand l'autorisation a été refusée — c'est le comportement que R6
    /// demande, donc l'erreur n'est ni journalisée ni remontée : la seule chose à faire d'un refus
    /// est de continuer sans notification.
    private func post(title: String, body: String) {
        let contenu = UNMutableNotificationContent()
        contenu.title = title
        contenu.body = body
        contenu.sound = .default
        let demande = UNNotificationRequest(
            identifier: UUID().uuidString, content: contenu, trigger: nil)
        center.add(demande, withCompletionHandler: nil)
    }
}
