import Foundation

/// The wire shape of Hugging Face's `GET /api/models/<owner>/<repo>?blobs=true` -- the one field
/// that decides what "Add a model" can do with a repository: which files it holds, and how big
/// each one is.
///
/// Decoding only `siblings` -- the endpoint sends far more (`downloads`, `tags`, `cardData`...) --
/// means a field Hugging Face adds later cannot break this. `size` is optional because `blobs=true`
/// is what asks for it in the first place; a caller that forgot the query parameter gets a listing
/// with no sizes rather than a decode failure, and ``ModelClassifier`` already treats an unknown
/// size as "-" rather than as an error.
public struct HuggingFaceSibling: Decodable, Equatable, Sendable {
    public let rfilename: String
    public let size: Int64?

    public init(rfilename: String, size: Int64?) {
        self.rfilename = rfilename
        self.size = size
    }
}

/// The half of the model-info response this app reads.
public struct HuggingFaceModelInfo: Decodable, Equatable, Sendable {
    public let siblings: [HuggingFaceSibling]

    public init(siblings: [HuggingFaceSibling]) {
        self.siblings = siblings
    }
}

/// One hit of `GET /api/models?search=...` -- the repository id, which is the only thing an
/// "Inspect this instead" affordance needs. Hugging Face's search response carries far more per
/// hit (`likes`, `downloads`, `tags`...); none of it is read here.
public struct HuggingFaceSearchResult: Decodable, Equatable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

/// One quantisation a repository offers, and the `.gguf` file(s) Ollama's `hf.co/<repo>:<tag>`
/// pull would fetch to install it -- one shard, or every shard of a sharded model that all share
/// this one tag.
public struct RefinerCandidate: Equatable, Sendable {
    /// Every `.gguf` file this tag pulls in, comma-joined -- a sharded model publishes several
    /// (`model-00001-of-00002.gguf, model-00002-of-00002.gguf`) that install as one Ollama pull
    /// and must read as one row, not one row per shard.
    public let filename: String
    public let tag: String
    /// The sum of every shard's size, or `nil` the moment any one of them has none --
    /// ``ModelClassifier/totalSize(under:in:)`` makes the identical call for a speech variant's
    /// folder, for the identical reason: a partial sum reads as a real number with nothing saying
    /// it undercounts.
    public let bytes: Int64?

    public init(filename: String, tag: String, bytes: Int64?) {
        self.filename = filename
        self.tag = tag
        self.bytes = bytes
    }
}

/// One speech-model variant a repository offers -- a top-level folder holding every one of
/// ``ModelInventory/requiredBundles`` -- and what it weighs, when every file under it reported a
/// size.
public struct SpeechCandidate: Equatable, Sendable {
    public let variant: String
    public let bytes: Int64?

    public init(variant: String, bytes: Int64?) {
        self.variant = variant
        self.bytes = bytes
    }
}

/// Which of Murmure's two engines a model, once installed, would run under.
public enum ModelRole: Equatable, Sendable {
    case speech
    case refiner
}

/// What "Inspect" concluded about a Hugging Face repository's blob listing.
///
/// **Why this reads the raw blob listing rather than `WhisperKit.fetchAvailableModels`.** That
/// WhisperKit call silently substitutes Argmax's own fallback table on a repository with no
/// `config.json` -- a wrong answer that looks right. `SpeechModelCatalog`, the app-target listing
/// that used to call it and detect the substitution after the fact, is deleted along with the
/// call: reading the repository's own files instead, the way this classifier does for every
/// repository and not only as a fallback, never has that failure mode to begin with, so there was
/// nothing left for the detector to detect in the live app.
public enum HuggingFaceClassification: Equatable, Sendable {
    case speechOnly([SpeechCandidate])
    case refinerOnly([RefinerCandidate])
    /// Both roles are real candidates -- the repository holds WhisperKit bundles AND `.gguf`
    /// files. Louis's own words: *"je veux ajouter N'IMPORTE QUEL modèle et choisir moi-même s'il
    /// s'agit d'un modèle de parole ou d'un modèle de raffinement"* -- so this case exists to be
    /// shown, not resolved for him.
    case both(speech: [SpeechCandidate], refiner: [RefinerCandidate])
    /// Neither engine can load anything here -- e.g. `XHToken/Spark-X2.5-4B`, five safetensors
    /// shards and nothing else. `hasSafetensors` is what decides whether searching for a GGUF
    /// conversion is worth trying: an empty or unreadable repository has no conversion to look for
    /// either.
    case notRunnable(reason: String, hasSafetensors: Bool)
}

