import Domain
import Foundation

public struct CandidateDraft: Sendable, Equatable {
    public var id: CandidateID
    public var jobID: JobID
    public var taskID: TaskID?
    public var kind: CandidateKind
    public var authorAttemptID: AttemptID?
    public var resultOID: String?
    public var revertsCandidateID: CandidateID?
    public var previousTargetOID: String
    public var candidateOID: String?
    public var targetRef: String
    public var worktreeID: WorktreeID?
    public var conflicts: [String]

    public init(
        id: CandidateID = CandidateID(), jobID: JobID, taskID: TaskID?, kind: CandidateKind, authorAttemptID: AttemptID?,
        resultOID: String?, revertsCandidateID: CandidateID? = nil, previousTargetOID: String, candidateOID: String?,
        targetRef: String, worktreeID: WorktreeID?, conflicts: [String] = []
    ) {
        self.id = id
        self.jobID = jobID
        self.taskID = taskID
        self.kind = kind
        self.authorAttemptID = authorAttemptID
        self.resultOID = resultOID
        self.revertsCandidateID = revertsCandidateID
        self.previousTargetOID = previousTargetOID
        self.candidateOID = candidateOID
        self.targetRef = targetRef
        self.worktreeID = worktreeID
        self.conflicts = conflicts
    }
}

public struct FindingDraft: Sendable, Equatable {
    public var severity: FindingSeverity
    public var path: String?
    public var line: Int?
    public var impact: String
    public var suggestion: String

    public init(severity: FindingSeverity, path: String?, line: Int?, impact: String, suggestion: String) {
        self.severity = severity
        self.path = path
        self.line = line
        self.impact = impact
        self.suggestion = suggestion
    }
}

public enum IntegrationStoreError: Error, Equatable, Sendable {
    /// A candidate was built while another one of the same task is still open.
    case openCandidateExists(CandidateID)
    /// Evidence for a commit the candidate no longer is (late answers for older OIDs).
    case staleEvidence(candidate: CandidateID, oid: String)
    case blockingFindingCannotBeAccepted(FindingID)
    case approvalNotUsable(ApprovalID, ApprovalState)
    /// The approval's time ran out; it is revoked and a new decision is needed.
    case approvalExpired(ApprovalID)
    /// Evidence changed since the caller checked the gate.
    case evidenceChanged(CandidateID)
    case openRevertExists(CandidateID)
    /// The same input was already rejected on evidence (red test or blocking finding): it needs
    /// a new author result (or, for a revert, a new target state), not a rebuild.
    case rejectedBefore(CandidateID)
    /// The attempt is not a finished reviewer of this candidate's task, or already recorded.
    case reviewAttemptNotUsable(AttemptID)
    /// The candidate's task cannot follow it (ended, held by the user or back with an author);
    /// nothing was changed.
    case taskCannotFollow(TaskID, from: TaskState, to: TaskState)
    /// Evidence and decisions are taken only while the candidate's task is in verification.
    case taskNotInVerification(TaskID, TaskState)
    /// The candidate is being published: its evidence is frozen until the publication is
    /// applied or released.
    case publicationInProgress(CandidateID)
}

/// Candidates, their test and review evidence, findings and approvals. Every change is one
/// transaction with its journal event.
extension Store {
    @discardableResult
    public func createCandidate(_ draft: CandidateDraft) throws -> CandidateRecord {
        let db = try connection()
        let now = currentTime()
        return try db.transaction { try insertCandidate(db, draft, now: now) }
    }

