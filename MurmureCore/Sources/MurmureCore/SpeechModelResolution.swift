import Foundation

/// Which WhisperKit variant a mode's stored `stt.model` actually asks the engine to load.
///
/// **Why this is not simply "pass `stt.model` straight through".** `Mode.defaultSTTModel` is
/// `"large-v3-turbo"` -- the value every built-in mode file has carried since before this field
/// did anything -- and it is a friendly alias, not the exact folder
/// `WhisperKitEngine.dictationModel` downloads and verifies (`"openai_whisper-…v20240930_turbo"`,
/// see that constant's own doc comment for why the two strings differ). Resolving an alias into an
/// exact folder means asking the Hub which folder it matches (`WhisperKit.download`'s own glob
/// search), and that is a network call this rule must never make on Louis's behalf just to decide
/// what an *existing, unedited* mode file means. So the alias every mode already carries, and a
/// blank field, both mean the same thing here -- "nothing was actually asked for" -- and resolve to
/// the engine's own default. Only a variant somebody typed that is neither of those is passed
/// through unchanged, for the engine to try resolving for real.
public enum SpeechModelResolution {
    /// `stored` is `Mode.stt.model` as read from the file; `engineDefault` is
    /// `WhisperKitEngine.dictationModel`. Trimmed before comparison, the same way
    /// `Mode.validationError` trims before deciding a field is empty.
    public static func variant(storedAs stored: String, engineDefault: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == Mode.defaultSTTModel { return engineDefault }
        return trimmed
    }
}
