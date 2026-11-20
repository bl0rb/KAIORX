import Domain
import Foundation
import Providers
import Storage

/// Decides whether a provider may run without an explicit user start, and checks access after
/// a quota block without inference (ADR 0005 §7, §10).
public protocol CapabilityGate: Sendable {
    func allowsAutomatic(_ provider: ProviderKind) async -> Bool
    /// A non-inference access check (probe) after a block expired.
    func accessRestored(_ provider: ProviderKind, account: AccountID) async -> Bool
}

/// Production gate: automatic runs only for providers with a `liveVerified` version (ADR 0003).
public struct CompatibilityGate: CapabilityGate {
    public init() {}

    public func allowsAutomatic(_ provider: ProviderKind) async -> Bool {
        CompatibilityMatrix.entries.contains { $0.provider == provider && $0.status == .liveVerified }
    }

    public func accessRestored(_ provider: ProviderKind, account: AccountID) async -> Bool { true }
}

public struct TickReport: Sendable, Equatable {
    public var promoted: [TaskID] = []
    public var reserved: [AttemptID] = []
    public var waiting: [TaskID: WaitReason] = [:]
    /// Tasks ready to run that need an explicit user start (no automatic permission).
    public var awaitingUserStart: [TaskID] = []
    /// Attempts cancelled because their consent was revoked.
    public var cancelledForRevocation: [AttemptID] = []
    /// Earliest time something waiting can change by itself (block end, retry time).
    public var nextWakeAt: Int64?

    mutating func wake(at time: Int64) { nextWakeAt = min(nextWakeAt ?? time, time) }
}

public enum SchedulerError: Error, Equatable, Sendable {
    case notAPlanTask(TaskID)
    case noIntegration(JobID)
}

