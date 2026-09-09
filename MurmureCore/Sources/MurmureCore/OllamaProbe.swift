import Foundation

/// Asking the local Ollama which models it has, and reading the answer as a row of the Models
/// table.
///
/// **Why the reachability check is a listing and not a call.** `/api/tags` reads Ollama's own
/// manifest directory and answers with what is on that disk; it loads nothing into memory. A
/// one-token `/api/generate` would answer the same question and would *also* pull a multi-gigabyte
/// model into RAM to do it — a settings pane that quietly warmed a model because it was opened is
/// a settings pane that costs seconds and gigabytes to look at.
///
/// **Why the failures are ``OllamaFailure`` and not a new enum.** T8 asks that "Ollama isn't
/// running" and "the model isn't pulled" stay two different sentences. They already are: lot 2
/// wrote that classification, measured it against the real server, and gave each case its own
/// remedy. A second vocabulary here would be a second place for the two to drift back into one.
///
/// The consequence, stated rather than left to be found: the sentences are written for the moment
/// a *dictation* fails ("...and dictate again"), which is a shade off in a settings table. That is
/// the price of having one sentence per failure in the whole app, and it is the right way round —
/// a table with its own wording would be a table that can disagree with the notch about what is
/// wrong.
public enum OllamaProbe {
    /// The listing route on a mode's configured base URL. The base is the root
    /// (`http://localhost:11434`), and nothing here edits it — see ``OllamaChat/endpoint(base:)``
    /// for why a wrong endpoint has to stay wrong and visible.
    public static func endpoint(base: URL) -> URL {
        base.appending(path: "api/tags")
    }

    /// What one probe concluded about one model.
    public enum Outcome: Equatable {
        /// The server answered and lists this model. `bytes` is the size it reports, 0 when the
        /// listing carried none.
        case pulled(bytes: Int64)
        case failed(OllamaFailure)
    }

    /// Reads the listing.
    ///
    /// The model is a parameter because the verdict is about the *relationship* between the
    /// answer and the model asked about — the same reason ``OllamaChat/outcome(status:body:transcript:model:)``
    /// takes one.
    public static func outcome(status: Int, body: Data, model: String) -> Outcome {
        // A non-200 means the same things on this route as on the other two, so it is read by the
        // same function. A 404 here is a mistyped endpoint rather than a missing model — Ollama
        // answers `/api/tags` whether or not it holds anything — and `statusFailure` already
        // distinguishes the JSON "model not found" body from the bare "404 page not found".
        if let failure = OllamaChat.statusFailure(status: status, body: body, model: model) {
            return .failed(failure)
        }

        let listing: Listing
        do {
            listing = try JSONDecoder().decode(Listing.self, from: body)
        } catch {
            return .failed(OllamaChat.unreadableBody(error, body))
        }

        let wanted = tagged(model)
        guard let found = listing.models.first(where: { tagged($0.name) == wanted }) else {
            return .failed(.modelNotPulled(model: model))
        }
        return .pulled(bytes: found.size ?? 0)
    }

    /// Reads a transport failure. Delegates, so "nothing is listening on the loopback address"
    /// is classified once in this package and not once per route.
    public static func outcome(transport error: any Error, elapsed: TimeInterval) -> Outcome {
        .failed(OllamaChat.failure(transport: error, elapsed: elapsed))
    }

    /// One model in Ollama's own listing: its name exactly as Ollama spells it, and the size it
    /// reports (0 when the listing carries none).
    public struct Listed: Equatable {
        public let name: String
        public let bytes: Int64

        public init(name: String, bytes: Int64) {
            self.name = name
            self.bytes = bytes
        }
    }

    /// What reading the whole listing concluded -- mirrors ``Outcome`` in shape rather than using
    /// `Swift.Result`, because `OllamaFailure` carries no `Error` conformance and adding one just
    /// to satisfy `Result`'s generic constraint would be a second reason for that type to exist.
    public enum ListingOutcome: Equatable {
        case listed([Listed])
        case failed(OllamaFailure)
    }

