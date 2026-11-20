import Domain
import Foundation

public enum StoreError: Error, Equatable, Sendable {
    case closed
    /// The command key was already used with a different payload.
    case commandKeyReused(CommandID)
    case notFound(entity: String, id: String)
    case versionConflict(entity: String, id: String, expected: Int, actual: Int)
    case activeAuthorExists(taskID: TaskID, attemptID: AttemptID)
    case activeReviewerExists(taskID: TaskID, attemptID: AttemptID)
    case taskNotOpen(taskID: TaskID, state: TaskState)
    /// Author attempts start only on `ready` tasks.
    case taskNotReady(taskID: TaskID, state: TaskState)
    /// Author attempts start only while the job is `active`.
    case jobNotActive(jobID: JobID, state: JobState)
    case projectMismatch(taskID: TaskID, expected: ProjectID)
    /// Another process holds this database (single writer per database file).
    case databaseInUse(path: String)
    /// `running` and its exits to `ready`/`resultReady` belong to the author attempt; a command
    /// may not move a task there.
    case taskManagedByAttempt(taskID: TaskID, from: TaskState, to: TaskState)
    /// `conflict`, `awaitingMerge` and `integrated` follow the task's integration candidate, and
    /// a task whose candidate is being published can only be blocked; a command may not do that.
    case taskManagedByIntegration(taskID: TaskID, from: TaskState, to: TaskState)
    /// The folder now holds a different repository than the one first attached.
    case repositoryMismatch(projectID: ProjectID, recorded: String, found: String)
    /// Another prepared Git operation for the same ref or worktree is still open.
    case gitOperationOpen(String)
    case gitOperationNotPrepared(GitOperationID)
    /// A provider event arrived for an attempt that has not been started.
    case unexpectedEvent(attemptID: AttemptID, state: AttemptState)
    case corruptRow(String)

    public var isVersionConflict: Bool {
        if case .versionConflict = self { true } else { false }
    }
}

public enum IngestOutcome: Sendable, Equatable {
    case recorded(seq: Int64)
    case ignored(IgnoreReason)

    public enum IgnoreReason: Sendable, Equatable {
        /// Terminal states are immutable; late events are dropped.
        case afterTerminal
        /// The adapter's deduplication key was already recorded for this attempt.
        case duplicate
        /// A second `started` for a running attempt.
        case redundantStart
    }
}

public struct RecoveryReport: Sendable, Equatable {
    /// Attempts that may have had a live process and are now `uncertain`.
    public var uncertain: [AttemptID] = []
    /// Reserved attempts that never started and were cancelled.
    public var cancelledReservations: [AttemptID] = []

    public var isEmpty: Bool { uncertain.isEmpty && cancelledReservations.isEmpty }
}

/// Everything the store persists, for restart comparisons.
public struct StoreSnapshot: Sendable, Equatable {
    public var projects: [ProjectRecord]
    public var jobs: [JobRecord]
    public var tasks: [TaskRecord]
    public var attempts: [AttemptRecord]
    public var events: [EventRecord]
    public var commandIDs: [String]
}