    /// A host-made revert: its task (starting where an author's task would be after its result,
    /// in `verifying`) and its candidate, in one transaction, so a refused revert leaves no task.
    @discardableResult
    public func createRevertCandidate(_ draft: CandidateDraft, taskTitle: String) throws -> CandidateRecord {
        guard draft.kind == .revert, draft.revertsCandidateID != nil, let taskID = draft.taskID else {
            throw StoreError.notFound(entity: "reverted candidate", id: draft.id.uuidString)
        }
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            let job = try loadJob(db, draft.jobID)
            try db.run(
                "INSERT INTO task (id, job_id, title, state, version, created_at) VALUES (?, ?, ?, 'verifying', 1, ?)",
                [.text(taskID.uuidString), .text(job.id.uuidString), .text(taskTitle), .integer(now)]
            )
            try appendEvent(
                db, kind: .taskCreated, projectID: job.projectID.uuidString, taskID: taskID.uuidString, attemptID: nil,
                payload: Canonical.encode(["jobID": job.id.uuidString, "title": taskTitle, "state": "verifying"]), dedupKey: nil, now: now
            )
            // A conflicted revert holds its task in `conflict` until it is resolved.
            return try insertCandidate(db, draft, now: now)
        }
    }

    /// Fails early (before any Git work) when a revert of this candidate is still open.
    public func requireNoOpenRevert(of id: CandidateID) throws {
        let open = try connection().query(
            "SELECT id FROM candidate WHERE reverts_candidate_id = ? AND state NOT IN ('published', 'rejected', 'superseded')",
            [.text(id.uuidString)]
        ) { try $0.requiredText(0) }
        if let first = open.first { throw IntegrationStoreError.openRevertExists(try parseID(first)) }
    }

    private func insertCandidate(_ db: SQLiteConnection, _ draft: CandidateDraft, now: Int64) throws -> CandidateRecord {
        do {
            let job = try loadJob(db, draft.jobID)
            var provider: ProviderKind?
            if let reverted = draft.revertsCandidateID {
                // The reviewer of a revert is checked against the author of the reverted change.
                provider = try loadCandidate(db, reverted).authorProvider
                let open = try db.query(
                    "SELECT id FROM candidate WHERE reverts_candidate_id = ? AND state NOT IN ('published', 'rejected', 'superseded')",
                    [.text(reverted.uuidString)]
                ) { try $0.requiredText(0) }
                if let first = open.first { throw IntegrationStoreError.openRevertExists(try parseID(first)) }
                if let rejected = try rejectedOnEvidence(
                    db, "c.reverts_candidate_id = ? AND c.previous_target_oid = ?", [.text(reverted.uuidString), .text(draft.previousTargetOID)]
                ) { throw IntegrationStoreError.rejectedBefore(rejected) }
            }
            if let result = draft.resultOID, let taskID = draft.taskID,
               let rejected = try rejectedOnEvidence(db, "c.task_id = ? AND c.result_oid = ?", [.text(taskID.uuidString), .text(result)]) {
                throw IntegrationStoreError.rejectedBefore(rejected)
            }
            if let attemptID = draft.authorAttemptID {
                let attempt = try loadAttempt(db, attemptID)
                guard attempt.projectID == job.projectID.uuidString, attempt.record.role == .author,
                      attempt.record.state == .succeeded, draft.taskID == attempt.record.taskID else {
                    throw StoreError.projectMismatch(taskID: attempt.record.taskID, expected: job.projectID)
                }
                provider = attempt.record.provider
            }
            if let taskID = draft.taskID {
                let open = try db.query(
                    "SELECT id FROM candidate WHERE task_id = ? AND state NOT IN ('published', 'rejected', 'superseded')",
                    [.text(taskID.uuidString)]
                ) { try $0.requiredText(0) }
                if let first = open.first { throw IntegrationStoreError.openCandidateExists(try parseID(first)) }
                let task = try loadTask(db, taskID).record
                guard Self.acceptsCandidate(task) else {
                    throw IntegrationStoreError.taskCannotFollow(taskID, from: task.state, to: .verifying)
                }
            }
            let state: CandidateState = draft.candidateOID == nil ? .conflicted : .built
            try db.run(
                """
                INSERT INTO candidate (id, project_id, job_id, task_id, kind, author_attempt_id, author_provider, result_oid,
                    reverts_candidate_id, previous_target_oid, candidate_oid, target_ref, worktree_id, state, conflicts_json,
                    version, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
                """,
                [
                    .text(draft.id.uuidString), .text(job.projectID.uuidString), .text(draft.jobID.uuidString),
                    .optional(draft.taskID?.uuidString), .text(draft.kind.rawValue), .optional(draft.authorAttemptID?.uuidString),
                    .optional(provider?.rawValue), .optional(draft.resultOID), .optional(draft.revertsCandidateID?.uuidString),
                    .text(draft.previousTargetOID), .optional(draft.candidateOID), .text(draft.targetRef),
                    .optional(draft.worktreeID?.uuidString), .text(state.rawValue), .text(try Self.json(draft.conflicts)), .integer(now),
                ]
            )
            try appendEvent(
                db, kind: .candidateBuilt, projectID: job.projectID.uuidString, taskID: draft.taskID?.uuidString, attemptID: nil,
                payload: Canonical.encode([
                    "candidateID": draft.id.uuidString, "state": state.rawValue, "previousTargetOID": draft.previousTargetOID,
                    "candidateOID": draft.candidateOID ?? "",
                ]),
                dedupKey: nil, now: now
            )
            let candidate = try loadCandidate(db, draft.id)
            try followTask(db, candidate, from: nil, to: state, now: now)
            return candidate
        }
    }

    /// Whether a task can take a new candidate: past its author's result, not held by the user
    /// (`blocked`), not ended, and not on its way back to an author (`needsChanges` included:
    /// only a new author result leaves it).
    public static func acceptsCandidate(_ task: TaskRecord) -> Bool {
        let backToAuthor: Set<TaskState> = [.pending, .ready, .running, .needsChanges]
        if task.state.isTerminal || task.state == .blocked || backToAuthor.contains(task.state) { return false }
        if task.state.isSideState, let resume = task.resumeState, backToAuthor.contains(resume) { return false }
        return true
    }

    /// Moves the candidate's task to the stage its candidate reached, inside the candidate's
    /// transaction: built → verifying, conflicted → conflict, accepted → awaitingMerge, accepted
    /// back to reviewing → verifying, rejected → needsChanges (a revert task: noResult),
    /// a superseded revert → noResult. A side state is left through its resume stage first.
    /// A forward move the task cannot make throws and undoes the whole transaction; an ending
    /// candidate leaves an ended or user-held task alone.
    private func followTask(_ db: SQLiteConnection, _ candidate: CandidateRecord, from: CandidateState?, to target: CandidateState, now: Int64) throws {
        guard let taskID = candidate.taskID else { return }
        let stages: [TaskState]
        switch (from, target) {
        // A publication that did not happen: the task still waits at (or is held before) the merge.
        case (.publishing?, .accepted): stages = []
        case (nil, .built), (.conflicted?, .built), (.accepted?, .reviewing): stages = [.verifying]
        case (nil, .conflicted): stages = [.verifying, .conflict]
        case (_, .accepted): stages = [.awaitingMerge]
        case (_, .rejected): stages = [candidate.kind == .revert ? .noResult : .needsChanges]
        case (_, .superseded): stages = candidate.kind == .revert ? [.noResult] : []
        default: stages = []
        }
        let ending = target == .rejected || target == .superseded
        let reason = "candidate \(candidate.id.uuidString) \(target.rawValue)"
        for stage in stages {
            var task = try loadTask(db, taskID)
            if task.record.state == stage { continue }
            if ending, task.record.state.isTerminal || task.record.state == .blocked { return }
            // Never lift the user's hold implicitly.
            if task.record.state == .blocked { throw IntegrationStoreError.taskCannotFollow(taskID, from: .blocked, to: stage) }
            let state = task.record.state
            if !state.allowsTransition(to: stage, resumeState: task.record.resumeState), state.isSideState, state != .blocked,
               let resume = task.record.resumeState, resume != stage, resume.allowsTransition(to: stage) {
                try changeTaskState(db, task, to: resume, reason: reason, now: now)
                task = try loadTask(db, taskID)
            }
            guard task.record.state.allowsTransition(to: stage, resumeState: task.record.resumeState) else {
                throw IntegrationStoreError.taskCannotFollow(taskID, from: task.record.state, to: stage)
            }
            try changeTaskState(db, task, to: stage, reason: reason, now: now)
        }
    }

    /// A task that goes back to an author (`ready`) or ends without integration closes its open
    /// candidates (rejected, approvals revoked). Their integration worktrees go at `recover`.
    func closeOpenCandidates(_ db: SQLiteConnection, task: TaskID, reason: String, now: Int64) throws {
        let open = try db.query(
            "SELECT id FROM candidate WHERE task_id = ? AND state IN ('conflicted', 'built', 'testing', 'reviewing', 'accepted')",
            [.text(task.uuidString)]
        ) { try parseID($0.requiredText(0)) as CandidateID }
        for id in open {
            try changeCandidate(db, try loadCandidate(db, id), to: .rejected, candidateOID: nil, conflicts: nil, reason: reason, now: now, moveTask: false)
        }
    }

    /// Evidence and decisions need an open candidate (not ended, not being published) whose task
    /// is in verification, checked atomically with them.
    private func requireTaskInVerification(_ db: SQLiteConnection, _ candidate: CandidateRecord) throws {
        if candidate.state == .publishing { throw IntegrationStoreError.publicationInProgress(candidate.id) }
        if candidate.state.isTerminal {
            throw IntegrationStoreError.staleEvidence(candidate: candidate.id, oid: candidate.candidateOID ?? "")
        }
        guard let taskID = candidate.taskID else { return }
        let task = try loadTask(db, taskID).record
        guard Self.acceptsCandidate(task) else { throw IntegrationStoreError.taskNotInVerification(taskID, task.state) }
    }

    /// Approval and publication need the task waiting for exactly this merge.
    private func requireAwaitingMerge(_ db: SQLiteConnection, _ candidate: CandidateRecord) throws {
        guard let taskID = candidate.taskID else { return }
        let task = try loadTask(db, taskID).record
        guard task.state == .awaitingMerge else { throw IntegrationStoreError.taskCannotFollow(taskID, from: task.state, to: .integrated) }
    }

    /// A rejected candidate matching `condition` that its evidence (a red test or a blocking
    /// finding) rejected.
    private func rejectedOnEvidence(_ db: SQLiteConnection, _ condition: String, _ values: [SQLValue]) throws -> CandidateID? {
        try db.query(
            """
            SELECT c.id FROM candidate c WHERE \(condition) AND c.state = 'rejected' AND (
                EXISTS (SELECT 1 FROM test_result t WHERE t.candidate_id = c.id AND t.status IN ('failed', 'crashed', 'inputsModified'))
                OR EXISTS (SELECT 1 FROM finding f JOIN review r ON r.id = f.review_id WHERE r.candidate_id = c.id AND f.severity = 'blocking'))
            LIMIT 1
            """,
            values
        ) { try parseID($0.requiredText(0)) as CandidateID }.first
    }

    /// Moves a candidate. Leaving it as rejected or superseded revokes its open approvals.
    /// With `onlyFrom`, nothing happens unless the current state is one of them (decided in the
    /// same transaction, so a concurrent change cannot be overwritten from a stale snapshot).
    /// With `atVersion`, nothing happens if evidence arrived since that version was read.
    /// `actor` marks the user's own move (a rejection): its reason may go to the next author.
    @discardableResult
    public func transitionCandidate(
        _ id: CandidateID, to target: CandidateState, candidateOID: String? = nil, conflicts: [String]? = nil, reason: String? = nil,
        onlyFrom: Set<CandidateState>? = nil, atVersion: Int? = nil, actor: String? = nil
    ) throws -> CandidateRecord {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            let candidate = try loadCandidate(db, id)
            if let onlyFrom, !onlyFrom.contains(candidate.state) { return candidate }
            if let atVersion, candidate.version != atVersion { return candidate }
            try changeCandidate(
                db, candidate, to: target, candidateOID: candidateOID, conflicts: conflicts, reason: reason, now: now, actor: actor
            )
            return try loadCandidate(db, id)
        }
    }

    /// Records which attempt a reviewer worktree belongs to (the attempt is created after it).
    public func linkWorktree(_ worktree: WorktreeID, to attempt: AttemptID) throws {
        let db = try connection()
        try db.transaction {
            try db.run("UPDATE worktree SET attempt_id = ? WHERE id = ? AND attempt_id IS NULL", [.text(attempt.uuidString), .text(worktree.uuidString)])
            try db.run("UPDATE attempt SET worktree_id = ? WHERE id = ? AND worktree_id IS NULL", [.text(worktree.uuidString), .text(attempt.uuidString)])
        }
    }

    /// One attempt's events of one kind, in order.
    public func events(attempt: AttemptID, kind: EventKind) throws -> [EventRecord] {
        let seqs = try connection().query(
            "SELECT seq FROM event WHERE attempt_id = ? AND kind = ? ORDER BY ordinal", [.text(attempt.uuidString), .text(kind.rawValue)]
        ) { $0.int(0) }
        var result: [EventRecord] = []
        for seq in seqs { result += try events(after: seq - 1, limit: 1) }
        return result
    }

    /// Test evidence for exactly the candidate's current commit.
    @discardableResult
    public func recordTest(
        candidate id: CandidateID, oid: String, profileDigest: String, status: TestStatus, exitCode: Int?,
        changedTestInputs: [String], summary: String
    ) throws -> TestResultRecord {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            let candidate = try loadCandidate(db, id)
            guard candidate.candidateOID == oid, !candidate.state.isTerminal else {
                throw IntegrationStoreError.staleEvidence(candidate: id, oid: oid)
            }
            try requireTaskInVerification(db, candidate)
            let purged = try contentPurged(db, candidate)
            let result = TestResultRecord(
                id: TestResultID(), candidateID: id, candidateOID: oid, profileDigest: profileDigest, status: status,
                exitCode: exitCode, changedTestInputs: changedTestInputs, summary: purged ? Self.purgedText : summary, at: now
            )
            try db.run(
                """
                INSERT INTO test_result (id, candidate_id, candidate_oid, profile_digest, status, exit_code, changed_test_inputs_json, summary, at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(result.id.uuidString), .text(id.uuidString), .text(oid), .text(profileDigest), .text(status.rawValue),
                    .optional(exitCode), .text(try Self.json(changedTestInputs)), .text(result.summary), .integer(now),
                ]
            )
            try bumpEvidence(db, id)
            try appendEvent(
                db, kind: .testFinished, projectID: candidate.projectID.uuidString, taskID: candidate.taskID?.uuidString,
                attemptID: nil, payload: Canonical.encode(["candidateID": id.uuidString, "candidateOID": oid, "status": status.rawValue]),
                dedupKey: nil, now: now
            )
            return result
        }
    }

    /// A review of exactly the candidate's current commit, with its findings.
    @discardableResult
    public func recordReview(
        candidate id: CandidateID, oid: String, reviewerAttemptID: AttemptID?, origin: ReviewOrigin, reviewerProvider: ProviderKind?,
        status: ReviewStatus, summary: String, findings: [FindingDraft]
    ) throws -> ReviewRecord {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            let candidate = try loadCandidate(db, id)
            guard candidate.candidateOID == oid, !candidate.state.isTerminal else {
                throw IntegrationStoreError.staleEvidence(candidate: id, oid: oid)
            }
            try requireTaskInVerification(db, candidate)
            if let reviewerAttemptID {
                // Only a finished reviewer of this candidate's task, only once, and only one that
                // reviewed exactly this commit: its worktree was prepared at the candidate commit.
                let attempt = try loadAttempt(db, reviewerAttemptID).record
                let recorded = try db.query("SELECT 1 FROM review WHERE reviewer_attempt_id = ?", [.text(reviewerAttemptID.uuidString)]) { $0.int(0) }
                let reviewedOID = try attempt.worktreeID.flatMap { tree in
                    try db.query("SELECT base_oid FROM worktree WHERE id = ?", [.text(tree.uuidString)]) { $0.text(0) }.first ?? nil
                }
                guard attempt.role == .reviewer, attempt.state == .succeeded, attempt.taskID == candidate.taskID,
                      attempt.provider == reviewerProvider, recorded.isEmpty, reviewedOID == oid else {
                    throw IntegrationStoreError.reviewAttemptNotUsable(reviewerAttemptID)
                }
            }
            let purged = try contentPurged(db, candidate)
            let review = ReviewRecord(
                id: ReviewID(), candidateID: id, candidateOID: oid, reviewerAttemptID: reviewerAttemptID, origin: origin,
                reviewerProvider: reviewerProvider, status: status, summary: purged ? Self.purgedText : summary, at: now
            )
            try db.run(
                """
                INSERT INTO review (id, candidate_id, candidate_oid, reviewer_attempt_id, origin, reviewer_provider, status, summary, at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(review.id.uuidString), .text(id.uuidString), .text(oid), .optional(reviewerAttemptID?.uuidString),
                    .text(origin.rawValue), .optional(reviewerProvider?.rawValue), .text(status.rawValue), .text(review.summary), .integer(now),
                ]
            )
            for finding in findings {
                try db.run(
                    """
                    INSERT INTO finding (id, review_id, severity, path, line, impact, suggestion, disposition)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'open')
                    """,
                    [
                        .text(FindingID().uuidString), .text(review.id.uuidString), .text(finding.severity.rawValue),
                        .optional(finding.path), .optional(finding.line), .text(purged ? Self.purgedText : finding.impact),
                        .text(purged ? Self.purgedText : finding.suggestion),
                    ]
                )
            }
            try bumpEvidence(db, id)
            try appendEvent(
                db, kind: .reviewFinished, projectID: candidate.projectID.uuidString, taskID: candidate.taskID?.uuidString,
                attemptID: nil,
                payload: Canonical.encode([
                    "candidateID": id.uuidString, "candidateOID": oid, "status": status.rawValue, "origin": origin.rawValue,
                    "findings": String(findings.count),
                ]),
                dedupKey: nil, now: now
            )
            return review
        }
    }

    /// The user's decision on a finding. Blocking findings cannot be accepted, only fixed in a
    /// new candidate.
    /// Returns the finding's candidate.
    @discardableResult
    public func decideFinding(_ id: FindingID, _ disposition: FindingDisposition, reason: String) throws -> CandidateID {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            guard let row = try db.query(
                "SELECT f.severity, c.project_id, c.task_id, c.id FROM finding f JOIN review r ON r.id = f.review_id JOIN candidate c ON c.id = r.candidate_id WHERE f.id = ?",
                [.text(id.uuidString)], { (try $0.requiredText(0), try $0.requiredText(1), $0.text(2), try $0.requiredText(3)) }
            ).first else { throw StoreError.notFound(entity: "finding", id: id.uuidString) }
            if row.0 == FindingSeverity.blocking.rawValue, disposition == .accepted {
                throw IntegrationStoreError.blockingFindingCannotBeAccepted(id)
            }
            let candidate = try loadCandidate(db, try parseID(row.3))
            try requireTaskInVerification(db, candidate)
            try bumpEvidence(db, candidate.id)
            if (reason).isEmpty { throw DomainError.reasonRequired(entity: "finding", state: disposition.rawValue) }
            let reason = try contentPurged(db, candidate) ? Self.purgedText : reason
            try db.run("UPDATE finding SET disposition = ?, reason = ? WHERE id = ?", [.text(disposition.rawValue), .text(reason), .text(id.uuidString)])
            try appendEvent(
                db, kind: .findingDecided, projectID: row.1, taskID: row.2, attemptID: nil,
                payload: Canonical.encode(["findingID": id.uuidString, "disposition": disposition.rawValue, "reason": reason]),
                dedupKey: nil, now: now
            )
            return candidate.id
        }
    }

    /// The user's approval to publish exactly this commit on top of exactly `expectedOldOID`.
    @discardableResult
    public func grantApproval(
        candidate id: CandidateID, expectedOldOID: String, policyVersion: Int, actor: String, ttl: Int64? = nil
    ) throws -> ApprovalRecord {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            let candidate = try loadCandidate(db, id)
            guard candidate.state == .accepted, let oid = candidate.candidateOID else {
                throw DomainError.invalidTransition(entity: "approval", from: candidate.state.rawValue, to: "granted")
            }
            try requireAwaitingMerge(db, candidate)
            let approval = ApprovalRecord(
                id: ApprovalID(), candidateID: id, candidateOID: oid, expectedOldOID: expectedOldOID, targetRef: candidate.targetRef,
                action: .publishIntegration, policyVersion: policyVersion, actor: actor, state: .granted, grantedAt: now, resolvedAt: nil,
                expiresAt: ttl.map { now + $0 }
            )
            try db.run(
                """
                INSERT INTO approval (id, candidate_id, candidate_oid, expected_old_oid, target_ref, action, policy_version, actor, state, granted_at,
                    expires_at)
                VALUES (?, ?, ?, ?, ?, 'publishIntegration', ?, ?, 'granted', ?, ?)
                """,
                [
                    .text(approval.id.uuidString), .text(id.uuidString), .text(oid), .text(expectedOldOID), .text(candidate.targetRef),
                    .integer(Int64(policyVersion)), .text(actor), .integer(now), .optional(approval.expiresAt),
                ]
            )
            try appendEvent(
                db, kind: .approvalResolved, projectID: candidate.projectID.uuidString, taskID: candidate.taskID?.uuidString, attemptID: nil,
                payload: Canonical.encode([
                    "approvalID": approval.id.uuidString, "action": "publishIntegration", "candidateID": id.uuidString,
                    "candidateOID": oid, "expectedOldOID": expectedOldOID, "state": "granted", "actor": actor,
                ]),
                dedupKey: nil, now: now
            )
            return approval
        }
    }

    /// Moves a candidate into `publishing` and journals the target update, in one transaction.
    /// Refuses unless the approval is granted for exactly this commit and target state, and
    /// (with `expectedVersion`) no evidence arrived since the caller checked the gate.
    public func preparePublication(candidate id: CandidateID, approval approvalID: ApprovalID, expectedVersion: Int? = nil) throws -> GitOperationID {
        let db = try connection()
        let now = currentTime()
        // An expired approval is revoked (committed) before the refusal is thrown.
        let expired: Bool = try db.transaction {
            let approval = try loadApproval(db, approvalID)
            guard approval.state == .granted, approval.isExpired(at: now) else { return false }
            try db.run("UPDATE approval SET state = 'revoked', resolved_at = ? WHERE id = ? AND state = 'granted'", [.integer(now), .text(approvalID.uuidString)])
            let candidate = try loadCandidate(db, approval.candidateID)
            try appendEvent(
                db, kind: .approvalResolved, projectID: candidate.projectID.uuidString, taskID: candidate.taskID?.uuidString, attemptID: nil,
                payload: Canonical.encode(["approvalID": approvalID.uuidString, "state": "revoked", "reason": "expired"]), dedupKey: nil, now: now
            )
            return true
        }
        if expired { throw IntegrationStoreError.approvalExpired(approvalID) }
        return try db.transaction {
            let candidate = try loadCandidate(db, id)
            if let expectedVersion, candidate.version != expectedVersion { throw IntegrationStoreError.evidenceChanged(id) }
            let approval = try loadApproval(db, approvalID)
            guard approval.state == .granted else { throw IntegrationStoreError.approvalNotUsable(approvalID, approval.state) }
            guard !approval.isExpired(at: now) else { throw IntegrationStoreError.approvalExpired(approvalID) }
            try requireAwaitingMerge(db, candidate)
            guard approval.candidateID == id, approval.candidateOID == candidate.candidateOID,
                  approval.expectedOldOID == candidate.previousTargetOID, let oid = candidate.candidateOID else {
                throw IntegrationStoreError.staleEvidence(candidate: id, oid: approval.candidateOID)
            }
            try changeCandidate(db, candidate, to: .publishing, candidateOID: nil, conflicts: nil, reason: nil, now: now)
            return try insertOperation(
                db, projectID: candidate.projectID, worktreeID: nil, kind: .updateRef, ref: candidate.targetRef,
                expectedOld: candidate.previousTargetOID, desiredNew: oid, candidateID: id, approvalID: approvalID, now: now
            )
        }
    }

    // MARK: Queries

    public func candidate(_ id: CandidateID) throws -> CandidateRecord? {
        let db = try connection()
        return try db.query("SELECT \(Self.candidateColumns) FROM candidate WHERE id = ?", [.text(id.uuidString)]) { try Self.candidate(from: $0) }.first
    }

    public func candidates(jobID: JobID) throws -> [CandidateRecord] {
        try connection().query(
            "SELECT \(Self.candidateColumns) FROM candidate WHERE job_id = ? ORDER BY created_at, id", [.text(jobID.uuidString)]
        ) { try Self.candidate(from: $0) }
    }

    public func testResults(candidate id: CandidateID) throws -> [TestResultRecord] {
        try connection().query(
            """
            SELECT id, candidate_id, candidate_oid, profile_digest, status, exit_code, changed_test_inputs_json, summary, at
            FROM test_result WHERE candidate_id = ? ORDER BY at, id
            """,
            [.text(id.uuidString)]
        ) { row in
            TestResultRecord(
                id: try parseID(row.requiredText(0)), candidateID: try parseID(row.requiredText(1)), candidateOID: try row.requiredText(2),
                profileDigest: try row.requiredText(3), status: try parseEnum(row.requiredText(4)), exitCode: row.optionalInt(5).map(Int.init),
                changedTestInputs: try Self.decode(row.requiredText(6)), summary: try row.requiredText(7), at: row.int(8)
            )
        }
    }

    public func reviews(candidate id: CandidateID) throws -> [ReviewRecord] {
        try connection().query(
            """
            SELECT id, candidate_id, candidate_oid, reviewer_attempt_id, origin, reviewer_provider, status, summary, at
            FROM review WHERE candidate_id = ? ORDER BY at, id
            """,
            [.text(id.uuidString)]
        ) { row in
            ReviewRecord(
                id: try parseID(row.requiredText(0)), candidateID: try parseID(row.requiredText(1)), candidateOID: try row.requiredText(2),
                reviewerAttemptID: try row.text(3).map(parseID), origin: try parseEnum(row.requiredText(4)),
                reviewerProvider: try row.text(5).map(parseEnum), status: try parseEnum(row.requiredText(6)),
                summary: try row.requiredText(7), at: row.int(8)
            )
        }
    }

    public func findings(candidate id: CandidateID) throws -> [FindingRecord] {
        try connection().query(
            """
            SELECT f.id, f.review_id, f.severity, f.path, f.line, f.impact, f.suggestion, f.disposition, f.reason
            FROM finding f JOIN review r ON r.id = f.review_id WHERE r.candidate_id = ? ORDER BY r.at, f.id
            """,
            [.text(id.uuidString)]
        ) { row in
            FindingRecord(
                id: try parseID(row.requiredText(0)), reviewID: try parseID(row.requiredText(1)), severity: try parseEnum(row.requiredText(2)),
                path: row.text(3), line: row.optionalInt(4).map(Int.init), impact: try row.requiredText(5),
                suggestion: try row.requiredText(6), disposition: try parseEnum(row.requiredText(7)), reason: row.text(8)
            )
        }
    }

    public func approvals(candidate id: CandidateID) throws -> [ApprovalRecord] {
        try connection().query("SELECT \(Self.approvalColumns) FROM approval WHERE candidate_id = ? ORDER BY granted_at, id", [.text(id.uuidString)]) {
            try Self.approval(from: $0)
        }
    }

    public func approval(_ id: ApprovalID) throws -> ApprovalRecord? {
        let db = try connection()
        return try db.query("SELECT \(Self.approvalColumns) FROM approval WHERE id = ?", [.text(id.uuidString)]) { try Self.approval(from: $0) }.first
    }

    // MARK: Helpers

    /// Publication applied: candidate published, approval consumed, task integrated.
    func applyPublication(_ db: SQLiteConnection, candidate id: CandidateID, approval: ApprovalID?, operation: GitOperationRecord, now: Int64) throws {
        let candidate = try loadCandidate(db, id)
        if candidate.state != .published {
            try changeCandidate(db, candidate, to: .published, candidateOID: nil, conflicts: nil, reason: nil, now: now)
        }
        if let approval {
            try db.run(
                "UPDATE approval SET state = 'consumed', resolved_at = ? WHERE id = ? AND state = 'granted'",
                [.integer(now), .text(approval.uuidString)]
            )
        }
        // Further approvals of the published candidate (a double approval) are spent with it.
        try db.run(
            "UPDATE approval SET state = 'revoked', resolved_at = ? WHERE candidate_id = ? AND state = 'granted'",
            [.integer(now), .text(id.uuidString)]
        )
        if let taskID = candidate.taskID {
            let task = try loadTask(db, taskID)
            // The target moved: that is the fact. A task the user blocked while it waited for this
            // merge is integrated as well.
            let waiting = task.record.state == .awaitingMerge || (task.record.state == .blocked && task.record.resumeState == .awaitingMerge)
            if waiting {
                try db.run(
                    "UPDATE task SET state = 'integrated', resume_state = NULL, integrated_oid = ?, version = version + 1 WHERE id = ?",
                    [.optional(operation.desiredNew), .text(taskID.uuidString)]
                )
                try appendEvent(
                    db, kind: .taskStateChanged, projectID: task.projectID, taskID: taskID.uuidString, attemptID: nil,
                    payload: Canonical.encode(StateChange(entityID: taskID.uuidString, from: task.record.state.rawValue, to: "integrated", reason: candidate.id.uuidString)),
                    dedupKey: nil, now: now
                )
            }
        }
        try appendEvent(
            db, kind: .integrationApplied, projectID: candidate.projectID.uuidString, taskID: candidate.taskID?.uuidString, attemptID: nil,
            payload: Canonical.encode([
                "candidateID": id.uuidString, "ref": operation.ref ?? "", "oldOID": operation.expectedOld ?? "",
                "newOID": operation.desiredNew ?? "", "gitOperationID": operation.id.uuidString,
            ]),
            dedupKey: nil, now: now
        )
    }

    private func changeCandidate(
        _ db: SQLiteConnection, _ candidate: CandidateRecord, to target: CandidateState, candidateOID: String?, conflicts: [String]?,
        reason: String?, now: Int64, moveTask: Bool = true, actor: String? = nil
    ) throws {
        try candidate.state.validateTransition(to: target)
        try db.run(
            """
            UPDATE candidate SET state = ?, candidate_oid = COALESCE(?, candidate_oid), conflicts_json = COALESCE(?, conflicts_json),
                version = version + 1 WHERE id = ?
            """,
            [.text(target.rawValue), .optional(candidateOID), .optional(try conflicts.map(Self.json)), .text(candidate.id.uuidString)]
        )
        if target == .rejected || target == .superseded || (candidate.state == .accepted && target == .reviewing) {
            // Approvals bind one commit and one target state: they do not outlive the candidate.
            try db.run(
                "UPDATE approval SET state = 'revoked', resolved_at = ? WHERE candidate_id = ? AND state = 'granted'",
                [.integer(now), .text(candidate.id.uuidString)]
            )
        }
        if moveTask { try followTask(db, candidate, from: candidate.state, to: target, now: now) }
        try appendEvent(
            db, kind: .candidateStateChanged, projectID: candidate.projectID.uuidString, taskID: candidate.taskID?.uuidString,
            attemptID: nil,
            payload: Canonical.encode(StateChange(
                entityID: candidate.id.uuidString, from: candidate.state.rawValue, to: target.rawValue,
                reason: try contentPurged(db, candidate) ? reason.map { _ in Self.purgedText } : reason,
                actor: actor, attemptID: actor == nil ? nil : candidate.authorAttemptID?.uuidString
            )),
            dedupKey: nil, now: now
        )
    }

    /// The user's reason for sending the task's last result back, for the next author prompt: the
    /// newest rejection by the user of a candidate built from the last succeeded author attempt,
    /// or the user's discard of that attempt (ADR 0011, rework reason). nil when there is none,
    /// when its payload or the attempt's content was forgotten, or when it is empty. Automatic
    /// rejections carry no `actor` and never count. Read in one transaction (one snapshot).
    public func reworkReason(task: TaskID) throws -> ReworkReason? {
        let db = try connection()
        return try db.transaction {
            guard let anchor = try db.query(
                """
                SELECT id, content_purged_at FROM attempt WHERE task_id = ? AND role = 'author' AND state = 'succeeded'
                ORDER BY ordinal DESC LIMIT 1
                """,
                [.text(task.uuidString)], { (id: try $0.requiredText(0), purgedAt: $0.optionalInt(1)) }
            ).first, anchor.purgedAt == nil else { return nil }
            let payload = "CAST(p.inline_content AS TEXT)"
            guard let row = try db.query(
                """
                SELECT e.kind, e.at, \(payload) FROM event e JOIN artifact p ON p.id = e.payload_id
                WHERE e.task_id = ?1 AND e.attempt_id IS NULL AND e.payload_purged_at IS NULL
                  AND json_extract(\(payload), '$.actor') IS NOT NULL
                  AND ((e.kind = 'candidate.stateChanged' AND json_extract(\(payload), '$.to') = 'rejected'
                        AND json_extract(\(payload), '$.entityID') IN (SELECT id FROM candidate WHERE author_attempt_id = ?2))
                    OR (e.kind = 'task.stateChanged' AND json_extract(\(payload), '$.to') = 'needsChanges'
                        AND json_extract(\(payload), '$.attemptID') = ?2))
                ORDER BY e.seq DESC LIMIT 1
                """,
                [.text(task.uuidString), .text(anchor.id)], { (kind: try $0.requiredText(0), at: $0.int(1), json: $0.text(2)) }
            ).first, let json = row.json else { return nil }
            struct Stored: Decodable {
                var entityID: String
                var reason: String?
            }
            let stored = try JSONDecoder().decode(Stored.self, from: Data(json.utf8))
            guard let text = stored.reason, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != Self.purgedText else {
                return nil
            }
            let source: ReworkReason.Source = row.kind == EventKind.candidateStateChanged.rawValue
                ? .rejected(try parseID(stored.entityID)) : .discarded
            return ReworkReason(source: source, attemptID: try parseID(anchor.id), text: text, at: row.at)
        }
    }

    /// The candidate's author attempt had its content forgotten: texts that arrive later about
    /// it (test and review summaries, findings, transition reasons) are not stored (ADR 0006 §7).
    func contentPurged(_ db: SQLiteConnection, _ candidate: CandidateRecord) throws -> Bool {
        guard let author = candidate.authorAttemptID else { return false }
        return try db.query("SELECT content_purged_at FROM attempt WHERE id = ?", [.text(author.uuidString)]) { $0.optionalInt(0) }.first ?? nil != nil
    }

    func releaseCandidate(_ db: SQLiteConnection, _ id: CandidateID, to target: CandidateState, now: Int64) throws {
        let candidate = try loadCandidate(db, id)
        guard candidate.state == .publishing else { return }
        try changeCandidate(db, candidate, to: target, candidateOID: nil, conflicts: nil, reason: "publication did not happen", now: now)
    }

    /// Any new evidence changes the candidate's version, so a gate check can be bound to it.
    private func bumpEvidence(_ db: SQLiteConnection, _ id: CandidateID) throws {
        try db.run("UPDATE candidate SET version = version + 1 WHERE id = ?", [.text(id.uuidString)])
    }

    func loadCandidate(_ db: SQLiteConnection, _ id: CandidateID) throws -> CandidateRecord {
        guard let candidate = try db.query("SELECT \(Self.candidateColumns) FROM candidate WHERE id = ?", [.text(id.uuidString)], {
            try Self.candidate(from: $0)
        }).first else { throw StoreError.notFound(entity: "candidate", id: id.uuidString) }
        return candidate
    }

    private func loadApproval(_ db: SQLiteConnection, _ id: ApprovalID) throws -> ApprovalRecord {
        guard let approval = try db.query("SELECT \(Self.approvalColumns) FROM approval WHERE id = ?", [.text(id.uuidString)], {
            try Self.approval(from: $0)
        }).first else { throw StoreError.notFound(entity: "approval", id: id.uuidString) }
        return approval
    }

    private static let candidateColumns = """
        id, project_id, job_id, task_id, kind, author_attempt_id, author_provider, result_oid, reverts_candidate_id,
        previous_target_oid, candidate_oid, target_ref, worktree_id, state, conflicts_json, version, created_at
        """

    private static func candidate(from row: SQLRow) throws -> CandidateRecord {
        CandidateRecord(
            id: try parseID(row.requiredText(0)), projectID: try parseID(row.requiredText(1)), jobID: try parseID(row.requiredText(2)),
            taskID: try row.text(3).map(parseID), kind: try parseEnum(row.requiredText(4)), authorAttemptID: try row.text(5).map(parseID),
            authorProvider: try row.text(6).map(parseEnum), resultOID: row.text(7), revertsCandidateID: try row.text(8).map(parseID),
            previousTargetOID: try row.requiredText(9), candidateOID: row.text(10), targetRef: try row.requiredText(11),
            worktreeID: try row.text(12).map(parseID), state: try parseEnum(row.requiredText(13)),
            conflicts: try decode(row.requiredText(14)), version: Int(row.int(15)), createdAt: row.int(16)
        )
    }

    private static let approvalColumns =
        "id, candidate_id, candidate_oid, expected_old_oid, target_ref, action, policy_version, actor, state, granted_at, resolved_at, expires_at"

    private static func approval(from row: SQLRow) throws -> ApprovalRecord {
        ApprovalRecord(
            id: try parseID(row.requiredText(0)), candidateID: try parseID(row.requiredText(1)), candidateOID: try row.requiredText(2),
            expectedOldOID: try row.requiredText(3), targetRef: try row.requiredText(4), action: try parseEnum(row.requiredText(5)),
            policyVersion: Int(row.int(6)), actor: try row.requiredText(7), state: try parseEnum(row.requiredText(8)),
            grantedAt: row.int(9), resolvedAt: row.optionalInt(10), expiresAt: row.optionalInt(11)
        )
    }

    static func json(_ values: [String]) throws -> String {
        String(decoding: try Canonical.encode(values), as: UTF8.self)
    }

    static func decode(_ text: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(text.utf8))
    }
}