    /// Every model Ollama's own listing carries -- for the Models pane's "every model Ollama has,
    /// independent of which mode names one" row set and the mode editor's Refiner model picker,
    /// neither of which is ``outcome(status:body:model:)``'s question ("is THIS one model
    /// pulled"). Reads the same `/api/tags` body that function does, through the same
    /// `Listing`/`Entry` decode, so the two cannot disagree about what "the listing" contains.
    ///
    /// `model` in ``OllamaChat/statusFailure(status:body:model:)`` names the model a 404 might be
    /// about -- irrelevant to a listing, which asks about none in particular, so it is passed as
    /// an empty string. The one 404 shape that check exists to catch, "model not found", cannot be
    /// this route's answer to begin with: `/api/tags` takes no model parameter to have not found.
    public static func list(status: Int, body: Data) -> ListingOutcome {
        if let failure = OllamaChat.statusFailure(status: status, body: body, model: "") {
            return .failed(failure)
        }
        do {
            let listing = try JSONDecoder().decode(Listing.self, from: body)
            return .listed(listing.models.map { Listed(name: $0.name, bytes: $0.size ?? 0) })
        } catch {
            return .failed(OllamaChat.unreadableBody(error, body))
        }
    }

    /// The table row a probe produces — or the row before any probe has run, when `outcome` is
    /// `nil`.
    ///
    /// The un-probed row exists because the table is drawn before the probe is allowed to run:
    /// the pane must show which language model a mode is configured with even when nothing has
    /// been asked of Ollama yet, and "not asked" must not be drawn as "not installed". They are
    /// different facts and the sentence says so.
    public static func row(for model: String, outcome: Outcome?) -> ModelRow {
        ModelRow(identifier: model, kind: .language, installation: installation(from: outcome))
    }

    private static func installation(from outcome: Outcome?) -> ModelInstallation {
        guard let outcome else {
            return .undetermined(reason: notCheckedYet)
        }
        switch outcome {
        case .pulled(let bytes):
            return .installed(bytes: bytes)
        // The one failure that IS an answer about the model: the server replied and does not have
        // it. That is `absent`, exactly like a speech model nobody downloaded, and the row's own
        // `detail` derives the `ollama pull` line from the identifier — so the sentence is
        // ``OllamaFailure/modelNotPulled(model:)``'s and there is still only one of it.
        case .failed(.modelNotPulled):
            return .absent
        case .failed(let failure):
            return .undetermined(reason: failure.remedy)
        }
    }

    /// The sentence a row carries before anything has been asked of Ollama. Here rather than in
    /// the view because it is the *distinction* T8 is about: not-asked and not-installed are
    /// different facts, and the only thing that keeps them apart on screen is this string being a
    /// different one.
    public static let notCheckedYet = "Not checked yet."

    /// An identifier with its implicit tag made explicit.
    ///
    /// Ollama's listing always spells the tag — a `ollama pull gemma3` is listed as
    /// `gemma3:latest` — while a mode file may or may not. Comparing the two raw strings would
    /// report a model as not pulled while it sits in the listing one word away, and the remedy
    /// shown would be a `ollama pull` of something already there.
    ///
    /// The tag is looked for **after the last slash**, not in the whole string, for the reason
    /// ``ModelDisplayName`` splits there: a registry with a port (`localhost:11434/team/model`)
    /// carries a colon that is not a tag.
    public static func tagged(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastComponent = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return lastComponent.contains(":") ? trimmed : trimmed + ":latest"
    }

    /// The half of `/api/tags` this file reads. Ollama sends more per entry (digest, modified
    /// date, a `details` block); decoding only what is used means a field added on their side
    /// cannot break the probe.
    private struct Listing: Decodable {
        struct Entry: Decodable {
            let name: String
            /// Absent from some builds' listings, so optional rather than a decode failure: a
            /// missing size costs a blank size column, and refusing the whole listing over it
            /// would cost the answer to "is it pulled".
            let size: Int64?
        }
        let models: [Entry]
    }
}