/// The single write path to the local database. Each command or provider event is validated,
/// applied and journaled in one transaction, with no suspension point between check and commit.
public actor Store {
    public static let systemClock: @Sendable () -> Int64 = {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    public nonisolated let path: String
    public nonisolated let migrationReport: MigrationReport
    private var db: SQLiteConnection?
    private var lockDescriptor: Int32
    let clock: @Sendable () -> Int64

    public init(
        path: String,
        migrations: [Migration] = CoreSchema.migrations,
        clock: @escaping @Sendable () -> Int64 = Store.systemClock
    ) throws {
        // One process per database: recovery would otherwise mark another process's live runs
        // `uncertain`. The lock disappears with the process, so a crash leaves no stale lock.
        // Keyed by the resolved folder, so a symlinked path takes the same lock. CLOEXEC: provider
        // processes started later must not inherit (and keep holding) the lock.
        let lock = open(Self.lockPath(for: path), O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw SQLiteError(code: 14, message: "Cannot open lock file: errno \(errno)") }
        guard Self.acquireLock(lock) else {
            Darwin.close(lock)
            throw StoreError.databaseInUse(path: path)
        }
        do {
            let connection = try SQLiteConnection(path: path)
            // Owner-only, before WAL and SHM files are created (SQLite copies these permissions).
            chmod(path, 0o600)
            try connection.configure()
            self.migrationReport = try Migrator.migrate(connection, migrations: migrations, databasePath: path, now: clock())
            self.db = connection
        } catch {
            Darwin.close(lock)
            throw error
        }
        self.lockDescriptor = lock
        self.path = path
        self.clock = clock
    }

    /// `flock` with a short retry. A child being spawned on another thread briefly holds a copy of
    /// every open file description, even `O_CLOEXEC` ones, until its exec; a store reopened in that
    /// window would otherwise see its own released lock as taken. A real second process keeps the
    /// lock and is still refused.
    static func acquireLock(_ descriptor: Int32, attempts: Int = 100) -> Bool {
        for _ in 0..<attempts {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
            guard errno == EWOULDBLOCK || errno == EINTR else { return false }
            usleep(10_000)
        }
        return false
    }

    static func lockPath(for path: String) -> String {
        let url = URL(filePath: path)
        let folder = url.deletingLastPathComponent().path(percentEncoded: false)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = realpath(folder, &buffer) != nil
            ? String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            : folder
        return URL(filePath: resolved, directoryHint: .isDirectory)
            .appending(path: url.lastPathComponent + ".lock").path(percentEncoded: false)
    }

    deinit {
        if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
    }

    /// Closes the database and releases the process lock.
    public func close() {
        db?.close()
        db = nil
        if lockDescriptor >= 0 {
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
    }

    func currentTime() -> Int64 { clock() }

    func connection() throws -> SQLiteConnection {
        guard let db else { throw StoreError.closed }
        return db
    }

    // MARK: Commands

    @discardableResult
    public func execute(_ command: Command) throws -> CommandOutcome {
        let db = try connection()
        let digest = try Canonical.sha256Hex(Canonical.encode(command.action))
        let now = clock()
        return try db.transaction {
            let previous = try db.query(
                "SELECT request_digest, object_id FROM command WHERE id = ?", [.text(command.id.uuidString)]
            ) { (digest: try $0.requiredText(0), objectID: try $0.requiredText(1)) }.first
            if let previous {
                guard previous.digest == digest else { throw StoreError.commandKeyReused(command.id) }
                return CommandOutcome(commandID: command.id, objectID: previous.objectID, isReplay: true)
            }
            let objectID = try apply(command.action, db: db, now: now)
            try db.run(
                "INSERT INTO command (id, kind, request_digest, object_id, status, at) VALUES (?, ?, ?, ?, 'applied', ?)",
                [.text(command.id.uuidString), .text(command.action.kind), .text(digest), .text(objectID), .integer(now)]
            )
            return CommandOutcome(commandID: command.id, objectID: objectID, isReplay: false)
        }
    }

    private func apply(_ action: CommandAction, db: SQLiteConnection, now: Int64) throws -> String {
        switch action {
        case let .openProject(id, name, rootLocator):
            let existing = try db.query(
                "SELECT id FROM project WHERE root_locator = ?", [.text(rootLocator)]
            ) { try $0.requiredText(0) }.first
            if let existing {
                return existing
            }
            try db.run(
                "INSERT INTO project (id, name, root_locator, created_at) VALUES (?, ?, ?, ?)",
                [.text(id.uuidString), .text(name), .text(rootLocator), .integer(now)]
            )
            try appendEvent(
                db, kind: .projectOpened, projectID: id.uuidString, taskID: nil, attemptID: nil,
                payload: Canonical.encode(["name": name, "rootLocator": rootLocator]), dedupKey: nil, now: now
            )
            return id.uuidString

        case let .createJob(id, projectID, goal):
            try requireExists(db, table: "project", id: projectID.uuidString)
            let goalData = Data(goal.utf8)
            let artifactID = ArtifactID().uuidString
            try insertArtifact(db, id: artifactID, projectID: projectID.uuidString, kind: "goal", content: goalData)
            try db.run(
                "INSERT INTO job (id, project_id, goal_artifact_id, state, version, created_at) VALUES (?, ?, ?, 'draft', 1, ?)",
                [.text(id.uuidString), .text(projectID.uuidString), .text(artifactID), .integer(now)]
            )
            try appendEvent(
                db, kind: .jobCreated, projectID: projectID.uuidString, taskID: nil, attemptID: nil,
                payload: Canonical.encode(["jobID": id.uuidString, "goalArtifactID": artifactID]), dedupKey: nil, now: now
            )
            return id.uuidString

        case let .createTask(id, jobID, title):
            let projectID = try db.query(
                "SELECT project_id FROM job WHERE id = ?", [.text(jobID.uuidString)]
            ) { try $0.requiredText(0) }.first
            guard let projectID else {
                throw StoreError.notFound(entity: "job", id: jobID.uuidString)
            }
            if try loadJob(db, jobID).currentPlanID != nil { throw PlanningError.jobHasPlan(jobID) }
            try db.run(
                "INSERT INTO task (id, job_id, title, state, version, created_at) VALUES (?, ?, ?, 'pending', 1, ?)",
                [.text(id.uuidString), .text(jobID.uuidString), .text(title), .integer(now)]
            )
            try appendEvent(
                db, kind: .taskCreated, projectID: projectID, taskID: id.uuidString, attemptID: nil,
                payload: Canonical.encode(["jobID": jobID.uuidString, "title": title]), dedupKey: nil, now: now
            )
            return id.uuidString

        case let .transitionJob(id, target, expectedVersion, reason):
            let job = try loadJob(db, id)
            try checkVersion(entity: "job", id: id.uuidString, expected: expectedVersion, actual: job.version)
            try job.state.validateTransition(to: target, resumeState: job.resumeState)
            if target.requiresReason, (reason ?? "").isEmpty {
                throw DomainError.reasonRequired(entity: JobState.entityName, state: target.rawValue)
            }
            if target == .done, let planID = job.currentPlanID {
                // Every task of the current plan integrated, and no task of the job still open.
                let open = try db.query(
                    """
                    SELECT COUNT(*) FROM task t WHERE t.job_id = ? AND (
                        t.state NOT IN ('integrated', 'noResult', 'failed', 'cancelled')
                        OR (t.state <> 'integrated' AND EXISTS (SELECT 1 FROM plan_task p WHERE p.plan_id = ? AND p.key = t.plan_key)))
                    """,
                    [.text(id.uuidString), .text(planID.uuidString)]
                ) { Int($0.int(0)) }.first ?? 0
                if open > 0 { throw PlanningError.jobNotComplete(id, openTasks: open) }
            }
            let resume = job.state.resumeState(after: target, current: job.resumeState)
            try db.run(
                "UPDATE job SET state = ?, state_reason = ?, resume_state = ?, version = version + 1 WHERE id = ?",
                [.text(target.rawValue), .optional(reason), .optional(resume?.rawValue), .text(id.uuidString)]
            )
            try appendEvent(
                db, kind: .jobStateChanged, projectID: job.projectID.uuidString, taskID: nil, attemptID: nil,
                payload: Canonical.encode(StateChange(entityID: id.uuidString, from: job.state.rawValue, to: target.rawValue, reason: reason)),
                dedupKey: nil, now: now
            )
            return id.uuidString

        case let .transitionTask(id, target, expectedVersion):
            let task = try loadTask(db, id)
            try checkVersion(entity: "task", id: id.uuidString, expected: expectedVersion, actual: task.record.version)
            try checkTaskCommand(db, task, to: target)
            try changeTaskState(db, task, to: target, reason: nil, now: now)
            return id.uuidString

        case let .reserveAttempt(reservation):
            let task = try loadTask(db, reservation.taskID)
            guard task.projectID == reservation.projectID.uuidString else {
                throw StoreError.projectMismatch(taskID: reservation.taskID, expected: reservation.projectID)
            }
            guard !task.record.state.isTerminal else {
                throw StoreError.taskNotOpen(taskID: reservation.taskID, state: task.record.state)
            }
            if reservation.role == .author {
                let job = try loadJob(db, task.record.jobID)
                guard job.state == .active else { throw StoreError.jobNotActive(jobID: job.id, state: job.state) }
            }
            let activeAuthor = try db.query(
                """
                SELECT id FROM attempt
                WHERE task_id = ? AND role = 'author' AND state NOT IN ('succeeded', 'failed', 'cancelled')
                """,
                [.text(reservation.taskID.uuidString)]
            ) { try $0.requiredText(0) }.first
            if reservation.role == .author, let active = activeAuthor {
                throw StoreError.activeAuthorExists(taskID: reservation.taskID, attemptID: try parseID(active))
            }
            if reservation.role == .author, task.record.planKey != nil {
                // Plan tasks start only through the scheduler's reservation (consent, slots, areas, budget).
                throw PlanningError.taskManagedByScheduler(task.record.id)
            }
            if reservation.role == .author, task.record.state != .ready {
                throw StoreError.taskNotReady(taskID: reservation.taskID, state: task.record.state)
            }
            if let account = reservation.accountID, try hasOpenBlock(db, account) {
                throw PlanningError.accountBlocked(account)
            }
            if reservation.role == .reviewer {
                // At most one open reviewer per task (two windows start one review).
                let openReviewer = try db.query(
                    "SELECT id FROM attempt WHERE task_id = ? AND role = 'reviewer' AND state NOT IN ('succeeded', 'failed', 'cancelled')",
                    [.text(reservation.taskID.uuidString)]
                ) { try $0.requiredText(0) }.first
                if let openReviewer { throw StoreError.activeReviewerExists(taskID: reservation.taskID, attemptID: try parseID(openReviewer)) }
            }
            let ordinal = try db.query(
                "SELECT COALESCE(MAX(ordinal), 0) + 1 FROM attempt WHERE task_id = ? AND role = ?",
                [.text(reservation.taskID.uuidString), .text(reservation.role.rawValue)]
            ) { $0.int(0) }.first ?? 1
            try db.run(
                """
                INSERT INTO attempt (id, task_id, role, ordinal, provider, mode, model, effort, state,
                                     spec_digest, reserved_at, version, account_id, consent_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'reserved', ?, ?, 1, ?, ?)
                """,
                [
                    .text(reservation.attemptID.uuidString), .text(reservation.taskID.uuidString),
                    .text(reservation.role.rawValue), .integer(ordinal), .text(reservation.provider.rawValue),
                    .text(reservation.mode.rawValue), .text(reservation.model), .optional(reservation.effort),
                    .text(reservation.specDigest), .integer(now), .optional(reservation.accountID?.uuidString),
                    .optional(reservation.consentID?.uuidString),
                ]
            )
            try appendEvent(
                db, kind: .attemptReserved, projectID: task.projectID, taskID: reservation.taskID.uuidString,
                attemptID: reservation.attemptID.uuidString, payload: Canonical.encode(reservation), dedupKey: nil, now: now
            )
            if reservation.role == .author {
                // The task runs while its author attempt is open (contract: one active author).
                try db.run(
                    "UPDATE task SET current_attempt_id = ? WHERE id = ?",
                    [.text(reservation.attemptID.uuidString), .text(reservation.taskID.uuidString)]
                )
                try changeTaskState(db, task, to: .running, reason: "attempt \(reservation.attemptID) reserved", now: now)
            }
            return reservation.attemptID.uuidString

        case let .attachRepository(projectID, identity, objectFormat):
            let recorded = try db.query(
                "SELECT git_common_identity FROM project WHERE id = ?", [.text(projectID.uuidString)]
            ) { (row: SQLRow) -> String? in row.text(0) }
            guard let current = recorded.first else { throw StoreError.notFound(entity: "project", id: projectID.uuidString) }
            if let current, current != identity {
                throw StoreError.repositoryMismatch(projectID: projectID, recorded: current, found: identity)
            }
            try db.run(
                "UPDATE project SET git_common_identity = ?, object_format = ? WHERE id = ?",
                [.text(identity), .text(objectFormat), .text(projectID.uuidString)]
            )
            try appendEvent(
                db, kind: .repositoryAttached, projectID: projectID.uuidString, taskID: nil, attemptID: nil,
                payload: Canonical.encode(["gitCommonIdentity": identity, "objectFormat": objectFormat]), dedupKey: nil, now: now
            )
            return projectID.uuidString

        case let .transitionAttempt(id, target, expectedVersion, errorClass):
            let attempt = try loadAttempt(db, id)
            try checkVersion(entity: "attempt", id: id.uuidString, expected: expectedVersion, actual: attempt.record.version)
            try changeAttemptState(db, attempt, to: target, errorClass: errorClass, kind: nil, payload: nil, now: now)
            return id.uuidString
        }
    }

    // MARK: Provider events

    /// Persists one adapter event for an attempt and applies the state change it implies.
    @discardableResult
    public func ingest(_ event: AgentEvent, attemptID: AttemptID, dedupKey rawDedupKey: String? = nil) throws -> IngestOutcome {
        let db = try connection()
        let now = clock()
        // An empty key is no key: identical events without a key are legitimate repeats.
        let dedupKey = rawDedupKey.flatMap { $0.isEmpty ? nil : $0 }
        return try db.transaction {
            var attempt = try loadAttempt(db, attemptID)
            if attempt.record.state.isTerminal { return .ignored(.afterTerminal) }
            if attempt.record.state == .reserved {
                throw StoreError.unexpectedEvent(attemptID: attemptID, state: attempt.record.state)
            }
            if let dedupKey {
                let seen = try db.query(
                    "SELECT 1 FROM event WHERE attempt_id = ? AND dedup_key = ?",
                    [.text(attemptID.uuidString), .text(dedupKey)]
                ) { $0.int(0) }
                if !seen.isEmpty { return .ignored(.duplicate) }
            }
            // An attempt whose content was forgotten keeps headers only (ADR 0006 §7).
            let purged = try db.query("SELECT content_purged_at FROM attempt WHERE id = ?", [.text(attemptID.uuidString)]) { $0.optionalInt(0) }.first ?? nil
            let payload: Data? = purged == nil ? try Canonical.encode(event) : nil

            // Any provider event proves the process runs.
            if attempt.record.state == .starting {
                var sessionID: String?
                if case let .started(id) = event { sessionID = id }
                try db.run(
                    "UPDATE attempt SET session_handle = COALESCE(?, session_handle) WHERE id = ?",
                    [.optional(sessionID), .text(attemptID.uuidString)]
                )
                let isStartEvent: Bool = if case .started = event { true } else { false }
                let seq = try changeAttemptState(
                    db, attempt, to: .running, errorClass: nil, kind: .attemptStarted,
                    payload: isStartEvent ? payload : nil, dedupKey: isStartEvent ? dedupKey : nil, now: now
                )
                if isStartEvent { return .recorded(seq: seq) }
                attempt = try loadAttempt(db, attemptID)
            } else if case let .started(sessionID) = event {
                // `started` can arrive after an early cancel moved the attempt to `cancelling`.
                // Keep the session handle and start time reconciliation needs; no state change.
                guard attempt.record.startedAt == nil || (attempt.record.sessionHandle == nil && sessionID != nil) else {
                    return .ignored(.redundantStart)
                }
                try db.run(
                    "UPDATE attempt SET session_handle = COALESCE(session_handle, ?), started_at = COALESCE(started_at, ?) WHERE id = ?",
                    [.optional(sessionID), .integer(now), .text(attemptID.uuidString)]
                )
                let seq = try appendEvent(
                    db, kind: .attemptStarted, projectID: attempt.projectID, taskID: attempt.record.taskID.uuidString,
                    attemptID: attemptID.uuidString, payload: payload, dedupKey: dedupKey, now: now
                )
                return .recorded(seq: seq)
            }

            if case let .rateLimited(signal) = event, let account = attempt.record.accountID {
                // The account is blocked in the same transaction as the event.
                _ = try blockAccount(
                    db, account, reason: signal.kind == .rateLimit ? "rateLimited" : "usageLimit", until: signal.resetAt,
                    retryAfterMs: signal.retryAfterMs, now: now, journal: false
                )
            }
            if case let .quotaObserved(signal) = event, let account = attempt.record.accountID {
                try recordQuotaObservation(db, account, signal, source: attempt.record.provider.rawValue, now: now)
            }
            if case let .completed(status) = event {
                // A turn refused for a limit is an infrastructure failure, not a failure on the substance.
                let limited = try !db.query(
                    "SELECT 1 FROM event WHERE attempt_id = ? AND kind = ? LIMIT 1", [.text(attemptID.uuidString), .text(EventKind.quotaBlocked.rawValue)]
                ) { $0.int(0) }.isEmpty
                let errorClass: String? = if case .failed = status { limited ? "rateLimited" : "providerFailed" } else { nil }
                let seq = try changeAttemptState(
                    db, attempt, to: status.attemptState, errorClass: errorClass, kind: .attemptCompleted,
                    payload: payload, dedupKey: dedupKey, now: now
                )
                return .recorded(seq: seq)
            }
            let seq = try appendEvent(
                db, kind: event.kind, projectID: attempt.projectID, taskID: attempt.record.taskID.uuidString,
                attemptID: attemptID.uuidString, payload: payload, dedupKey: dedupKey, now: now
            )
            return .recorded(seq: seq)
        }
    }

    // MARK: Recovery

    /// After a restart no provider process of this app is alive. Attempts that may have had one
    /// become `uncertain`; reservations that never started are cancelled.
    public func recoverAfterRestart() throws -> RecoveryReport {
        let db = try connection()
        let now = clock()
        return try db.transaction {
            var report = RecoveryReport()
            let open = try db.query(
                "SELECT id FROM attempt WHERE state NOT IN ('succeeded', 'failed', 'cancelled', 'uncertain') ORDER BY reserved_at, id"
            ) { try $0.requiredText(0) }
            for rawID in open {
                let attempt = try loadAttempt(db, try parseID(rawID))
                if attempt.record.state == .reserved {
                    try changeAttemptState(
                        db, attempt, to: .cancelled, errorClass: "notStartedBeforeRestart", kind: nil, payload: nil, now: now
                    )
                    report.cancelledReservations.append(attempt.record.id)
                } else if attempt.record.state.mayHaveLiveProcess {
                    try changeAttemptState(
                        db, attempt, to: .uncertain, errorClass: "processLostOnRestart", kind: .recoveryRequired,
                        payload: nil, now: now
                    )
                    report.uncertain.append(attempt.record.id)
                }
            }
            // No process of an earlier run is alive: an `uncertain` attempt frees its slot.
            try db.run("UPDATE attempt SET process_lost = 1 WHERE state = 'uncertain' AND process_lost = 0")
            return report
        }
    }

    // MARK: Queries

    public func projects() throws -> [ProjectRecord] {
        try connection().query(
            "SELECT id, name, root_locator, git_common_identity, object_format, created_at FROM project ORDER BY created_at, id"
        ) {
            ProjectRecord(id: try parseID($0.requiredText(0)), name: try $0.requiredText(1),
                          rootLocator: try $0.requiredText(2), gitCommonIdentity: $0.text(3), objectFormat: $0.text(4),
                          createdAt: $0.int(5))
        }
    }

    public func jobs(projectID: ProjectID? = nil) throws -> [JobRecord] {
        let filter = projectID == nil ? "" : "WHERE project_id = ?"
        return try connection().query(
            "SELECT \(Self.jobColumns) FROM job \(filter) ORDER BY created_at, id",
            projectID.map { [.text($0.uuidString)] } ?? []
        ) { try Self.job(from: $0) }
    }

    public func tasks(jobID: JobID? = nil) throws -> [TaskRecord] {
        let filter = jobID == nil ? "" : "WHERE job_id = ?"
        return try connection().query(
            "SELECT \(Self.taskColumns) FROM task \(filter) ORDER BY created_at, id",
            jobID.map { [.text($0.uuidString)] } ?? []
        ) { try Self.task(from: $0) }
    }

    public func task(_ id: TaskID) throws -> TaskRecord? {
        try connection().query("SELECT \(Self.taskColumns) FROM task WHERE id = ?", [.text(id.uuidString)]) {
            try Self.task(from: $0)
        }.first
    }

    public func attempt(_ id: AttemptID) throws -> AttemptRecord? {
        try connection().query("SELECT \(Self.attemptColumns) FROM attempt WHERE id = ?", [.text(id.uuidString)]) {
            try Self.attempt(from: $0)
        }.first
    }

    public func attempts(taskID: TaskID? = nil) throws -> [AttemptRecord] {
        let filter = taskID == nil ? "" : "WHERE task_id = ?"
        return try connection().query(
            "SELECT \(Self.attemptColumns) FROM attempt \(filter) ORDER BY reserved_at, id",
            taskID.map { [.text($0.uuidString)] } ?? []
        ) { try Self.attempt(from: $0) }
    }

    /// Attempts that are not terminal, including `uncertain` ones that still hold their slot.
    public func activeAttempts() throws -> [AttemptRecord] {
        try connection().query(
            "SELECT \(Self.attemptColumns) FROM attempt WHERE state NOT IN ('succeeded', 'failed', 'cancelled') ORDER BY reserved_at, id"
        ) { try Self.attempt(from: $0) }
    }

    /// Events after a replay cursor, oldest first.
    public func events(after seq: Int64 = 0, limit: Int = 1_000) throws -> [EventRecord] {
        try connection().query(
            """
            SELECT e.seq, e.event_id, e.schema_version, e.project_id, e.task_id, e.attempt_id, e.ordinal,
                   e.kind, e.at, e.payload_id, a.inline_content, e.dedup_key
            FROM event e LEFT JOIN artifact a ON a.id = e.payload_id
            WHERE e.seq > ? ORDER BY e.seq LIMIT ?
            """,
            [.integer(seq), .integer(Int64(limit))]
        ) { row in
            EventRecord(
                seq: row.int(0), eventID: try parseID(row.requiredText(1)), schemaVersion: Int(row.int(2)),
                projectID: try parseID(row.requiredText(3)), taskID: try row.text(4).map(parseID),
                attemptID: try row.text(5).map(parseID), ordinal: row.optionalInt(6).map(Int.init),
                kind: EventKind(rawValue: try row.requiredText(7)), at: row.int(8),
                payloadID: try row.text(9).map(parseID), payload: row.blob(10), dedupKey: row.text(11)
            )
        }
    }

    public func snapshot() throws -> StoreSnapshot {
        StoreSnapshot(
            projects: try projects(), jobs: try jobs(), tasks: try tasks(), attempts: try attempts(),
            events: try events(limit: Int.max),
            commandIDs: try connection().query("SELECT id FROM command ORDER BY id") { try $0.requiredText(0) }
        )
    }

    // MARK: Helpers

    struct StateChange: Encodable {
        var entityID: String
        var from: String
        var to: String
        var reason: String?
    }

    struct LoadedTask {
        var record: TaskRecord
        var projectID: String
    }

    struct LoadedAttempt {
        var record: AttemptRecord
        var projectID: String
    }

    /// Commands may not enter `running` except as the resume of a side state whose author attempt
    /// is still open, and may not leave `running` for `ready`/`resultReady`: those moves follow
    /// the author attempt (reservation and attempt end).
    private func checkTaskCommand(_ db: SQLiteConnection, _ task: LoadedTask, to target: TaskState) throws {
        let from = task.record.state
        let refused = (
            (from == .running && (target == .ready || target == .resultReady))
                || (target == .running && !(from.isSideState && task.record.resumeState == .running))
        )
        if refused { throw StoreError.taskManagedByAttempt(taskID: task.record.id, from: from, to: target) }
        if task.record.planKey != nil, target == .ready, from == .pending || (from == .blocked && task.record.resumeState == .pending) {
            throw PlanningError.taskManagedByScheduler(task.record.id)
        }
        if target == .running {
            let author = try task.record.currentAttemptID.flatMap { try loadAttempt(db, $0).record }
            guard let author, !author.state.isTerminal else {
                throw StoreError.taskManagedByAttempt(taskID: task.record.id, from: from, to: target)
            }
        }
        // Domain errors come first; these moves are valid but belong to the integration chain.
        guard from.allowsTransition(to: target, resumeState: task.record.resumeState) else { return }
        let resumesFromHold = from == .blocked && target == task.record.resumeState
        // Leaving `conflict` for verification is the resolution's move, not a command's.
        let integrationMove = target == .conflict || target == .integrated
            || (target == .awaitingMerge && !resumesFromHold) || (from == .awaitingMerge && target == .verifying)
            || (from == .conflict && target == .verifying)
        // A revert task is the host's: no author can rework it, so it cannot go back to one.
        let hostsRevert = try !db.query(
            "SELECT 1 FROM candidate WHERE task_id = ? AND kind = 'revert' LIMIT 1", [.text(task.record.id.uuidString)]
        ) { $0.int(0) }.isEmpty
        if hostsRevert, target == .ready || target == .needsChanges {
            throw StoreError.taskManagedByIntegration(taskID: task.record.id, from: from, to: target)
        }
        let publishing = try db.query(
            "SELECT 1 FROM candidate WHERE task_id = ? AND state = 'publishing'", [.text(task.record.id.uuidString)]
        ) { $0.int(0) }
        if integrationMove || (!publishing.isEmpty && target != .blocked && !resumesFromHold) {
            throw StoreError.taskManagedByIntegration(taskID: task.record.id, from: from, to: target)
        }
    }

    /// Validates, applies and journals a task transition, keeping the resume state of side states.
    func changeTaskState(_ db: SQLiteConnection, _ task: LoadedTask, to target: TaskState, reason: String?, now: Int64) throws {
        let current = task.record.state
        try current.validateTransition(to: target, resumeState: task.record.resumeState)
        let resume = current.resumeState(after: target, current: task.record.resumeState)
        try db.run(
            "UPDATE task SET state = ?, resume_state = ?, version = version + 1 WHERE id = ?",
            [.text(target.rawValue), .optional(resume?.rawValue), .text(task.record.id.uuidString)]
        )
        try appendEvent(
            db, kind: .taskStateChanged, projectID: task.projectID, taskID: task.record.id.uuidString, attemptID: nil,
            payload: Canonical.encode(StateChange(entityID: task.record.id.uuidString, from: current.rawValue, to: target.rawValue, reason: reason)),
            dedupKey: nil, now: now
        )
        if target == .ready || target == .needsChanges || (target.isTerminal && target != .integrated) {
            // Back to an author or ended: its open integration candidates cannot be published.
            try closeOpenCandidates(db, task: task.record.id, reason: "task \(target.rawValue)", now: now)
        }
        if current == .blocked, target == .verifying {
            // A hold taken during a conflict resumes at `verifying` (the side state's stage); the
            // conflict is still open until its candidate is resolved.
            let conflicted = try db.query(
                "SELECT 1 FROM candidate WHERE task_id = ? AND state = 'conflicted' LIMIT 1", [.text(task.record.id.uuidString)]
            ) { $0.int(0) }
            if !conflicted.isEmpty {
                try changeTaskState(db, try loadTask(db, task.record.id), to: .conflict, reason: "conflict still open", now: now)
            }
        }
    }

    /// The memory dispatch moves a reserved attempt to `starting` in its own transaction (ADR 0006 §6).
    @discardableResult
    func changeAttemptStateForDispatch(_ db: SQLiteConnection, _ attempt: LoadedAttempt, now: Int64) throws -> Int64 {
        try changeAttemptState(db, attempt, to: .starting, errorClass: nil, kind: nil, payload: nil, now: now)
    }

    @discardableResult
    private func changeAttemptState(
        _ db: SQLiteConnection, _ attempt: LoadedAttempt, to target: AttemptState, errorClass: String?,
        kind: EventKind?, payload: Data?, dedupKey: String? = nil, now: Int64
    ) throws -> Int64 {
        let current = attempt.record.state
        try current.validateTransition(to: target)
        try db.run(
            """
            UPDATE attempt SET state = ?, version = version + 1,
                error_class = COALESCE(?, error_class),
                started_at = CASE WHEN ? = 'running' THEN COALESCE(started_at, ?) ELSE started_at END,
                ended_at = CASE WHEN ? IN ('succeeded', 'failed', 'cancelled') THEN ? ELSE ended_at END
            WHERE id = ?
            """,
            [
                .text(target.rawValue), .optional(errorClass), .text(target.rawValue), .integer(now),
                .text(target.rawValue), .integer(now), .text(attempt.record.id.uuidString),
            ]
        )
        let eventKind = kind ?? (target.isTerminal ? .attemptCompleted : .attemptStateChanged)
        let eventPayload = try payload ?? Canonical.encode(
            StateChange(entityID: attempt.record.id.uuidString, from: current.rawValue, to: target.rawValue, reason: errorClass)
        )
        let seq = try appendEvent(
            db, kind: eventKind, projectID: attempt.projectID, taskID: attempt.record.taskID.uuidString,
            attemptID: attempt.record.id.uuidString, payload: eventPayload, dedupKey: dedupKey, now: now
        )
        if target.isTerminal { try settleReservation(db, attempt: attempt.record, terminal: target, now: now) }
        // The task follows its current author attempt: a result makes it `resultReady`, anything
        // else returns it to `ready` for a new attempt. A task moved to a side state meanwhile
        // keeps that state for an explicit decision.
        if target.isTerminal, attempt.record.role == .author {
            let task = try loadTask(db, attempt.record.taskID)
            let next: TaskState = target == .succeeded ? .resultReady : .ready
            let reason = "attempt \(attempt.record.id) \(target.rawValue)"
            if task.record.currentAttemptID == attempt.record.id {
                if task.record.state == .running {
                    try changeTaskState(db, task, to: next, reason: reason, now: now)
                } else if task.record.state.isSideState, task.record.resumeState == .running {
                    // The task was blocked while its author ran: it must not resume to `running`
                    // without an author, so the resume target follows the attempt's outcome.
                    try db.run(
                        "UPDATE task SET resume_state = ?, version = version + 1 WHERE id = ?",
                        [.text(next.rawValue), .text(task.record.id.uuidString)]
                    )
                    try appendEvent(
                        db, kind: .taskStateChanged, projectID: task.projectID, taskID: task.record.id.uuidString,
                        attemptID: nil,
                        payload: Canonical.encode(StateChange(
                            entityID: task.record.id.uuidString, from: task.record.state.rawValue,
                            to: task.record.state.rawValue, reason: "\(reason); resumes at \(next.rawValue)"
                        )),
                        dedupKey: nil, now: now
                    )
                }
            }
        }
        return seq
    }

    @discardableResult
    func appendEvent(
        _ db: SQLiteConnection, kind: EventKind, projectID: String, taskID: String?, attemptID: String?,
        payload: Data?, dedupKey: String?, now: Int64
    ) throws -> Int64 {
        var ordinal: Int64?
        if let attemptID {
            ordinal = try db.query(
                "SELECT COALESCE(MAX(ordinal), 0) + 1 FROM event WHERE attempt_id = ?", [.text(attemptID)]
            ) { $0.int(0) }.first
        }
        var payloadID: String?
        if let payload {
            let id = ArtifactID().uuidString
            try insertArtifact(db, id: id, projectID: projectID, kind: "eventPayload", content: payload)
            payloadID = id
        }
        try db.run(
            """
            INSERT INTO event (event_id, schema_version, project_id, task_id, attempt_id, ordinal, kind, at, payload_id, dedup_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(EventID().uuidString), .integer(Int64(EventRecord.schemaVersion)), .text(projectID),
                .optional(taskID), .optional(attemptID), .optional(ordinal), .text(kind.rawValue), .integer(now),
                .optional(payloadID), .optional(dedupKey),
            ]
        )
        return db.lastInsertRowID
    }

    private func insertArtifact(_ db: SQLiteConnection, id: String, projectID: String?, kind: String, content: Data) throws {
        try db.run(
            """
            INSERT INTO artifact (id, project_id, kind, inline_content, digest, byte_count, sensitivity)
            VALUES (?, ?, ?, ?, ?, ?, 'normal')
            """,
            [.text(id), .optional(projectID), .text(kind), .blob(content), .text(Canonical.sha256Hex(content)), .integer(Int64(content.count))]
        )
    }

    func requireExists(_ db: SQLiteConnection, table: String, id: String) throws {
        let found = try db.query("SELECT 1 FROM \(table) WHERE id = ?", [.text(id)]) { $0.int(0) }
        if found.isEmpty { throw StoreError.notFound(entity: table, id: id) }
    }

    func checkVersion(entity: String, id: String, expected: Int, actual: Int) throws {
        guard expected == actual else {
            throw StoreError.versionConflict(entity: entity, id: id, expected: expected, actual: actual)
        }
    }

    func loadJob(_ db: SQLiteConnection, _ id: JobID) throws -> JobRecord {
        guard let job = try db.query("SELECT \(Self.jobColumns) FROM job WHERE id = ?", [.text(id.uuidString)], {
            try Self.job(from: $0)
        }).first else { throw StoreError.notFound(entity: "job", id: id.uuidString) }
        return job
    }

    func loadTask(_ db: SQLiteConnection, _ id: TaskID) throws -> LoadedTask {
        guard let task = try db.query(
            "SELECT \(Self.taskColumnList("t")), j.project_id FROM task t JOIN job j ON j.id = t.job_id WHERE t.id = ?",
            [.text(id.uuidString)], { LoadedTask(record: try Self.task(from: $0), projectID: try $0.requiredText(12)) }
        ).first else { throw StoreError.notFound(entity: "task", id: id.uuidString) }
        return task
    }

    func loadAttempt(_ db: SQLiteConnection, _ id: AttemptID) throws -> LoadedAttempt {
        guard let attempt = try db.query(
            """
            SELECT \(Self.attemptColumnList("a")), j.project_id
            FROM attempt a JOIN task t ON t.id = a.task_id JOIN job j ON j.id = t.job_id
            WHERE a.id = ?
            """,
            [.text(id.uuidString)], { LoadedAttempt(record: try Self.attempt(from: $0), projectID: try $0.requiredText(23)) }
        ).first else { throw StoreError.notFound(entity: "attempt", id: id.uuidString) }
        return attempt
    }

    private static let jobColumns = "id, project_id, goal_artifact_id, state, state_reason, resume_state, version, created_at, base_oid, integration_ref, current_plan_id"

    private static func job(from row: SQLRow) throws -> JobRecord {
        JobRecord(
            id: try parseID(row.requiredText(0)), projectID: try parseID(row.requiredText(1)),
            goalArtifactID: try parseID(row.requiredText(2)), state: try parseEnum(row.requiredText(3)),
            stateReason: row.text(4), resumeState: try row.text(5).map(parseEnum),
            baseOID: row.text(8), integrationRef: row.text(9), currentPlanID: try row.text(10).map(parseID),
            version: Int(row.int(6)), createdAt: row.int(7)
        )
    }

    private static let taskColumns = taskColumnList(nil)

    private static func taskColumnList(_ alias: String?) -> String {
        let p = alias.map { "\($0)." } ?? ""
        return [
            "id", "job_id", "title", "state", "current_attempt_id", "resume_state", "version", "created_at",
            "plan_key", "wait_reason", "ready_at", "integrated_oid",
        ]
            .map { p + $0 }.joined(separator: ", ")
    }

    private static func task(from row: SQLRow) throws -> TaskRecord {
        TaskRecord(
            id: try parseID(row.requiredText(0)), jobID: try parseID(row.requiredText(1)),
            title: try row.requiredText(2), state: try parseEnum(row.requiredText(3)),
            currentAttemptID: try row.text(4).map(parseID), resumeState: try row.text(5).map(parseEnum),
            planKey: row.text(8), waitReason: row.text(9), readyAt: row.optionalInt(10), integratedOID: row.text(11),
            version: Int(row.int(6)), createdAt: row.int(7)
        )
    }

    private static let attemptColumns = attemptColumnList(nil)

    private static func attemptColumnList(_ alias: String?) -> String {
        let p = alias.map { "\($0)." } ?? ""
        return [
            "id", "task_id", "role", "ordinal", "provider", "mode", "model", "effort", "state", "spec_digest",
            "session_handle", "reserved_at", "started_at", "ended_at", "error_class", "version", "worktree_id",
            "base_oid", "account_id", "model_profile_id", "plan_id", "tier", "consent_id",
        ].map { p + $0 }.joined(separator: ", ")
    }

    private static func attempt(from row: SQLRow) throws -> AttemptRecord {
        AttemptRecord(
            id: try parseID(row.requiredText(0)), taskID: try parseID(row.requiredText(1)),
            role: try parseEnum(row.requiredText(2)), ordinal: Int(row.int(3)),
            provider: try parseEnum(row.requiredText(4)), mode: try parseEnum(row.requiredText(5)),
            model: try row.requiredText(6), effort: row.text(7), state: try parseEnum(row.requiredText(8)),
            specDigest: try row.requiredText(9), sessionHandle: row.text(10), reservedAt: row.int(11),
            startedAt: row.optionalInt(12), endedAt: row.optionalInt(13), errorClass: row.text(14),
            worktreeID: try row.text(16).map(parseID), baseOID: row.text(17), accountID: try row.text(18).map(parseID),
            modelProfileID: try row.text(19).map(parseID), planID: try row.text(20).map(parseID),
            tier: try row.text(21).map(parseEnum), consentID: try row.text(22).map(parseID), version: Int(row.int(15))
        )
    }
}

func parseID<Tag>(_ text: String) throws -> TypedID<Tag> {
    guard let id = TypedID<Tag>(string: text) else { throw StoreError.corruptRow("Invalid ID \(text)") }
    return id
}

func parseEnum<T: RawRepresentable>(_ text: String) throws -> T where T.RawValue == String {
    guard let value = T(rawValue: text) else { throw StoreError.corruptRow("Unknown \(T.self) value \(text)") }
    return value
}
