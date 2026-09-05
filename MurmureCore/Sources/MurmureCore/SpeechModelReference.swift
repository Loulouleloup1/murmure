import Foundation

/// A speech model exactly as WhisperKit's own Hugging Face Hub client names it: a repository
/// (`owner/name`) and the variant folder inside it.
///
/// **Why this exists.** Before this type, a mode's `stt.model` and the engine's own installed
/// folder lived in two different namespaces -- a friendly display alias (`"large-v3-turbo"`) on
/// one side, the exact on-disk folder name (`"openai_whisper-large-v3-v20240930_turbo"`) on the
/// other, with nothing that could hold the two in agreement (`SpeechModelResolution`'s own doc
/// comment, before this commit). Louis's own instruction on reviewing the Models pane was
/// specific: *"utiliser le format Hugging Face pour les modèles"* -- so ``string`` below IS the
/// display form as well as the resolvable one, and there is exactly one of it.
public struct SpeechModelReference: Equatable, Hashable, Sendable {
    /// The Hugging Face repository id, e.g. `argmaxinc/whisperkit-coreml`.
    public let repository: String
    /// The folder inside it, e.g. `openai_whisper-large-v3-v20240930_turbo`.
    public let variant: String

    public init(repository: String, variant: String) {
        self.repository = repository
        self.variant = variant
    }

    /// The exact model Murmure ships installed and warmed (`scripts/bootstrap.sh` runs
    /// `ModelWarmup`, which loads exactly this one). `WhisperKitEngine.dictationModel` and
    /// `WhisperKitEngine.modelRepo` are reads of this pair, not a second copy of the two strings --
    /// the same relationship ``ModelInventory/requiredBundles`` already holds between the app
    /// target and this package.
    public static let shippedDefault = SpeechModelReference(
        repository: "argmaxinc/whisperkit-coreml",
        variant: "openai_whisper-large-v3-v20240930_turbo")

    /// `"owner/name/variant"` -- the same three path segments a Hugging Face URL for this model
    /// carries (`huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-...`), read
    /// left to right. This is both the stored form (`Mode.stt.model`, once ``ModeStore`` has
    /// migrated it) and the display form (a speech ``ModelRow/name``): Louis asked for one format
    /// for both, not a stored value and a separate presentation of it.
    public var string: String { "\(repository)/\(variant)" }

    /// Parses `"owner/name/variant"`. The first two components are always the repository -- a
    /// Hugging Face repository id is always exactly `owner/name`, never deeper -- so everything
    /// after that, rejoined with `/`, is the variant. Joining rather than taking a single third
    /// component is deliberate: no variant folder on the installed store has ever itself
    /// contained a slash, but a parse that assumed it never could would silently truncate the day
    /// one does.
    ///
    /// Fewer than three components -- blank, the legacy display alias, a bare variant with no
    /// repository -- is not a reference at all, and this returns `nil` rather than guessing a
    /// repository for it. That guess is ``SpeechModelResolution``'s to make, with the caller's own
    /// engine default in hand; this initialiser has no default to fall back on and must not invent
    /// one.
    public init?(parsing string: String) {
        let components = string.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count >= 3 else { return nil }
        repository = "\(components[0])/\(components[1])"
        variant = components[2...].joined(separator: "/")
    }
}
