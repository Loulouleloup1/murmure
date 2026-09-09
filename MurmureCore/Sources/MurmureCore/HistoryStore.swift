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
/// `Sendable` because it holds one `DatabaseQueue` and nothing else, and serialising access from
/// any thread is what that type is for (`DatabaseQueue: @unchecked Sendable`, GRDB). Spelled out
/// rather than inferred: a public struct gets no automatic conformance, and the store crosses an
/// actor boundary on every dictation -- `DictationSession` is an actor and the app's
/// `DictationRecording` carries this value into it.
public struct HistoryStore: Sendable {
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

        // Additive, on a database that may already hold Louis's real rows: never edit
        // `v1-dictation`, a registered migration is immutable the moment it has shipped.
        migrator.registerMigration("v2-correctedText") { db in
            try db.alter(table: "dictation") { t in
                t.add(column: "correctedText", .text)
            }

            // FTS5 has no `ALTER TABLE ... ADD COLUMN` for an external-content table, so the
            // index is dropped and rebuilt rather than altered. `correctedText` is made
            // searchable here for the same reason `rawTranscript`/`refinedText` already are:
            // Louis searching his history is looking for what he actually wrote, which in a
            // no-refiner mode is the corrected text, not the model's pre-correction output.
            // The three `synchronize` triggers are found by name rather than hard-coded: GRDB
            // does not document what it calls them, and a wrong guess would leave a stale
            // trigger pointing at a table that no longer exists.
            let triggerNames = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'dictation'"
            )
            for name in triggerNames {
                try db.execute(sql: "DROP TRIGGER \"\(name)\"")
            }
            try db.execute(sql: "DROP TABLE dictation_fts")

