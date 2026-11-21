import Domain
import Foundation
import Orchestration
import Storage

/// Fixtures for UI tests (`-KAIORXUITest`, temporary database and repository) and the Workbench
/// tests. Never used by the normal app: it records an author result without any provider run.
public enum UITestSeed {
    /// An author result as a finished run leaves it: the attempt succeeded, the task is
    /// `resultReady`, `writes` (path → content) lie in its worktree, nothing is sealed yet. With
    /// `planTask` the job gets a plan with that task and the attempt is reserved through the
    /// store's scheduled reservation, so it carries its plan revision (the write area comes from
    /// there, ADR 0011 §4); the seed's own consent is revoked again before returning.
    public static func authorResult(
        services: AppServices, project: ProjectID, title: String, writes: [String: String], planTask: PlanTaskDraft? = nil,
        baseRevision: String = "HEAD"
    ) async throws -> (job: JobID, task: TaskID, attempt: AttemptID, worktree: WorktreeID) {
        guard let workspace = services.workspace else { throw ActionError.unavailable("Git") }
        let store = services.store
        let job = JobID()
        try await store.execute(Command(.createJob(id: job, projectID: project, goal: title)))
        if let planTask {
            let (plan, _) = try await store.proposePlan(job: job, draft: PlanDraft(tasks: [planTask]), createdBy: .user, expectedCurrent: nil)
            try await store.acceptPlan(plan.id, expectedCurrent: nil)
        } else {
            try await store.execute(Command(.transitionJob(id: job, to: .planned, expectedVersion: 1, reason: nil)))
        }
        guard let record = try await store.jobs().first(where: { $0.id == job }) else { throw ActionError.unknown("job") }
        try await store.execute(Command(.transitionJob(id: job, to: .active, expectedVersion: record.version, reason: nil)))
        _ = try await workspace.openIntegration(job, baseRevision: baseRevision)
        guard let tip = try await store.integrationTip(job: job) else { throw ActionError.unknown("integration") }
        var consent: ConsentID?
        let task: TaskID, attempt: AttemptID
        if let planTask {
            (task, attempt, consent) = try await reservePlanned(services: services, project: project, job: job, key: planTask.key)
        } else {
            (task, attempt) = try await reserveUnplanned(services: services, project: project, job: job, title: title)
        }
        let tree = try await finishRun(services: services, project: project, attempt: attempt, base: tip, writes: writes)
        // Nothing else may start under the seed's consent; the run it covered has ended.
        if let consent { try await store.revokeConsent(consent, reason: "uitest-seed") }
        return (job, task, attempt, tree)
    }

    /// A job with one task whose recorded author result (a new file) is built into a candidate
    /// on the job's integration target. Returns the job, the task and the built candidate.
    public static func builtCandidate(
        services: AppServices, project: ProjectID, title: String, baseRevision: String = "HEAD"
    ) async throws -> (job: JobID, task: TaskID, candidate: CandidateRecord) {
        guard let workspace = services.workspace, let integration = services.integration else { throw ActionError.unavailable("Git") }
        let seeded = try await authorResult(
            services: services, project: project, title: title, writes: ["LEERWERT.md": "Leerwert: nil\n"], baseRevision: baseRevision
        )
        _ = try await workspace.seal(seeded.worktree, allowedPrefixes: nil, message: title)
        guard case .built(let candidate) = try await integration.buildCandidate(from: seeded.worktree) else { throw ActionError.unknown("candidate") }
        return (seeded.job, seeded.task, candidate)
    }

    /// A sealed plan-task result with one change inside its write area (`docs/`) and one outside
    /// (`NOTIZ.md`): the seal dropped the outside path, so building needs the user's confirmation.
    public static func undeclared(
        services: AppServices, project: ProjectID, title: String
    ) async throws -> (job: JobID, task: TaskID, worktree: WorktreeID) {
        guard let workspace = services.workspace else { throw ActionError.unavailable("Git") }
        let planTask = PlanTaskDraft(key: "doku", title: title, criteria: ["Die Dokumentation nennt den Leerwert."], writePaths: ["docs/"])
        let seeded = try await authorResult(
            services: services, project: project, title: title,
            writes: ["docs/LEERWERT.md": "Leerwert: nil\n", "NOTIZ.md": "außerhalb des Schreibbereichs\n"], planTask: planTask
        )
        _ = try await workspace.seal(seeded.worktree, allowedPrefixes: planTask.writePaths, message: title)
        return (seeded.job, seeded.task, seeded.worktree)
    }

    /// A sealed result of a run that changed nothing.
    public static func empty(services: AppServices, project: ProjectID, title: String) async throws -> (job: JobID, task: TaskID, worktree: WorktreeID) {
        guard let workspace = services.workspace else { throw ActionError.unavailable("Git") }
        let seeded = try await authorResult(services: services, project: project, title: title, writes: [:])
        _ = try await workspace.seal(seeded.worktree, allowedPrefixes: nil, message: title)
        return (seeded.job, seeded.task, seeded.worktree)
    }

