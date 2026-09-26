import AppKit
import Foundation
import MurmureCore

/// What the Transcripts pane is looking at: the tiles the folder yields, the one open in reading
/// mode, and the two things a tile offers (criterion 17: open and delete, nothing else).
///
/// Thin, like `HistoryPaneModel` and `VocabularyPaneModel` and for the same reason -- the app
/// target has no test bundle, so anything decided here is verified by reading. Everything that is
/// a decision is in `MurmureCore` and tested there: what a tile shows and in what order
/// (`TranscriptTile`, contract of lot 9), how wide a tile is and how many fit (`TranscriptsLayout`,
/// same contract), where the files live and what a listing is (`TranscriptLibrary`, lot 2). What
/// is left below is one folder walk, one `NSWorkspace` call, and one `FileManager.removeItem`.
///
/// **This model creates nothing.** `TranscriptLibrary.defaultBase` is `Storage.url(subfolder:)`,
/// the PURE path, and nothing here calls `Storage.directory()`: opening the window must not build
/// a folder in Louis's Application Support (the rule `FinderReveal` states for the two reveal
/// buttons that already exist), and the first launch therefore shows an empty grid rather than an
/// empty folder it made on the way in.
///
/// **No transcript content is ever logged.** There is no `Logger` in this file at all: the
/// library's three reads do not throw (an unreadable file is counted, an unknown id is a tile that
/// already went away), so there is nothing to report beyond a word on screen -- and a word about a
/// transcription is a transcription in the log (criterion 15).
@MainActor
final class TranscriptsPaneModel: ObservableObject {
    /// The tiles, already in display order -- `createdAt` descending, then `id` (rule 8 of the
    /// lot-9 contract). Nothing sorts here: the order is a decision, and it is in the core.
    @Published private(set) var tiles: [TranscriptTile] = []

    /// How many `.json` files the last listing could not read.
    ///
    /// Not decoration: it is the only thing that explains a transcript Louis can see in the Finder
    /// and not in the grid, and the library counts them exactly so this can say so (criterion 14).
    /// A count and never a name -- the file name is the transcript's title.
    @Published private(set) var unreadableCount = 0

    /// The tile open in reading mode, or nil while the grid is showing.
    @Published private(set) var openID: String?

    /// The document being read, decoded from disk when it was opened. **Not kept in `tiles`**: a
    /// tile is five strings, and the reading pane needs the segments. Re-read on every open, so a
    /// transcript rewritten between two clicks is the one that is shown.
    @Published private(set) var openDocument: TranscriptDocument?

    /// What went wrong with the one thing here that can refuse: the Finder.
    @Published private(set) var problem: String?

    /// The queue's elements, in the order they were added (criterion 19).
    ///
    /// A mirror of `TranscriptQueue.entries`, refreshed at every transition (a launch, the end of a
    /// job): the queue is an actor, the view cannot `await`, and reading it once per frame is not a
    /// thing a SwiftUI body may do. The queue stays the authority -- nothing here reorders, filters
    /// or invents an element, and every read goes through ``refresh()``.
    @Published private(set) var queue: [TranscriptQueueEntry] = []

    /// How far into the running job the progress bar is, 0...1, or nil when there is nothing to
    /// measure (nothing running, or the model is still being prepared).
    @Published private(set) var progress: Double?

    /// Where the model's own preparation is, while the first video job loads it.
    ///
    /// Not part of the bar: a 1.6 GB download and a 112 s CoreML compile have no known fraction, so
    /// the bar turns while it happens rather than pretending to advance. The *words* are
    /// `StatusPanelText`'s -- the same sentence the dictation panel shows for the same wait, which
    /// is the whole point of that case existing.
    @Published private(set) var preparation: ModelPreparation?

    private let library: TranscriptLibrary

    /// The notifier of criterion 18. A stored initialiser rather than an injected parameter: a
    /// default argument is evaluated outside this class's actor, and `TranscriptNotifier` is
    /// `@MainActor` (it is built here, with the model, because the authorization is asked once per
    /// process).
    private let notifier = TranscriptNotifier()

    /// The queue itself: FIFO, strictly sequential, one job at a time. The *policy* is
    /// `TranscriptQueue`'s (core, tested by lot 10's contract) -- what is here is only the work.
    ///
    /// `lazy` because the job it is built with is this model's own work, and a stored property
    /// cannot be handed a closure that captures `self` during `init`.
    ///
    /// **A vanished model THROWS, it does not return.** `Job` renders the document the work wrote;
    /// a silent `return` here would hand the queue a success with no document behind it — a `done`
    /// with no stem, the state the queue now makes unconstructible. There is nobody left to write
    /// anything, so the work is cancelled, and `announceFailure` already says nothing about a
    /// cancellation.
    private lazy var file = TranscriptQueue { [weak self] entry in
        guard let self else { throw CancellationError() }
        return try await self.run(entry)
    }

