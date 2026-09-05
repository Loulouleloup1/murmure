import XCTest
@testable import MurmureCore

/// A literal, byte-for-byte copy of `WhisperKit.Constants.languages` (WhisperKit 1.1.0,
/// `Sources/WhisperKit/Core/Models.swift`) -- `MurmureCore` cannot import WhisperKit itself
/// (`Mode.swift`'s own doc comment), so this is how `LanguageOptions.dedupe` is tested against the
/// REAL shape (112 names, 100 codes, eleven codes shared by more than one name) rather than a
/// synthetic toy dictionary that would not have caught the duplicate-id defect this type fixes
/// (review, lot 3a, item 3). If WhisperKit's own table ever changes, this copy has to be
/// refreshed alongside it.
private let realWhisperKitLanguages: [String: String] = [
    "english": "en", "chinese": "zh", "german": "de", "spanish": "es", "russian": "ru",
    "korean": "ko", "french": "fr", "japanese": "ja", "portuguese": "pt", "turkish": "tr",
    "polish": "pl", "catalan": "ca", "dutch": "nl", "arabic": "ar", "swedish": "sv",
    "italian": "it", "indonesian": "id", "hindi": "hi", "finnish": "fi", "vietnamese": "vi",
    "hebrew": "he", "ukrainian": "uk", "greek": "el", "malay": "ms", "czech": "cs",
    "romanian": "ro", "danish": "da", "hungarian": "hu", "tamil": "ta", "norwegian": "no",
    "thai": "th", "urdu": "ur", "croatian": "hr", "bulgarian": "bg", "lithuanian": "lt",
    "latin": "la", "maori": "mi", "malayalam": "ml", "welsh": "cy", "slovak": "sk",
    "telugu": "te", "persian": "fa", "latvian": "lv", "bengali": "bn", "serbian": "sr",
    "azerbaijani": "az", "slovenian": "sl", "kannada": "kn", "estonian": "et", "macedonian": "mk",
    "breton": "br", "basque": "eu", "icelandic": "is", "armenian": "hy", "nepali": "ne",
    "mongolian": "mn", "bosnian": "bs", "kazakh": "kk", "albanian": "sq", "swahili": "sw",
    "galician": "gl", "marathi": "mr", "punjabi": "pa", "sinhala": "si", "khmer": "km",
    "shona": "sn", "yoruba": "yo", "somali": "so", "afrikaans": "af", "occitan": "oc",
    "georgian": "ka", "belarusian": "be", "tajik": "tg", "sindhi": "sd", "gujarati": "gu",
    "amharic": "am", "yiddish": "yi", "lao": "lo", "uzbek": "uz", "faroese": "fo",
    "haitian creole": "ht", "pashto": "ps", "turkmen": "tk", "nynorsk": "nn", "maltese": "mt",
    "sanskrit": "sa", "luxembourgish": "lb", "myanmar": "my", "tibetan": "bo", "tagalog": "tl",
    "malagasy": "mg", "assamese": "as", "tatar": "tt", "hawaiian": "haw", "lingala": "ln",
    "hausa": "ha", "bashkir": "ba", "javanese": "jw", "sundanese": "su", "cantonese": "yue",
    "burmese": "my", "valencian": "ca", "flemish": "nl", "haitian": "ht",
    "letzeburgesch": "lb", "pushto": "ps", "panjabi": "pa", "moldavian": "ro",
    "moldovan": "ro", "sinhalese": "si", "castilian": "es", "mandarin": "zh",
]

final class LanguageOptionsTests: XCTestCase {
    /// The shape the defect actually lived in: 112 names sharing 100 codes.
    func testTheRealTableHasMoreNamesThanCodes() {
        XCTAssertEqual(realWhisperKitLanguages.count, 112)
        XCTAssertEqual(Set(realWhisperKitLanguages.values).count, 100)
    }

    /// One row per code, not per name -- the fix for the 12 duplicate `ForEach` ids.
    func testDedupeOnTheRealTableProducesExactlyOneRowPerCode() {
        let options = LanguageOptions.dedupe(realWhisperKitLanguages)

        XCTAssertEqual(options.count, 100)
        XCTAssertEqual(Set(options.map(\.code)).count, 100, "a code appears more than once")
    }

