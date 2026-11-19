import Domain
import Foundation
import SQLite3

public struct WorktreeRegistration: Sendable, Equatable {
    public var id: WorktreeID
    public var projectID: ProjectID
    public var attemptID: AttemptID?
    public var pathToken: String
    public var baseOID: String
    public var kind: WorktreeKind
    public var ownerNonce: String

    public init(
        id: WorktreeID = WorktreeID(), projectID: ProjectID, attemptID: AttemptID?, pathToken: String,
        baseOID: String, kind: WorktreeKind, ownerNonce: String
    ) {
        self.id = id
        self.projectID = projectID
        self.attemptID = attemptID
        self.pathToken = pathToken
        self.baseOID = baseOID
        self.kind = kind
        self.ownerNonce = ownerNonce
    }
}

/// Domain changes applied in the same transaction that completes a Git operation.
public struct GitOperationEffects: Sendable, Equatable {
    public var worktreeState: WorktreeState?
    public var resultOID: String?
    public var savedTree: String?
    public var seal: (status: SealStatus, rejected: [String: String])?
    /// Records the job's base and integration ref once that ref exists.
    public var jobIntegration: (job: JobID, baseOID: String, ref: String)?

    public init(
        worktreeState: WorktreeState? = nil, resultOID: String? = nil, savedTree: String? = nil,
        seal: (status: SealStatus, rejected: [String: String])? = nil,
        jobIntegration: (job: JobID, baseOID: String, ref: String)? = nil
    ) {
        self.seal = seal
        self.worktreeState = worktreeState
        self.resultOID = resultOID
        self.savedTree = savedTree
        self.jobIntegration = jobIntegration
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.worktreeState == rhs.worktreeState && lhs.resultOID == rhs.resultOID && lhs.savedTree == rhs.savedTree
            && lhs.seal?.status == rhs.seal?.status && lhs.seal?.rejected == rhs.seal?.rejected
            && lhs.jobIntegration?.job == rhs.jobIntegration?.job && lhs.jobIntegration?.baseOID == rhs.jobIntegration?.baseOID
            && lhs.jobIntegration?.ref == rhs.jobIntegration?.ref
    }
}

