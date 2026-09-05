import Foundation

/// What a repository's own raw file listing says about which folders are speech-model variants,
/// for the repositories `WhisperKit.fetchAvailableModels` cannot answer for.
///
/// **Why this exists at all.** `fetchAvailableModels` reads a `config.json` at the repository
/// root; when there is none it does not fail or come back empty -- it falls back to Argmax's own
/// device-support list and answers with THAT, silently. A third-party repository that simply
/// holds CoreML folders with no `config.json` gets a plausible-looking list of variant names that
/// describes `argmaxinc/whisperkit-coreml`, not the repository asked about. That is a wrong answer
/// wearing the shape of a right one, which is worse than an empty list -- an empty list at least
/// says "nothing here". `SpeechModelCatalog`, the app-target caller that used to detect the
/// fallback firing and call this, is deleted -- `ModelClassifier` bypasses `fetchAvailableModels`
/// entirely now, reading the same raw blob listing every classification uses, so the fallback
/// never fires in the live app at all. What is here still detects and repairs it directly, for
/// whichever caller needs to (`benchmark/modelnettest` exercises it against a real repository) --
/// it is the mechanism, not the app-target wiring, that survives.
public enum SpeechModelListing {
    /// Every top-level folder in `filenames` that holds, somewhere under it, a path for EACH name
    /// in `requiredBundles` -- the same three bundles `ModelInventory.requiredBundles` and
    /// `WhisperKitEngine.load` require before a variant is considered loadable at all. A folder
    /// missing even one is not offered: it is either a different kind of asset (a tokenizer, a
    /// dataset card) or a variant this app could not load if it were offered.
    ///
    /// `filenames` is a flat file listing -- `HubApiWrapper.getFilenames`'s own shape, one path per
    /// file, no directories -- which is why "does this folder hold the bundle" is answered by a
    /// substring check on the file paths rather than a real tree walk.
    ///
    /// Sorted, for a deterministic menu: the two collections above are unordered.
    public static func plausibleVariants(in filenames: [String], requiredBundles: [String]) -> [String] {
        guard !requiredBundles.isEmpty else { return [] }

        var pathsByTopFolder: [String: [String]] = [:]
        for path in filenames {
            guard let slash = path.firstIndex(of: "/") else { continue }
            let top = String(path[path.startIndex..<slash])
            pathsByTopFolder[top, default: []].append(path)
        }

        let variants = pathsByTopFolder.filter { _, paths in
            requiredBundles.allSatisfy { bundle in paths.contains { $0.contains("/\(bundle)/") } }
        }.keys

        return variants.sorted()
    }
}