    /// **The video model, loaded at the FIRST launch of a video and not before**: it is the 1.6 GB
    /// download when it is absent, and paying it at app launch would be paying it for everyone who
    /// never transcribes a video. Kept so the second job does not reload it — the *runner* is what
    /// is kept, and it holds the transcriber built on the loaded model.
    ///
    /// **The dictation's engine, RECEIVED and never built here** (lot 11-S): the app constructs
    /// exactly one `WhisperKitEngine`, in `DictationController`, and
    /// `loadedModelForVideo(dedicatingComputeUnits: false)` reuses the model it already loaded. A
    /// second instance would be a second 1.6 GB load and a second claim on the compute units —
    /// and the only way to ask for one remains the L12 parameter, never a second construction.
    private let engine: WhisperKitEngine
    private var runner: TranscriptJobRunner?

    init(library: TranscriptLibrary = TranscriptLibrary(), engine: WhisperKitEngine) {
        self.library = library
        self.engine = engine
    }

    // MARK: - Reading the folder

    /// The folder the transcripts live in -- `~/Library/Application Support/Murmure/Transcripts/`
    /// (R3). Read off the library rather than resolved again, so the grid and the reveal button
    /// cannot end up pointing at two different directories.
    var folder: URL { library.base }

    /// Whether there is anything to reveal yet. False on a first launch, where nothing has ever
    /// written a transcript: the button is disabled rather than offering a Finder window on a
    /// folder that is not there.
    var canReveal: Bool {
        FileManager.default.fileExists(atPath: folder.path)
    }

    var isEmpty: Bool { tiles.isEmpty }

    /// The one sentence a half-readable library needs, or nil when every file was decoded.
    ///
    /// A transcript that is on disk and not in the grid is the only silent hole criterion 14 can
    /// leave, and the library counts those files precisely so this can name them (never by their
    /// name: a file name is the transcript's title, and the count is what a reader needs to know
    /// that something is wrong rather than that he has fewer videos than he thought).
    var unreadableNote: String? {
        switch unreadableCount {
        case 0: nil
        case 1: "1 transcript could not be read."
        default: "\(unreadableCount) transcripts could not be read."
        }
    }

    /// Re-walks the folder. Called on every appearance and after every delete.
    ///
    /// **The disk is the index** (criterion 14): there is no list to keep in sync, so this is the
    /// whole of the reload -- `list()` walks the folder, decodes what it finds, and the tiles
    /// follow. Deleting a transcript in the Finder and coming back to this pane is exactly this
    /// call, and that is why nothing here caches a count of anything.
    func reload() {
        let listing = library.list()
        tiles = TranscriptTile.tiles(for: listing.documents, calendar: .current)
        unreadableCount = listing.unreadableCount
        // A transcript that just went away (deleted here, or in the Finder, or written over by an
        // acquisition) cannot stay open: the reading pane would be showing a document that is no
        // longer on disk -- the one thing criterion 14 forbids.
        if let openID, library.transcript(id: openID) == nil { closeReading() }
    }

    // MARK: - The two actions of a tile (criterion 17)

    /// Opens a tile: the grid gives way to the continuous text.
    func open(_ tile: TranscriptTile) {
        openDocument = library.transcript(id: tile.id)
        openID = openDocument == nil ? nil : tile.id
    }

    /// Back to the grid. The document goes with the selection, so nothing can be read from a
    /// transcript the pane is not showing.
    func closeReading() {
        openID = nil
        openDocument = nil
    }

    /// Deletes a transcript -- both files, `.json` and `.md`, under one stem (criterion 17).
    ///
    /// The confirmation in front of this is what makes it safe to be irreversible; the library
    /// never throws on a delete (an id that matches nothing is a tile that already went away), so
    /// the only thing left to do is reload.
    func delete(_ tile: TranscriptTile) {
        library.delete(id: tile.id)
        if openID == tile.id { closeReading() }
        reload()
    }

    // MARK: - The panel's own affordance (R3)

