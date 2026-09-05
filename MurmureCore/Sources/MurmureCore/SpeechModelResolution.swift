import Foundation

/// Parses a mode's stored `stt.model` into the repository and variant WhisperKit should load.
///
/// **Why this is not simply "pass `stt.model` straight through".** Before ``SpeechModelReference``
/// existed, `Mode.defaultSTTModel` was the friendly display alias `"large-v3-turbo"` -- the value
/// every built-in mode file carried since before this field did anything -- and it named no
/// folder WhisperKit's own Hub client would ever download into. ``ModeStore`` now rewrites that
/// alias to the real reference on load and saves the file (see its own doc comment on
/// `migrateSTTModelIfNeeded`), so a freshly migrated mode never reaches this function carrying
/// it. But migration is a write, and this function has to be right about a file it has not
/// written yet: the legacy alias, a blank field, and a bare variant with no repository at all are
/// still legitimate inputs here, for exactly the callers a migration has not reached -- a `Mode`
/// built in memory rather than loaded from disk, or a store `ModeStore` could not save back to
/// (its own write is best-effort).
///
/// Resolving an unrecognised alias against the Hub would mean a network call this function must
/// never make just to decide what an *existing, unedited* mode file means -- so the alias and a
/// blank field both collapse to `engineDefault` without ever asking anything but the string
/// itself.
public enum SpeechModelResolution {
    /// The shipped alias every mode file carried before ``SpeechModelReference`` existed --
    /// kept as a literal here rather than read back off `Mode.defaultSTTModel`, because that
    /// property now IS the reference string and is no longer equal to this.
    public static let legacyDefaultAlias = "large-v3-turbo"

    /// `stored` is `Mode.stt.model` as read from the file; `engineDefault` is the engine's own
    /// default, ``SpeechModelReference/shippedDefault`` at every real call site. Classified by
    /// ``StoredSTTModelShape``, the same classification ``ModeStore``'s migration uses -- see that
    /// type's own doc comment for why the two must never classify a stored value differently.
    ///
    /// What each shape resolves to:
    /// 1. Blank, or the legacy alias -- "nothing was actually asked for" -- resolves to
    ///    `engineDefault`.
    /// 2. A full `"owner/name/variant"` reference is returned exactly as parsed -- resolving
    ///    whether that repository and variant actually exist on the Hub is the engine's job, not
    ///    this one's.
    /// 3. A bare variant folder name with no repository -- the shape every mode file carried
    ///    before this migration, for a variant that is not the shipped default -- is assumed to
    ///    live in `engineDefault`'s own repository, the same assumption ``ModeStore``'s migration
    ///    makes when it rewrites this shape on disk.
    /// 4. Unresolvable (in practice, a two-component `"owner/name"` with no variant) -- there is
    ///    no reference to hand back, so this resolves to `engineDefault` exactly like the blank
    ///    case, which is the fallback ``ModeStore``'s own report for this shape promises
    ///    (`ModeLoadProblem.sttModelNotAReference`'s wording). Guessing a variant instead --
    ///    treating the whole two-component string as shape 3's single bare name -- was the exact
    ///    defect a review caught here: it silently pointed dictation at a fabricated reference
    ///    under `engineDefault`'s repository, which the Hub does not have, so it failed a download
    ///    round trip (or failed outright offline) instead of falling back the way the store's own
    ///    report claimed it would.
    public static func reference(
        storedAs stored: String, engineDefault: SpeechModelReference
    ) -> SpeechModelReference {
        switch StoredSTTModelShape.classify(stored) {
        case .blankOrLegacyAlias, .unresolvable:
            return engineDefault
        case .reference(let full):
            return full
        case .bareVariant(let variant):
            return SpeechModelReference(repository: engineDefault.repository, variant: variant)
        }
    }
}

/// The shape a stored `stt.model` is in, decided ONCE so ``ModeStore`` (deciding whether to rewrite
/// a file) and ``SpeechModelResolution`` (deciding what the engine loads right now) cannot silently
/// classify the same string two different ways.
///
/// **Why this type exists.** It replaces two independent copies of the same parsing rule that had
/// already drifted apart once: the store refused to complete a two-component value
/// (`ModeStore.STTModelMigration.unresolvable`) while the resolver still assumed a repository for
/// it, so a mode holding `"openai/whisper-large-v3"` kept its own file untouched -- correctly -- but
/// dictation still tried to load `argmaxinc/whisperkit-coreml/openai/whisper-large-v3`, a reference
/// that names a different model in a repository the mode never mentioned, and failed instead of
/// falling back the way the file's own report claimed it would. One classification, read by both,
/// is what keeps that from happening again silently.
enum StoredSTTModelShape: Equatable {
    /// Blank, or ``SpeechModelResolution/legacyDefaultAlias`` -- "nothing was actually asked for".
    case blankOrLegacyAlias
    /// Already a full reference, parsed by ``SpeechModelReference/init(parsing:)``.
    case reference(SpeechModelReference)
    /// A bare variant folder name with no repository at all -- exactly one path segment. Left to
    /// the caller to complete against whichever repository it treats as the default.
    case bareVariant(String)
    /// Neither of the above -- in practice, exactly two segments (`"owner/name"`, no variant).
    /// Not completable by guessing the missing segment: doing so silently points at a DIFFERENT
    /// model than the one actually named, which is the defect this type exists to rule out.
    case unresolvable(String)

    /// Trimmed before classifying, the same way `Mode.validationError` trims before deciding a
    /// field is empty.
    static func classify(_ stored: String) -> StoredSTTModelShape {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == SpeechModelResolution.legacyDefaultAlias {
            return .blankOrLegacyAlias
        }
        if let full = SpeechModelReference(parsing: trimmed) { return .reference(full) }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        return components.count == 1 ? .bareVariant(trimmed) : .unresolvable(trimmed)
    }
}