/// Deriving what "Add a model" can offer from a repository's own files, and nothing else --
/// no network, no WhisperKit, no Ollama. Fed by ``HuggingFaceModelInfo`` (the app target's fetch
/// of the blobs listing) or, for a bare `.gguf` filename, usable on its own.
public enum ModelClassifier {
    /// The full verdict for one repository: every speech variant `SpeechModelListing` finds,
    /// every `.gguf` file turned into a candidate, and which of the four shapes that adds up to.
    ///
    /// `requiredBundles` travels in rather than being read off ``ModelInventory`` directly so this
    /// file needs nothing from that one beyond what a caller already has to pass -- the same
    /// seam ``SpeechModelListing/plausibleVariants(in:requiredBundles:)`` already uses.
    public static func classify(
        siblings: [HuggingFaceSibling], requiredBundles: [String]
    ) -> HuggingFaceClassification {
        let filenames = siblings.map(\.rfilename)
        let speech = SpeechModelListing.plausibleVariants(in: filenames, requiredBundles: requiredBundles)
            .map { SpeechCandidate(variant: $0, bytes: totalSize(under: $0, in: siblings)) }
        let refiner = refinerCandidates(in: siblings)

        switch (speech.isEmpty, refiner.isEmpty) {
        case (false, false):
            return .both(speech: speech, refiner: refiner)
        case (false, true):
            return .speechOnly(speech)
        case (true, false):
            return .refinerOnly(refiner)
        case (true, true):
            let hasSafetensors = filenames.contains { $0.lowercased().hasSuffix(".safetensors") }
            let reason = hasSafetensors
                ? "This repository only publishes safetensors weights -- not a format WhisperKit "
                    + "or Ollama can load directly."
                : "This repository has no WhisperKit model bundles and no GGUF files Murmure could run."
            return .notRunnable(reason: reason, hasSafetensors: hasSafetensors)
        }
    }

    /// Every `.gguf` file in the listing, grouped into one candidate PER QUANTISATION -- not one
    /// per file. `ollama pull hf.co/<repo>:<tag>` fetches every shard that shares a tag in one
    /// pull, so a three-shard `Q4_K_M` model is one thing Ollama installs, and offering it as
    /// three identical-looking "Q4_K_M" rows would let Louis press Install on the wrong fraction
    /// of it. A file whose name carries no recognisable quantisation (checked on its own folder
    /// too -- see `GGUFQuantization.tag`) is skipped rather than offered with a guessed tag: an
    /// install button has to name something Ollama's `hf.co/` pull will actually resolve.
    static func refinerCandidates(in siblings: [HuggingFaceSibling]) -> [RefinerCandidate] {
        struct Group {
            var filenames: [String] = []
            var bytes: Int64 = 0
            var sizeKnown = true
        }
        var order: [String] = []
        var groups: [String: Group] = [:]
        for sibling in siblings where sibling.rfilename.lowercased().hasSuffix(".gguf") {
            guard let tag = GGUFQuantization.tag(fromFilename: sibling.rfilename) else { continue }
            if groups[tag] == nil {
                order.append(tag)
                groups[tag] = Group()
            }
            groups[tag]?.filenames.append(sibling.rfilename)
            if let size = sibling.size, groups[tag]?.sizeKnown == true {
                groups[tag]?.bytes += size
            } else {
                groups[tag]?.sizeKnown = false
            }
        }
        return order.map { tag in
            let group = groups[tag]!
            return RefinerCandidate(
                filename: group.filenames.joined(separator: ", "), tag: tag,
                bytes: group.sizeKnown ? group.bytes : nil)
        }
    }

    /// Every hit's repository id, for the "Inspect this instead" row search offers on a
    /// ``HuggingFaceClassification/notRunnable(reason:hasSafetensors:)`` result. Never throws: a
    /// search response this cannot read is an empty list of suggestions, not a crash of the
    /// sheet that is already explaining a different repository could not be run.
    public static func searchSuggestions(from data: Data) -> [String] {
        (try? JSONDecoder().decode([HuggingFaceSearchResult].self, from: data))?.map(\.id) ?? []
    }

    /// The bytes under `folder/` -- `nil` unless EVERY file under it reported a size. A sum built
    /// from only the files that happened to report one would be a number smaller than the truth
    /// with nothing saying so; the row's own size column already reads "-" for `nil`
    /// (`ModelSize` is never asked to print a lie by omission).
    private static func totalSize(under folder: String, in siblings: [HuggingFaceSibling]) -> Int64? {
        let prefix = folder + "/"
        let matching = siblings.filter { $0.rfilename.hasPrefix(prefix) }
        guard !matching.isEmpty else { return nil }
        var total: Int64 = 0
        for file in matching {
            guard let size = file.size else { return nil }
            total += size
        }
        return total
    }
}