/// Package F scheduler (ADR 0005). Never sleeps: `tick()` reserves what may run now and says when
/// to call it again. Store and scheduler read the same clock, so tests run in virtual time.
public actor Scheduler {
    private let store: Store
    private let coordinator: RunCoordinator
    private let workspace: WorkspaceService
    private let gate: any CapabilityGate
    private let limits: SchedulerLimits
    /// Reservation size when the profile has no typical token count (marked uncertain).
    public static let defaultReservationTokens = 50_000

    public init(store: Store, coordinator: RunCoordinator, workspace: WorkspaceService, gate: any CapabilityGate, limits: SchedulerLimits = SchedulerLimits()) {
        self.store = store
        self.coordinator = coordinator
        self.workspace = workspace
        self.gate = gate
        self.limits = limits
    }

    // MARK: Tick

    public func tick() async throws -> TickReport {
        var report = TickReport()
        // Revocation: stop running work of the revoked consent at once.
        for attempt in try await store.attemptsUnderRevokedConsent() {
            try await coordinator.cancel(attempt, reason: "consentRevoked")
            report.cancelledForRevocation.append(attempt)
        }
        try await checkExpiredBlocks(&report)

        let jobs = try await store.jobs().filter { $0.state == .active && $0.currentPlanID != nil }
        var candidates: [Candidate] = []
        for job in jobs {
            report.promoted += try await store.promoteReadyTasks(job: job.id)
            guard let planID = job.currentPlanID, try await store.integrationTip(job: job.id) != nil, job.integrationRef != nil else { continue }
            let plan = try await store.validatedPlan(planID)
            let tasks = try await store.tasks(jobID: job.id).filter { $0.planKey != nil }
            let finished = Set(tasks.filter { $0.state == .integrated }.compactMap(\.planKey))
            let lengths = plan.remainingPathLengths(finished: finished)
            for task in tasks where task.state == .ready || task.state == .needsChanges {
                guard let key = task.planKey, let planned = plan.task(key) else { continue }
                candidates.append(Candidate(task: task, job: job, planID: planID, planned: planned, pathLength: lengths[key] ?? 1))
            }
        }
        let lastReservation = try await lastReservationPerProject()
        candidates.sort { a, b in
            if a.pathLength != b.pathLength { return a.pathLength > b.pathLength }
            let ra = a.task.readyAt ?? .max, rb = b.task.readyAt ?? .max
            if ra != rb { return ra < rb }
            let pa = lastReservation[a.job.projectID] ?? .min, pb = lastReservation[b.job.projectID] ?? .min
            if pa != pb { return pa < pb }
            return (a.task.planKey ?? "") < (b.task.planKey ?? "")
        }
        for candidate in candidates {
            try await schedule(candidate, actor: "scheduler", report: &report)
        }
        for block in try await store.openBlocks() { if let until = block.until { report.wake(at: until) } }
        return report
    }

    /// An explicit user start of a ready plan task: the same reservation, without the
    /// automatic-permission gate.
    public func start(_ taskID: TaskID, actor: String) async throws -> TickReport {
        guard let task = try await store.task(taskID), let key = task.planKey,
              let job = try await store.jobs().first(where: { $0.id == task.jobID }), let planID = job.currentPlanID else {
            throw SchedulerError.notAPlanTask(taskID)
        }
        guard try await store.integrationTip(job: job.id) != nil, job.integrationRef != nil else { throw SchedulerError.noIntegration(job.id) }
        _ = try await store.promoteReadyTasks(job: job.id)
        guard let refreshed = try await store.task(taskID), let planned = try await store.validatedPlan(planID).task(key) else {
            throw SchedulerError.notAPlanTask(taskID)
        }
        var report = TickReport()
        try await schedule(Candidate(task: refreshed, job: job, planID: planID, planned: planned, pathLength: 1), actor: actor, report: &report)
        return report
    }

    // MARK: One task

    struct Candidate {
        var task: TaskRecord
        var job: JobRecord
        var planID: PlanRevisionID
        var planned: PlannedTask
        var pathLength: Int
    }

    private func schedule(_ c: Candidate, actor: String, report: inout TickReport) async throws {
        var task = c.task
        let attempts = try await store.attempts(taskID: task.id).filter { $0.role == .author }
        if attempts.contains(where: { !$0.state.isTerminal }) { return }
        let history = try await countedHistory(task, attempts, planned: c.planned)
        let decision = Router.nextTier(planned: c.planned.tier, history: history)

        if case .userDecision(let reason) = decision.outcome {
            try await wait(task, WaitReason(.userDecision, reason), decision: decision, report: &report)
            return
        }
        // Technical start failures since the last counted attempt: at most two retries, spaced.
        let technical = Array(attempts.reversed().prefix { Self.isTechnicalStartFailure($0) })
        if !technical.isEmpty {
            if technical.count > StartRetry.maxRetries {
                try await wait(task, WaitReason(.userDecision, "startRetries"), decision: decision, report: &report)
                return
            }
            let retryAt = (technical.first?.endedAt ?? 0) + StartRetry.delayMs(task: task.id, retry: technical.count - 1)
            if await store.now() < retryAt {
                try await wait(task, WaitReason(.retryLater, String(retryAt)), decision: nil, report: &report)
                report.wake(at: retryAt)
                return
            }
        }
        if task.state == .needsChanges {
            // A repair or escalation: the scheduler brings the task back to its author.
            guard !history.isEmpty else { return }
            try await store.execute(Command(.transitionTask(id: task.id, to: .ready, expectedVersion: task.version)))
            guard let ready = try await store.task(task.id) else { return }
            task = ready
        }
        guard let tier = decision.outcome.tier else { return }

        // Provider: a task with author attempts keeps its provider; no rotation.
        let now = await store.now()
        let consents = try await store.consents(project: c.job.projectID)
            .filter { $0.isValid(at: now) && ($0.draft.jobID == nil || $0.draft.jobID == c.job.id) }
        let profiles = try await store.modelProfiles()
        let fixedProvider = attempts.first?.provider
        var options: [(ConsentRecord, ModelProfile)] = []
        for consent in consents where consent.draft.roles.contains(.author) && (fixedProvider == nil || consent.draft.provider == fixedProvider) {
            if let profile = ModelProfile.smallest(profiles, provider: consent.draft.provider, role: .author, atLeast: tier) {
                options.append((consent, profile))
            }
        }
        guard !options.isEmpty else {
            let anyConsent = consents.contains { $0.draft.roles.contains(.author) && (fixedProvider == nil || $0.draft.provider == fixedProvider) }
            try await wait(task, WaitReason(anyConsent ? .profileMissing : .consent, anyConsent ? tier.rawValue : "none"), decision: decision, report: &report)
            return
        }
        var firstWait: WaitReason?
        for (consent, profile) in options {
            // An independent reviewer must be possible before the author starts.
            guard let reviewer = consents.first(where: { $0.draft.roles.contains(.reviewer) && $0.draft.provider != profile.provider }) else {
                firstWait = firstWait ?? WaitReason(.noIndependentReviewer)
                continue
            }
            if actor == "scheduler", !(await gate.allowsAutomatic(profile.provider)) {
                firstWait = firstWait ?? WaitReason(.awaitingUserStart, profile.provider.rawValue)
                continue
            }
            let reviewProfile = ModelProfile.smallest(profiles, provider: reviewer.draft.provider, role: .reviewer, atLeast: .fast)
            let spec = makeSpec(c, task: task, profile: profile, decision: decision, failure: history.isEmpty ? nil : try await lastFailureReport(task))
            let reservation = ScheduledReservation(
                attemptID: spec.attemptID, taskID: task.id, planID: c.planID, consentID: consent.id, profile: profile, tier: profile.tier,
                specDigest: try spec.digest(), reservedTokens: profile.typicalTokens ?? Self.defaultReservationTokens,
                sizeUncertain: profile.typicalTokens == nil, reviewAccountID: reviewer.draft.accountID,
                reviewTokens: reviewProfile?.typicalTokens, decision: decision, actor: actor
            )
            switch try await store.reserveScheduled(reservation, limits: limits, recordWait: false) {
            case .skipped:
                return
            case .waiting(let reason):
                firstWait = firstWait ?? reason
                continue
            case .reserved(let attempt):
                report.reserved.append(attempt)
                try await launch(attempt, spec: spec, job: c.job)
                return
            }
        }
        if let firstWait {
            if firstWait.kind == .awaitingUserStart {
                report.awaitingUserStart.append(task.id)
                try await wait(task, firstWait, decision: decision, report: &report)
            } else {
                try await wait(task, firstWait, decision: nil, report: &report)
            }
        }
    }

    /// Prepares the attempt's worktree at its recorded base and starts it. A failure before the
    /// turn cancels the reservation; the task returns to `ready` for a spaced retry.
    private func launch(_ attempt: AttemptID, spec: AttemptSpec, job: JobRecord) async throws {
        guard let record = try await store.attempt(attempt), let base = record.baseOID else { return }
        let tree: WorktreeRecord
        do {
            tree = try await workspace.prepareWorktree(projectID: job.projectID, attemptID: attempt, kind: .author, base: base)
        } catch {
            try await failBeforeTurn(attempt, errorClass: "worktreeFailed")
            return
        }
        var spec = spec
        spec.workingDirectory = await workspace.path(of: tree)
        _ = try await coordinator.launch(attempt, spec: spec)
    }

    private func failBeforeTurn(_ attempt: AttemptID, errorClass: String) async throws {
        for _ in 0..<5 {
            guard let record = try await store.attempt(attempt), record.state == .reserved else { return }
            do {
                try await store.execute(Command(.transitionAttempt(id: attempt, to: .failed, expectedVersion: record.version, errorClass: errorClass)))
                return
            } catch let error as StoreError where error.isVersionConflict { continue }
        }
    }

    private func wait(_ task: TaskRecord, _ reason: WaitReason, decision: TierDecision?, report: inout TickReport) async throws {
        report.waiting[task.id] = reason
        let changed = task.waitReason != reason.description
        try await store.setWaitReason(task.id, reason)
        if changed, let decision, reason.kind == .userDecision || reason.kind == .awaitingUserStart {
            try await store.recordDecision(
                task: task.id, rule: decision.rule, evidence: decision.evidence, outcome: reason.description, actor: "scheduler",
                remaining: decision.remainingAttempts
            )
        }
    }

    // MARK: History

    static let technicalStartFailures: Set<String> = ["startFailed", "adapterUnavailable", "worktreeFailed"]

    static func isTechnicalStartFailure(_ attempt: AttemptRecord) -> Bool {
        attempt.state == .failed && attempt.startedAt == nil && technicalStartFailures.contains(attempt.errorClass ?? "")
    }

    /// Author attempts that reached a turn and failed on the substance (ADR 0005 §8), oldest first.
    func countedHistory(_ task: TaskRecord, _ attempts: [AttemptRecord], planned: PlannedTask) async throws -> [CountedAttempt] {
        guard let job = try await store.jobs().first(where: { $0.id == task.jobID }) else { return [] }
        let candidates = try await store.candidates(jobID: job.id)
        var result: [CountedAttempt] = []
        for attempt in attempts.sorted(by: { $0.ordinal < $1.ordinal }) where attempt.startedAt != nil && attempt.state.isTerminal {
            let tier = attempt.tier ?? planned.tier
            if attempt.state == .failed, attempt.errorClass == "providerFailed" {
                let reason = try await failureReason(attempt.id)
                result.append(CountedAttempt(tier: tier, failure: .providerFailed(fingerprint: FailureFingerprint.of(reason))))
                continue
            }
            guard attempt.state == .succeeded else { continue }
            for candidate in candidates where candidate.authorAttemptID == attempt.id && candidate.state == .rejected {
                let tests = try await store.testResults(candidate: candidate.id)
                if let red = tests.last(where: { [.failed, .crashed, .inputsModified].contains($0.status) }) {
                    result.append(CountedAttempt(tier: tier, failure: .redTest(fingerprint: FailureFingerprint.of(red.summary))))
                    break
                }
                if try await store.findings(candidate: candidate.id).contains(where: { $0.severity == .blocking }) {
                    result.append(CountedAttempt(tier: tier, failure: .blockingFinding))
                    break
                }
            }
        }
        return result
    }

    private func failureReason(_ attempt: AttemptID) async throws -> String {
        for event in try await store.events(attempt: attempt, kind: .attemptCompleted).reversed() {
            if let data = event.payload, case .completed(.failed(let reason))? = try? JSONDecoder().decode(AgentEvent.self, from: data) {
                return reason
            }
        }
        return "providerFailed"
    }

    /// The report of the last counted failure, for a repair prompt.
    private func lastFailureReport(_ task: TaskRecord) async throws -> String? {
        let attempts = try await store.attempts(taskID: task.id).filter { $0.role == .author && $0.startedAt != nil }.sorted { $0.ordinal < $1.ordinal }
        guard let last = attempts.last else { return nil }
        if last.state == .failed, last.errorClass == "providerFailed" { return try await failureReason(last.id) }
        let candidates = try await store.candidates(jobID: task.jobID).filter { $0.authorAttemptID == last.id }
        for candidate in candidates.reversed() {
            if let red = try await store.testResults(candidate: candidate.id).last(where: { $0.status != .passed }) { return "Test: \(red.summary)" }
            let blocking = try await store.findings(candidate: candidate.id).filter { $0.severity == .blocking }
            if !blocking.isEmpty {
                return blocking.map { "Blocking finding \($0.path ?? "?"):\($0.line.map(String.init) ?? "?"): \($0.impact) – \($0.suggestion)" }.joined(separator: "\n")
            }
        }
        return nil
    }

    private func makeSpec(_ c: Candidate, task: TaskRecord, profile: ModelProfile, decision: TierDecision, failure: String?) -> AttemptSpec {
        let d = c.planned.draft
        var lines = ["Task: \(d.title)", "Goal: \(d.goal)", "Acceptance criteria:"] + d.criteria.map { "- \($0)" }
        if let writes = d.writePaths { lines.append("You may change only: \(writes.joined(separator: ", "))") }
        if case .repair = decision.outcome { lines.append("This is a repair attempt after a failed check.") }
        if let failure { lines.append("Report of the last failed check:\n\(failure)") }
        if case .escalate = decision.outcome { lines.append("Earlier attempts failed the same way; this attempt runs on a stronger profile.") }
        return AttemptSpec(
            attemptID: AttemptID(), taskID: task.id, projectID: c.job.projectID, role: .author, provider: profile.provider,
            runMode: .automatic, modelProfile: profile.id.uuidString, effectiveModel: profile.model, effort: profile.effort,
            writablePaths: d.writePaths, prompt: lines.joined(separator: "\n")
        )
    }

    // MARK: Quota and ordering

    /// Blocks whose end has passed: access is checked without inference before the block is
    /// lifted; a failed check blocks again (doubling).
    private func checkExpiredBlocks(_ report: inout TickReport) async throws {
        let now = await store.now()
        for block in try await store.openBlocks() {
            guard let until = block.until, until <= now else { continue }
            guard let provider = try await store.provider(of: block.accountID) else { continue }
            if await gate.accessRestored(provider, account: block.accountID) {
                _ = try await store.activeBlock(block.accountID)
            } else {
                let renewed = try await store.blockAccount(block.accountID, reason: block.reason)
                if let end = renewed.until { report.wake(at: end) }
            }
        }
    }

    private func lastReservationPerProject() async throws -> [ProjectID: Int64] {
        var result: [ProjectID: Int64] = [:]
        let jobs = try await store.jobs()
        let projectOfJob = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.projectID) })
        let tasks = try await store.tasks()
        let jobOfTask = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.jobID) })
        for attempt in try await store.attempts() {
            guard let job = jobOfTask[attempt.taskID], let project = projectOfJob[job] else { continue }
            result[project] = max(result[project] ?? .min, attempt.reservedAt)
        }
        return result
    }
}