/// Worktrees and the Git journal. Every Git side effect is journaled as `prepared` and committed
/// before it happens; completing it and its domain effects is one transaction.
extension Store {
    /// Registers a new worktree (`preparing`) and journals its creation.
    @discardableResult
    public func registerWorktree(_ registration: WorktreeRegistration) throws -> (WorktreeRecord, GitOperationID) {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            try requireExists(db, table: "project", id: registration.projectID.uuidString)
            if let attemptID = registration.attemptID {
                let attempt = try loadAttempt(db, attemptID)
                guard attempt.projectID == registration.projectID.uuidString else {
                    throw StoreError.projectMismatch(taskID: attempt.record.taskID, expected: registration.projectID)
                }
            }
            try db.run(
                """
                INSERT INTO worktree (id, project_id, attempt_id, path_token, base_oid, kind, owner_nonce, state, version, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'preparing', 1, ?)
                """,
                [
                    .text(registration.id.uuidString), .text(registration.projectID.uuidString),
                    .optional(registration.attemptID?.uuidString), .text(registration.pathToken), .text(registration.baseOID),
                    .text(registration.kind.rawValue), .text(registration.ownerNonce), .integer(now),
                ]
            )
            if let attemptID = registration.attemptID {
                try db.run("UPDATE attempt SET worktree_id = ? WHERE id = ?", [.text(registration.id.uuidString), .text(attemptID.uuidString)])
            }
            let operation = try insertOperation(
                db, projectID: registration.projectID, worktreeID: registration.id, kind: .addWorktree,
                ref: nil, expectedOld: nil, desiredNew: registration.baseOID, now: now
            )
            return (try loadWorktree(db, registration.id), operation)
        }
    }

    /// Journals a ref update. `expectedOld == nil` means the ref must not exist yet.
    @discardableResult
    public func prepareRefUpdate(
        projectID: ProjectID, worktreeID: WorktreeID?, ref: String, expectedOld: String?, desiredNew: String
    ) throws -> GitOperationID {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            try insertOperation(db, projectID: projectID, worktreeID: worktreeID, kind: .updateRef, ref: ref,
                                expectedOld: expectedOld, desiredNew: desiredNew, now: now)
        }
    }

    /// Moves a worktree to `removing` and journals its removal, including whether it is forced.
    @discardableResult
    public func prepareWorktreeRemoval(_ id: WorktreeID, force: Bool = false) throws -> GitOperationID {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            let worktree = try loadWorktree(db, id)
            try changeWorktree(db, worktree, to: .removing, resultOID: nil, savedTree: nil, seal: nil, now: now)
            return try insertOperation(db, projectID: worktree.projectID, worktreeID: id, kind: .removeWorktree,
                                       ref: nil, expectedOld: nil, desiredNew: nil, force: force, now: now)
        }
    }

    /// Records what happened to a prepared operation, together with its domain effects.
    public func completeGitOperation(
        _ id: GitOperationID, as state: GitOperationState, detail: String? = nil, effects: GitOperationEffects = GitOperationEffects()
    ) throws {
        precondition(state != .prepared, "completion must leave `prepared`")
        let db = try connection()
        let now = currentTime()
        try db.transaction {
            let operation = try loadOperation(db, id)
            guard operation.state == .prepared else { throw StoreError.gitOperationNotPrepared(id) }
            try db.run(
                "UPDATE git_operation SET state = ?, detail = ?, applied_at = ? WHERE id = ?",
                [.text(state.rawValue), .optional(detail), state == .applied ? .integer(now) : .null, .text(id.uuidString)]
            )
            try appendEvent(
                db, kind: .gitOperationCompleted, projectID: operation.projectID.uuidString, taskID: nil, attemptID: nil,
                payload: Canonical.encode(["operation": id.uuidString, "state": state.rawValue, "detail": detail ?? ""]),
                dedupKey: nil, now: now
            )
            if let target = effects.worktreeState, let worktreeID = operation.worktreeID {
                let worktree = try loadWorktree(db, worktreeID)
                if worktree.state != target {
                    try changeWorktree(db, worktree, to: target, resultOID: effects.resultOID, savedTree: effects.savedTree,
                                       seal: effects.seal, now: now)
                }
            }
            if let integration = effects.jobIntegration {
                try db.run(
                    "UPDATE job SET base_oid = ?, integration_ref = ?, version = version + 1 WHERE id = ? AND integration_ref IS NULL",
                    [.text(integration.baseOID), .text(integration.ref), .text(integration.job.uuidString)]
                )
            }
        }
    }

    /// Worktree state changes outside a journaled operation (sealing, attention flags).
    public func transitionWorktree(
        _ id: WorktreeID, to target: WorktreeState, resultOID: String? = nil, savedTree: String? = nil,
        seal: (status: SealStatus, rejected: [String: String])? = nil
    ) throws {
        let db = try connection()
        let now = currentTime()
        try db.transaction {
            try changeWorktree(db, try loadWorktree(db, id), to: target, resultOID: resultOID, savedTree: savedTree, seal: seal, now: now)
        }
    }

    public func worktree(_ id: WorktreeID) throws -> WorktreeRecord? {
        let db = try connection()
        return try db.query("SELECT \(Self.worktreeColumns) FROM worktree WHERE id = ?", [.text(id.uuidString)]) {
            try Self.worktree(from: $0)
        }.first
    }

    public func worktrees(projectID: ProjectID? = nil) throws -> [WorktreeRecord] {
        let filter = projectID == nil ? "" : "WHERE project_id = ?"
        return try connection().query(
            "SELECT \(Self.worktreeColumns) FROM worktree \(filter) ORDER BY created_at, id",
            projectID.map { [.text($0.uuidString)] } ?? []
        ) { try Self.worktree(from: $0) }
    }

    public func gitOperations(state: GitOperationState? = nil) throws -> [GitOperationRecord] {
        let filter = state == nil ? "" : "WHERE state = ?"
        return try connection().query(
            "SELECT \(Self.operationColumns) FROM git_operation \(filter) ORDER BY created_at, id",
            state.map { [.text($0.rawValue)] } ?? []
        ) { try Self.operation(from: $0) }
    }

    // MARK: Helpers

    private func insertOperation(
        _ db: SQLiteConnection, projectID: ProjectID, worktreeID: WorktreeID?, kind: GitOperationKind, ref: String?,
        expectedOld: String?, desiredNew: String?, force: Bool = false, now: Int64
    ) throws -> GitOperationID {
        let id = GitOperationID()
        do {
            try db.run(
                """
                INSERT INTO git_operation (id, project_id, worktree_id, kind, ref, expected_old, desired_new, state, force, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'prepared', ?, ?)
                """,
                [
                    .text(id.uuidString), .text(projectID.uuidString), .optional(worktreeID?.uuidString), .text(kind.rawValue),
                    .optional(ref), .optional(expectedOld), .optional(desiredNew), .integer(force ? 1 : 0), .integer(now),
                ]
            )
        } catch let error as SQLiteError where error.primaryCode == SQLITE_CONSTRAINT {
            if ref == nil, worktreeID == nil { throw error }
            let busy = try db.query(
                "SELECT 1 FROM git_operation WHERE state = 'prepared' AND (ref = ? OR (worktree_id = ? AND kind <> 'updateRef'))",
                [.optional(ref), .optional(worktreeID?.uuidString)]
            ) { $0.int(0) }
            if busy.isEmpty { throw error }
            throw StoreError.gitOperationOpen(ref ?? worktreeID?.uuidString ?? "")
        }
        try appendEvent(
            db, kind: .gitOperationPrepared, projectID: projectID.uuidString, taskID: nil, attemptID: nil,
            payload: Canonical.encode([
                "operation": id.uuidString, "kind": kind.rawValue, "ref": ref ?? "", "expectedOld": expectedOld ?? "",
                "desiredNew": desiredNew ?? "",
            ]),
            dedupKey: nil, now: now
        )
        return id
    }

    private func changeWorktree(
        _ db: SQLiteConnection, _ worktree: WorktreeRecord, to target: WorktreeState, resultOID: String?, savedTree: String?,
        seal: (status: SealStatus, rejected: [String: String])?, now: Int64
    ) throws {
        try worktree.state.validateTransition(to: target)
        let rejected = try seal.map { String(decoding: try Canonical.encode($0.rejected), as: UTF8.self) }
        try db.run(
            """
            UPDATE worktree SET state = ?, result_oid = COALESCE(?, result_oid), saved_tree = COALESCE(?, saved_tree),
                seal_status = COALESCE(?, seal_status), rejected_json = COALESCE(?, rejected_json),
                version = version + 1 WHERE id = ?
            """,
            [
                .text(target.rawValue), .optional(resultOID), .optional(savedTree), .optional(seal?.status.rawValue),
                .optional(rejected), .text(worktree.id.uuidString),
            ]
        )
        try appendEvent(
            db, kind: .worktreeStateChanged, projectID: worktree.projectID.uuidString, taskID: nil, attemptID: nil,
            payload: Canonical.encode(StateChange(entityID: worktree.id.uuidString, from: worktree.state.rawValue, to: target.rawValue, reason: resultOID)),
            dedupKey: nil, now: now
        )
    }

    private func loadWorktree(_ db: SQLiteConnection, _ id: WorktreeID) throws -> WorktreeRecord {
        guard let worktree = try db.query("SELECT \(Self.worktreeColumns) FROM worktree WHERE id = ?", [.text(id.uuidString)], {
            try Self.worktree(from: $0)
        }).first else { throw StoreError.notFound(entity: "worktree", id: id.uuidString) }
        return worktree
    }

    private func loadOperation(_ db: SQLiteConnection, _ id: GitOperationID) throws -> GitOperationRecord {
        guard let operation = try db.query("SELECT \(Self.operationColumns) FROM git_operation WHERE id = ?", [.text(id.uuidString)], {
            try Self.operation(from: $0)
        }).first else { throw StoreError.notFound(entity: "git_operation", id: id.uuidString) }
        return operation
    }

    private static let worktreeColumns =
        "id, project_id, attempt_id, path_token, base_oid, kind, owner_nonce, state, result_oid, saved_tree, version, created_at, seal_status, rejected_json"

    private static func worktree(from row: SQLRow) throws -> WorktreeRecord {
        WorktreeRecord(
            id: try parseID(row.requiredText(0)), projectID: try parseID(row.requiredText(1)),
            attemptID: try row.text(2).map(parseID), pathToken: try row.requiredText(3), baseOID: try row.requiredText(4),
            kind: try parseEnum(row.requiredText(5)), ownerNonce: try row.requiredText(6), state: try parseEnum(row.requiredText(7)),
            resultOID: row.text(8), savedTree: row.text(9), sealStatus: try row.text(12).map(parseEnum),
            rejectedPaths: try row.text(13).map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:],
            version: Int(row.int(10)), createdAt: row.int(11)
        )
    }

    private static let operationColumns =
        "id, project_id, worktree_id, kind, ref, expected_old, desired_new, state, detail, created_at, applied_at, force"

    private static func operation(from row: SQLRow) throws -> GitOperationRecord {
        GitOperationRecord(
            id: try parseID(row.requiredText(0)), projectID: try parseID(row.requiredText(1)),
            worktreeID: try row.text(2).map(parseID), kind: try parseEnum(row.requiredText(3)), ref: row.text(4),
            expectedOld: row.text(5), desiredNew: row.text(6), state: try parseEnum(row.requiredText(7)),
            detail: row.text(8), force: row.int(11) == 1, createdAt: row.int(9), appliedAt: row.optionalInt(10)
        )
    }
}