    /// A conflicted candidate: a first task's result (`KONFLIKT.md`, one content) is the job's
    /// integration base and accepted as already contained; a second task's result, from the
    /// commit before, adds the same file with another content. Nothing is published.
    public static func conflicted(
        services: AppServices, project: ProjectID, title: String, baseRevision: String = "HEAD"
    ) async throws -> (job: JobID, task: TaskID, candidate: CandidateRecord) {
        guard let workspace = services.workspace, let integration = services.integration, let git = services.git else {
            throw ActionError.unavailable("Git")
        }
        let store = services.store
        let base = try await git.resolveCommit(baseRevision, in: try await workspace.attach(project))
        let job = JobID()
        try await store.execute(Command(.createJob(id: job, projectID: project, goal: title)))
        try await store.execute(Command(.transitionJob(id: job, to: .planned, expectedVersion: 1, reason: nil)))
        try await store.execute(Command(.transitionJob(id: job, to: .active, expectedVersion: 2, reason: nil)))
        // The first result exists before the job's integration, which then starts at it.
        let (first, firstAttempt) = try await reserveUnplanned(services: services, project: project, job: job, title: "\(title) (Integrationsstand)")
        let firstTree = try await finishRun(
            services: services, project: project, attempt: firstAttempt, base: base, writes: ["KONFLIKT.md": "Stand der Integration\n"]
        )
        _ = try await workspace.seal(firstTree, allowedPrefixes: nil, message: "\(title) (Integrationsstand)")
        guard let firstResult = try await workspace.worktree(firstTree).resultOID else { throw ActionError.unknown("result") }
        _ = try await workspace.openIntegration(job, baseRevision: firstResult)
        try await integration.acceptEmptyResult(first)
        let (task, attempt) = try await reserveUnplanned(services: services, project: project, job: job, title: title)
        let tree = try await finishRun(services: services, project: project, attempt: attempt, base: base, writes: ["KONFLIKT.md": "Stand des Ergebnisses\n"])
        _ = try await workspace.seal(tree, allowedPrefixes: nil, message: title)
        guard case .conflicted(let candidate, _) = try await integration.buildCandidate(from: tree) else { throw ActionError.unknown("conflict") }
        return (job, task, candidate)
    }

    // MARK: Steps

    /// A task outside any plan, ready, with a reserved fake author attempt.
    static func reserveUnplanned(services: AppServices, project: ProjectID, job: JobID, title: String) async throws -> (TaskID, AttemptID) {
        let store = services.store
        let task = TaskID(), attempt = AttemptID()
        try await store.execute(Command(.createTask(id: task, jobID: job, title: title)))
        try await store.execute(Command(.transitionTask(id: task, to: .ready, expectedVersion: 1)))
        try await store.execute(Command(.reserveAttempt(AttemptReservation(
            attemptID: attempt, taskID: task, projectID: project, role: .author, provider: .fake, mode: .automatic, model: "fake-seed",
            specDigest: "uitest-seed"
        ))))
        return (task, attempt)
    }

    /// The plan task `key`, made ready and reserved like the scheduler does (plan revision,
    /// consent, profile, budget), under a job-scoped consent of the local fake account that
    /// `authorResult` revokes once the run is recorded.
    static func reservePlanned(
        services: AppServices, project: ProjectID, job: JobID, key: String
    ) async throws -> (TaskID, AttemptID, ConsentID) {
        let store = services.store
        try await store.promoteReadyTasks(job: job)
        guard let task = try await store.tasks(jobID: job).first(where: { $0.planKey == key }),
              let planID = try await store.jobs().first(where: { $0.id == job })?.currentPlanID else { throw ActionError.unknown("plan task") }
        // The app's own local account (`WorkbenchActions.grantConsent`): a task keeps its account
        // (ADR 0005 §8), so a later consent of the user picks a discarded seed task up again.
        let account = try await store.registerAccount(provider: .fake, identity: "local")
        let consent = try await store.grantConsent(ConsentDraft(
            projectID: project, jobID: job, provider: .fake, accountID: account, roles: [.author], writeRoots: [""], sensitiveRoots: [""],
            unconfirmedAttemptLimit: 1
        ))
        let profile: ModelProfile
        if let existing = try await store.modelProfiles().first(where: {
            $0.provider == .fake && $0.role == .author && $0.tier == .fast && $0.model == "fake-seed" && $0.isUsable
        }) {
            profile = existing
        } else {
            profile = ModelProfile(provider: .fake, role: .author, tier: .fast, model: "fake-seed", verifiedAt: 1)
            try await store.registerModelProfile(profile)
        }
        if try await store.budgetRemaining(account: account, job: job) == nil {
            try await store.createBudget(account: account, job: job, tokenLimit: 1_000_000)
        }
        let attempt = AttemptID()
        let outcome = try await store.reserveScheduled(ScheduledReservation(
            attemptID: attempt, taskID: task.id, planID: planID, consentID: consent.id, profile: profile, tier: .fast, specDigest: "uitest-seed",
            reservedTokens: 1, sizeUncertain: false, decision: Router.nextTier(planned: .fast, history: []), actor: "uitest-seed"
        ), limits: SchedulerLimits(global: 1_000, perAccount: 1_000))
        guard outcome == .reserved(attempt) else { throw ActionError.unknown("reservation: \(outcome)") }
        return (task.id, attempt, consent.id)
    }

    /// Prepares the author worktree at `base`, writes `writes` into it and records the run as
    /// started and succeeded (the task becomes `resultReady`). Returns the worktree.
    static func finishRun(
        services: AppServices, project: ProjectID, attempt: AttemptID, base: String, writes: [String: String]
    ) async throws -> WorktreeID {
        guard let workspace = services.workspace else { throw ActionError.unavailable("Git") }
        let store = services.store
        let tree = try await workspace.prepareWorktree(projectID: project, attemptID: attempt, kind: .author, base: base)
        let root = workspace.path(of: tree)
        for (path, content) in writes.sorted(by: { $0.key < $1.key }) {
            let file = URL(filePath: root).appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        guard let version = try await store.attempt(attempt)?.version else { throw ActionError.unknown("attempt") }
        try await store.execute(Command(.transitionAttempt(id: attempt, to: .starting, expectedVersion: version, errorClass: nil)))
        _ = try await store.ingest(.started(sessionID: "uitest-seed"), attemptID: attempt)
        _ = try await store.ingest(.completed(.succeeded), attemptID: attempt)
        return tree.id
    }
}