    /// Shows the transcripts folder in the Finder.
    ///
    /// **A folder is OPENED, a file is SELECTED**, which is `FinderReveal`'s arbitration for the
    /// two buttons this window already has -- and it is the reason this call is `open` and not the
    /// `activateFileViewerSelecting` the plan names in its parenthetical: on a directory, `select`
    /// opens the folder that CONTAINS it with the item highlighted, and criterion 14 asks for the
    /// folder itself to be opened -- the `.json` files are what a reader pressing this is looking
    /// for (deleting one of them and watching its tile go is the eye gate).
    func revealFolder() {
        guard canReveal else { return }
        // `open` returns false when the Finder refuses; a refusal is not Murmure's and the only
        // thing worth adding is where it was pointing.
        if !NSWorkspace.shared.open(folder) {
            problem = "The Finder would not open \(folder.path)."
        } else {
            problem = nil
        }
    }

    func dismissProblem() {
        problem = nil
    }

    // MARK: - The continuous text (criterion 16)

    /// One paragraph of the reading pane: its text, and the instant of its first word.
    struct Paragraph: Identifiable, Equatable {
        /// The paragraph's rank in the document. Its identity for the hover: two paragraphs of one
        /// document can be equal strings, and a hover keyed on the text would light both.
        let id: Int
        let text: String
        /// Seconds from the start of the source audio -- the value `TranscriptSegment` carries,
        /// never a formatted string.
        let start: Double
    }

    /// The paragraphs of a document, each with the instant of its first word.
    ///
    /// **The fusion rule is not written here.** It is frozen in `TranscriptMarkdown` -- consecutive
    /// segments are merged while the pause stays under 1.2 s and the paragraph under 480
    /// characters -- and tested by lot 1. A second copy in the app target would be a second rule
    /// that agrees today and can part company tomorrow, which is the argument `TranscriptTile`
    /// already makes for `HistoryRow.duration`. The pane therefore **reads the frozen render**
    /// rather than deciding anything.
    ///
    /// How the pairing works, and why it needs no threshold: `TranscriptMarkdown` builds its body
    /// by concatenating the non-blank segment texts, joined by **one space inside a paragraph** and
    /// by a **blank line between two paragraphs**. Reading that body and the segments in lockstep
    /// consumes exactly one segment text at a time, and the separator that follows it says whether
    /// the paragraph continues. The instants are therefore collected on the way, and the paragraph
    /// texts are slices of the render -- so the pane cannot disagree with the `.md` file it is
    /// showing.
    ///
    /// Two things the earlier, string-splitting version of this got wrong, and that the reading
    /// below is written against: a **segment's own text may contain blank lines** (the render only
    /// trims its edges), so a paragraph is not "everything between two blank lines"; and the
    /// paragraph boundary belongs to the pair of segments, not to the text.
    static func paragraphs(of document: TranscriptDocument) -> [Paragraph] {
        guard let corps = readingBody(of: document) else { return [] }

        var paragraphs: [Paragraph] = []
        var curseur = corps.startIndex
        var debut = curseur
        var instant: Double?

        for (rang, segment) in document.segments.enumerated() {
            let texte = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A blank segment is transparent in the render (lot 1), so it is transparent here: it
            // neither starts a paragraph nor counts as one of its words.
            guard !texte.isEmpty else { continue }
            // The render is the reference. If the body no longer begins with this segment's text,
            // the fusion rule moved under this pane -- so nothing is guessed: the rest is rendered
            // one segment per paragraph, which loses no word and invents no instant.
            guard corps[curseur...].hasPrefix(texte) else {
                for reste in document.segments[rang...] {
                    let orphelin = reste.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !orphelin.isEmpty else { continue }
                    paragraphs.append(
                        Paragraph(id: paragraphs.count, text: orphelin, start: reste.start))
                }
                return paragraphs
            }
            if instant == nil { instant = segment.start }
            curseur = corps.index(curseur, offsetBy: texte.count)

            if corps[curseur...].hasPrefix("\n\n") {
                // A blank line: the paragraph being read ends here, before the break.
                paragraphs.append(
                    Paragraph(
                        id: paragraphs.count, text: String(corps[debut..<curseur]),
                        start: instant ?? 0))
                curseur = corps.index(curseur, offsetBy: 2)
                debut = curseur
                instant = nil
            } else if corps[curseur...].hasPrefix(" ") {
                curseur = corps.index(curseur, offsetBy: 1)
            }
        }
        // The last paragraph has no separator after it.
        if let instant {
            paragraphs.append(
                Paragraph(
                    id: paragraphs.count, text: String(corps[debut...]), start: instant))
        }
        return paragraphs
    }

