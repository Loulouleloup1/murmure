import Foundation
import GRDB

/// A history database that could not be used, and why.
///
/// Named rather than thrown raw so that a broken archive is a sentence the window can show
/// (lot 4 T9) instead of a crash: spec §9's rule for the refiner -- a component that fails must
/// not cost a dictation -- applies here too. A `HistoryStore` that will not open is a history that
/// will not open, not an app that will not run.
public enum HistoryStoreError: Error, Equatable, CustomStringConvertible {
    /// The file could not be opened, or the schema could not be brought up to date.
    case databaseUnusable(path: String, message: String)
    /// D7: the audio path is stored relative to `recordings/`. Refused at the door rather than
    /// stored and resolved into nonsense later.
    case audioFilenameNotRelative(String)

    public var description: String {
        switch self {
        case .databaseUnusable(let path, let message):
            "history database at \(path) is unusable -- \(message)"
        case .audioFilenameNotRelative(let name):
            "audio filename \(name.debugDescription) must be relative to recordings/"
        }
    }
}

/// The dictation history: `murmure.sqlite` (spec §7), one table and its full-text index (§5.2).
///
/// `databaseURL` is injected and there is **no convenience initializer** (§5.4 rule 2), for the
/// same reason `ModeStore(directory:)` has none: a `HistoryStore()` that defaulted to
/// `~/Library/Application Support/Murmure/murmure.sqlite` would compile at every call site and be
/// wrong at exactly one -- the test that runs migrations against Louis's real archive. The app
/// resolves the real path once, in `DictationController`, and hands it down.
///
/// The store owns rows, not files. It never creates, moves or deletes a WAV: `clearAudio` returns
/// the filenames it detached and the caller deletes them, because the store does not know where
/// `recordings/` is and should not be given a second folder to be wrong about.
public struct HistoryStore {
    private let dbQueue: DatabaseQueue

