import Domain
import Foundation

/// Package F (ADR 0005): plan revisions, consent, model profiles, budgets, quota blocks,
/// readiness and the scheduler's atomic reservation.
public enum PlanningError: Error, Equatable, Sendable {
    case invalidPlan(PlanIssues)
    /// The job's accepted revision is not the one the caller expected.
    case planRevisionMoved(expected: PlanRevisionID?, actual: PlanRevisionID?)
    case revisionAlreadyAccepted(PlanRevisionID)
    /// A started task (from `running`, not ended) may only stay unchanged in a new revision.
    case startedTaskChanged(String)
    case startedTaskRemoved(String)
    /// Plan tasks become ready through their predecessors, not by command.
    case taskManagedByScheduler(TaskID)
    /// A job with a plan gets its tasks from revisions.
    case jobHasPlan(JobID)
    /// `active → done` needs every task of the current plan integrated and no open task.
    case jobNotComplete(JobID, openTasks: Int)
    case emptyResultNotAcceptable(TaskID, TaskState)
    case blockNotReleasable(QuotaBlockID)
    /// Plans of a done or cancelled job do not change.
    case jobClosed(JobID, JobState)
    /// The user's quota block or revocation stops this account.
    case accountBlocked(AccountID)
    /// A plan task's review needs a valid reviewer consent for its provider.
    case noReviewerConsent(ProviderKind)
}

extension Store {
    /// The store's clock (virtual in tests); the scheduler reads the same time.
    public func now() -> Int64 { currentTime() }

    // MARK: Plans