    func testDedupeIsSortedByName() {
        let options = LanguageOptions.dedupe(realWhisperKitLanguages)

        XCTAssertEqual(options.map(\.name), options.map(\.name).sorted())
    }

    /// Deterministic across runs: the display name comes from `Locale`, fixed per code, so a
    /// shared code's chosen NAME (which of romanian/moldavian/moldovan) no longer matters to the
    /// output -- only the code does, and `Locale` always answers the same way for the same code.
    func testDedupePicksTheSameNameForASharedCodeEveryRun() {
        let first = LanguageOptions.dedupe(realWhisperKitLanguages)
        let second = LanguageOptions.dedupe(realWhisperKitLanguages)

        XCTAssertEqual(first, second)
        let ro = try! XCTUnwrap(first.first { $0.code == "ro" })
        XCTAssertEqual(ro.name, "Romanian")
    }

    /// The one code every shipped mode actually uses (`voice.json`, `prompt.json` both store
    /// `"fr"`) has to survive the dedupe, shown under the name `Locale` gives it rather than the
    /// table's own lowercase spelling.
    func testFrenchSurvivesTheDedupe() {
        let options = LanguageOptions.dedupe(realWhisperKitLanguages)

        XCTAssertEqual(options.first { $0.code == "fr" }?.name, "French")
    }

    // MARK: - The three pinned codes (review, lot 3a leftovers, item 3)

    /// Not "Castilian": WhisperKit's own table keeps `castilian`/`spanish` under one code and the
    /// first-alphabetical tie-break used to surface the former, with no "Spanish" anywhere in the
    /// list. `Locale` fixes this because it does not consult the table's own name at all.
    func testSpanishNamesTheCodeEsRatherThanCastilian() {
        let options = LanguageOptions.dedupe(realWhisperKitLanguages)
        XCTAssertEqual(options.first { $0.code == "es" }?.name, "Spanish")
    }

    /// Not "Moldavian": same defect, over `ro`.
    func testRomanianNamesTheCodeRoRatherThanMoldavian() {
        let options = LanguageOptions.dedupe(realWhisperKitLanguages)
        XCTAssertEqual(options.first { $0.code == "ro" }?.name, "Romanian")
    }

    func testFrenchIsCapitalisedTheWayLocaleWritesIt() {
        let options = LanguageOptions.dedupe(realWhisperKitLanguages)
        XCTAssertEqual(options.first { $0.code == "fr" }?.name, "French")
    }

    /// A code `Locale` itself does not resolve -- `"zz"` is not a real ISO 639 code and is not in
    /// WhisperKit's own table either -- falls back to the table's own name rather than being
    /// dropped or crashing.
    func testACodeLocaleDoesNotKnowFallsBackToTheTablesOwnName() {
        let options = LanguageOptions.dedupe(["klingon": "zz"])
        XCTAssertEqual(options, [LanguageOption(code: "zz", name: "klingon")])
    }

    // MARK: - A small synthetic case, read independently of the real table above

    /// The dedupe still collapses a shared code to one entry -- which raw name it kept no longer
    /// shows in the OUTPUT (both resolve to the same `Locale` name), but only one row must exist.
    func testASharedCodeCollapsesToOneEntry() {
        let options = LanguageOptions.dedupe(["zulu": "zu", "chinese": "zh", "mandarin": "zh"])

        XCTAssertEqual(options, [
            LanguageOption(code: "zh", name: "Chinese"),
            LanguageOption(code: "zu", name: "Zulu"),
        ])
    }

    func testNoDuplicatesProducesOneEntryPerInput() {
        let options = LanguageOptions.dedupe(["french": "fr", "german": "de"])

        XCTAssertEqual(options, [
            LanguageOption(code: "fr", name: "French"),
            LanguageOption(code: "de", name: "German"),
        ])
    }

    func testEmptyTableProducesNoOptions() {
        XCTAssertEqual(LanguageOptions.dedupe([:]), [])
    }
}