    /// The body of the frozen render, without its two-line header and without the trailing
    /// newline -- or nil when the document has no paragraph at all (a work written before its
    /// first unit, or a `failed` one).
    ///
    /// The header is **exactly two lines** (lot 1's contract: the title, then the source line) and
    /// the body follows one empty line, so this is a split rather than a search for the first
    /// blank line: a title is a line, and looking for a double newline would trip over one that
    /// contained a break of its own.
    private static func readingBody(of document: TranscriptDocument) -> Substring? {
        let rendu = TranscriptMarkdown.render(document)
        let lignes = rendu.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard let queue = lignes.last, queue.hasPrefix("\n") else { return nil }
        var corps = queue.dropFirst()
        while corps.hasSuffix("\n") { corps = corps.dropLast() }
        return corps.isEmpty ? nil : corps
    }

    /// An instant of the transcript, as the hover shows it: `0:42`, `12:05`, `1:02:03`.
    ///
    /// **Truncated, not rounded**, unlike `HistoryRow.duration`: a duration is a measurement and
    /// half a second of it rounds, while an instant is a position in the media -- the second shown
    /// is the second the video is at, and `0:43` for a word that starts at 42.8 s would send the
    /// reader half a second past it. The minutes part is not padded (`0:42`, not `00:42`), the
    /// same way a media player writes it.
    static func instant(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let minutes = (total % 3_600) / 60
        let secondes = total % 60
        guard total >= 3_600 else { return String(format: "%d:%02d", minutes, secondes) }
        return String(format: "%d:%02d:%02d", total / 3_600, minutes, secondes)
    }

    /// Where to go to resume at `start` (criterion 16). **The pane does not play anything**: an
    /// embedded player is out of scope, so a paragraph's timestamp is a link and the system's
    /// default handler does the rest.
    ///
    /// - YouTube takes `t=<seconds>s` and seeks to it;
    /// - X has no instant parameter, so the post is the best the address can do;
    /// - a local file is opened by its path.
    static func link(to start: Double, in document: TranscriptDocument) -> URL? {
        let seconde = max(0, Int(start.rounded(.down)))
        switch document.source.kind {
        case .youtube:
            guard let url = document.source.url else { return nil }
            var composants = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let existants = composants?.queryItems ?? []
            composants?.queryItems = existants + [URLQueryItem(name: "t", value: "\(seconde)s")]
            return composants?.url ?? url
        case .x:
            return document.source.url
        case .file:
            return document.source.path.map { URL(fileURLWithPath: $0) }
        }
    }

    // MARK: - Launching, and the queue (criteria 18 and 19)

    /// Whether the queue is working on something -- what the menu bar's **progress bar** follows.
    ///
    /// The elements that are DONE or FAILED do not count: it answers whether there is work to show
    /// a bar for, and the notification is what says a job ended.
    ///
    /// **The badge no longer follows this** (criterion 18, decision O1): a badge that goes dark when
    /// the work ends cannot tell a finished job from a session that never ran one, which is what
    /// ``badge`` -- and `TranscriptBadge.state(of:)` in the core behind it -- exists for.
    var isWorking: Bool {
        queue.contains { $0.state == .running || $0.state == .waiting }
    }

    /// The menu bar's badge (criterion 18, decision O1): a dot while work is running, a check once
    /// it has finished, nothing at rest.
    ///
    /// **Computed, never stored**: ``queue`` is the queue's published mirror, re-read after the
    /// enqueue and after the drain, and the queue stays the authority -- a second stored state here
    /// could only drift from it. No new `refresh()` either: the rule reads what the mirror already
    /// carries, and it is `MurmureCore`'s `TranscriptBadge` (tested there) that decides.
    var badge: TranscriptBadgeState {
        TranscriptBadge.state(of: queue)
    }

    /// The elements the menu bar shows: what is running, what is waiting its turn, and what failed
    /// -- a failure's reason is the one thing in the queue that asks something of Louis (rule 4: a
    /// cancellation is the only failure without one, and the queue is the only thing that makes
    /// one).
    ///
    /// **Finished elements are not here.** A "Done" line states nothing that can be acted on, and a
    /// menu that kept a line per finished transcription would grow all day. Nothing is removed from
    /// the queue itself -- rule 2 keeps every element in `entries` whatever its state, and this is
    /// only which of them a menu, a list of things to do, is the right place for.
    var menuLines: [TranscriptQueueEntry] {
        queue.filter { $0.state != .done }
    }

    /// The last line of the running work: the queue's own sentence for its element, from
    /// `TranscriptQueueText` (core, frozen by lot 10's contract -- `Murmure/` has no test bundle).
    var runningLine: String? {
        queue.first { $0.state == .running }.map { TranscriptQueueText.label(for: $0) }
    }