    /// Validates and stores a new revision of the job's plan (not yet accepted). Returns it with
    /// its difference to the accepted revision.
    @discardableResult
    public func proposePlan(
        job jobID: JobID, draft: PlanDraft, createdBy: PlanAuthor, expectedCurrent: PlanRevisionID?
    ) throws -> (PlanRevisionRecord, PlanDiff) {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            let job = try loadJob(db, jobID)
            guard !job.state.isTerminal else { throw PlanningError.jobClosed(jobID, job.state) }
            guard job.currentPlanID == expectedCurrent else {
                throw PlanningError.planRevisionMoved(expected: expectedCurrent, actual: job.currentPlanID)
            }
            let tasks = try planTasksByKey(db, job: jobID)
            let validated = try validateAgainstTasks(db, draft, tasks: tasks)

            let rev = (try db.query("SELECT COALESCE(MAX(rev), 0) + 1 FROM plan_revision WHERE job_id = ?", [.text(jobID.uuidString)]) { $0.int(0) }.first) ?? 1
            let id = PlanRevisionID()
            let estimate = try estimate(db, validated)
            try db.run(
                """
                INSERT INTO plan_revision (id, job_id, rev, created_by, digest, draft_json, estimate_json, created_at, validated_at,
                    based_on_plan_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(id.uuidString), .text(jobID.uuidString), .integer(rev), .text(createdBy.rawValue), .text(validated.digest),
                    .text(String(decoding: try Canonical.encode(draft), as: UTF8.self)),
                    .text(String(decoding: try Canonical.encode(estimate), as: UTF8.self)), .integer(now), .integer(now),
                    .optional(expectedCurrent?.uuidString),
                ]
            )
            for task in validated.tasks {
                let d = task.draft
                try db.run(
                    """
                    INSERT INTO plan_task (plan_id, key, task_id, title, goal, criteria_json, read_paths_json, write_paths_json,
                        risk, difficulty_json, tier, uncertain, test_profile)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(id.uuidString), .text(task.key), .optional(tasks[task.key]?.id.uuidString), .text(d.title), .text(d.goal),
                        .text(try Self.json(d.criteria)), .text(try Self.json(d.readPaths)), .optional(try d.writePaths.map(Self.json)),
                        .text(d.risk.rawValue), .text(String(decoding: try Canonical.encode(d.difficulty), as: UTF8.self)),
                        .text(task.tier.rawValue), .integer(task.uncertainDifficulty ? 1 : 0), .optional(d.testProfile),
                    ]
                )
            }
            for task in validated.tasks {
                for predecessor in task.predecessors.sorted() {
                    try db.run(
                        "INSERT INTO dependency (plan_id, predecessor_key, successor_key) VALUES (?, ?, ?)",
                        [.text(id.uuidString), .text(predecessor), .text(task.key)]
                    )
                }
            }
            let current = try job.currentPlanID.map { try loadPlan(db, $0) }
            let currentPlan = try current.map { try PlanValidator.validate($0.draft).get() }
            let diff = PlanDiff(from: currentPlan, to: validated)
            try appendEvent(
                db, kind: .planProposed, projectID: job.projectID.uuidString, taskID: nil, attemptID: nil,
                payload: Canonical.encode(["jobID": jobID.uuidString, "planID": id.uuidString, "rev": String(rev), "createdBy": createdBy.rawValue]),
                dedupKey: nil, now: now
            )
            return (try loadPlan(db, id), diff)
        }
    }

    /// Accepts a proposed revision: new keys get tasks in `pending`, removed tasks that have not
    /// started end `cancelled`, the previous revision is superseded, a draft job becomes `planned`.
    public func acceptPlan(_ id: PlanRevisionID, expectedCurrent: PlanRevisionID?) throws {
        let db = try connection()
        let now = currentTime()
        try db.transaction {
            let plan = try loadPlan(db, id)
            guard plan.acceptedAt == nil else { throw PlanningError.revisionAlreadyAccepted(id) }
            let job = try loadJob(db, plan.jobID)
            guard !job.state.isTerminal else { throw PlanningError.jobClosed(job.id, job.state) }
            // The revision must replace the one it was proposed (and its diff computed) against.
            let basedOn = try db.query("SELECT based_on_plan_id FROM plan_revision WHERE id = ?", [.text(id.uuidString)]) { $0.text(0) }.first ?? nil
            guard job.currentPlanID == expectedCurrent, basedOn == job.currentPlanID?.uuidString else {
                throw PlanningError.planRevisionMoved(expected: expectedCurrent, actual: job.currentPlanID)
            }
            let tasks = try planTasksByKey(db, job: plan.jobID)
            // Task states may have changed since the proposal.
            _ = try validateAgainstTasks(db, plan.draft, tasks: tasks)
            let newRows = try planTaskRows(db, plan: id)
            let oldRows = try job.currentPlanID.map { try planTaskRows(db, plan: $0) } ?? [:]
            func started(_ task: TaskRecord) -> Bool {
                !task.state.isTerminal && !(task.state == .pending || task.state == .ready)
                    && !(task.state == .blocked && (task.resumeState == .pending || task.resumeState == .ready))
            }
            for (key, task) in tasks where started(task) {
                guard let row = newRows[key] else { throw PlanningError.startedTaskRemoved(key) }
                if let old = oldRows[key], old != row { throw PlanningError.startedTaskChanged(key) }
            }
            for (key, task) in tasks where newRows[key] == nil && !task.state.isTerminal {
                try changeTaskState(db, try loadTask(db, task.id), to: .cancelled, reason: "removedInRevision", now: now)
            }
            for key in newRows.keys.sorted() where tasks[key] == nil {
                let taskID = TaskID()
                let title = newRows[key]!.title
                try db.run(
                    "INSERT INTO task (id, job_id, title, state, plan_key, version, created_at) VALUES (?, ?, ?, 'pending', ?, 1, ?)",
                    [.text(taskID.uuidString), .text(plan.jobID.uuidString), .text(title), .text(key), .integer(now)]
                )
                try appendEvent(
                    db, kind: .taskCreated, projectID: job.projectID.uuidString, taskID: taskID.uuidString, attemptID: nil,
                    payload: Canonical.encode(["jobID": plan.jobID.uuidString, "title": title, "planKey": key]), dedupKey: nil, now: now
                )
            }
            // Every row of the accepted revision names its task.
            for (key, task) in try planTasksByKey(db, job: plan.jobID) where newRows[key] != nil {
                try db.run("UPDATE plan_task SET task_id = ? WHERE plan_id = ? AND key = ?", [.text(task.id.uuidString), .text(id.uuidString), .text(key)])
            }
            if let previous = job.currentPlanID {
                try db.run("UPDATE plan_revision SET superseded_at = ? WHERE id = ?", [.integer(now), .text(previous.uuidString)])
            }
            try db.run("UPDATE plan_revision SET accepted_at = ? WHERE id = ?", [.integer(now), .text(id.uuidString)])
            try db.run("UPDATE job SET current_plan_id = ?, version = version + 1 WHERE id = ?", [.text(id.uuidString), .text(plan.jobID.uuidString)])
            if job.state == .draft {
                try db.run("UPDATE job SET state = 'planned', version = version + 1 WHERE id = ?", [.text(plan.jobID.uuidString)])
                try appendEvent(
                    db, kind: .jobStateChanged, projectID: job.projectID.uuidString, taskID: nil, attemptID: nil,
                    payload: Canonical.encode(StateChange(entityID: plan.jobID.uuidString, from: "draft", to: "planned", reason: "plan accepted")),
                    dedupKey: nil, now: now
                )
            }
            try appendEvent(
                db, kind: .planAccepted, projectID: job.projectID.uuidString, taskID: nil, attemptID: nil,
                payload: Canonical.encode(["jobID": plan.jobID.uuidString, "planID": id.uuidString, "rev": String(plan.rev)]),
                dedupKey: nil, now: now
            )
        }
    }

    /// Validates a draft against the job's tasks: an ended or reverted task can neither be
    /// depended on nor run again under its key (ADR 0005 §2).
    func validateAgainstTasks(_ db: SQLiteConnection, _ draft: PlanDraft, tasks: [String: TaskRecord]) throws -> ValidatedPlan {
        var unreachable = Set<String>()
        for (key, task) in tasks {
            let state = try satisfaction(db, task)
            if state == .ended || state == .reverted { unreachable.insert(key) }
        }
        let validated: ValidatedPlan
        switch PlanValidator.validate(draft, ended: unreachable) {
        case .success(let plan): validated = plan
        case .failure(let issues): throw PlanningError.invalidPlan(issues)
        }
        let reused = validated.tasks.map(\.key).filter { key in tasks[key].map { $0.state.isTerminal && $0.state != .integrated } ?? false }
        if !reused.isEmpty { throw PlanningError.invalidPlan(PlanIssues(reused.map { .unreachable(task: $0, predecessor: $0) })) }
        return validated
    }

    public func plan(_ id: PlanRevisionID) throws -> PlanRevisionRecord { try loadPlan(try connection(), id) }

    public func plans(job: JobID) throws -> [PlanRevisionRecord] {
        let db = try connection()
        let ids = try db.query("SELECT id FROM plan_revision WHERE job_id = ? ORDER BY rev", [.text(job.uuidString)]) { try parseID($0.requiredText(0)) as PlanRevisionID }
        return try ids.map { try loadPlan(db, $0) }
    }

    /// The validated form of a stored revision.
    public func validatedPlan(_ id: PlanRevisionID) throws -> ValidatedPlan {
        try PlanValidator.validate(try loadPlan(try connection(), id).draft).get()
    }

    // MARK: Readiness

    /// Moves pending plan tasks whose predecessors are all satisfied to `ready` and records
    /// why others wait (`predecessorEnded`, `predecessorReverted`). Returns the tasks made ready.
    @discardableResult
    public func promoteReadyTasks(job jobID: JobID) throws -> [TaskID] {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            let job = try loadJob(db, jobID)
            guard let planID = job.currentPlanID, job.state == .active || job.state == .planned else { return [] }
            let tasks = try planTasksByKey(db, job: jobID)
            let edges = try db.query(
                "SELECT predecessor_key, successor_key FROM dependency WHERE plan_id = ?", [.text(planID.uuidString)]
            ) { (try $0.requiredText(0), try $0.requiredText(1)) }
            var predecessors: [String: [String]] = [:]
            for (p, s) in edges { predecessors[s, default: []].append(p) }
            var promoted: [TaskID] = []
            for key in try planTaskRows(db, plan: planID).keys.sorted() {
                guard let task = tasks[key] else { continue }
                let heldBeforeStart = task.state == .blocked && (task.resumeState == .ready || task.resumeState == .pending)
                guard task.state == .pending || task.state == .ready || heldBeforeStart else { continue }
                var reason: WaitReason?
                for p in (predecessors[key] ?? []).sorted() {
                    guard let pred = tasks[p] else { continue }
                    switch try satisfaction(db, pred) {
                    case .satisfied: continue
                    case .open: if reason == nil { reason = WaitReason(.slot, "predecessorsOpen") }
                    case .ended: reason = WaitReason(.predecessorEnded, p)
                    case .reverted: reason = WaitReason(.predecessorReverted, p)
                    }
                    if reason?.kind == .predecessorEnded || reason?.kind == .predecessorReverted { break }
                }
                let stale = task.waitReason.flatMap(WaitReason.init(stored:)).map { $0.kind == .predecessorEnded || $0.kind == .predecessorReverted } ?? false
                if let reason, reason.detail == "predecessorsOpen" {
                    // A revision gave the task an open predecessor: it is not ready (any more).
                    if stale { try setWaitReason(db, task, nil, now: now) }
                    if task.state == .ready {
                        try changeTaskState(db, try loadTask(db, task.id), to: .pending, reason: "predecessorAdded", now: now)
                        try db.run("UPDATE task SET ready_at = NULL WHERE id = ?", [.text(task.id.uuidString)])
                    } else if heldBeforeStart, task.resumeState == .ready {
                        // The user's hold stays; it resumes before the predecessors now.
                        try db.run("UPDATE task SET resume_state = 'pending', ready_at = NULL, version = version + 1 WHERE id = ?", [.text(task.id.uuidString)])
                    }
                    continue
                }
                if heldBeforeStart {
                    if let reason { try setWaitReason(db, task, reason, now: now) }
                    continue
                }
                if let reason {
                    try setWaitReason(db, task, reason, now: now)
                    continue
                }
                if task.state == .pending {
                    try changeTaskState(db, try loadTask(db, task.id), to: .ready, reason: "predecessors integrated", now: now)
                    try db.run("UPDATE task SET ready_at = ?, wait_reason = NULL WHERE id = ?", [.integer(now), .text(task.id.uuidString)])
                    try appendEvent(
                        db, kind: .taskReady, projectID: job.projectID.uuidString, taskID: task.id.uuidString, attemptID: nil,
                        payload: Canonical.encode(["planKey": key]), dedupKey: nil, now: now
                    )
                    promoted.append(task.id)
                } else if let stored = task.waitReason, let old = WaitReason(stored: stored),
                          old.kind == .predecessorEnded || old.kind == .predecessorReverted {
                    try setWaitReason(db, task, nil, now: now)
                }
            }
            return promoted
        }
    }

    enum Satisfaction { case satisfied, open, ended, reverted }

    /// A predecessor is satisfied when it is integrated and its published change was not reverted.
    func satisfaction(_ db: SQLiteConnection, _ task: TaskRecord) throws -> Satisfaction {
        if task.state == .integrated {
            let reverted = try db.query(
                """
                SELECT 1 FROM candidate c JOIN candidate r ON r.reverts_candidate_id = c.id
                WHERE c.task_id = ? AND c.state = 'published' AND r.state = 'published' LIMIT 1
                """,
                [.text(task.id.uuidString)]
            ) { $0.int(0) }
            return reverted.isEmpty ? .satisfied : .reverted
        }
        return task.state.isTerminal ? .ended : .open
    }

    /// Records (or clears) why a ready task waits; journals only a change of the reason.
    public func setWaitReason(_ task: TaskID, _ reason: WaitReason?) throws {
        let db = try connection()
        let now = currentTime()
        try db.transaction { try setWaitReason(db, try loadTask(db, task).record, reason, now: now) }
    }

    func setWaitReason(_ db: SQLiteConnection, _ task: TaskRecord, _ reason: WaitReason?, now: Int64) throws {
        let stored = reason?.description
        guard task.waitReason != stored else { return }
        try db.run("UPDATE task SET wait_reason = ? WHERE id = ?", [.optional(stored), .text(task.id.uuidString)])
        let projectID = try loadTask(db, task.id).projectID
        try appendEvent(
            db, kind: reason == nil ? .taskReady : .taskBlocked, projectID: projectID, taskID: task.id.uuidString, attemptID: nil,
            payload: Canonical.encode(["reason": stored ?? "", "previous": task.waitReason ?? ""]), dedupKey: nil, now: now
        )
    }

    /// The job's integration state according to the store: the last applied update of its
    /// integration ref, else its base.
    public func integrationTip(job jobID: JobID) throws -> String? {
        let db = try connection()
        return try integrationTip(db, try loadJob(db, jobID))
    }

    func integrationTip(_ db: SQLiteConnection, _ job: JobRecord) throws -> String? {
        guard let ref = job.integrationRef else { return job.baseOID }
        let applied = try db.query(
            """
            SELECT desired_new FROM git_operation WHERE project_id = ? AND ref = ? AND state = 'applied'
            ORDER BY applied_at DESC, rowid DESC LIMIT 1
            """,
            [.text(job.projectID.uuidString), .text(ref)]
        ) { $0.text(0) }.first
        return (applied ?? nil) ?? job.baseOID
    }

    /// An empty or already contained result the user accepts as done (ADR 0005 §4): the task is
    /// integrated at the current integration state without a candidate.
    public func acceptEmptyResult(_ taskID: TaskID, expectedVersion: Int, integratedOID: String) throws {
        let db = try connection()
        let now = currentTime()
        try db.transaction {
            let task = try loadTask(db, taskID)
            try checkVersion(entity: "task", id: taskID.uuidString, expected: expectedVersion, actual: task.record.version)
            let open = try db.query(
                "SELECT 1 FROM candidate WHERE task_id = ? AND state NOT IN ('published', 'rejected', 'superseded')", [.text(taskID.uuidString)]
            ) { $0.int(0) }
            guard task.record.state == .resultReady, open.isEmpty else {
                throw PlanningError.emptyResultNotAcceptable(taskID, task.record.state)
            }
            try db.run("UPDATE task SET integrated_oid = ? WHERE id = ?", [.text(integratedOID), .text(taskID.uuidString)])
            try changeTaskState(db, task, to: .integrated, reason: "empty result accepted", now: now)
        }
    }

    /// Risk and named test profile of a task in its job's current plan; nil outside a plan.
    public func plannedTask(_ taskID: TaskID) throws -> (risk: PlanTaskRisk, testProfile: String?, writePaths: [String]?)? {
        let db = try connection()
        let task = try loadTask(db, taskID).record
        guard let key = task.planKey, let plan = try loadJob(db, task.jobID).currentPlanID,
              let row = try planTaskRows(db, plan: plan)[key] else { return nil }
        return (try parseEnum(row.risk), row.testProfile, try row.writePaths.map { try Self.decode($0) })
    }

    // MARK: Accounts, consent, profiles, budgets

    @discardableResult
    public func registerAccount(provider: ProviderKind, identity: String) throws -> AccountID {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            if let existing = try db.query(
                "SELECT id FROM provider_account WHERE provider = ? AND opaque_identity = ?", [.text(provider.rawValue), .text(identity)]
            ) { try parseID($0.requiredText(0)) as AccountID }.first { return existing }
            let id = AccountID()
            try db.run(
                "INSERT INTO provider_account (id, provider, opaque_identity, created_at) VALUES (?, ?, ?, ?)",
                [.text(id.uuidString), .text(provider.rawValue), .text(identity), .integer(now)]
            )
            return id
        }
    }

    @discardableResult
    public func grantConsent(_ draft: ConsentDraft) throws -> ConsentRecord {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            try requireExists(db, table: "project", id: draft.projectID.uuidString)
            let account = try db.query("SELECT provider FROM provider_account WHERE id = ?", [.text(draft.accountID.uuidString)]) { try $0.requiredText(0) }.first
            guard account == draft.provider.rawValue else { throw StoreError.notFound(entity: "account", id: draft.accountID.uuidString) }
            let id = ConsentID()
            let digest = try draft.scopeDigest()
            try db.run(
                """
                INSERT INTO consent (id, project_id, job_id, provider, account_id, mode, roles_json, write_roots_json,
                    sensitive_roots_json, unconfirmed_attempt_limit, scope_digest, granted_at, expires_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(id.uuidString), .text(draft.projectID.uuidString), .optional(draft.jobID?.uuidString), .text(draft.provider.rawValue),
                    .text(draft.accountID.uuidString), .text(draft.mode.rawValue), .text(try Self.json(draft.roles.map(\.rawValue))),
                    .text(try Self.json(draft.writeRoots)), .text(try Self.json(draft.sensitiveRoots)),
                    .optional(draft.unconfirmedAttemptLimit), .text(digest), .integer(now), .optional(draft.expiresAt),
                ]
            )
            try appendEvent(
                db, kind: .policyDecided, projectID: draft.projectID.uuidString, taskID: nil, attemptID: nil,
                payload: Canonical.encode(["consentID": id.uuidString, "action": "granted", "scopeDigest": digest]), dedupKey: nil, now: now
            )
            return try loadConsent(db, id)
        }
    }

    /// Revokes a consent: no new reservation under it from now on. `reason` names why (for
    /// example `restored` after a backup restore); nil for the user's own revocation.
    public func revokeConsent(_ id: ConsentID, reason: String? = nil) throws {
        let db = try connection()
        let now = currentTime()
        try db.transaction { try revokeConsent(db, id, reason: reason, now: now) }
    }

    func revokeConsent(_ db: SQLiteConnection, _ id: ConsentID, reason: String?, now: Int64) throws {
        let consent = try loadConsent(db, id)
        guard consent.revokedAt == nil else { return }
        try db.run("UPDATE consent SET revoked_at = ? WHERE id = ?", [.integer(now), .text(id.uuidString)])
        try appendEvent(
            db, kind: .policyDecided, projectID: consent.draft.projectID.uuidString, taskID: nil, attemptID: nil,
            payload: Canonical.encode(["consentID": id.uuidString, "action": "revoked", "reason": reason ?? "user"]), dedupKey: nil, now: now
        )
    }

    /// Revokes every open consent in one transaction (after restoring a backup: nothing granted
    /// then counts now).
    public func revokeAllConsents(reason: String) throws {
        let db = try connection()
        let now = currentTime()
        try db.transaction {
            let ids = try db.query("SELECT id FROM consent WHERE revoked_at IS NULL ORDER BY granted_at, id") { try parseID($0.requiredText(0)) as ConsentID }
            for id in ids { try revokeConsent(db, id, reason: reason, now: now) }
        }
    }

    public func consents(project: ProjectID) throws -> [ConsentRecord] {
        let db = try connection()
        let ids = try db.query("SELECT id FROM consent WHERE project_id = ? ORDER BY granted_at, id", [.text(project.uuidString)]) { try parseID($0.requiredText(0)) as ConsentID }
        return try ids.map { try loadConsent(db, $0) }
    }

    /// Records a model profile. `verifiedAt` outside tests comes only from package A.
    public func registerModelProfile(_ profile: ModelProfile) throws {
        let db = try connection()
        try db.run(
            """
            INSERT INTO model_profile (id, provider, role, tier, model, effort, context_limit, typical_tokens, observed_duration_ms,
                verified_at, disabled_reason, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(profile.id.uuidString), .text(profile.provider.rawValue), .text(profile.role.rawValue), .text(profile.tier.rawValue),
                .text(profile.model), .optional(profile.effort), .optional(profile.contextLimit), .optional(profile.typicalTokens),
                .optional(profile.observedDurationMs), .optional(profile.verifiedAt), .optional(profile.disabledReason), .integer(currentTime()),
            ]
        )
    }

    public func modelProfiles() throws -> [ModelProfile] { try modelProfiles(try connection()) }

    func modelProfiles(_ db: SQLiteConnection) throws -> [ModelProfile] {
        try db.query(
            """
            SELECT id, provider, role, tier, model, effort, context_limit, typical_tokens, observed_duration_ms, verified_at, disabled_reason
            FROM model_profile ORDER BY created_at, id
            """
        ) { row in
            ModelProfile(
                id: try parseID(row.requiredText(0)), provider: try parseEnum(row.requiredText(1)), role: try parseEnum(row.requiredText(2)),
                tier: try parseEnum(row.requiredText(3)), model: try row.requiredText(4), effort: row.text(5),
                contextLimit: row.optionalInt(6).map(Int.init), typicalTokens: row.optionalInt(7).map(Int.init),
                observedDurationMs: row.optionalInt(8), verifiedAt: row.optionalInt(9), disabledReason: row.text(10)
            )
        }
    }

    @discardableResult
    public func createBudget(account: AccountID, job: JobID, tokenLimit: Int) throws -> BudgetBucketID {
        let db = try connection()
        let id = BudgetBucketID()
        try db.run(
            "INSERT INTO budget_bucket (id, account_id, job_id, token_limit, created_at) VALUES (?, ?, ?, ?, ?)",
            [.text(id.uuidString), .text(account.uuidString), .text(job.uuidString), .integer(Int64(tokenLimit)), .integer(currentTime())]
        )
        return id
    }

    /// Tokens of the (account, job) bucket not yet reserved or spent; nil without a bucket.
    public func budgetRemaining(account: AccountID, job: JobID) throws -> Int? {
        try budgetRemaining(try connection(), account: account, job: job)?.remaining
    }

    func budgetRemaining(_ db: SQLiteConnection, account: AccountID, job: JobID) throws -> (bucket: String, remaining: Int)? {
        guard let bucket = try db.query(
            "SELECT id, token_limit FROM budget_bucket WHERE account_id = ? AND job_id = ?", [.text(account.uuidString), .text(job.uuidString)]
        ) { (try $0.requiredText(0), Int($0.int(1))) }.first else { return nil }
        let used = try db.query(
            """
            SELECT COALESCE(SUM(CASE state WHEN 'settled' THEN settled_tokens WHEN 'released' THEN 0 ELSE reserved_tokens END), 0)
            FROM reservation WHERE bucket_id = ?
            """,
            [.text(bucket.0)]
        ) { Int($0.int(0)) }.first ?? 0
        return (bucket.0, bucket.1 - used)
    }

    /// The user settles an `unresolved` reservation (usage never reported): with the tokens they
    /// name, or released when nil.
    public func resolveReservation(attempt: AttemptID, settledTokens: Int?) throws {
        let db = try connection()
        let now = currentTime()
        try db.transaction {
            let state = try db.query("SELECT state FROM reservation WHERE attempt_id = ?", [.text(attempt.uuidString)]) { try $0.requiredText(0) }.first
            guard state == "unresolved" else { return }
            if let tokens = settledTokens {
                try db.run(
                    "UPDATE reservation SET state = 'settled', settled_tokens = ?, settled_at = ? WHERE attempt_id = ?",
                    [.integer(Int64(tokens)), .integer(now), .text(attempt.uuidString)]
                )
            } else {
                try db.run("UPDATE reservation SET state = 'released', settled_at = ? WHERE attempt_id = ?", [.integer(now), .text(attempt.uuidString)])
            }
        }
    }

    public func reservation(attempt: AttemptID) throws -> (reserved: Int, settled: Int?, state: String)? {
        try connection().query(
            "SELECT reserved_tokens, settled_tokens, state FROM reservation WHERE attempt_id = ?", [.text(attempt.uuidString)]
        ) { (Int($0.int(0)), $0.optionalInt(1).map(Int.init), try $0.requiredText(2)) }.first
    }

    // MARK: Quota

    /// Blocks an account (user or adapter). Duration: `until` if given, otherwise the latest
    /// known reset of an exhausted window, otherwise 60 s doubling per consecutive block, at
    /// most 15 minutes. Revocation and plan stop block until released.
    @discardableResult
    public func blockAccount(_ account: AccountID, reason: String, until: Int64? = nil, retryAfterMs: Int64? = nil) throws -> QuotaBlockRecord {
        let db = try connection()
        let now = currentTime()
        return try db.transaction { try blockAccount(db, account, reason: reason, until: until, retryAfterMs: retryAfterMs, now: now) }
    }

    static let blockFallbackMs: Int64 = 60_000
    static let blockMaxMs: Int64 = 15 * 60_000

    func blockAccount(
        _ db: SQLiteConnection, _ account: AccountID, reason: String, until: Int64?, retryAfterMs: Int64?, now: Int64, journal: Bool = true
    ) throws -> QuotaBlockRecord {
        let previous = try db.query(
            "SELECT sequence, released_at, until FROM quota_block WHERE account_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
            [.text(account.uuidString)]
        ) { (Int($0.int(0)), $0.optionalInt(1), $0.optionalInt(2)) }.first
        // Consecutive: the previous block is still active or ended less than the maximum ago.
        let consecutive = previous.map { $0.1 == nil || now - ($0.1 ?? now) <= Self.blockMaxMs } ?? false
        let sequence = consecutive ? (previous!.0 + 1) : 1
        var end: Int64?
        var source: String
        if let until {
            (end, source) = (until, "given")
        } else if reason == "revoked" || reason == "planStop" || reason == "manual" {
            (end, source) = (nil, "open")
        } else if let retryAfterMs {
            (end, source) = (now + retryAfterMs, "retryAfter")
        } else if let reset = try db.query(
            """
            SELECT MAX(reset_at) FROM quota_observation o
            WHERE account_id = ? AND reset_at > ? AND observed_at = (
                SELECT MAX(observed_at) FROM quota_observation WHERE account_id = o.account_id AND window_key = o.window_key AND unit = o.unit)
            AND ((unit = 'percent' AND observed_used >= 100) OR (observed_limit IS NOT NULL AND observed_used >= observed_limit))
            """,
            [.text(account.uuidString), .integer(now)]
        ) { $0.optionalInt(0) }.first ?? nil {
            (end, source) = (reset, "reset")
        } else {
            (end, source) = (now + min(Self.blockMaxMs, Self.blockFallbackMs << Int64(min(sequence - 1, 10))), "fallback")
        }
        // An open block that lasts at least as long stays (no end counts as the latest end).
        if let open = try openBlockID(db, account) {
            let current = try loadBlock(db, open)
            if current.until == nil || (end != nil && current.until! >= end!) { return current }
            try db.run("UPDATE quota_block SET released_at = ?, released_by = 'expiry' WHERE id = ?", [.integer(now), .text(open.uuidString)])
            try journalQuota(db, account, kind: .quotaReleased, ["blockID": open.uuidString, "releasedBy": "replaced"], now: now)
        }
        let id = QuotaBlockID()
        try db.run(
            "INSERT INTO quota_block (id, account_id, reason, until, sequence, created_at, end_source) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [.text(id.uuidString), .text(account.uuidString), .text(reason), .optional(end), .integer(Int64(sequence)), .integer(now), .text(source)]
        )
        if journal {
            try journalQuota(
                db, account, kind: .quotaBlocked,
                ["blockID": id.uuidString, "reason": reason, "until": end.map(String.init) ?? "", "sequence": String(sequence), "endSource": source],
                now: now
            )
        }
        try recordDecision(
            db, projectID: nil, jobID: nil, taskID: nil, attemptID: nil, account: account, rule: "quotaBlock",
            evidence: ["reason": reason, "until": end.map(String.init) ?? "release", "sequence": String(sequence), "endSource": source],
            outcome: "blocked", actor: "scheduler", remaining: nil, alternative: nil, now: now
        )
        return try loadBlock(db, id)
    }

    func openBlockID(_ db: SQLiteConnection, _ account: AccountID) throws -> QuotaBlockID? {
        try db.query(
            "SELECT id FROM quota_block WHERE account_id = ? AND released_at IS NULL ORDER BY created_at DESC, rowid DESC LIMIT 1", [.text(account.uuidString)]
        ) { try parseID($0.requiredText(0)) as QuotaBlockID }.first
    }

    /// Whether the account has a block not released yet, expired or not: an expired block is
    /// lifted only after the scheduler's access check (ADR 0005 §10).
    func hasOpenBlock(_ db: SQLiteConnection, _ account: AccountID) throws -> Bool { try openBlockID(db, account) != nil }

    /// `quota.blocked` / `quota.released` in the project of the account's latest consent.
    func journalQuota(_ db: SQLiteConnection, _ account: AccountID, kind: EventKind, _ payload: [String: String], now: Int64) throws {
        guard let project = try db.query(
            "SELECT project_id FROM consent WHERE account_id = ? ORDER BY granted_at DESC LIMIT 1", [.text(account.uuidString)]
        ) { $0.text(0) }.first ?? nil else { return }
        var body = payload
        body["accountID"] = account.uuidString
        try appendEvent(db, kind: kind, projectID: project, taskID: nil, attemptID: nil, payload: Canonical.encode(body), dedupKey: nil, now: now)
    }

    /// The account's open block. With `releasingExpired`, an expired one is released first (only
    /// after the scheduler's access check).
    public func activeBlock(_ account: AccountID, releasingExpired: Bool = false) throws -> QuotaBlockRecord? {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            guard let id = try openBlockID(db, account) else { return nil }
            let block = try loadBlock(db, id)
            guard releasingExpired, let until = block.until, until <= now else { return block }
            try db.run("UPDATE quota_block SET released_at = ?, released_by = 'expiry' WHERE id = ?", [.integer(now), .text(id.uuidString)])
            try journalQuota(db, account, kind: .quotaReleased, ["blockID": id.uuidString, "releasedBy": "expiry"], now: now)
            try recordDecision(
                db, projectID: nil, jobID: nil, taskID: nil, attemptID: nil, account: account, rule: "quotaBlock",
                evidence: ["blockID": id.uuidString], outcome: "released", actor: "scheduler", remaining: nil, alternative: nil, now: now
            )
            return nil
        }
    }

    /// The user lifts a block once when no reset is known (fallback or open end), or a manual
    /// block at any time. A block with a known reset or Retry-After expires by itself.
    public func releaseBlock(_ id: QuotaBlockID) throws {
        let db = try connection()
        let now = currentTime()
        try db.transaction {
            let block = try loadBlock(db, id)
            guard block.releasedAt == nil else { return }
            let source = try db.query("SELECT end_source FROM quota_block WHERE id = ?", [.text(id.uuidString)]) { $0.text(0) }.first ?? nil
            // Once per run of consecutive blocks: an earlier user release within the run forbids another.
            let earlierUserRelease = try !db.query(
                "SELECT 1 FROM quota_block WHERE account_id = ? AND released_by = 'user' AND released_at >= ? LIMIT 1",
                [.text(block.accountID.uuidString), .integer(block.createdAt - Self.blockMaxMs * Int64(block.sequence))]
            ) { $0.int(0) }.isEmpty
            let releasable = block.reason == "manual" || ((source == "fallback" || source == "open") && !earlierUserRelease)
            guard releasable else { throw PlanningError.blockNotReleasable(id) }
            try db.run("UPDATE quota_block SET released_at = ?, released_by = 'user' WHERE id = ?", [.integer(now), .text(id.uuidString)])
            try journalQuota(db, block.accountID, kind: .quotaReleased, ["blockID": id.uuidString, "releasedBy": "user"], now: now)
            try recordDecision(
                db, projectID: nil, jobID: nil, taskID: nil, attemptID: nil, account: block.accountID, rule: "quotaBlock",
                evidence: ["blockID": id.uuidString], outcome: "released", actor: "user", remaining: nil, alternative: nil, now: now
            )
        }
    }

    /// Blocks not released yet (expired ones included: the scheduler checks access first).
    public func openBlocks() throws -> [QuotaBlockRecord] {
        let db = try connection()
        let ids = try db.query("SELECT id FROM quota_block WHERE released_at IS NULL ORDER BY created_at, id") { try parseID($0.requiredText(0)) as QuotaBlockID }
        return try ids.map { try loadBlock(db, $0) }
    }

    /// Future resets of windows at or above `percent`: the scheduler wakes at them.
    public func quotaResets(atLeast percent: Int) throws -> [Int64] {
        let db = try connection()
        let now = currentTime()
        return try db.query(
            """
            SELECT reset_at FROM quota_observation o WHERE reset_at > ? AND observed_at = (
                SELECT MAX(observed_at) FROM quota_observation WHERE account_id = o.account_id AND window_key = o.window_key AND unit = o.unit)
            AND ((unit = 'percent' AND observed_used >= ?) OR (observed_limit > 0 AND observed_used * 100 >= observed_limit * ?))
            """,
            [.integer(now), .integer(Int64(percent)), .integer(Int64(percent))]
        ) { $0.int(0) }
    }

    /// Open attempts under a revoked consent, or of an account one of whose consents was revoked
    /// after they were reserved (ADR 0005 §7: running attempts of the account stop).
    public func attemptsUnderRevokedConsent() throws -> [AttemptID] {
        try connection().query(
            """
            SELECT a.id FROM attempt a
            WHERE a.state IN ('reserved', 'starting', 'running', 'awaitingApproval')
            AND (EXISTS (SELECT 1 FROM consent c WHERE c.id = a.consent_id AND c.revoked_at IS NOT NULL)
                OR EXISTS (SELECT 1 FROM consent c WHERE c.account_id = a.account_id AND c.revoked_at >= a.reserved_at))
            ORDER BY a.reserved_at, a.id
            """
        ) { try parseID($0.requiredText(0)) as AttemptID }
    }

    public func provider(of account: AccountID) throws -> ProviderKind? {
        try connection().query("SELECT provider FROM provider_account WHERE id = ?", [.text(account.uuidString)]) { try parseEnum($0.requiredText(0)) as ProviderKind }.first
    }

    public func recordQuotaObservation(_ account: AccountID, _ signal: QuotaSignal, source: String) throws {
        let db = try connection()
        let now = currentTime()
        try db.transaction { try recordQuotaObservation(db, account, signal, source: source, now: now) }
    }

    func recordQuotaObservation(_ db: SQLiteConnection, _ account: AccountID, _ signal: QuotaSignal, source: String, now: Int64) throws {
        try db.run(
            """
            INSERT INTO quota_observation (id, account_id, window_key, unit, observed_limit, observed_used, reset_at, observed_at, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(UUID().uuidString.lowercased()), .text(account.uuidString), .text(signal.windowKey), .text(signal.unit.rawValue),
                .optional(signal.limit), .optional(signal.used), .optional(signal.resetAt), .integer(now), .text(source),
            ]
        )
    }

    /// Highest used percentage over the latest observation of each window; nil if none known.
    func quotaUsedPercent(_ db: SQLiteConnection, _ account: AccountID, now: Int64) throws -> Int? {
        // A window whose reset has passed no longer limits (its next value is unknown until reported).
        let rows = try db.query(
            """
            SELECT unit, observed_used, observed_limit FROM quota_observation o
            WHERE account_id = ? AND (reset_at IS NULL OR reset_at > ?) AND observed_at = (
                SELECT MAX(observed_at) FROM quota_observation WHERE account_id = o.account_id AND window_key = o.window_key AND unit = o.unit)
            """,
            [.text(account.uuidString), .integer(now)]
        ) { (try $0.requiredText(0), $0.optionalInt(1).map(Int.init), $0.optionalInt(2).map(Int.init)) }
        let shares = rows.compactMap { row -> Int? in
            QuotaSignal(windowKey: "", unit: QuotaUnit(rawValue: row.0) ?? .percent, used: row.1, limit: row.2, resetAt: nil).usedPercent
        }
        return shares.max()
    }

    // MARK: Scheduled reservation

    /// Reserves an author attempt for a scheduled plan task in one transaction: the task must
    /// still be ready in the expected revision with satisfied predecessors, and consent, quota,
    /// slots, write area and budget must allow it. Otherwise the wait reason is recorded.
    public func reserveScheduled(_ r: ScheduledReservation, limits: SchedulerLimits, recordWait: Bool = true) throws -> ScheduledOutcome {
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            let loaded = try loadTask(db, r.taskID)
            let task = loaded.record
            guard task.state == .ready, let key = task.planKey else { return .skipped }
            let job = try loadJob(db, task.jobID)
            guard job.state == .active, job.currentPlanID == r.planID else { return .skipped }
            let activeAuthor = try db.query(
                "SELECT 1 FROM attempt WHERE task_id = ? AND role = 'author' AND state NOT IN ('succeeded', 'failed', 'cancelled')",
                [.text(task.id.uuidString)]
            ) { $0.int(0) }
            guard activeAuthor.isEmpty else { return .skipped }
            func wait(_ reason: WaitReason) throws -> ScheduledOutcome {
                if recordWait { try setWaitReason(db, task, reason, now: now) }
                return .waiting(reason)
            }
            // Predecessors may have been reverted since the task became ready.
            let edges = try db.query(
                "SELECT predecessor_key FROM dependency WHERE plan_id = ? AND successor_key = ?", [.text(r.planID.uuidString), .text(key)]
            ) { try $0.requiredText(0) }
            let byKey = try planTasksByKey(db, job: job.id)
            for p in edges.sorted() {
                guard let pred = byKey[p] else { continue }
                switch try satisfaction(db, pred) {
                case .satisfied: continue
                case .reverted: return try wait(WaitReason(.predecessorReverted, p))
                case .ended: return try wait(WaitReason(.predecessorEnded, p))
                case .open: return .skipped
                }
            }
            guard let row = try planTaskRows(db, plan: r.planID)[key] else { return .skipped }
            let area = try WriteArea.resolve(try row.writePaths.map { try Self.decode($0) })

            // Consent.
            let consent = try loadConsent(db, r.consentID)
            let d = consent.draft
            guard consent.isValid(at: now), d.projectID.uuidString == loaded.projectID, d.jobID == nil || d.jobID == job.id,
                  d.provider == r.profile.provider, d.roles.contains(.author) else { return try wait(WaitReason(.consent, "notValid")) }
            let roots = row.risk == PlanTaskRisk.sensitive.rawValue ? d.sensitiveRoots : d.writeRoots
            guard area.isCovered(by: roots) else { return try wait(WaitReason(.consent, row.risk == "sensitive" ? "sensitiveArea" : "writeArea")) }
            let account = d.accountID

            // Quota.
            if try hasOpenBlock(db, account) { return try wait(WaitReason(.quota, "blocked")) }
            let accountActive = try activeAttemptCount(db, account: account)
            if let used = try quotaUsedPercent(db, account, now: now) {
                if used >= 100 { return try wait(WaitReason(.quota, "exhausted")) }
                if used >= limits.warnPercent, accountActive > 0 { return try wait(WaitReason(.quota, "nearLimit")) }
            } else {
                let limit = d.unconfirmedAttemptLimit ?? 0
                // Attempts that reached the provider, or may still do so; not those that failed before a turn.
                let spent = try db.query(
                    "SELECT COUNT(*) FROM attempt WHERE consent_id = ? AND (started_at IS NOT NULL OR state NOT IN ('succeeded', 'failed', 'cancelled', 'uncertain'))",
                    [.text(consent.id.uuidString)]
                ) { Int($0.int(0)) }.first ?? 0
                if spent >= limit { return try wait(WaitReason(.quota, "unknownQuotaLimit")) }
            }

            // Slots.
            let globalActive = try activeAttemptCount(db, account: nil)
            if globalActive >= limits.global { return try wait(WaitReason(.slot, "global")) }
            if accountActive >= limits.perAccount { return try wait(WaitReason(.slot, "account")) }
            if globalActive == limits.global - 1, try reviewWaiting(db, project: loaded.projectID) {
                return try wait(WaitReason(.slot, "reviewReserved"))
            }

            // Write area against tasks of the same job that hold one.
            for other in try areaHolders(db, job: job.id) where other.id != task.id {
                let otherArea: WriteArea
                if let otherKey = other.planKey, let otherRow = try planTaskRows(db, plan: r.planID)[otherKey] {
                    otherArea = try WriteArea.resolve(try otherRow.writePaths.map { try Self.decode($0) })
                } else {
                    // Host tasks (reverts) and tasks outside the plan: unknown area.
                    otherArea = .wholeProject
                }
                if area.overlaps(otherArea) { return try wait(WaitReason(.writeArea, other.planKey ?? other.id.uuidString)) }
            }

            // Budget.
            guard let budget = try budgetRemaining(db, account: account, job: job.id) else { return try wait(WaitReason(.budget, "noBucket")) }
            if budget.remaining < r.reservedTokens { return try wait(WaitReason(.budget, "insufficient")) }
            if let reviewAccount = r.reviewAccountID, let tokens = r.reviewTokens,
               let reviewBudget = try budgetRemaining(db, account: reviewAccount, job: job.id), reviewBudget.remaining < tokens {
                return try wait(WaitReason(.budget, "reviewReserve"))
            }

            // Reserve.
            let base = try integrationTip(db, job)
            let ordinal = try db.query(
                "SELECT COALESCE(MAX(ordinal), 0) + 1 FROM attempt WHERE task_id = ? AND role = 'author'", [.text(task.id.uuidString)]
            ) { $0.int(0) }.first ?? 1
            try db.run(
                """
                INSERT INTO attempt (id, task_id, role, ordinal, provider, mode, model, effort, state, spec_digest, reserved_at, version,
                    base_oid, account_id, model_profile_id, plan_id, tier, consent_id)
                VALUES (?, ?, 'author', ?, ?, ?, ?, ?, 'reserved', ?, ?, 1, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(r.attemptID.uuidString), .text(task.id.uuidString), .integer(ordinal), .text(r.profile.provider.rawValue),
                    .text(d.mode.rawValue), .text(r.profile.model), .optional(r.profile.effort), .text(r.specDigest), .integer(now),
                    .optional(base), .text(account.uuidString), .text(r.profile.id.uuidString), .text(r.planID.uuidString),
                    .text(r.tier.rawValue), .text(consent.id.uuidString),
                ]
            )
            try db.run(
                """
                INSERT INTO reservation (id, attempt_id, bucket_id, reserved_tokens, size_uncertain, state, created_at)
                VALUES (?, ?, ?, ?, ?, 'held', ?)
                """,
                [
                    .text(UUID().uuidString.lowercased()), .text(r.attemptID.uuidString), .text(budget.bucket),
                    .integer(Int64(r.reservedTokens)), .integer(r.sizeUncertain ? 1 : 0), .integer(now),
                ]
            )
            try appendEvent(
                db, kind: .attemptReserved, projectID: loaded.projectID, taskID: task.id.uuidString, attemptID: r.attemptID.uuidString,
                payload: Canonical.encode(r), dedupKey: nil, now: now
            )
            try db.run("UPDATE task SET current_attempt_id = ?, wait_reason = NULL WHERE id = ?", [.text(r.attemptID.uuidString), .text(task.id.uuidString)])
            try changeTaskState(db, loaded, to: .running, reason: "attempt \(r.attemptID) scheduled", now: now)
            var evidence = r.decision.evidence
            evidence["provider"] = r.profile.provider.rawValue
            evidence["model"] = r.profile.model
            evidence["reservedTokens"] = String(r.reservedTokens)
            if r.sizeUncertain { evidence["sizeUncertain"] = "true" }
            try recordDecision(
                db, projectID: loaded.projectID, jobID: job.id, taskID: task.id, attemptID: r.attemptID, account: account,
                rule: r.decision.rule, evidence: evidence, outcome: "reserved:\(r.tier.rawValue)", actor: r.actor,
                remaining: r.decision.remainingAttempts, alternative: nil, now: now
            )
            return .reserved(r.attemptID)
        }
    }

    /// Active attempts holding a slot (of one account, or all), as the scheduler counts them;
    /// for the review sheet's slot pre-check (ADR 0011 §8).
    public func activeAttemptCount(account: AccountID?) throws -> Int {
        try activeAttemptCount(try connection(), account: account)
    }

    /// Active attempts holding a slot (of one account, or all). An `uncertain` attempt left
    /// from a restart has no process and frees its slot (ADR 0005 §6).
    func activeAttemptCount(_ db: SQLiteConnection, account: AccountID?) throws -> Int {
        let filter = account == nil ? "" : "AND account_id = ?"
        return try db.query(
            """
            SELECT COUNT(*) FROM attempt
            WHERE (state IN ('reserved', 'starting', 'running', 'awaitingApproval', 'cancelling')
                OR (state = 'uncertain' AND process_lost = 0 AND COALESCE(error_class, '') <> 'processLostOnRestart')) \(filter)
            """,
            account.map { [.text($0.uuidString)] } ?? []
        ) { Int($0.int(0)) }.first ?? 0
    }

    /// A candidate of the project waits for its review: reviewing, its task in verification (not
    /// held by the user), no readable review of its commit yet and no open reviewer attempt.
    func reviewWaiting(_ db: SQLiteConnection, project: String) throws -> Bool {
        !(try db.query(
            """
            SELECT 1 FROM candidate c JOIN task t ON t.id = c.task_id WHERE c.project_id = ? AND c.state = 'reviewing'
            AND t.state = 'verifying'
            AND NOT EXISTS (SELECT 1 FROM review r WHERE r.candidate_id = c.id AND r.candidate_oid = c.candidate_oid AND r.status <> 'invalid')
            AND NOT EXISTS (SELECT 1 FROM attempt a WHERE a.task_id = c.task_id AND a.role = 'reviewer'
                AND a.state NOT IN ('succeeded', 'failed', 'cancelled'))
            LIMIT 1
            """,
            [.text(project)]
        ) { $0.int(0) }.isEmpty)
    }

    /// Tasks of the job that hold their write area (ADR 0005 §6).
    func areaHolders(_ db: SQLiteConnection, job: JobID) throws -> [TaskRecord] {
        let ids = try db.query(
            """
            SELECT t.id FROM task t WHERE t.job_id = ? AND (
                t.state IN ('running', 'resultReady', 'verifying', 'awaitingMerge', 'conflict')
                OR (t.state = 'blocked' AND t.resume_state IN ('running', 'resultReady', 'verifying', 'awaitingMerge', 'conflict'))
                OR EXISTS (SELECT 1 FROM attempt a WHERE a.task_id = t.id AND a.role = 'author'
                    AND a.state NOT IN ('succeeded', 'failed', 'cancelled')))
            """,
            [.text(job.uuidString)]
        ) { try parseID($0.requiredText(0)) as TaskID }
        return try ids.map { try loadTask(db, $0).record }
    }

    // MARK: Budget settlement

    /// Settles the attempt's reservation when it reaches a terminal state: with the reported
    /// usage, released if it never started, otherwise `unresolved`.
    func settleReservation(_ db: SQLiteConnection, attempt: AttemptRecord, terminal: AttemptState, now: Int64) throws {
        guard try !db.query("SELECT 1 FROM reservation WHERE attempt_id = ? AND state IN ('held', 'unresolved')", [.text(attempt.id.uuidString)]) { $0.int(0) }.isEmpty else { return }
        if attempt.startedAt == nil && attempt.state != .uncertain {
            try db.run("UPDATE reservation SET state = 'released', settled_at = ? WHERE attempt_id = ?", [.integer(now), .text(attempt.id.uuidString)])
            return
        }
        if let used = try reportedUsage(db, attempt.id) {
            try db.run(
                "UPDATE reservation SET state = 'settled', settled_tokens = ?, settled_at = ? WHERE attempt_id = ?",
                [.integer(Int64(used)), .integer(now), .text(attempt.id.uuidString)]
            )
        } else {
            try db.run("UPDATE reservation SET state = 'unresolved', settled_at = ? WHERE attempt_id = ?", [.integer(now), .text(attempt.id.uuidString)])
        }
    }

    /// Input plus output tokens from the attempt's usage events: the last running total plus
    /// deltas reported after it. Nil if nothing was reported.
    func reportedUsage(_ db: SQLiteConnection, _ attempt: AttemptID) throws -> Int? {
        let payloads = try db.query(
            """
            SELECT a.inline_content FROM event e JOIN artifact a ON a.id = e.payload_id
            WHERE e.attempt_id = ? AND e.kind = ? ORDER BY e.ordinal
            """,
            [.text(attempt.uuidString), .text(EventKind.usageObserved.rawValue)]
        ) { $0.blob(0) }
        var total: Int?
        for data in payloads.compactMap({ $0 }) {
            guard case .usage(let sample) = try? JSONDecoder().decode(AgentEvent.self, from: data) else { continue }
            let tokens = (sample.inputTokens ?? 0) + (sample.outputTokens ?? 0)
            total = sample.cumulative ? tokens : (total ?? 0) + tokens
        }
        return total
    }

    // MARK: Decisions

    @discardableResult
    func recordDecision(
        _ db: SQLiteConnection, projectID: String?, jobID: JobID?, taskID: TaskID?, attemptID: AttemptID?, account: AccountID?,
        rule: String, evidence: [String: String], outcome: String, actor: String, remaining: Int?, alternative: String?, now: Int64
    ) throws -> DecisionID {
        var project = projectID
        if project == nil, let taskID { project = try loadTask(db, taskID).projectID }
        if project == nil, let account {
            project = try db.query("SELECT project_id FROM consent WHERE account_id = ? ORDER BY granted_at DESC LIMIT 1", [.text(account.uuidString)]) { $0.text(0) }.first ?? nil
        }
        let id = DecisionID()
        guard let project else { return id }
        try db.run(
            """
            INSERT INTO decision (id, project_id, job_id, task_id, attempt_id, account_id, rule_version, rule, evidence_json, outcome, actor,
                remaining_attempts, alternative, at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(id.uuidString), .text(project), .optional(jobID?.uuidString), .optional(taskID?.uuidString), .optional(attemptID?.uuidString),
                .optional(account?.uuidString), .integer(Int64(Router.ruleVersion)), .text(rule),
                .text(String(decoding: try Canonical.encode(evidence), as: UTF8.self)), .text(outcome), .text(actor),
                .optional(remaining), .optional(alternative), .integer(now),
            ]
        )
        try appendEvent(
            db, kind: .policyDecided, projectID: project, taskID: taskID?.uuidString, attemptID: attemptID?.uuidString,
            payload: Canonical.encode(["decisionID": id.uuidString, "rule": rule, "outcome": outcome, "actor": actor]), dedupKey: nil, now: now
        )
        return id
    }

    /// Records a scheduler or user decision that reserved nothing (for the timeline).
    public func recordDecision(task: TaskID, rule: String, evidence: [String: String], outcome: String, actor: String, remaining: Int?, alternative: String? = nil) throws {
        let db = try connection()
        let now = currentTime()
        try db.transaction {
            let loaded = try loadTask(db, task)
            try recordDecision(
                db, projectID: loaded.projectID, jobID: loaded.record.jobID, taskID: task, attemptID: nil, account: nil, rule: rule,
                evidence: evidence, outcome: outcome, actor: actor, remaining: remaining, alternative: alternative, now: now
            )
        }
    }

    public func decisions(task: TaskID) throws -> [DecisionRecord] {
        try connection().query(
            """
            SELECT id, task_id, attempt_id, account_id, rule, rule_version, evidence_json, outcome, actor, remaining_attempts, alternative, at
            FROM decision WHERE task_id = ? ORDER BY at, rowid
            """,
            [.text(task.uuidString)]
        ) { row in
            DecisionRecord(
                id: try parseID(row.requiredText(0)), taskID: try row.text(1).map(parseID), attemptID: try row.text(2).map(parseID),
                accountID: try row.text(3).map(parseID), rule: try row.requiredText(4), ruleVersion: Int(row.int(5)),
                evidence: try JSONDecoder().decode([String: String].self, from: Data(row.requiredText(6).utf8)),
                outcome: try row.requiredText(7), actor: try row.requiredText(8), remainingAttempts: row.optionalInt(9).map(Int.init),
                alternative: row.text(10), at: row.int(11)
            )
        }
    }

    // MARK: Loading

    func loadPlan(_ db: SQLiteConnection, _ id: PlanRevisionID) throws -> PlanRevisionRecord {
        guard let plan = try db.query(
            """
            SELECT id, job_id, rev, created_by, digest, draft_json, estimate_json, created_at, accepted_at, superseded_at
            FROM plan_revision WHERE id = ?
            """,
            [.text(id.uuidString)], { row in
                PlanRevisionRecord(
                    id: try parseID(row.requiredText(0)), jobID: try parseID(row.requiredText(1)), rev: Int(row.int(2)),
                    createdBy: try parseEnum(row.requiredText(3)), digest: try row.requiredText(4),
                    draft: try JSONDecoder().decode(PlanDraft.self, from: Data(row.requiredText(5).utf8)),
                    estimate: try JSONDecoder().decode(PlanEstimate.self, from: Data(row.requiredText(6).utf8)),
                    createdAt: row.int(7), acceptedAt: row.optionalInt(8), supersededAt: row.optionalInt(9)
                )
            }
        ).first else { throw StoreError.notFound(entity: "plan revision", id: id.uuidString) }
        return plan
    }

    struct PlanTaskRow: Equatable {
        var title, goal, criteria, readPaths: String
        var writePaths: String?
        var risk, difficulty, tier: String
        var testProfile: String?
    }

    func planTaskRows(_ db: SQLiteConnection, plan: PlanRevisionID) throws -> [String: PlanTaskRow] {
        let rows = try db.query(
            """
            SELECT key, title, goal, criteria_json, read_paths_json, write_paths_json, risk, difficulty_json, tier, test_profile
            FROM plan_task WHERE plan_id = ?
            """,
            [.text(plan.uuidString)]
        ) { row in
            (try row.requiredText(0), PlanTaskRow(
                title: try row.requiredText(1), goal: try row.requiredText(2), criteria: try row.requiredText(3), readPaths: try row.requiredText(4),
                writePaths: row.text(5), risk: try row.requiredText(6), difficulty: try row.requiredText(7), tier: try row.requiredText(8),
                testProfile: row.text(9)
            ))
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    /// The job's plan tasks by key.
    func planTasksByKey(_ db: SQLiteConnection, job: JobID) throws -> [String: TaskRecord] {
        let ids = try db.query(
            "SELECT id FROM task WHERE job_id = ? AND plan_key IS NOT NULL", [.text(job.uuidString)]
        ) { try parseID($0.requiredText(0)) as TaskID }
        var result: [String: TaskRecord] = [:]
        for id in ids {
            let task = try loadTask(db, id).record
            if let key = task.planKey { result[key] = task }
        }
        return result
    }

    func loadConsent(_ db: SQLiteConnection, _ id: ConsentID) throws -> ConsentRecord {
        guard let consent = try db.query(
            """
            SELECT id, project_id, job_id, provider, account_id, mode, roles_json, write_roots_json, sensitive_roots_json,
                unconfirmed_attempt_limit, scope_digest, granted_at, expires_at, revoked_at
            FROM consent WHERE id = ?
            """,
            [.text(id.uuidString)], { row in
                ConsentRecord(
                    id: try parseID(row.requiredText(0)),
                    draft: ConsentDraft(
                        projectID: try parseID(row.requiredText(1)), jobID: try row.text(2).map(parseID), provider: try parseEnum(row.requiredText(3)),
                        accountID: try parseID(row.requiredText(4)), mode: try parseEnum(row.requiredText(5)),
                        roles: try Self.decode(row.requiredText(6)).map { try parseEnum($0) as AttemptRole },
                        writeRoots: try Self.decode(row.requiredText(7)), sensitiveRoots: try Self.decode(row.requiredText(8)),
                        unconfirmedAttemptLimit: row.optionalInt(9).map(Int.init), expiresAt: row.optionalInt(12)
                    ),
                    scopeDigest: try row.requiredText(10), grantedAt: row.int(11), revokedAt: row.optionalInt(13)
                )
            }
        ).first else { throw StoreError.notFound(entity: "consent", id: id.uuidString) }
        return consent
    }

    func loadBlock(_ db: SQLiteConnection, _ id: QuotaBlockID) throws -> QuotaBlockRecord {
        guard let block = try db.query(
            "SELECT id, account_id, reason, until, sequence, created_at, released_at, released_by FROM quota_block WHERE id = ?",
            [.text(id.uuidString)], { row in
                QuotaBlockRecord(
                    id: try parseID(row.requiredText(0)), accountID: try parseID(row.requiredText(1)), reason: try row.requiredText(2),
                    until: row.optionalInt(3), sequence: Int(row.int(4)), createdAt: row.int(5), releasedAt: row.optionalInt(6),
                    releasedBy: row.text(7)
                )
            }
        ).first else { throw StoreError.notFound(entity: "quota block", id: id.uuidString) }
        return block
    }

    /// Expected effort: tasks per tier and the typical tokens of the smallest usable author
    /// profile at each task's tier (any provider).
    func estimate(_ db: SQLiteConnection, _ plan: ValidatedPlan) throws -> PlanEstimate {
        let profiles = try modelProfiles(db).filter { $0.isUsable && $0.role == .author }
        var estimate = PlanEstimate()
        for task in plan.tasks {
            estimate.tasksPerTier[task.tier.rawValue, default: 0] += 1
            if task.uncertainDifficulty { estimate.uncertainTasks.append(task.key) }
            let candidates = profiles.filter { $0.tier >= task.tier }.sorted { $0.tier < $1.tier }
            if let tokens = candidates.first?.typicalTokens { estimate.expectedTokens += tokens } else { estimate.unknownTasks.append(task.key) }
        }
        return estimate
    }
}
