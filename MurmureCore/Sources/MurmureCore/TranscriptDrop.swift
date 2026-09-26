import Foundation

/// **Les entrées de lancement d'un dépôt** : ce qu'un geste de dépôt remet à la file d'attente, dans
/// l'ordre du geste (critère 19 de la SPEC — « un dépôt de plusieurs fichiers les met tous en file ;
/// aucun n'est ignoré en silence » ; décision **O2** adoptée par Louis le 22/09/2026 ; plan §4 lot
/// 10-O2).
///
/// **Pourquoi cette fonction existe.** Jusqu'au 22/09/2026, la cible de dépôt de la fenêtre lisait
/// `guard …, let url = urls.first` (`Murmure/MurmureApp.swift`) : trois fichiers lâchés sur la
/// fenêtre en mettaient **un** en file, le geste rendait `true`, et les deux autres disparaissaient
/// sans un mot. C'est un échec silencieux — exactement ce que le critère 19, amendé le 22/09,
/// interdit — et il ne se voyait dans aucun test parce que la règle vivait dans le corps d'une vue.
/// Elle vit ici : une fonction pure, appelée par la cible de dépôt, mesurable par un test.
///
/// **La règle, et rien de plus.** `count == urls.count` : aucune troncature (pas de `first`), aucune
/// fusion de doublons (deux fois la même URL font deux entrées — c'est le geste de quelqu'un, pas un
/// ensemble), aucun réordonnancement (l'ordre est celui du dépôt). Un fichier se rend par son chemin
/// (`URL.path`, décodé : espaces et accents compris), un lien tel quel (`URL.absoluteString`) — parce
/// que c'est le texte qu'une personne aurait collé dans le prompt de collage, et que le point de
/// résolution qui décide de ce qu'il lit prend ce texte-là.
///
/// **Ce que cette fonction ne fait pas : elle ne valide rien.** La décision de ce qui est
/// transcriviable (le chemin d'un fichier qui existe, un lien reconnu, le reste refusé avec sa
/// phrase) reste là où elle est — `TranscriptsPaneModel.launch(for:)` décide ce qu'il lit, **une
/// seule fois**, et `transcribe(_:)` dit le refus. Cette fonction-ci ne perd rien et ne juge rien :
/// elle transporte ce que le geste a donné, et c'est la file (lot 10, critère 19) qui traite ensuite
/// ces entrées l'une après l'autre, dans cet ordre.
public enum TranscriptDrop {
    /// Les entrées de lancement d'un dépôt : **une par URL déposée, dans l'ordre du dépôt** — le
    /// chemin pour un fichier (`URL.path`), le lien tel quel (`URL.absoluteString`).
    ///
    /// - Parameter urls: les URLs du geste de dépôt, telles que la cible de dépôt les reçoit.
    /// - Returns: `urls.count` entrées, dans l'ordre reçu. Jamais moins : rien n'est ignoré en
    ///   silence ici, et rien n'est fusionné.
    public static func sources(for urls: [URL]) -> [String] {
        urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
    }
}