    /// A batch of launch entries. Accepted entries are enqueued sequentially in one task so the
    /// drop order is the queue order; refusals remain visible on `problem` (the last one wins).
    @discardableResult
    func transcribe(_ entrees: [String]) -> [String] {
        var accepted: [String] = []
        var refusals: [String] = []
        for entree in entrees {
            if Self.launch(for: entree) != nil {
                accepted.append(entree)
            } else {
                refusals.append(Self.refusal(for: entree))
            }
        }
        Task { @MainActor in
            for entree in accepted {
                await file.enqueue(source: entree)
            }
            await refresh()
            await file.drain()
            await refresh()
        }
        if let last = refusals.last { problem = last }
        return refusals
    }

    /// Accepts a single launch entry by delegating to the batch path.
    @discardableResult
    func transcribe(_ entree: String) -> String? {
        transcribe([entree]).first
    }

    /// Re-reads the queue. **The queue is the authority** (an actor, the way the disk is for the
    /// tiles): nothing here keeps a second list that could drift from it.
    func refresh() async {
        queue = await file.entries
    }

    /// The document a completed work's stem names, read from the disk.
    ///
    /// The socket needs the document itself — that is what `transcribe` prints — and
    /// ``TranscriptQueueOutcome/complete(documentID:)`` carries the **stem** the queue wrote on the
    /// entry, never a document. The library is the disk, and the disk is still the authority on
    /// what exists (criterion 14); this is a read by the key the work itself delivered.
    func finishedDocument(id: String) -> TranscriptDocument? {
        library.transcript(id: id)
    }

    /// What one submission ended with, read from the element the queue finished.
    ///
    /// **The key is CARRIED, never recomputed** (lot 10-S-R). The stem of the file the work wrote
    /// reaches this method inside `terminal.documentID`, put there by `TranscriptQueue.drain()` in
    /// the same transition that wrote `.done`. The disk is still the authority on *what exists* —
    /// criterion 14 is untouched, `reload()` and `open(_:)` still read it — but the disk is no
    /// longer asked *which file this work wrote*, because that question has exactly one answer and
    /// it was already travelling.
    ///
    /// **Why the old reading could not work.** It resolved the source a third time and asked the
    /// library for the source's *canonical identity*; the library wants a *stem*, so the guard was
    /// always false and `.complete` was unreachable -- `rc=1` « finished without writing a
    /// transcript » on a transcript written and verified on disk. Recomputing the stem instead is
    /// not available either: the library is the only authority on it, and two writes of one source
    /// yield **two stems for one identity**.
    ///
    /// A stop is a failure **with** its reason (it says where to resume from) and a cancellation is
    /// a failure **without** one — the queue is the only thing that produces the second, and
    /// ``TranscriptQueueEntry/error`` tells them apart. The socket adds no state of its own.
    enum TranscriptQueueOutcome: Sendable, Equatable {
        case complete(documentID: String)
        case failed(reason: String?)
    }

    /// Hands `source` to the one queue and starts its drainage, without waiting for the work.
    ///
    /// **The same path as a drop or a paste** (``transcribe(_:)`` enqueues into this very queue), so
    /// a submission from the socket and one from the panel traverse one FIFO and can never start two
    /// video jobs at once (criterion 19). Nothing is created here: the queue, the runner and the
    /// model are the panel's.
    func submit(_ source: String) async -> TranscriptQueueEntry {
        let element = await file.enqueue(source: source)
        await refresh()
        // A separate task, so the caller gets its element at once: without `--wait` the socket
        // answers "queued" immediately, and rule 4 makes a second drainage while one runs a no-op.
        Task { @MainActor in await file.drain() }
        return element
    }

