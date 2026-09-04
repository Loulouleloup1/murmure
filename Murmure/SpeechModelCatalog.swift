import Foundation
import MurmureCore
import WhisperKit

/// Asking a Hugging Face repository which speech-model variants it offers -- the "list what it
/// offers" step of *"connecter Hugging Face"*, before a variant is picked and downloaded.
///
/// Kept in the app target rather than `MurmureCore` for the one reason that decides it every time
/// in this codebase: it calls WhisperKit, which only the app target links. The DECISION this file
/// makes -- what to do when the repository has no support config -- is one line
/// (`config.repoName == Constants.fallbackModelSupportConfig.repoName`); everything it is a
/// decision ABOUT (parsing what was typed, deriving a plausible variant from a raw file listing)
/// already lives in `MurmureCore` and is tested there.
enum SpeechModelCatalog {
    /// What asking a repository came back with.
    enum Listing: Equatable {
        /// The repository publishes its own `config.json`, and this is what it lists.
        case variants([String])
        /// No support config on this repository. `WhisperKit.fetchModelSupportConfig` does not
        /// fail or come back empty when that file is missing -- it silently answers with
        /// Argmax's OWN fallback list, which is a real answer about a DIFFERENT repository worn
        /// as though it were this one (`SpeechModelListing`'s own doc comment). What is offered
        /// here instead is read straight from this repository's file listing: every folder that
        /// holds the three bundles a variant needs before this app could load it at all.
        case derivedVariants([String])
        /// Neither a config nor any folder that looks like a model variant.
        case none
        /// The repository could not be reached or does not exist. `detail` is what the Hub client
        /// said, because a repository id can be wrong in more ways than one sentence could name.
        case failure(detail: String)
    }

    /// `repository` is the canonical `owner/repo` id -- `HuggingFaceRepository.parse`'s output,
    /// not raw user input.
    static func fetchListing(repository: String) async -> Listing {
        let config = await WhisperKit.fetchModelSupportConfig(from: repository)

        // The one signal available that the config above is a real answer about THIS repository
        // rather than the generic fallback: `fetchModelSupportConfig` returns
        // `Constants.fallbackModelSupportConfig` verbatim when it found no `config.json`, and
        // that constant's `repoName` is the literal "whisperkit-coreml-fallback" -- a name no
        // real repository on the Hub can carry, since a repository's `config.json` names ITSELF.
        guard config.repoName == Constants.fallbackModelSupportConfig.repoName else {
            let variants = (try? await WhisperKit.fetchAvailableModels(from: repository)) ?? []
            return variants.isEmpty ? .none : .variants(variants.sorted())
        }

        do {
            let files = try await HubApiWrapper().getFilenames(
                from: .init(id: repository, type: .models))
            let derived = SpeechModelListing.plausibleVariants(
                in: files, requiredBundles: ModelInventory.requiredBundles)
            return derived.isEmpty ? .none : .derivedVariants(derived)
        } catch {
            return .failure(detail: error.localizedDescription)
        }
    }
}