/// Reading the quantisation Ollama expects out of a `.gguf` file's own name.
///
/// **Why this is a general rule and not a lookup table.** A hard-coded list of known quantisation
/// strings would need a new entry every time a quantisation scheme is invented, and would silently
/// offer nothing for one it had not been told about yet -- the empty-list failure this whole
/// feature exists to avoid. Instead this reads the shape every quantised GGUF filename shares:
/// the last `-` or `.`-separated segment before `.gguf` that looks like one (`Q4_K_M`, `IQ4_XS`,
/// `F16`...), on the two separators real repositories are seen using
/// (`s1-mini-q4_k_m.gguf`, a hyphen; `Meta-Llama-3-8B.Q4_K_M.gguf`, a dot). An underscore is never
/// a split point: `Q4_K_M` is one token, not three.
public enum GGUFQuantization {
    /// `nil` when `filename` does not end in `.gguf`, or when neither the basename nor its parent
    /// folder carries a segment that looks like a quantisation.
    ///
    /// **Reads the basename, not the whole path.** `rfilename` in a Hugging Face listing is the
    /// full path within the repository, and a sharded model often nests its files one folder per
    /// quantisation (`Q4_K_M/model-00001-of-00002.gguf`). Splitting that whole string on `-`/`.`
    /// without first dropping the `Q4_K_M/` folder read `Q4_K_M/model` as one segment -- and
    /// because it starts with `Q` followed by a digit, ``looksLikeQuantisation`` accepted it,
    /// producing the tag `Q4_K_M/MODEL`, which is not anything Ollama's `hf.co/` pull would ever
    /// resolve. Reading only the last path component first is what keeps a folder name from ever
    /// leaking into the tag this way.
    ///
    /// **Falls back to the parent folder when the basename alone has no quantisation token.** The
    /// same sharded layout often names every shard generically
    /// (`model-00001-of-00002.gguf`, `model-00002-of-00002.gguf`) and puts the one piece of
    /// information that actually varies -- the quantisation -- on the enclosing folder instead.
    /// A bare `model.gguf` with nothing above it and no tag in its own name still resolves to
    /// `nil`: there is nothing here Ollama's `hf.co/` pull could name.
    ///
    /// Returned upper-cased: Ollama's own listing of a `hf.co/` pull shows the tag as typed at
    /// pull time, not as read off the filename -- the model already installed on this machine
    /// (`hf.co/superwhisper/s1-mini-GGUF:Q4_K_M`) was pulled with an upper-case tag even though
    /// its file is `s1-mini-q4_k_m.gguf`. Matching that convention, rather than the file's own
    /// case, is what makes a candidate's tag read the way every other row in the table already
    /// does.
    public static func tag(fromFilename filename: String) -> String? {
        guard filename.lowercased().hasSuffix(".gguf") else { return nil }
        let components = filename.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let basename = components.last ?? filename
        if let quant = quantisationSegment(in: basename) {
            return quant.uppercased()
        }
        guard components.count > 1, let parent = components.dropLast().last,
            looksLikeQuantisation(parent)
        else { return nil }
        return parent.uppercased()
    }

    /// The last `-`/`.`-separated segment of `basename` (its `.gguf` extension already dropped)
    /// that looks like a quantisation, or `nil` when none does.
    private static func quantisationSegment(in basename: String) -> String? {
        let stem = basename.hasSuffix(".gguf") ? String(basename.dropLast(".gguf".count)) : basename
        let segments = stem.split(whereSeparator: { $0 == "-" || $0 == "." }).map(String.init)
        return segments.last(where: looksLikeQuantisation)
    }

    /// `Q<digits>...` or `IQ<digits>...` -- the llama.cpp k-quant and i-quant families -- or one of
    /// the unquantised storage formats a repository sometimes ships alongside them.
    private static func looksLikeQuantisation(_ segment: String) -> Bool {
        let upper = segment.uppercased()
        if upper.hasPrefix("IQ"), upper.dropFirst(2).first?.isNumber == true { return true }
        if upper.hasPrefix("Q"), upper.dropFirst().first?.isNumber == true { return true }
        return ["F16", "F32", "BF16", "FP16"].contains(upper)
    }
}