            try db.create(virtualTable: "dictation_fts", using: FTS5()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
                t.synchronize(withTable: "dictation")
                t.column("rawTranscript")
                t.column("refinedText")
                t.column("correctedText")
            }
            // Repopulates the new index from `dictation` -- FTS5's own command for exactly this
            // -- so rows written before this migration are searchable again rather than only
            // rows inserted after it.
            try db.execute(sql: "INSERT INTO dictation_fts(dictation_fts) VALUES('rebuild')")
        }

        // Additive again, same rule as v2: never edit `v1-dictation` or `v2-correctedText`.
        migrator.registerMigration("v3-wordCounts") { db in
            try db.alter(table: "dictation") { t in
                t.add(column: "rawWordCount", .integer)
                t.add(column: "finalWordCount", .integer)
            }
            // Backfill once, here, for rows whose text still exists. Rows already purged of text
            // keep NULL counts and simply contribute no words. Uses the app's single counting rule.
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, rawTranscript, correctedText, refinedText FROM dictation
                WHERE rawTranscript IS NOT NULL OR correctedText IS NOT NULL OR refinedText IS NOT NULL
                """)
            for row in rows {
                let raw: String? = row["rawTranscript"]
                let corrected: String? = row["correctedText"]
                let refined: String? = row["refinedText"]
                let final = refined ?? corrected ?? raw
                try db.execute(
                    sql: "UPDATE dictation SET rawWordCount = ?, finalWordCount = ? WHERE id = ?",
                    arguments: [WordCount.count(raw), WordCount.count(final), row["id"] as Int64])
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

    /// Writes one row back, by its id.
    ///
    /// The one edit the archive takes: "Process again" (D12) re-refines a stored transcript and
    /// the row has to carry the result -- the new refined text, and the mode and the model that
    /// produced it, or the metadata block would describe a refinement that is no longer the one
    /// on screen.
    ///
    /// The whole row, not a set of columns, because a partial update is a second definition of
    /// what a row is; the caller reads the record, changes what it means to change and hands it
    /// back. The full-text index follows through the `synchronize` triggers the migration wrote,
    /// which is what makes a re-refined dictation findable by a word only the new text contains.
    ///
    /// Throws `.audioFilenameNotRelative` on the same guard `insert` uses -- one door, one rule --
    /// and returns whether a row with that id was there to write to. A record with no id at all is
    /// a record that was never inserted, so there is nothing to update and it answers false.
    @discardableResult
    public func update(_ record: HistoryRecord) throws -> Bool {
        guard let id = record.id else { return false }
        if let name = record.audioFilename, !HistoryRecord.isSafeRelativeAudioFilename(name) {
            throw HistoryStoreError.audioFilenameNotRelative(name)
        }
        return try dbQueue.write { db in
            guard try HistoryRecord.exists(db, key: id) else { return false }
            try record.update(db)
            return true
        }
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
    /// `correctedText` is dictated content exactly like the other two -- it is Louis's own words,
    /// vocabulary-corrected -- and clearing only `rawTranscript`/`refinedText` would leave it
    /// outliving the 30-day promise this method exists to keep.
    ///
    /// Returns the number of rows whose text was cleared.
    @discardableResult
    public func clearText(startedBefore cutoff: Date) throws -> Int {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE dictation
                    SET rawTranscript = NULL, correctedText = NULL, refinedText = NULL
                    WHERE startedAt < ?
                      AND (rawTranscript IS NOT NULL OR correctedText IS NOT NULL
                           OR refinedText IS NOT NULL)
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

    /// Every audio filename the archive still points at.
    ///
    /// The counterpart to `clearAudio`'s return value, and the reason it exists is the retention
    /// sweep: that one says which files became unreferenced, this one says which are still spoken
    /// for. A sweep that deletes by modification time needs the second list or a clock skew, a
    /// restored backup or a copied file deletes a recording the pane still offers to play.
    ///
    /// A `Set` because the only question ever asked of it is membership, and because two rows
    /// naming the same file is a duplicate the caller must not be made to think about.
    public func referencedAudioFilenames() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT audioFilename FROM dictation WHERE audioFilename IS NOT NULL"
            ))
        }
    }

    /// How many dictations still have text that `clearText` would take.
    ///
    /// **Not the number of rows**, and the difference is the whole reason this counts what it
    /// counts: the 30-day sweep leaves rows behind with their text nulled, so an archive of 1 469
    /// dictations can hold 200 with anything left to lose. `HistoryClearing`'s dialog puts this
    /// number in a sentence -- "the raw and refined text of N dictations" -- and a row count there
    /// would overstate the damage by everything the app had already deleted on its own.
    ///
    /// It is also what makes the button disable itself rather than open a dialog about nothing:
    /// `HistoryClearing.confirmation(dictationCount:)` says a caller with nothing to delete does
    /// exactly that.
    ///
    /// The predicate is `clearText`'s own, spelled the same way, so the count and the delete
    /// cannot come to disagree about what "has text" means.
    public func countWithText() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM dictation
                    WHERE rawTranscript IS NOT NULL OR correctedText IS NOT NULL
                       OR refinedText IS NOT NULL
                    """
            ) ?? 0
        }
    }

    /// Every row, without any text column, oldest first. Small (a few hundred kilobytes for
    /// thousands of rows) and deliberately unfiltered: period and outcome filtering happen in
    /// `DictationStatistics.compute`, where the local calendar is known.
    public func statisticsRows() throws -> [DictationStatisticsRow] {
        try dbQueue.read { db in
            try DictationStatisticsRow.fetchAll(db, sql: """
                SELECT startedAt, durationSeconds, outcome, rawWordCount, finalWordCount,
                       targetBundleID, targetAppName, modeName
                FROM dictation ORDER BY startedAt ASC
                """)
        }
    }

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
    /// The query is turned into an FTS5 expression by `HistorySearchPattern` rather than handed to
    /// `MATCH` as typed: `MATCH` has a syntax, and a dictation search box will be given quotes,
    /// colons and stray parentheses. That is also where the search-as-you-type rule lives -- the
    /// word still under the cursor matches as a prefix, so `mo` finds `moi` -- which is a decision
    /// about feel, not about storage, and is tested as a string.
    ///
    /// A query that carries nothing searchable at all -- empty, or only punctuation -- yields no
    /// expression, and that is answered with no rows rather than with every row, because a search
    /// that matched everything would read as a search that failed. An expression FTS5 will not
    /// take is answered the same way: rows or none, never a thrown syntax error. Quoting every
    /// word makes that unreachable, and it stays as the floor under it.
    public func search(_ query: String, limit: Int, offset: Int = 0) throws -> [HistoryRecord] {
        guard let expression = HistorySearchPattern.matchExpression(for: query),
              let pattern = try? FTS5Pattern(rawPattern: expression)
        else { return [] }
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
