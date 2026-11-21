import Domain
import Foundation
import Memory

/// Package G (ADR 0006): memory entries, revisions, sources, edges, grants, retrieval,
/// manifests, forgetting and purge jobs.
public enum MemoryError: Error, Equatable, Sendable {
    case secretFound([String])
    case noSource
    /// The entry's active revision is not the one the caller expected.
    case activeRevisionMoved(expected: MemoryRevisionID?, actual: MemoryRevisionID?)
    case revisionNotProposed(MemoryRevisionID)
    case derivationCycle(MemoryRevisionID)
    case upstreamNotOlder(MemoryRevisionID)
    case manifestNotPrepared(MemoryManifestID)
    /// Dispatch refused: the manifest was revoked with this reason.
    case dispatchRefused(String)
    case invalidScope
    /// A project or task entry cannot derive from another project's revision.
    case foreignUpstream(MemoryRevisionID)
    /// The task's candidate in verification comes from an attempt whose content was forgotten.
    case candidateContentPurged(TaskID)
}

/// Who reads: the attempt's project and task, its provider and the planned reviewer provider.
public struct MemoryReader: Sendable, Equatable {
    public var projectID: ProjectID
    public var taskID: TaskID?
    /// nil: the owner's own search (no grant filter).
    public var provider: ProviderKind?
    public var reviewerProvider: ProviderKind?

    public init(projectID: ProjectID, taskID: TaskID?, provider: ProviderKind?, reviewerProvider: ProviderKind? = nil) {
        self.projectID = projectID
        self.taskID = taskID
        self.provider = provider
        self.reviewerProvider = reviewerProvider
    }
}

public struct RetrievalCandidates: Sendable, Equatable {
    public var pins: [ExcerptCandidate] = []
    public var hits: [ExcerptCandidate] = []
    public var neighbours: [Int64: ExcerptCandidate] = [:]
    /// Hits dropped because a contradicting revision in scope is not usable.
    public var withheld: [MemoryRevisionID] = []
}

public struct ForgetReport: Sendable, Equatable {
    public var revisions: Int
    public var entries: Int
    /// Attempts whose content was purged; the non-terminal ones must be cancelled.
    public var attempts: [AttemptID]
    public var purgeJob: PurgeJobID
}

public struct PurgeOutcome: Sendable, Equatable {
    public var done: [PurgeJobID] = []
    /// Jobs left pending (a reader held the WAL); retried on the next run.
    public var pending: [PurgeJobID] = []
    public var removedBackups: [String] = []
}

extension Store {
    public static let purgedText = "Inhalt gelöscht"

    // MARK: Policy

    /// Interim project memory policy (ADR 0006 §4): global notes allowed, providers that may
    /// receive memory. Every change raises `rev`, which manifests record.
    public func setMemoryPolicy(project: ProjectID, allowGlobal: Bool, providers: [ProviderKind]) throws {
        let db = try connection()
        try db.run(
            """
            INSERT INTO project_memory_policy (project_id, allow_global, allowed_providers_json, rev) VALUES (?, ?, ?, 1)
            ON CONFLICT(project_id) DO UPDATE SET allow_global = excluded.allow_global,
                allowed_providers_json = excluded.allowed_providers_json, rev = rev + 1
            """,
            [.text(project.uuidString), .integer(allowGlobal ? 1 : 0), .text(try Self.json(providers.map(\.rawValue).sorted()))]
        )
    }

    func memoryPolicy(_ db: SQLiteConnection, _ project: ProjectID) throws -> (allowGlobal: Bool, providers: Set<ProviderKind>, rev: Int) {
        guard let row = try db.query(
            "SELECT allow_global, allowed_providers_json, rev FROM project_memory_policy WHERE project_id = ?", [.text(project.uuidString)]
        ) { ($0.int(0) == 1, try Self.decode($0.requiredText(1)), Int($0.int(2))) }.first else { return (false, [], 0) }
        return (row.0, Set(row.1.compactMap(ProviderKind.init(rawValue:))), row.2)
    }

    // MARK: Writing

    /// A new entry with its first revision. A user note is active at once; a proposal waits in
    /// the inbox. Repeating the same import (same scope, sources and content) returns the
    /// existing revision.
    @discardableResult
    public func addMemory(_ draft: MemoryDraft) throws -> MemoryRevisionRecord {
        let db = try connection()
        let now = currentTime()
        return try db.transaction { try addMemory(db, draft, now: now) }
    }

    /// Several new entries in one transaction (bulk import), with the same idempotence as
    /// `addMemory`: an already imported draft (also twice in one batch) returns its revision.
    @discardableResult
    public func addMemories(_ drafts: [MemoryDraft]) throws -> [MemoryRevisionRecord] {
        let db = try connection()
        let now = currentTime()
        return try db.transaction { try drafts.map { try addMemory(db, $0, now: now) } }
    }

