import Foundation
import MurmureCore

/// Asking Hugging Face what a repository actually holds -- the network half of "Add a model".
///
/// **Why this reads `?blobs=true` rather than going through `WhisperKit`'s own listing APIs.**
/// `WhisperKit.fetchAvailableModels` silently answers with Argmax's own fallback table when a
/// repository has no `config.json` -- a wrong answer that looks right. `SpeechModelCatalog`, the
/// app-target listing that used to call it and detect the substitution after the fact, is deleted
/// along with the call: reading the repository's raw file listing instead -- which is what
/// `ModelClassifier.classify` decides from -- never has that failure mode to begin with, and it is
/// the one request that can answer both "does this repository hold a speech model" and "does it
/// hold a `.gguf` file", which `WhisperKit`'s own APIs cannot: they only ever answer the first.
///
/// Kept in the app target, like every other network client in this codebase, because the app
/// target has no test bundle and this file is a fetch and nothing more -- the decision it feeds is
/// `ModelClassifier`, tested in `MurmureCore`.
enum ModelInspector {
    enum Failure: Error, Equatable {
        case notReachable(detail: String)
        case notFound
    }

    /// A short-lived session: this is metadata, not a download, and a repository that does not
    /// exist should say so in seconds rather than leave the sheet spinning.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// `repository` is the canonical `owner/repo` id -- `HuggingFaceRepository.parse`'s output.
    static func classify(repository: String) async -> Result<HuggingFaceClassification, Failure> {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repository)?blobs=true")
        else { return .failure(.notFound) }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.notReachable(detail: "not an HTTP response"))
            }
            guard http.statusCode == 200 else {
                return http.statusCode == 404 ? .failure(.notFound) : .failure(
                    .notReachable(detail: "HTTP \(http.statusCode)"))
            }
            let info = try JSONDecoder().decode(HuggingFaceModelInfo.self, from: data)
            return .success(
                ModelClassifier.classify(siblings: info.siblings, requiredBundles: ModelInventory.requiredBundles))
        } catch {
            return .failure(.notReachable(detail: error.localizedDescription))
        }
    }

    /// Repository ids that look like a GGUF conversion of `repositoryName` -- the "Inspect this
    /// instead" row set offered on a ``HuggingFaceClassification/notRunnable(reason:hasSafetensors:)``
    /// result. `repositoryName` is the bare repo name (no owner): searching on the owner as well
    /// would miss every third-party conversion, which is the common case -- the model's own author
    /// rarely publishes the quantised copy themselves.
    ///
    /// Never throws and never reports a network failure as anything but an empty list: a search
    /// that could not be read is not worth interrupting the "this repository will not run" message
    /// already on screen for.
    static func searchGGUFConversions(of repositoryName: String) async -> [String] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "search", value: "\(repositoryName) GGUF"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components.url else { return [] }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return [] }
        return ModelClassifier.searchSuggestions(from: data)
    }
}