    /// Opens the database and brings the schema up to date. The containing folder must exist --
    /// creating it is `Storage.directory(subfolder:)`'s job, and this type is not allowed to
    /// create anything on its own (§5.4).
    public init(databaseURL: URL) throws {
        do {
            dbQueue = try DatabaseQueue(path: databaseURL.path)
            try Self.migrator.migrate(dbQueue)
        } catch {
            throw HistoryStoreError.databaseUnusable(
                path: databaseURL.path,
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Schema

    /// Registered migrations rather than a one-shot `CREATE TABLE`, because the second migration
    /// will certainly run against a file that already has rows in it, and the first one has to be
    /// written as though it will.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-dictation") { db in
            try db.create(table: "dictation") { t in
                t.primaryKey("id", .integer)
                t.column("startedAt", .text).notNull()
                t.column("durationSeconds", .double).notNull()
                t.column("outcome", .text).notNull()
                t.column("modeKey", .text).notNull()
                t.column("modeName", .text).notNull()
                t.column("sttModel", .text).notNull()
                t.column("llmModel", .text)
                t.column("rawTranscript", .text)
                t.column("refinedText", .text)
                t.column("insertedCharacters", .integer).notNull()
                t.column("targetBundleID", .text)
                t.column("targetAppName", .text)
                t.column("audioFilename", .text)
                t.column("transcriptionSeconds", .double)
                t.column("refinementSeconds", .double)
                t.column("failureMessage", .text)
            }

            // Raw SQL because the descending order is the point: history is read newest-first and
            // purged oldest-first, and GRDB's `create(index:on:columns:)` cannot express `DESC`.
            try db.execute(sql: "CREATE INDEX dictation_startedAt ON dictation(startedAt DESC)")

            try db.create(virtualTable: "dictation_fts", using: FTS5()) { t in
                // `remove_diacritics 2` (§5.2), not GRDB's default `removeLegacy` (=1), which
                // folds only the Latin-1 range. Louis dictates French: `cle` must find `clé`, and
                // `réglé` must find `regle`. The tokenizer runs over the query as well as over
                // the text, which is what makes it work in both directions.
                t.tokenizer = .unicode61(diacritics: .remove)
                // External content: the index stores no text of its own, it points at `dictation`
                // rows. That is what makes it cheap, and it is also why it does NOT update itself
                // -- `synchronize` writes the three triggers (insert, update, delete) that keep it
                // in step, and without them a deleted row keeps matching for ever.
                t.synchronize(withTable: "dictation")
                t.column("rawTranscript")
                t.column("refinedText")
            }
        }

        return migrator
    }

    // MARK: - Writing

    /// Inserts one dictation and returns it with the id the database assigned.
    @discardableResult
    public func insert(_ record: HistoryRecord) throws -> HistoryRecord {
        if let name = record.audioFilename, !HistoryRecord.isSafeRelativeAudioFilename(name) {
            throw HistoryStoreError.audioFilenameNotRelative(name)
        }
        var inserted = record
        try dbQueue.write { db in try inserted.insert(db) }
        return inserted
    }

    /// Removes one row. Returns whether there was one to remove.
    ///
    /// The WAV is left on disk: the caller reads `audioFilename` first if it wants the file gone.
    @discardableResult
    public func delete(id: Int64) throws -> Bool {
        try dbQueue.write { db in try HistoryRecord.deleteOne(db, key: id) }
    }

    /// Forgets the text of every dictation started before `cutoff`, keeping the rows.
    ///
    /// One half of the retention policy of 2026-09-01: text is dropped after 30 days because
    /// dictations carry client and internal work content, and a bounded window is a privacy
    /// property. The row survives so the archive still says a dictation happened, when, how long
    /// it took and through which mode.
    ///
    /// Leaves `audioFilename` alone -- audio expires on its own, shorter clock -- and leaves
    /// `failureMessage` alone, which is Murmure's own words about a failure, not dictated content.
    ///
    /// Returns the number of rows whose text was cleared.
    @discardableResult
    public func clearText(startedBefore cutoff: Date) throws -> Int {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE dictation SET rawTranscript = NULL, refinedText = NULL
                    WHERE startedAt < ?
                      AND (rawTranscript IS NOT NULL OR refinedText IS NOT NULL)
                    """,
                arguments: [HistoryTimestamp.string(from: cutoff)]
            )
            return db.changesCount
        }
    }

    /// Detaches the audio of every dictation started before `cutoff`, keeping the rows and their
    /// text, and returns the filenames that are now unreferenced.
    ///
    /// The other half of the retention policy: audio goes after 3 days. Deleting the files is the
    /// caller's, because the store does not know where `recordings/` is -- so a caller that
    /// ignores the returned list leaves orphaned WAVs rather than orphaned rows, which is the
    /// failure worth having of the two.
    @discardableResult
    public func clearAudio(startedBefore cutoff: Date) throws -> [String] {
        try dbQueue.write { db in
            let cutoffText = HistoryTimestamp.string(from: cutoff)
            let detached = try String.fetchAll(
                db,
                sql: """
                    SELECT audioFilename FROM dictation
                    WHERE startedAt < ? AND audioFilename IS NOT NULL
                    ORDER BY startedAt DESC, id DESC
                    """,
                arguments: [cutoffText]
            )
            try db.execute(
                sql: "UPDATE dictation SET audioFilename = NULL WHERE startedAt < ?",
                arguments: [cutoffText]
            )
            return detached
        }
    }

    // MARK: - Reading

    public func record(id: Int64) throws -> HistoryRecord? {
        try dbQueue.read { db in try HistoryRecord.fetchOne(db, key: id) }
    }

    /// One page of history, newest first.
    ///
    /// The tie-break is `id DESC` and it is not decoration: two dictations can share a timestamp
    /// (a fixture, a clock that did not move, a restored backup), and a page whose order is
    /// undefined within a tie shows a row twice across two pages and drops another. Same
    /// timestamp means the row inserted later comes first, which is the same "newest first" rule
    /// one level down.
    public func page(limit: Int, offset: Int = 0) throws -> [HistoryRecord] {
        try dbQueue.read { db in
            try HistoryRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM dictation
                    ORDER BY startedAt DESC, id DESC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [limit, offset]
            )
        }
    }

    /// Full-text search over the raw transcript and the refined text, newest first.
    ///
    /// The query is turned into an FTS5 pattern by `FTS5Pattern(matchingAllTokensIn:)` rather than
    /// handed to `MATCH` as typed: `MATCH` has a syntax, and a dictation search box will be given
    /// quotes, colons and stray parentheses. A query that carries no token at all -- empty, or
    /// only punctuation -- yields no pattern, and that is answered with no rows rather than with
    /// every row, because a search that matched everything would read as a search that failed.
    ///
    /// Tokens are matched whole, not as prefixes: `connect` does not find `connecteur`. Whether
    /// the last token should match as a prefix is a search-feel decision and belongs with the
    /// query builder in T5, not here.
    public func search(_ query: String, limit: Int, offset: Int = 0) throws -> [HistoryRecord] {
        guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }
        return try dbQueue.read { db in
            try HistoryRecord.fetchAll(
                db,
                sql: """
                    SELECT dictation.* FROM dictation
                    JOIN dictation_fts ON dictation_fts.rowid = dictation.id
                    WHERE dictation_fts MATCH ?
                    ORDER BY dictation.startedAt DESC, dictation.id DESC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [pattern, limit, offset]
            )
        }
    }
}