    /// Waits for the end of the work `element` names, and says how it ended.
    ///
    /// The wait follows the entry's own `id` inside the queue, so two submissions awaited at the
    /// same time each get their own result (criterion 4 of the lot). An identifier this queue never
    /// issued cannot be waited for, and says so instead of hanging.
    func outcome(of element: TranscriptQueueEntry) async -> TranscriptQueueOutcome {
        let terminal: TranscriptQueueEntry
        do {
            terminal = try await file.wait(for: element.id)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
        // The note sits ABOVE the `case` on purpose: the contract's `mutant-c1` anchors on
        // `case .done:` immediately followed by the `return`, so a comment *inside* the arm would
        // make that capture inapplicable — and an inapplicable capture is a control nobody has
        // proven alive. The reasoning itself belongs to ``TranscriptQueueOutcome``.
        switch terminal.state {
        case .done:
            return .complete(documentID: terminal.documentID)
        case .failed:
            // `error == nil` is a cancellation, and the queue is the only thing that produces one.
            return .failed(reason: terminal.error)
        case .waiting, .running:
            // Inattachable : `wait(for:)` rend un état TERMINAL par construction. Le cas est
            // nommé plutôt que couvert par un `default`, pour qu'un état ajouté plus tard ne le
            // comprenne pas par héritage.
            return .failed(reason: "The transcription of « \(terminal.source) » did not finish.")
        }
    }

    /// What the one queue says of itself, for the socket's `status` — the core's line, read and not
    /// recomputed. No transcript crosses it (criterion 15).
    func queueStatus() async -> String {
        await file.status
    }

    private static func refusal(for entree: String) -> String {
        let texte = entree.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !texte.isEmpty else {
            return "Nothing to transcribe: paste a link, or drop a video file here."
        }
        return
            "Murmure cannot transcribe « \(texte) »: it is neither a file that exists nor a "
            + "link to YouTube or X."
    }

    /// What Murmure understands of a launch entry: the canonical source, and the title the work is
    /// given.
    struct Launch: Equatable {
        let source: TranscriptSource
        let title: String
    }

    /// The two shapes a launch takes, and only those two (plan §2.7): a **link** -- and only a
    /// YouTube or X one, the hosts the core recognises in increment 1 -- or an **existing file**.
    ///
    /// **The host is no longer read here.** The core answers both questions at one place --
    /// `TranscriptSource.resolve(_:)`, which derives the `kind` from the family its identity
    /// extraction succeeded on, and never yields a source without an identity. A link the core
    /// gives no identity to is therefore refused rather than queued under a name nothing could
    /// compute, and the pane and the CLI cannot disagree about which entries those are.
    ///
    /// **No `CFBundleURLTypes` is needed for this** (decision R1): the declaration would make
    /// Murmure a candidate handler for every link on the machine. Pasting into the pane, dropping
    /// into the pane and dropping a FILE on the icon all work without it.
    static func launch(for entree: String) -> Launch? {
        guard case .source(let source) = TranscriptSource.resolve(entree) else { return nil }

        switch source.kind {
        case .file:
            // A local file is launched under its own name (plan §2.4: "ou nom de fichier pour un
            // local"), extension dropped: the title is a title, not a file name. What is queued
            // stays the user's own text, `~` included as the core expanded it.
            return Launch(
                source: source,
                title: URL(fileURLWithPath: source.path ?? "").deletingPathExtension()
                    .lastPathComponent)
        case .youtube, .x:
            return Launch(
                source: source,
                // A link has no title YET, and the title is asked for before the acquisition reads
                // `yt-dlp`'s own metadata. The empty string is the honest entry, and it is now the
                // whole of this surface's answer: since lot 8-T, the runner reads the source's title
                // itself, after `AcquisitionService.acquire`, from the very `Acquired.metadata` this
                // launch cannot have yet -- and one invocation of `yt-dlp` is what tells it (a second
                // call would pay the measured 13-16 s of PyInstaller startup, §8). So the empty title
                // is *not* what the document ends up carrying: it
                // is the caller's contribution to `TranscriptJobTitle.resolve`, which prefers the
                // acquisition's title for a link. It still decides the working directory's name --
                // `TranscriptFilenames.stem` falls back to the source's identity ("si le titre
                // manque, repli sur l'hôte + identifiant de source", §2.4) -- and
                // `MenuText.notificationBody("")` remains the guard for a transcript whose source
                // carries no title at all: nothing is invented.
                title: "")
        }
    }

    /// One element's work: transcribe the source, and announce how it ended.
    ///
    /// Runs on the main actor: the queue calls it from a detached task, so this is a hop, and what
    /// it does between two homes is set properties and await the runner. The heavy work is the
    /// runner's own actor and its subprocesses -- the main actor is never the one doing it.
    ///
    /// **An element ends here, and its end is announced here, once.** Exactly one of the two
    /// announcements below closes a queued element, whichever way it ends: a `throw` from any site
    /// of ``perform(_:)`` -- the decoder missing, a model that would not download, an entry that is
    /// no longer readable when its turn comes, the runner failing -- reaches Louis by the same
    /// path as the runner's own failures. A `throw` written outside ``perform(_:)`` would be the
    /// one that fails in silence, which is why there is none.
    ///
    /// **It renders the document, not its title.** The title is what the notification says; the
    /// document is what the queue carries so that the stem of the file just written reaches the
    /// entry. Rendering only the title would drop the stem on the floor, and the only way to get it
    /// back would be to look the document up by its source -- the re-derivation this lot removes.
    @MainActor
    private func run(_ entry: TranscriptQueueEntry) async throws -> TranscriptDocument {
        // Criterion 18 / decision R6: the notification authorization is asked **at the first
        // launched job**, never at launch. A refusal costs the notification alone -- the badge and
        // the progress bar are independent of it. Asked before anything can end the job, so that
        // the first element's own failure is announced rather than posted to a centre that nobody
        // was ever asked about.
        notifier.askAtFirstJob()
        do {
            let document = try await perform(entry)
            notifier.finished(title: document.title)
            return document
        } catch {
            announceFailure(error)
            throw error
        }
    }

    /// The work of one element, up to the document it wrote.
    ///
    /// No announcement in here: what ends an element is said once, by ``run(_:)``, so that no
    /// `throw` site of this method can end one silently.
    @MainActor
    private func perform(_ entry: TranscriptQueueEntry) async throws -> TranscriptDocument {
        guard let launch = Self.launch(for: entry.source) else {
            throw LaunchFailure.unreadable(entry.source)
        }

        // The runner reports from its own actor, and the events have to reach this one **in
        // order** (a bar that goes backwards is a bar nobody trusts). An `AsyncStream` is what
        // guarantees that: the continuation is thread-safe, and the consumer is a single task on
        // this actor, so two events cannot overtake each other the way two unstructured `Task`s
        // hopping to the main actor can.
        let (flux, continuation) = AsyncStream<TranscriptJobRunner.Event>.makeStream()
        let consommation = Task { @MainActor [weak self] in
            for await evenement in flux { self?.observe(evenement) }
        }

        let travail: TranscriptJobRunner
        do {
            travail = try await videoRunner()
        } catch {
            continuation.finish()
            await consommation.value
            preparation = nil
            throw error
        }

        let issue: TranscriptJobRunner.Outcome
        do {
            issue = try await travail.run(
                source: launch.source, title: launch.title,
                onEvent: { evenement in continuation.yield(evenement) })
        } catch {
            continuation.finish()
            await consommation.value
            progress = nil
            reload()
            // The reason stays the work's own: ``run(_:)`` decides whether it is one to announce
            // (a cancellation is Louis's own doing and the queue already says "Cancelled" for it).
            throw error
        }

        continuation.finish()
        await consommation.value
        progress = nil
        reload()

        switch issue {
        case .complete(let document):
            // The transcript is on disk: this is the end criterion 18 announces, and the body says
            // WHICH transcript (three links in a row end minutes after the click). The **document**
            // goes back up through ``run(_:)`` to the queue, which writes its stem on the entry --
            // the title alone would leave the only key the result is read by lying on the floor.
            return document
        case .stopped(let document):
            // A stop was asked for: the document stays `inProgress` on disk and starting the same
            // source again resumes it (R7). Not a completion, so no notification (``LaunchFailure``
            // carries that decision, in one place); not a success either, so the element is failed
            // WITH its reason rather than reported done.
            throw LaunchFailure.stopped(document.id)
        }
    }

    /// The failure sentence that reaches Louis outside the app -- and **the one place that decides
    /// whether there is one at all**.
    ///
    /// Two ends of an element are not announced, and both are Louis's own decision: a
    /// **cancellation** (his stop of the queue's running job -- the element already says
    /// "Cancelled", and the reason-less failure the queue records is that decision), and a **stop
    /// he asked for** (``LaunchFailure/stopped(_:)``, whose element says where to resume from).
    /// Everything else ends an element minutes after the click -- the 1.6 GB download of the model
    /// is the long one -- and criterion 18 is exactly about the ends he is not there to see.
    ///
    /// The body is the failure's own sentence, the way ``TranscriptNotifier/failed(reason:)``
    /// passes it: a reason is not a word Murmure owns ("failed to fetch: HTTP 403" does not
    /// translate), and it is the same text the element shows after "Failed: ".
    private func announceFailure(_ error: Error) {
        if error is CancellationError || Task.isCancelled { return }
        if let failure = error as? LaunchFailure, !failure.isAnnounced { return }
        notifier.failed(reason: error.localizedDescription)
    }

    /// The runner, built at the first launch and kept afterwards.
    ///
    /// **The dictation's engine, received and not built** (lot 11-S): `loadedModelForVideo` carries
    /// the shared-instance policy by its `dedicatingComputeUnits: false`, so the video reuses the
    /// model the dictation already loaded. A second instance exists only through that parameter.
    ///
    /// Its preparation is reported to ``preparation`` by the dictation's own engine, which is the
    /// same sentence the dictation panel shows for the same wait (`StatusPanelText`, the case that
    /// exists because a 1.6 GB download with no number looks exactly like a hang).
    private func videoRunner() async throws -> TranscriptJobRunner {
        if let runner { return runner }
        guard let ffmpeg = EmbeddedTools.ffmpeg(in: .main) else {
            throw LaunchFailure.missingDecoder
        }
        let modele = try await engine.loadedModelForVideo(dedicatingComputeUnits: false)
        preparation = nil
        let runner = TranscriptJobRunner(
            configuration: .init(
                library: library, ffmpeg: ffmpeg, applicationSupport: Storage.url(),
                // The name that goes into the document is the reference that actually ran: lot 8's
                // configuration asks for it precisely so that a fallback would be visible in the
                // archive. `loadedModelForVideo()` loads the shipped default.
                model: SpeechModelReference.shippedDefault.string),
            transcriber: VideoTranscriber(model: modele))
        self.runner = runner
        return runner
    }

    /// How far into the whole job one runner event puts the bar.
    ///
    /// **A fraction of the WHOLE work, not a unit counter.** The SPEC (l.42) asks the progress to
    /// cover the work's **two phases** -- the raw transcription, then increment 2's rework -- so
    /// the bar advances through a table of phases, each holding a share of it. A unit counter could
    /// not say what is left after the last unit, and increment 2 will add its own row here without
    /// the bar changing shape. The shares are shares of the BAR, not promises of duration: a 38 min
    /// video's acquisition and decode are short beside its units, and a resumed job that skips the
    /// acquisition simply fills its share in one step.
    private func observe(_ evenement: TranscriptJobRunner.Event) {
        switch evenement {
        case .acquiring:
            progress = 0
        case .decoded:
            progress = Phase.beforeUnits
        case .planned:
            progress = Phase.beforeUnits
        case .resuming(let index, let of):
            progress = Phase.fraction(unit: index, of: of)
        case .unitCompleted(let index, let of):
            progress = Phase.fraction(unit: index + 1, of: of)
        case .stopRequested:
            // Nothing moves: the stop is not an advance, and the element's own state says what
            // happened to it.
            break
        case .completed:
            progress = 1
        }
    }

    private enum Phase {
        static let acquiring = 0.10
        static let decoding = 0.05
        static let transcribing = 0.85

        static var beforeUnits: Double { acquiring + decoding }

        static func fraction(unit: Int, of units: Int) -> Double {
            guard units > 0 else { return beforeUnits }
            let borne = min(max(unit, 0), units)
            return beforeUnits + transcribing * Double(borne) / Double(units)
        }
    }

    /// What can stop a launch from becoming a transcript. Every case carries a sentence Louis can
    /// act on: the queue's element shows it after "Failed: ", and the notification for that
    /// element carries it too -- unless ``isAnnounced`` says otherwise, which is the only case
    /// where the two disagree.
    enum LaunchFailure: LocalizedError {
        /// The entry was readable when it was queued and no longer is (a file moved, a link
        /// mistyped by a caller that did not go through ``transcribe(_:)``).
        case unreadable(String)
        /// The embedded LGPL decoder is missing: a build problem, said out loud rather than
        /// reported as an acquisition failure on a video that never reached `yt-dlp`.
        case missingDecoder
        /// The work stopped before the end. Not a success -- the document on disk is `inProgress`
        /// -- and the way forward is the normal launch path (R7), which resumes it.
        case stopped(String)

        /// Whether the end this failure describes is announced outside the app.
        ///
        /// **Only a stop he asked for is silent**, and for the same reason ``TranscriptNotifier``
        /// leaves the decision to its caller: he asked for it, the element's own line says where to
        /// resume from, and the notification is for the ends he is away for. The two others can
        /// both arrive minutes after the click -- the missing decoder is read when the runner is
        /// built, and an entry stops being readable whenever the file it names goes away -- so both
        /// are announced, like any failure of the work itself.
        var isAnnounced: Bool {
            switch self {
            case .stopped:
                false
            case .unreadable, .missingDecoder:
                true
            }
        }

        var errorDescription: String? {
            switch self {
            case .unreadable(let entree):
                "« \(entree) » is neither a file that exists nor a link to YouTube or X."
            case .missingDecoder:
                "The bundled ffmpeg decoder is missing from this build: video transcription "
                    + "cannot run."
            case .stopped(let id):
                "The transcription stopped before the end. Its work is kept: start « \(id) » again "
                    + "from the menu or the drop target to resume where it stopped."
            }
        }
    }
}