    func addMemory(_ db: SQLiteConnection, _ draft: MemoryDraft, now: Int64) throws -> MemoryRevisionRecord {
        // An import that was edited returns the entry's active revision. One that was retired
        // without a successor or rejected leads to a successor key derived from that revision,
        // so the same draft can be imported again and stays idempotent afterwards.
        var importKey = try Self.importKey(draft)
        while let holder = try db.query("SELECT id, state FROM memory_revision WHERE import_key = ?", [.text(importKey)], {
            (try parseID($0.requiredText(0)) as MemoryRevisionID, try $0.requiredText(1))
        }).first {
            if holder.1 == MemoryRevisionState.active.rawValue || holder.1 == MemoryRevisionState.proposed.rawValue {
                return try loadMemoryRevision(db, holder.0)
            }
            // Edited since (a successor is active): that is the entry the import became.
            if let current = try activeRevision(db, try Self.entryID(db, holder.0)) { return try loadMemoryRevision(db, current) }
            importKey = Canonical.sha256Hex(Data((importKey + "\u{0}" + holder.0.uuidString).utf8))
        }
        try Self.checkContent(draft.title, draft.body)
        guard !draft.sources.isEmpty else { throw MemoryError.noSource }
        let entry = MemoryEntryID()
        do {
            try db.run(
                "INSERT INTO memory_entry (id, scope, project_id, task_id, pinned, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                [
                    .text(entry.uuidString), .text(draft.scope.rawValue), .optional(draft.projectID?.uuidString),
                    .optional(draft.taskID?.uuidString), .integer(draft.pinned ? 1 : 0), .integer(now),
                ]
            )
        } catch { throw MemoryError.invalidScope }
        return try insertRevision(
            db, entry: entry, number: 1, previous: nil, title: draft.title, body: draft.body, kind: draft.kind, author: draft.author,
            sources: draft.sources, validUntil: draft.validUntil, importKey: importKey, now: now
        )
    }

    /// A successor revision (editing). With `author: .user` it replaces the active revision at
    /// once; as a proposal it waits. `expectedActive` must name the current active revision.
    @discardableResult
    public func reviseMemory(
        _ entry: MemoryEntryID, expectedActive: MemoryRevisionID?, title: String, body: String, kind: MemoryKind,
        sources: [MemorySourceDraft], author: MemoryAuthorKind = .user, validUntil: Int64? = nil
    ) throws -> MemoryRevisionRecord {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            let active = try activeRevision(db, entry)
            guard active == expectedActive else { throw MemoryError.activeRevisionMoved(expected: expectedActive, actual: active) }
            try Self.checkContent(title, body)
            guard !sources.isEmpty else { throw MemoryError.noSource }
            let last = try db.query("SELECT id, number FROM memory_revision WHERE entry_id = ? ORDER BY number DESC LIMIT 1", [.text(entry.uuidString)]) {
                (try parseID($0.requiredText(0)) as MemoryRevisionID, Int($0.int(1)))
            }.first
            return try insertRevision(
                db, entry: entry, number: (last?.1 ?? 0) + 1, previous: last?.0, title: title, body: body, kind: kind, author: author,
                sources: sources, validUntil: validUntil, importKey: nil, now: now
            )
        }
    }

    /// Confirms a proposal: it replaces the expected active revision in one transaction.
    public func confirmMemory(_ revision: MemoryRevisionID, expectedActive: MemoryRevisionID?) throws {
        let db = try connection()
        let now = currentTime()
        try db.transaction {
            let record = try loadMemoryRevision(db, revision)
            guard record.state == .proposed else { throw MemoryError.revisionNotProposed(revision) }
            let active = try activeRevision(db, record.entryID)
            guard active == expectedActive else { throw MemoryError.activeRevisionMoved(expected: expectedActive, actual: active) }
            try activate(db, record, replacing: active, now: now)
        }
    }

    public func rejectMemory(_ revision: MemoryRevisionID) throws {
        let db = try connection()
        try db.transaction {
            guard try loadMemoryRevision(db, revision).state == .proposed else { throw MemoryError.revisionNotProposed(revision) }
            try db.run("UPDATE memory_revision SET state = 'rejected' WHERE id = ?", [.text(revision.uuidString)])
        }
    }

    /// Ends an active revision without a successor (it stays in the local history).
    public func retireMemory(_ revision: MemoryRevisionID) throws {
        let db = try connection()
        try db.transaction {
            try db.run("DELETE FROM memory_chunk WHERE revision_id = ?", [.text(revision.uuidString)])
            try db.run("UPDATE memory_revision SET state = 'retired' WHERE id = ? AND state = 'active'", [.text(revision.uuidString)])
        }
    }

    public func setPinned(_ entry: MemoryEntryID, _ pinned: Bool) throws {
        try connection().run("UPDATE memory_entry SET pinned = ? WHERE id = ?", [.integer(pinned ? 1 : 0), .text(entry.uuidString)])
    }

    @discardableResult
    public func addMemoryEdge(from: MemoryRevisionID, to: MemoryRevisionID, type: MemoryEdgeType, evidence: MemorySourceID) throws -> MemoryEdgeID {
        let db = try connection()
        let (a, b) = type.isSymmetric && to.uuidString < from.uuidString ? (to, from) : (from, to)
        let id = MemoryEdgeID()
        try db.run(
            "INSERT INTO memory_edge (id, from_revision_id, to_revision_id, type, evidence_source_id, confirmed_at) VALUES (?, ?, ?, ?, ?, ?)",
            [.text(id.uuidString), .text(a.uuidString), .text(b.uuidString), .text(type.rawValue), .text(evidence.uuidString), .integer(currentTime())]
        )
        return id
    }

    /// Grants revisions to a target project and provider, in one transaction (ADR 0006 §4).
    @discardableResult
    public func grantMemory(_ revisions: [MemoryRevisionID], to project: ProjectID, provider: ProviderKind) throws -> [MemoryGrantID] {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            try revisions.map { revision in
                let existing = try db.query(
                    "SELECT id FROM memory_grant WHERE revision_id = ? AND target_project_id = ? AND provider = ? AND revoked_at IS NULL",
                    [.text(revision.uuidString), .text(project.uuidString), .text(provider.rawValue)]
                ) { try parseID($0.requiredText(0)) as MemoryGrantID }.first
                if let existing { return existing }
                let id = MemoryGrantID()
                try db.run(
                    "INSERT INTO memory_grant (id, revision_id, target_project_id, provider, granted_at) VALUES (?, ?, ?, ?, ?)",
                    [.text(id.uuidString), .text(revision.uuidString), .text(project.uuidString), .text(provider.rawValue), .integer(now)]
                )
                return id
            }
        }
    }

    /// Revokes a grant: prepared manifests that relied on it are revoked; attempts that already
    /// received it lose their session handle (no resume). Returns the open attempts among those,
    /// for the broker to cancel.
    public func revokeMemoryGrant(_ id: MemoryGrantID) throws -> [AttemptID] {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            guard let grant = try db.query(
                "SELECT revision_id, target_project_id, provider FROM memory_grant WHERE id = ? AND revoked_at IS NULL", [.text(id.uuidString)]
            ) { (try $0.requiredText(0), try $0.requiredText(1), try $0.requiredText(2)) }.first else { return [] }
            try db.run("UPDATE memory_grant SET revoked_at = ? WHERE id = ?", [.integer(now), .text(id.uuidString)])
            let manifests = try db.query(
                """
                SELECT DISTINCT m.id, m.delivery, m.attempt_id FROM memory_manifest m
                JOIN memory_manifest_item i ON i.manifest_id = m.id
                JOIN attempt a ON a.id = m.attempt_id JOIN task t ON t.id = a.task_id JOIN job j ON j.id = t.job_id
                WHERE i.revision_id = ? AND j.project_id = ? AND (m.provider = ? OR m.reviewer_provider = ?) AND m.delivery <> 'revoked'
                """,
                [.text(grant.0), .text(grant.1), .text(grant.2), .text(grant.2)]
            ) { (try parseID($0.requiredText(0)) as MemoryManifestID, try $0.requiredText(1), try parseID($0.requiredText(2)) as AttemptID) }
            var open: [AttemptID] = []
            for (manifest, delivery, attempt) in manifests {
                if delivery == ManifestDelivery.prepared.rawValue {
                    try revokeManifest(db, manifest, reason: "grantRevoked", now: now)
                } else {
                    try db.run("UPDATE attempt SET session_handle = NULL, resume_blocked_at = ? WHERE id = ?", [.integer(now), .text(attempt.uuidString)])
                    if let record = try? loadAttempt(db, attempt).record, !record.state.isTerminal { open.append(attempt) }
                }
            }
            return open
        }
    }

    // MARK: Retrieval

    /// The read set of a reader (ADR 0006 §4, §5) as SQL over `memory_revision r JOIN
    /// memory_entry e`, so a retrieval checks only the revisions it touches (pins, FTS matches,
    /// neighbours, contradictions) instead of loading every revision of the scope first.
    ///
    /// - In scope: active, and task (the reader's task in its project), project (the reader's
    ///   project) or global (allowed by the policy, or the owner's own view); expired ones too.
    /// - Usable: in scope, not expired, and for a provider reader also not stale and granted to
    ///   the reader's project for the provider and the reviewer provider.
    struct MemoryReadSet {
        /// A condition with its parameters, in the order of its `?` placeholders.
        struct Condition {
            var sql: String
            var values: [SQLValue]
        }

        /// Active and in scope, expired ones included.
        let inScope: Condition
        /// What a revision in scope also needs to be usable (`1` when nothing).
        let extra: Condition

        /// nil when the reader may receive nothing: its provider or reviewer provider is not
        /// allowed by the project's policy.
        init?(_ policy: (allowGlobal: Bool, providers: Set<ProviderKind>, rev: Int), reader: MemoryReader, stale: Set<MemoryRevisionID>, now: Int64) throws {
            let project = SQLValue.text(reader.projectID.uuidString)
            var scopes = ["(e.scope = 'project' AND e.project_id = ?)"]
            var scopeValues = [project]
            if let task = reader.taskID {
                scopes.append("(e.scope = 'task' AND e.task_id = ? AND e.project_id = ?)")
                scopeValues += [.text(task.uuidString), project]
            }
            if policy.allowGlobal || reader.provider == nil { scopes.append("e.scope = 'global'") }
            inScope = Condition(sql: "r.state = 'active' AND (\(scopes.joined(separator: " OR ")))", values: scopeValues)
            var parts = ["(r.valid_until IS NULL OR r.valid_until > ?)"]
            var values: [SQLValue] = [.integer(now)]
            if let provider = reader.provider {
                guard policy.providers.contains(provider) else { return nil }
                if let reviewer = reader.reviewerProvider, !policy.providers.contains(reviewer) { return nil }
                if !stale.isEmpty {
                    parts.append("r.id NOT IN (SELECT value FROM json_each(?))")
                    values.append(.text(try Store.json(stale.map(\.uuidString).sorted())))
                }
                for p in Set([provider] + (reader.reviewerProvider.map { [$0] } ?? [])).sorted(by: { $0.rawValue < $1.rawValue }) {
                    parts.append(
                        "EXISTS (SELECT 1 FROM memory_grant g WHERE g.revision_id = r.id AND g.target_project_id = ? AND g.provider = ? AND g.revoked_at IS NULL)"
                    )
                    values += [project, .text(p.rawValue)]
                }
            }
            extra = Condition(sql: parts.joined(separator: " AND "), values: values)
        }

        var usable: Condition { Condition(sql: "\(inScope.sql) AND \(extra.sql)", values: inScope.values + extra.values) }
        /// In scope but not usable: such a revision withholds what it contradicts.
        var blocking: Condition { Condition(sql: "\(inScope.sql) AND NOT (\(extra.sql))", values: inScope.values + extra.values) }
    }

    func memoryReadSet(_ db: SQLiteConnection, _ reader: MemoryReader, stale: Set<MemoryRevisionID>, now: Int64) throws -> MemoryReadSet? {
        try MemoryReadSet(try memoryPolicy(db, reader.projectID), reader: reader, stale: stale, now: now)
    }

    /// Candidates for a context package: pins, FTS hits (at most 20 per scope, in one query with
    /// the read-set filter), graph neighbours and withheld contradictions. The `contradicts` rule
    /// holds for every excerpt (pin, hit, neighbour): a contradicting revision in the scope set
    /// (expired ones included) that may not be used withholds it.
    public func memoryCandidates(_ reader: MemoryReader, query: String?, stale: Set<MemoryRevisionID>) throws -> RetrievalCandidates {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            var result = RetrievalCandidates()
            guard let readSet = try memoryReadSet(db, reader, stale: stale, now: now) else { return result }
            let usable = readSet.usable
            let blocking = readSet.blocking
            var contradicted: [MemoryRevisionID: Bool] = [:]
            // The queries below fix their join order (CROSS JOIN): starting from the few FTS
            // matches or edge ends, every read-set check is a key lookup. Left to itself, the
            // planner may start from all entries of the project instead (no statistics), which
            // made each per-hit edge query cost milliseconds at 10,000 revisions.
            /// The other ends of a revision's edges of the given types, as a materialized CTE `o`.
            func otherEnds(_ types: String) -> String {
                """
                WITH o(other) AS MATERIALIZED (
                    SELECT to_revision_id FROM memory_edge WHERE from_revision_id = ? AND type IN (\(types))
                    UNION ALL SELECT from_revision_id FROM memory_edge WHERE to_revision_id = ? AND type IN (\(types)))
                """
            }
            /// True (and recorded as withheld) when a contradicting in-scope revision is not usable.
            func withheld(_ revision: MemoryRevisionID) throws -> Bool {
                if let known = contradicted[revision] { return known }
                let id = SQLValue.text(revision.uuidString)
                let blocked = try !db.query(
                    """
                    \(otherEnds("'contradicts'"))
                    SELECT 1 FROM o CROSS JOIN memory_revision r ON r.id = o.other CROSS JOIN memory_entry e ON e.id = r.entry_id
                    WHERE \(blocking.sql) LIMIT 1
                    """,
                    [id, id] + blocking.values
                ) { $0.int(0) }.isEmpty
                contradicted[revision] = blocked
                if blocked, !result.withheld.contains(revision) { result.withheld.append(revision) }
                return blocked
            }
            /// A usable revision with its entry, scope and confirmation time.
            typealias Usable = (revision: MemoryRevisionID, entry: MemoryEntryID, scope: MemoryScope, confirmedAt: Int64)
            func usableRow(_ row: SQLRow) throws -> Usable {
                (try parseID(row.requiredText(0)), try parseID(row.requiredText(1)), try parseEnum(row.requiredText(2)), row.int(3))
            }
            func firstChunk(_ info: Usable, reason: SelectionReason) throws -> ExcerptCandidate? {
                guard try !withheld(info.revision) else { return nil }
                return try db.query(
                    "SELECT rowid, byte_from, byte_to, body FROM memory_chunk WHERE revision_id = ? ORDER BY ordinal LIMIT 1",
                    [.text(info.revision.uuidString)]
                ) { row in
                    ExcerptCandidate(
                        chunkRowID: row.int(0), revisionID: info.revision, entryID: info.entry, scope: info.scope, confirmedAt: info.confirmedAt,
                        byteFrom: Int(row.int(1)), byteTo: Int(row.int(2)), reason: reason, digest: Canonical.sha256Hex(Data(try row.requiredText(3).utf8))
                    )
                }.first
            }
            let pins = try db.query(
                """
                SELECT r.id, r.entry_id, e.scope, r.confirmed_at FROM memory_entry e CROSS JOIN memory_revision r ON r.entry_id = e.id
                WHERE e.pinned = 1 AND \(usable.sql) ORDER BY r.id
                """,
                usable.values, usableRow
            )
            for info in pins {
                if let pin = try firstChunk(info, reason: .pin) { result.pins.append(pin) }
            }
            guard let query, !query.isEmpty else { return result }
            // The read-set filter applies before the 20-per-scope window, so revisions the reader
            // may not use never take a slot; the body is read only for the rows that remain.
            let hits = try db.query(
                """
                WITH ranked AS MATERIALIZED (SELECT rowid AS fts_rowid, bm25(memory_fts) AS score FROM memory_fts WHERE memory_fts MATCH ?)
                SELECT w.rowid, w.revision_id, w.entry_id, w.scope, w.confirmed_at, c.byte_from, c.byte_to, w.score, c.body FROM (
                    SELECT c.rowid AS rowid, c.revision_id AS revision_id, c.ordinal AS ordinal, r.entry_id AS entry_id, e.scope AS scope,
                        r.confirmed_at AS confirmed_at, ranked.score AS score,
                        ROW_NUMBER() OVER (PARTITION BY e.scope ORDER BY ranked.score, c.revision_id, c.ordinal) AS n
                    FROM ranked
                    CROSS JOIN memory_chunk c ON c.rowid = ranked.fts_rowid
                    CROSS JOIN memory_revision r ON r.id = c.revision_id CROSS JOIN memory_entry e ON e.id = r.entry_id
                    WHERE \(usable.sql)
                ) w JOIN memory_chunk c ON c.rowid = w.rowid
                WHERE w.n <= 20
                ORDER BY w.score, w.revision_id, w.ordinal
                """,
                [.text(query)] + usable.values
            ) { (row: SQLRow) in
                (
                    row.int(0), try parseID(row.requiredText(1)) as MemoryRevisionID, try parseID(row.requiredText(2)) as MemoryEntryID,
                    try parseEnum(row.requiredText(3)) as MemoryScope, row.int(4), Int(row.int(5)), Int(row.int(6)), row.double(7), try row.requiredText(8)
                )
            }
            for (rowid, revision, entry, scope, confirmedAt, from, to, score, body) in hits {
                guard try !withheld(revision) else { continue }
                result.hits.append(ExcerptCandidate(
                    chunkRowID: rowid, revisionID: revision, entryID: entry, scope: scope, confirmedAt: confirmedAt,
                    byteFrom: from, byteTo: to, score: score, reason: .lexical, digest: Canonical.sha256Hex(Data(body.utf8))
                ))
                guard result.neighbours[rowid] == nil else { continue }
                // One neighbour over verifies/depends_on, itself usable and not withheld.
                let id = SQLValue.text(revision.uuidString)
                let neighbours = try db.query(
                    """
                    \(otherEnds("'verifies', 'depends_on'"))
                    SELECT r.id, r.entry_id, e.scope, r.confirmed_at FROM o
                    CROSS JOIN memory_revision r ON r.id = o.other CROSS JOIN memory_entry e ON e.id = r.entry_id
                    WHERE \(usable.sql) ORDER BY r.id
                    """,
                    [id, id] + usable.values, usableRow
                )
                if let neighbour = try neighbours.lazy.compactMap({ try firstChunk($0, reason: .graph) }).first {
                    result.neighbours[rowid] = neighbour
                }
            }
            return result
        }
    }

    /// The first of `revisions` the reader may not use (in the given order), or nil.
    func firstUnusable(_ db: SQLiteConnection, _ reader: MemoryReader, _ revisions: [MemoryRevisionID], stale: Set<MemoryRevisionID>, now: Int64) throws -> MemoryRevisionID? {
        guard let usable = try memoryReadSet(db, reader, stale: stale, now: now)?.usable else { return revisions.first }
        return try revisions.first { revision in
            try db.query(
                "SELECT 1 FROM memory_revision r CROSS JOIN memory_entry e ON e.id = r.entry_id WHERE r.id = ? AND \(usable.sql)",
                [.text(revision.uuidString)] + usable.values
            ) { $0.int(0) }.isEmpty
        }
    }

    /// The owner's own search (no grants): active revisions of a project (and its tasks) and
    /// global ones, or all with `project == nil`.
    public func searchMemory(_ query: String, project: ProjectID?) throws -> [MemoryRevisionRecord] {
        let db = try connection()
        let filter = project == nil ? "" : "AND (e.project_id = ? OR e.scope = 'global')"
        var values: [SQLValue] = [.text(query)]
        if let project { values.append(.text(project.uuidString)) }
        let ids = try db.query(
            """
            WITH ranked AS MATERIALIZED (SELECT rowid AS fts_rowid, bm25(memory_fts) AS score FROM memory_fts WHERE memory_fts MATCH ?)
            SELECT r.id, MIN(ranked.score) AS best FROM ranked
            JOIN memory_chunk c ON c.rowid = ranked.fts_rowid
            JOIN memory_revision r ON r.id = c.revision_id JOIN memory_entry e ON e.id = r.entry_id
            WHERE r.state = 'active' \(filter)
            GROUP BY r.id ORDER BY best, r.id
            """,
            values
        ) { try parseID($0.requiredText(0)) as MemoryRevisionID }
        return try ids.map { try loadMemoryRevision(db, $0) }
    }

    // MARK: Manifests

    @discardableResult
    public func prepareManifest(
        _ id: MemoryManifestID = MemoryManifestID(), attempt: AttemptID, reviewerProvider: ProviderKind?, baseOID: String?,
        items: [ManifestItemRecord]
    ) throws -> ManifestRecord {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            let loaded = try loadAttempt(db, attempt)
            let policy = try memoryPolicy(db, try parseID(loaded.projectID))
            try db.run(
                """
                INSERT INTO memory_manifest (id, attempt_id, provider, reviewer_provider, model_ref, policy_version, retriever_version, base_oid,
                    created_at, delivery, token_estimate)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'prepared', ?)
                """,
                [
                    .text(id.uuidString), .text(attempt.uuidString), .text(loaded.record.provider.rawValue), .optional(reviewerProvider?.rawValue),
                    .text(loaded.record.model), .integer(Int64(policy.rev)), .integer(Int64(Retriever.version)), .optional(baseOID), .integer(now),
                    .integer(Int64(items.map(\.tokenEstimate).reduce(0, +))),
                ]
            )
            for item in items {
                try db.run(
                    """
                    INSERT INTO memory_manifest_item (manifest_id, position, revision_id, byte_from, byte_to, excerpt_digest, token_estimate, reason, rank)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(id.uuidString), .integer(Int64(item.position)), .text(item.revisionID.uuidString), .integer(Int64(item.byteFrom)),
                        .integer(Int64(item.byteTo)), .text(item.excerptDigest), .integer(Int64(item.tokenEstimate)), .text(item.reason.rawValue),
                        .integer(Int64(item.rank)),
                    ]
                )
            }
            return try loadManifest(db, id)
        }
    }

    /// The user deselects excerpts before the package is sent.
    public func deselectManifestItems(_ id: MemoryManifestID, positions: Set<Int>) throws {
        let db = try connection()
        try db.transaction {
            guard try loadManifest(db, id).delivery == .prepared else { throw MemoryError.manifestNotPrepared(id) }
            for position in positions {
                try db.run("DELETE FROM memory_manifest_item WHERE manifest_id = ? AND position = ?", [.text(id.uuidString), .integer(Int64(position))])
            }
            try db.run(
                "UPDATE memory_manifest SET token_estimate = (SELECT COALESCE(SUM(token_estimate), 0) FROM memory_manifest_item WHERE manifest_id = ?) WHERE id = ?",
                [.text(id.uuidString), .text(id.uuidString)]
            )
        }
    }

    public func manifest(_ id: MemoryManifestID) throws -> ManifestRecord { try loadManifest(try connection(), id) }

    public func manifests(attempt: AttemptID) throws -> [ManifestRecord] {
        let db = try connection()
        let ids = try db.query("SELECT id FROM memory_manifest WHERE attempt_id = ? ORDER BY created_at, id", [.text(attempt.uuidString)]) {
            try parseID($0.requiredText(0)) as MemoryManifestID
        }
        return try ids.map { try loadManifest(db, $0) }
    }

    /// The single handover point (ADR 0006 §6): rechecks every item and the policy, consent and
    /// attempt, then marks the manifest `dispatched` and moves the attempt `reserved → starting`
    /// in one transaction. A refusal revokes the manifest. With `manual`, the attempt does not
    /// move and the manifest becomes a manual handoff. `rendered` are the items the caller
    /// rendered: if the manifest no longer holds exactly these, the text is not what was checked.
    public func dispatchManifest(
        _ id: MemoryManifestID, stale: Set<MemoryRevisionID>, manual: Bool = false, rendered: [ManifestItemRecord]? = nil
    ) throws {
        let db = try connection()
        let now = currentTime()
        let refusal: String? = try db.transaction { () throws -> String? in
            let manifest = try loadManifest(db, id)
            guard manifest.delivery == .prepared else { throw MemoryError.manifestNotPrepared(id) }
            let attempt = try loadAttempt(db, manifest.attemptID)
            let project: ProjectID = try parseID(attempt.projectID)
            let policy = try memoryPolicy(db, project)
            func refuse(_ reason: String) throws -> String? {
                try revokeManifest(db, id, reason: reason, now: now)
                return reason
            }
            if !manual, attempt.record.state != .reserved { return try refuse("attemptNotReserved") }
            if let rendered, rendered != manifest.items { return try refuse("manifestChanged") }
            if try db.query("SELECT content_purged_at FROM attempt WHERE id = ?", [.text(manifest.attemptID.uuidString)]) { $0.optionalInt(0) }.first ?? nil != nil {
                return try refuse("contentPurged")
            }
            if !manifest.items.isEmpty {
                if policy.rev != manifest.policyVersion { return try refuse("policyChanged") }
                if let consent = attempt.record.consentID, !(try loadConsent(db, consent).isValid(at: now)) { return try refuse("consentInvalid") }
                let reader = MemoryReader(
                    projectID: project, taskID: attempt.record.taskID, provider: manifest.provider, reviewerProvider: manifest.reviewerProvider
                )
                if let missing = try firstUnusable(db, reader, manifest.items.map(\.revisionID), stale: stale, now: now) {
                    return try refuse("revisionNotUsable:\(missing.uuidString)")
                }
            }
            try db.run(
                "UPDATE memory_manifest SET delivery = ?, dispatched_at = ? WHERE id = ?",
                [.text(manual ? ManifestDelivery.manual.rawValue : ManifestDelivery.dispatched.rawValue), .integer(now), .text(id.uuidString)]
            )
            try appendEvent(
                db, kind: .memoryDispatched, projectID: attempt.projectID, taskID: attempt.record.taskID.uuidString,
                attemptID: manifest.attemptID.uuidString,
                payload: Canonical.encode(["manifestID": id.uuidString, "items": String(manifest.items.count), "delivery": manual ? "manual" : "dispatched"]),
                dedupKey: nil, now: now
            )
            if !manual {
                _ = try changeAttemptStateForDispatch(db, attempt, now: now)
            }
            return nil
        }
        if let refusal { throw MemoryError.dispatchRefused(refusal) }
    }

    func revokeManifest(_ db: SQLiteConnection, _ id: MemoryManifestID, reason: String, now: Int64) throws {
        try db.run("UPDATE memory_manifest SET delivery = 'revoked', revoked_reason = ? WHERE id = ? AND delivery <> 'revoked'", [.text(reason), .text(id.uuidString)])
        let attempt = try db.query("SELECT a.id, j.project_id, a.task_id FROM memory_manifest m JOIN attempt a ON a.id = m.attempt_id JOIN task t ON t.id = a.task_id JOIN job j ON j.id = t.job_id WHERE m.id = ?", [.text(id.uuidString)]) {
            (try $0.requiredText(0), try $0.requiredText(1), try $0.requiredText(2))
        }.first
        if let attempt {
            try appendEvent(
                db, kind: .memoryRevoked, projectID: attempt.1, taskID: attempt.2, attemptID: attempt.0,
                payload: Canonical.encode(["manifestID": id.uuidString, "reason": reason.split(separator: ":").first.map(String.init) ?? reason]),
                dedupKey: nil, now: now
            )
        }
    }

    /// A manifest of an attempt that ended without dispatch is revoked.
    public func revokeManifest(_ id: MemoryManifestID, reason: String) throws {
        let db = try connection()
        let now = currentTime()
        try db.transaction { try revokeManifest(db, id, reason: reason, now: now) }
    }

    // MARK: Forgetting

    /// Forgets entries (ADR 0006 §7): all their revisions, everything derived from them, the
    /// content of every attempt that received them and of what followed from those attempts,
    /// in one transaction, plus a purge job for what lies outside the database.
    public func forgetMemory(_ entries: [MemoryEntryID]) throws -> ForgetReport {
        let db = try connection()
        let now = currentTime()
        let report = try db.transaction { try forget(db, entries: entries, now: now) }
        try PurgeLedger.record([(report.purgeJob, now)], database: path)
        return report
    }

    /// Forgets every memory entry of a project (and what was derived from them elsewhere).
    public func forgetProjectMemory(_ project: ProjectID) throws -> ForgetReport {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            let entries = try db.query("SELECT id FROM memory_entry WHERE project_id = ?", [.text(project.uuidString)]) {
                try parseID($0.requiredText(0)) as MemoryEntryID
            }
            return try forget(db, entries: entries, now: now)
        }.recordingLedger(database: path, at: now)
    }

    func forget(_ db: SQLiteConnection, entries: [MemoryEntryID], now: Int64) throws -> ForgetReport {
        var revisions = Set<String>()
        var attempts = Set<String>()
        for entry in entries {
            revisions.formUnion(try db.query("SELECT id FROM memory_revision WHERE entry_id = ?", [.text(entry.uuidString)]) { try $0.requiredText(0) })
        }
        // Closure: derived revisions (and later revisions of their entries), attempts that
        // received a revision, what followed from those attempts, and revisions citing them.
        var changed = true
        while changed {
            changed = false
            let revJSON = try Self.json(Array(revisions)), attJSON = try Self.json(Array(attempts))
            let derived = try db.query(
                """
                SELECT r2.id FROM memory_source s JOIN memory_revision r ON r.id = s.revision_id
                JOIN memory_revision r2 ON r2.entry_id = r.entry_id AND r2.number >= r.number
                WHERE s.upstream_revision_id IN (SELECT value FROM json_each(?)) OR s.attempt_id IN (SELECT value FROM json_each(?))
                """,
                [.text(revJSON), .text(attJSON)]
            ) { try $0.requiredText(0) }
            let received = try db.query(
                """
                SELECT DISTINCT m.attempt_id FROM memory_manifest m JOIN memory_manifest_item i ON i.manifest_id = m.id
                WHERE i.revision_id IN (SELECT value FROM json_each(?))
                """,
                [.text(revJSON)]
            ) { try $0.requiredText(0) }
            // Candidates of affected authors, their reviewers, and later attempts of the same task:
            // authors (repair prompts) and reviewers, also those that have not recorded a review yet.
            let followed = try db.query(
                """
                SELECT r.reviewer_attempt_id FROM candidate c JOIN review r ON r.candidate_id = c.id
                WHERE c.author_attempt_id IN (SELECT value FROM json_each(?)) AND r.reviewer_attempt_id IS NOT NULL
                UNION SELECT later.id FROM attempt a JOIN attempt later ON later.task_id = a.task_id
                    AND later.reserved_at >= a.reserved_at AND later.id <> a.id
                WHERE a.id IN (SELECT value FROM json_each(?)) AND a.role = 'author'
                """,
                [.text(attJSON), .text(attJSON)]
            ) { try $0.requiredText(0) }
            for id in derived where revisions.insert(id).inserted { changed = true }
            for id in received + followed where attempts.insert(id).inserted { changed = true }
        }
        let revJSON = try Self.json(Array(revisions)), attJSON = try Self.json(Array(attempts))
        let affectedEntries = try db.query(
            "SELECT DISTINCT entry_id FROM memory_revision WHERE id IN (SELECT value FROM json_each(?))", [.text(revJSON)]
        ) { try $0.requiredText(0) }
        // Delete in dependency order: sources first (they hold the cross-revision references).
        for sql in [
            "DELETE FROM memory_chunk WHERE revision_id IN (SELECT value FROM json_each(?))",
            "DELETE FROM memory_manifest_item WHERE revision_id IN (SELECT value FROM json_each(?))",
            "DELETE FROM memory_grant WHERE revision_id IN (SELECT value FROM json_each(?))",
            "DELETE FROM memory_edge WHERE from_revision_id IN (SELECT value FROM json_each(?1)) OR to_revision_id IN (SELECT value FROM json_each(?1))",
            "DELETE FROM memory_source WHERE revision_id IN (SELECT value FROM json_each(?))",
            "DELETE FROM memory_revision WHERE id IN (SELECT value FROM json_each(?))",
        ] { try db.run(sql, [.text(revJSON)]) }
        var removedEntries = 0
        for entry in affectedEntries {
            let left = try db.query("SELECT COUNT(*) FROM memory_revision WHERE entry_id = ?", [.text(entry)]) { $0.int(0) }.first ?? 0
            if left == 0 {
                try db.run("DELETE FROM memory_entry WHERE id = ?", [.text(entry)])
                removedEntries += 1
            }
        }
        // Content of affected attempts and of their candidates' evidence.
        for attempt in attempts.sorted() {
            let loaded = try loadAttempt(db, try parseID(attempt))
            let payloads = try db.query(
                "SELECT seq, payload_id FROM event WHERE attempt_id = ? AND payload_id IS NOT NULL", [.text(attempt)]
            ) { ($0.int(0), try $0.requiredText(1)) }
            for (seq, artifact) in payloads {
                try db.run("UPDATE event SET payload_id = NULL, payload_purged_at = ? WHERE seq = ?", [.integer(now), .integer(seq)])
                try db.run("DELETE FROM artifact WHERE id = ? AND kind = 'eventPayload'", [.text(artifact)])
            }
            try db.run(
                "UPDATE attempt SET content_purged_at = ?, session_handle = NULL, resume_blocked_at = ? WHERE id = ?",
                [.integer(now), .integer(now), .text(attempt)]
            )
            try appendEvent(
                db, kind: .contentPurged, projectID: loaded.projectID, taskID: loaded.record.taskID.uuidString, attemptID: attempt,
                payload: Canonical.encode(["reason": "memoryForgotten", "payloads": String(payloads.count)]), dedupKey: nil, now: now
            )
        }
        // Candidate events (state changes with test summaries in their reason, test and review
        // results) carry no attempt: their payloads go by the candidate they name.
        let candidateEvents = try db.query(
            """
            SELECT e.seq, e.payload_id FROM event e JOIN artifact p ON p.id = e.payload_id
            WHERE e.attempt_id IS NULL AND (
                json_extract(CAST(p.inline_content AS TEXT), '$.entityID') IN (SELECT id FROM candidate WHERE author_attempt_id IN (SELECT value FROM json_each(?1)))
                OR json_extract(CAST(p.inline_content AS TEXT), '$.candidateID') IN (SELECT id FROM candidate WHERE author_attempt_id IN (SELECT value FROM json_each(?1))))
            """,
            [.text(attJSON)]
        ) { ($0.int(0), try $0.requiredText(1)) }
        // Finding decisions name only the finding.
        let findingEvents = try db.query(
            """
            SELECT e.seq, e.payload_id FROM event e JOIN artifact p ON p.id = e.payload_id
            WHERE e.attempt_id IS NULL AND json_extract(CAST(p.inline_content AS TEXT), '$.findingID') IN (
                SELECT f.id FROM finding f JOIN review r ON r.id = f.review_id JOIN candidate c ON c.id = r.candidate_id
                WHERE c.author_attempt_id IN (SELECT value FROM json_each(?)))
            """,
            [.text(attJSON)]
        ) { ($0.int(0), try $0.requiredText(1)) }
        for (seq, artifact) in candidateEvents + findingEvents {
            try db.run("UPDATE event SET payload_id = NULL, payload_purged_at = ? WHERE seq = ?", [.integer(now), .integer(seq)])
            try db.run("DELETE FROM artifact WHERE id = ? AND kind = 'eventPayload'", [.text(artifact)])
        }
        let text = Self.purgedText
        try db.run(
            "UPDATE review SET summary = ? WHERE candidate_id IN (SELECT id FROM candidate WHERE author_attempt_id IN (SELECT value FROM json_each(?)))",
            [.text(text), .text(attJSON)]
        )
        try db.run(
            """
            UPDATE finding SET impact = ?1, suggestion = ?1, reason = CASE WHEN reason IS NULL THEN NULL ELSE ?1 END WHERE review_id IN (SELECT r.id FROM review r JOIN candidate c ON c.id = r.candidate_id
                WHERE c.author_attempt_id IN (SELECT value FROM json_each(?2)))
            """,
            [.text(text), .text(attJSON)]
        )
        try db.run(
            "UPDATE test_result SET summary = ? WHERE candidate_id IN (SELECT id FROM candidate WHERE author_attempt_id IN (SELECT value FROM json_each(?)))",
            [.text(text), .text(attJSON)]
        )
        let job = PurgeJobID()
        try db.run(
            "INSERT INTO purge_job (id, opaque_targets, state, at) VALUES (?, ?, 'pending', ?)",
            [.text(job.uuidString), .text(try Self.json(["migrationBackups", "walCheckpoint", "integrityCheck"])), .integer(now)]
        )
        let open = try attempts.compactMap { id -> AttemptID? in
            let record = try loadAttempt(db, try parseID(id)).record
            return record.state.isTerminal ? nil : record.id
        }.sorted { $0.uuidString < $1.uuidString }
        return ForgetReport(revisions: revisions.count, entries: removedEntries, attempts: open, purgeJob: job)
    }

    /// Runs pending purge jobs (after a forget and at start, before the scheduler): removes the
    /// app's migration backups taken before the job, truncates the WAL (left pending while a
    /// reader holds it) and checks FTS and foreign keys.
    @discardableResult
    public func runPurgeJobs() throws -> PurgeOutcome {
        let db = try connection()
        var outcome = PurgeOutcome()
        let jobs = try db.query("SELECT id, at FROM purge_job WHERE state = 'pending' ORDER BY at, id") { (try parseID($0.requiredText(0)) as PurgeJobID, $0.int(1)) }
        guard !jobs.isEmpty else { return outcome }
        // A crash between the forget and its ledger line is caught up here (before any restore).
        try PurgeLedger.record(jobs, database: path)
        let url = URL(filePath: path)
        let folder = url.deletingLastPathComponent().path(percentEncoded: false)
        let prefix = url.lastPathComponent + ".backup-"
        let latest = jobs.map(\.1).max() ?? 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasPrefix(prefix) {
            // `<db>.backup-v<N>-<time>`: taken before the newest job, it may hold forgotten content.
            guard let time = name.split(separator: "-").last.flatMap({ Int64($0) }), time <= latest else { continue }
            let file = URL(filePath: folder).appending(path: name).path(percentEncoded: false)
            if (try? FileManager.default.removeItem(atPath: file)) != nil { outcome.removedBackups.append(name) }
        }
        try db.execute("INSERT INTO memory_fts(memory_fts, rank) VALUES ('integrity-check', 1)")
        let violations = try db.query("PRAGMA foreign_key_check") { $0.text(0) }
        if !violations.isEmpty { throw StoreError.corruptRow("foreign key violations after purge: \(violations.count)") }
        let busy = try db.query("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) }.first ?? 1
        for (id, _) in jobs {
            if busy == 0 {
                try db.run("UPDATE purge_job SET state = 'done', done_at = ? WHERE id = ?", [.integer(currentTime()), .text(id.uuidString)])
                outcome.done.append(id)
            } else {
                outcome.pending.append(id)
            }
        }
        return outcome
    }

    // MARK: Inspector and export

    public func memoryRevision(_ id: MemoryRevisionID) throws -> MemoryRevisionRecord { try loadMemoryRevision(try connection(), id) }

    public func memoryRevisions(entry: MemoryEntryID) throws -> [MemoryRevisionRecord] {
        let db = try connection()
        let ids = try db.query("SELECT id FROM memory_revision WHERE entry_id = ? ORDER BY number", [.text(entry.uuidString)]) {
            try parseID($0.requiredText(0)) as MemoryRevisionID
        }
        return try ids.map { try loadMemoryRevision(db, $0) }
    }

    /// Entries visible in a project's inspector: its own (project and task) and global ones.
    public func memoryInbox(project: ProjectID) throws -> [MemoryRevisionRecord] {
        let db = try connection()
        let ids = try db.query(
            """
            SELECT r.id FROM memory_revision r JOIN memory_entry e ON e.id = r.entry_id
            WHERE r.state = 'proposed' AND (e.project_id = ? OR e.scope = 'global') ORDER BY r.created_at, r.id
            """,
            [.text(project.uuidString)]
        ) { try parseID($0.requiredText(0)) as MemoryRevisionID }
        return try ids.map { try loadMemoryRevision(db, $0) }
    }

    /// Sources of a revision as a viewer in `viewer` may see them (ADR 0006 §4): nothing of
    /// another project shows. A derived source whose upstream lies in another project is reduced
    /// to its kind, for every scope; a global revision shows a source in full only to the
    /// project it came from, any other viewer sees kind and time.
    public func memorySources(_ revision: MemoryRevisionID, viewer: ProjectID?) throws -> [MemorySourceRecord] {
        let db = try connection()
        let sources = try db.query(
            """
            SELECT id, kind, observed_at, locator, git_oid, blob_oid, byte_from, byte_to, source_digest, origin_project_id, origin_task_id,
                attempt_id, event_seq, upstream_revision_id
            FROM memory_source WHERE revision_id = ? ORDER BY observed_at, id
            """,
            [.text(revision.uuidString)]
        ) { row in
            MemorySourceRecord(id: try parseID(row.requiredText(0)), revisionID: revision, draft: MemorySourceDraft(
                kind: try parseEnum(row.requiredText(1)), observedAt: row.int(2), locator: row.text(3), gitOID: row.text(4), blobOID: row.text(5),
                byteFrom: row.optionalInt(6).map(Int.init), byteTo: row.optionalInt(7).map(Int.init), sourceDigest: row.text(8),
                originProjectID: try row.text(9).map(parseID), originTaskID: try row.text(10).map(parseID), attemptID: try row.text(11).map(parseID),
                eventSeq: row.optionalInt(12), upstreamRevisionID: try row.text(13).map(parseID)
            ))
        }
        guard let viewer else { return sources }
        let record = try loadMemoryRevision(db, revision)
        return try sources.map { source in
            // Every project the source names: its upstream's (nil for a global upstream), its
            // origin, its task's and its attempt's.
            var homes: [ProjectID?] = []
            if let upstream = source.draft.upstreamRevisionID { homes.append(try loadMemoryRevision(db, upstream).projectID) }
            if let origin = source.draft.originProjectID { homes.append(origin) }
            if let task = source.draft.originTaskID { homes.append(try parseID(try loadTask(db, task).projectID)) }
            if let attempt = source.draft.attemptID { homes.append(try parseID(try loadAttempt(db, attempt).projectID)) }
            let named = homes.compactMap { $0 }
            let visible = record.scope == .global
                ? !named.isEmpty && homes.count == named.count && named.allSatisfy { $0 == viewer }
                : named.allSatisfy { $0 == viewer }
            if visible { return source }
            var hidden = source
            hidden.draft = MemorySourceDraft(kind: source.draft.kind, observedAt: source.draft.observedAt, locator: "crossProject")
            return hidden
        }
    }

    public func memoryEdges(_ revision: MemoryRevisionID, viewer: ProjectID) throws -> [MemoryEdgeRecord] {
        let db = try connection()
        let rows = try db.query(
            "SELECT id, from_revision_id, to_revision_id, type, evidence_source_id FROM memory_edge WHERE from_revision_id = ?1 OR to_revision_id = ?1 ORDER BY id",
            [.text(revision.uuidString)]
        ) { row in
            MemoryEdgeRecord(
                id: try parseID(row.requiredText(0)), from: try parseID(row.requiredText(1)), to: try parseID(row.requiredText(2)),
                type: MemoryEdgeType(rawValue: try row.requiredText(3)) ?? .relatedTo, evidence: try parseID(row.requiredText(4))
            )
        }
        // Only edges whose other end the viewer's project may read.
        return try rows.filter { edge in
            let other = try loadMemoryRevision(db, edge.from == revision ? edge.to : edge.from)
            return other.scope == .global || other.projectID == viewer
        }
    }

    /// A project's memory as JSON (active revisions, their sources and edges), after the secret
    /// check; the returned data is the preview.
    public func exportMemory(project: ProjectID) throws -> Data {
        let db = try connection()
        let ids = try db.query(
            """
            SELECT r.id FROM memory_revision r JOIN memory_entry e ON e.id = r.entry_id
            WHERE r.state = 'active' AND e.project_id = ? ORDER BY e.scope, r.id
            """,
            [.text(project.uuidString)]
        ) { try parseID($0.requiredText(0)) as MemoryRevisionID }
        struct Item: Encodable {
            var revision: MemoryRevisionRecord
            var sources: [MemorySourceRecord]
            var edges: [MemoryEdgeRecord]
        }
        let items = try ids.map { id in
            Item(revision: try loadMemoryRevision(db, id), sources: try memorySources(id, viewer: project), edges: try memoryEdges(id, viewer: project))
        }
        for item in items {
            let found = SecretScanner.scan(item.revision.title + "\n" + item.revision.body)
            if !found.isEmpty { throw MemoryError.secretFound(found.map(\.kind)) }
        }
        struct Export: Encodable {
            var schemaVersion = 1
            var projectID: String
            var items: [Item]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(Export(projectID: project.uuidString, items: items))
    }

    // MARK: Helpers

    static func checkContent(_ title: String, _ body: String) throws {
        let found = SecretScanner.scan(title + "\n" + body)
        if !found.isEmpty { throw MemoryError.secretFound(found.map(\.kind)) }
    }

    /// Every attribute of the draft: the same import twice is one revision; a draft that
    /// differs in anything (also pin, kind, expiry, author) is a new one.
    static func importKey(_ draft: MemoryDraft) throws -> String {
        struct Key: Encodable {
            var scope: String, project: String?, task: String?, sources: [MemorySourceDraft], content: String
            var kind: String, author: String, pinned: Bool, validUntil: Int64?
        }
        return Canonical.sha256Hex(try Canonical.encode(Key(
            scope: draft.scope.rawValue, project: draft.projectID?.uuidString, task: draft.taskID?.uuidString, sources: draft.sources,
            content: Canonical.sha256Hex(Data((draft.title + "\u{0}" + draft.body).utf8)),
            kind: draft.kind.rawValue, author: draft.author.rawValue, pinned: draft.pinned, validUntil: draft.validUntil
        )))
    }

    func insertRevision(
        _ db: SQLiteConnection, entry: MemoryEntryID, number: Int, previous: MemoryRevisionID?, title: String, body: String, kind: MemoryKind,
        author: MemoryAuthorKind, sources: [MemorySourceDraft], validUntil: Int64?, importKey: String?, now: Int64
    ) throws -> MemoryRevisionRecord {
        let id = MemoryRevisionID()
        try db.run(
            """
            INSERT INTO memory_revision (id, entry_id, number, previous_id, title, body, kind, state, author_kind, created_at, valid_until,
                content_digest, import_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'proposed', ?, ?, ?, ?, ?)
            """,
            [
                .text(id.uuidString), .text(entry.uuidString), .integer(Int64(number)), .optional(previous?.uuidString), .text(title), .text(body),
                .text(kind.rawValue), .text(author.rawValue), .integer(now), .optional(validUntil),
                .text(Canonical.sha256Hex(Data((title + "\u{0}" + body).utf8))), .optional(importKey),
            ]
        )
        for source in sources { try insertSource(db, revision: id, source) }
        let record = try loadMemoryRevision(db, id)
        if author == .user { try activate(db, record, replacing: try activeRevision(db, entry), now: now) }
        return try loadMemoryRevision(db, id)
    }

    func insertSource(_ db: SQLiteConnection, revision: MemoryRevisionID, _ s: MemorySourceDraft) throws {
        if let upstream = s.upstreamRevisionID {
            // An older, concrete revision, and no cycle through derivations.
            let up = try loadMemoryRevision(db, upstream)
            guard up.confirmedAt != nil || up.state == .proposed else { throw MemoryError.upstreamNotOlder(upstream) }
            // A project or task entry derives only from its own project or from a global entry;
            // only a global entry may carry another project's knowledge (ADR 0006 §4).
            let own = try loadMemoryRevision(db, revision)
            if own.scope != .global, up.scope != .global, up.projectID != own.projectID { throw MemoryError.foreignUpstream(upstream) }
            var frontier = [upstream.uuidString]
            var seen = Set<String>()
            while let next = frontier.popLast() {
                if next == revision.uuidString { throw MemoryError.derivationCycle(upstream) }
                guard seen.insert(next).inserted else { continue }
                frontier += try db.query(
                    "SELECT upstream_revision_id FROM memory_source WHERE revision_id = ? AND upstream_revision_id IS NOT NULL", [.text(next)]
                ) { try $0.requiredText(0) }
            }
        }
        try db.run(
            """
            INSERT INTO memory_source (id, revision_id, kind, observed_at, locator, git_oid, blob_oid, byte_from, byte_to, source_digest,
                origin_project_id, origin_task_id, attempt_id, event_seq, upstream_revision_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(MemorySourceID().uuidString), .text(revision.uuidString), .text(s.kind.rawValue), .integer(s.observedAt), .optional(s.locator),
                .optional(s.gitOID), .optional(s.blobOID), .optional(s.byteFrom), .optional(s.byteTo), .optional(s.sourceDigest),
                .optional(s.originProjectID?.uuidString), .optional(s.originTaskID?.uuidString), .optional(s.attemptID?.uuidString),
                .optional(s.eventSeq), .optional(s.upstreamRevisionID?.uuidString),
            ]
        )
    }

    /// Makes a revision the active one: the previous active revision retires and loses its
    /// chunks, the new one gets chunks (FTS follows through the triggers).
    func activate(_ db: SQLiteConnection, _ record: MemoryRevisionRecord, replacing previous: MemoryRevisionID?, now: Int64) throws {
        if let previous {
            try db.run("DELETE FROM memory_chunk WHERE revision_id = ?", [.text(previous.uuidString)])
            try db.run("UPDATE memory_revision SET state = 'retired' WHERE id = ?", [.text(previous.uuidString)])
        }
        try db.run("UPDATE memory_revision SET state = 'active', confirmed_at = ? WHERE id = ?", [.integer(now), .text(record.id.uuidString)])
        for chunk in Chunker.chunks(record.body) {
            try db.run(
                """
                INSERT INTO memory_chunk (revision_id, ordinal, byte_from, byte_to, title, body, symbols, chunker_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(record.id.uuidString), .integer(Int64(chunk.ordinal)), .integer(Int64(chunk.byteFrom)), .integer(Int64(chunk.byteTo)),
                    .text(record.title), .text(chunk.text), .text(chunk.symbols + " " + Identifiers.symbols(in: record.title)),
                    .integer(Int64(Retriever.version)),
                ]
            )
        }
    }

    func activeRevision(_ db: SQLiteConnection, _ entry: MemoryEntryID) throws -> MemoryRevisionID? {
        try db.query("SELECT id FROM memory_revision WHERE entry_id = ? AND state = 'active'", [.text(entry.uuidString)]) {
            try parseID($0.requiredText(0)) as MemoryRevisionID
        }.first
    }

    static func entryID(_ db: SQLiteConnection, _ revision: MemoryRevisionID) throws -> MemoryEntryID {
        try parseID(try db.query("SELECT entry_id FROM memory_revision WHERE id = ?", [.text(revision.uuidString)]) { try $0.requiredText(0) }.first ?? "")
    }

    func loadMemoryRevision(_ db: SQLiteConnection, _ id: MemoryRevisionID) throws -> MemoryRevisionRecord {
        guard let record = try db.query(
            """
            SELECT r.id, r.entry_id, e.scope, e.project_id, e.task_id, r.number, r.previous_id, r.title, r.body, r.kind, r.state, r.author_kind,
                r.created_at, r.confirmed_at, r.valid_until, r.content_digest
            FROM memory_revision r JOIN memory_entry e ON e.id = r.entry_id WHERE r.id = ?
            """,
            [.text(id.uuidString)], { row in
                MemoryRevisionRecord(
                    id: try parseID(row.requiredText(0)), entryID: try parseID(row.requiredText(1)), scope: try parseEnum(row.requiredText(2)),
                    projectID: try row.text(3).map(parseID), taskID: try row.text(4).map(parseID), number: Int(row.int(5)),
                    previousID: try row.text(6).map(parseID), title: try row.requiredText(7), body: try row.requiredText(8),
                    kind: try parseEnum(row.requiredText(9)), state: try parseEnum(row.requiredText(10)), author: try parseEnum(row.requiredText(11)),
                    createdAt: row.int(12), confirmedAt: row.optionalInt(13), validUntil: row.optionalInt(14), contentDigest: try row.requiredText(15)
                )
            }
        ).first else { throw StoreError.notFound(entity: "memory revision", id: id.uuidString) }
        return record
    }

    func loadManifest(_ db: SQLiteConnection, _ id: MemoryManifestID) throws -> ManifestRecord {
        let items = try db.query(
            """
            SELECT position, revision_id, byte_from, byte_to, excerpt_digest, token_estimate, reason, rank
            FROM memory_manifest_item WHERE manifest_id = ? ORDER BY position
            """,
            [.text(id.uuidString)]
        ) { row in
            ManifestItemRecord(
                position: Int(row.int(0)), revisionID: try parseID(row.requiredText(1)), byteFrom: Int(row.int(2)), byteTo: Int(row.int(3)),
                excerptDigest: try row.requiredText(4), tokenEstimate: Int(row.int(5)), reason: try parseEnum(row.requiredText(6)), rank: Int(row.int(7))
            )
        }
        guard let manifest = try db.query(
            """
            SELECT id, attempt_id, provider, reviewer_provider, policy_version, retriever_version, base_oid, delivery, token_estimate, revoked_reason
            FROM memory_manifest WHERE id = ?
            """,
            [.text(id.uuidString)], { row in
                ManifestRecord(
                    id: try parseID(row.requiredText(0)), attemptID: try parseID(row.requiredText(1)), provider: try parseEnum(row.requiredText(2)),
                    reviewerProvider: try row.text(3).map(parseEnum), policyVersion: Int(row.int(4)), retrieverVersion: Int(row.int(5)),
                    baseOID: row.text(6), delivery: try parseEnum(row.requiredText(7)), tokenEstimate: Int(row.int(8)), revokedReason: row.text(9),
                    items: items
                )
            }
        ).first else { throw StoreError.notFound(entity: "memory manifest", id: id.uuidString) }
        return manifest
    }

    /// Git sources of active revisions of a project with their path and blob, for the staleness
    /// check against a base (only the project's own sources).
    public func gitSources(project: ProjectID) throws -> [(MemoryRevisionID, String, String)] {
        try connection().query(
            """
            SELECT s.revision_id, s.locator, s.blob_oid FROM memory_source s JOIN memory_revision r ON r.id = s.revision_id
            WHERE s.kind = 'git' AND s.origin_project_id = ? AND r.state = 'active' ORDER BY s.revision_id, s.locator
            """,
            [.text(project.uuidString)]
        ) { (try parseID($0.requiredText(0)) as MemoryRevisionID, try $0.requiredText(1), try $0.requiredText(2)) }
    }

    /// Test and review sources of active revisions of a project with the commit they checked.
    public func checkedCommitSources(project: ProjectID) throws -> [(MemoryRevisionID, String)] {
        try connection().query(
            """
            SELECT s.revision_id, s.git_oid FROM memory_source s JOIN memory_revision r ON r.id = s.revision_id
            WHERE s.kind IN ('test', 'review') AND s.origin_project_id = ? AND r.state = 'active' ORDER BY s.revision_id
            """,
            [.text(project.uuidString)]
        ) { (try parseID($0.requiredText(0)) as MemoryRevisionID, try $0.requiredText(1)) }
    }
}

extension ForgetReport {
    func recordingLedger(database: String, at time: Int64) throws -> ForgetReport {
        try PurgeLedger.record([(purgeJob, time)], database: database)
        return self
    }
}
