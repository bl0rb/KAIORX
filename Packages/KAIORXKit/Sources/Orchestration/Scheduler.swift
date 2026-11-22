import Domain
import Foundation
import Providers
import Storage

/// Decides whether a provider may run without an explicit user start, and checks access after
/// a quota block without inference (ADR 0005 §7, §10). The product gate is `AutomationGate`
/// (ADR 0009); simple gates (tests, UI tests) only answer `allowsAutomatic`.
public protocol CapabilityGate: Sendable {
    func allowsAutomatic(_ provider: ProviderKind) async -> Bool
    /// Why a provider may not run automatically right now; checked before every automatic
    /// reservation, so a blocked provider never reserves and then fails at its start.
    func automaticVerdict(_ provider: ProviderKind) async -> AutomaticVerdict
    /// A non-inference access check (probe) after a block expired.
    func accessRestored(_ provider: ProviderKind, account: AccountID) async -> Bool
    /// Called once at app start with the running adapters, before the scheduler exists.
    func prepare(_ context: GateContext) async
}

extension CapabilityGate {
    public func automaticVerdict(_ provider: ProviderKind) async -> AutomaticVerdict {
        await allowsAutomatic(provider) ? .allowed : .blocked(.notPermitted)
    }

    public func prepare(_ context: GateContext) async {}
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
    /// Appends the attempt's project memory (ADR 0006 §6) when set.
    private let memory: MemoryBroker?
    /// Reservation size when the profile has no typical token count (marked uncertain).
    public static let defaultReservationTokens = 50_000

    public init(
        store: Store, coordinator: RunCoordinator, workspace: WorkspaceService, gate: any CapabilityGate, limits: SchedulerLimits = SchedulerLimits(),
        memory: MemoryBroker? = nil
    ) {
        self.memory = memory
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
        for reset in try await store.quotaResets(atLeast: limits.warnPercent) { report.wake(at: reset) }
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
        try await checkExpiredBlocks(&report)
        try await schedule(Candidate(task: refreshed, job: job, planID: planID, planned: planned, pathLength: 1), actor: actor, report: &report)
        return report
    }

    /// The user's decision on a task that waits for one (attempt limit, top tier, start
    /// retries): the count starts afresh after the attempts so far, optionally at a higher tier.
    public func grant(_ taskID: TaskID, tier: CapabilityTier? = nil, actor: String) async throws {
        let ordinal = try await store.attempts(taskID: taskID).filter { $0.role == .author }.map(\.ordinal).max() ?? 0
        var evidence = ["afterOrdinal": String(ordinal)]
        if let tier { evidence["tier"] = tier.rawValue }
        try await store.recordDecision(task: taskID, rule: "userGrant", evidence: evidence, outcome: "granted", actor: actor, remaining: Router.maxAuthorAttempts)
        try await store.setWaitReason(taskID, nil)
    }

    private func latestGrant(_ taskID: TaskID) async throws -> (afterOrdinal: Int, tier: CapabilityTier?)? {
        guard let decision = try await store.decisions(task: taskID).last(where: { $0.rule == "userGrant" }) else { return nil }
        return (Int(decision.evidence["afterOrdinal"] ?? "0") ?? 0, decision.evidence["tier"].flatMap(CapabilityTier.init(rawValue:)))
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
        let allAttempts = try await store.attempts(taskID: task.id).filter { $0.role == .author }
        if allAttempts.contains(where: { !$0.state.isTerminal }) { return }
        // A user grant starts the count afresh (and may raise the tier).
        let grant = try await latestGrant(task.id)
        let attempts = allAttempts.filter { $0.ordinal > (grant?.afterOrdinal ?? 0) }
        let counted = try await countedHistory(task, attempts, planned: c.planned)
        let history = counted.map(\.0)
        let plannedTier = max(c.planned.tier, grant?.tier ?? .fast)
        let decision = Router.nextTier(planned: plannedTier, history: history)

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
            // A repair, an escalation or a user grant: the scheduler brings the task back to its author.
            guard !history.isEmpty || (grant != nil && attempts.isEmpty) else {
                // Rejected or discarded without a counted failure: only the user can send it back
                // (a grant, `allowMoreAttempts`), so say so instead of stalling silently.
                try await wait(task, WaitReason(.userDecision, "rework"), decision: nil, report: &report)
                return
            }
            guard let current = try await store.task(task.id), current.state == .needsChanges else { return }
            do {
                try await store.execute(Command(.transitionTask(id: task.id, to: .ready, expectedVersion: current.version)))
            } catch is StoreError, is DomainError, is PlanningError {
                // Lost a race (another scheduler, a user hold): nothing to do this tick.
                return
            }
            guard let ready = try await store.task(task.id) else { return }
            task = ready
        }
        guard let tier = decision.outcome.tier else { return }

        // Provider: a task with author attempts keeps its provider; no rotation.
        let now = await store.now()
        let consents = try await store.consents(project: c.job.projectID)
            .filter { $0.isValid(at: now) && ($0.draft.jobID == nil || $0.draft.jobID == c.job.id) }
        let profiles = try await store.modelProfiles()
        // No provider or account rotation for a task that already ran (ADR 0005 §8).
        let fixedProvider = allAttempts.first?.provider
        let fixedAccount = allAttempts.first(where: { $0.accountID != nil })?.accountID
        func eligible(_ consent: ConsentRecord) -> Bool {
            consent.draft.roles.contains(.author) && (fixedProvider == nil || consent.draft.provider == fixedProvider)
                && (fixedAccount == nil || consent.draft.accountID == fixedAccount)
        }
        var options: [(ConsentRecord, ModelProfile)] = []
        for consent in consents where eligible(consent) {
            if let profile = ModelProfile.smallest(profiles, provider: consent.draft.provider, role: .author, atLeast: tier) {
                options.append((consent, profile))
            }
        }
        guard !options.isEmpty else {
            let anyConsent = consents.contains(where: eligible)
            try await wait(task, WaitReason(anyConsent ? .profileMissing : .consent, anyConsent ? tier.rawValue : "none"), decision: decision, report: &report)
            return
        }
        // The user's reason for sending the last result back goes into the prompt (ADR 0011);
        // the spec digest covers it, and `launch` checks it again before the turn.
        let rework = try await store.reworkReason(task: task.id)
        var firstWait: WaitReason?
        for (consent, profile) in options {
            // An independent reviewer must be possible before the author starts.
            guard let reviewer = ReviewerChoice.reviewer(consents: consents, author: profile.provider, job: c.job.id, now: now) else {
                firstWait = firstWait ?? WaitReason(.noIndependentReviewer)
                continue
            }
            // Checked before the reservation: a blocked provider waits for the user with the
            // reason (channel, installed version, confinement, subscription), never reserves.
            if actor == "scheduler", case .blocked(let block) = await gate.automaticVerdict(profile.provider) {
                firstWait = firstWait ?? WaitReason(.awaitingUserStart, block.detail(for: profile.provider))
                continue
            }
            let reviewProfile = ReviewerChoice.profile(profiles, provider: reviewer.draft.provider)
            var spec = makeSpec(c, task: task, profile: profile, decision: decision, failure: counted.last?.1, rework: rework)
            if memory != nil { spec.memoryManifestID = MemoryManifestID() }
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
                try await launch(attempt, spec: spec, job: c.job, reviewer: reviewer.draft.provider, planned: c.planned, rework: rework)
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
    /// turn cancels the reservation; the task returns to `ready` for a spaced retry. The rework
    /// reason the prompt carries is read again first: a forget between the read and the
    /// reservation did not include this attempt, so a changed reason never starts it.
    private func launch(
        _ attempt: AttemptID, spec: AttemptSpec, job: JobRecord, reviewer: ProviderKind, planned: PlannedTask, rework: ReworkReason?
    ) async throws {
        guard let record = try await store.attempt(attempt), let base = record.baseOID else { return }
        if try await store.reworkReason(task: record.taskID) != rework {
            try await failBeforeTurn(attempt, errorClass: "reworkChanged")
            return
        }
        let tree: WorktreeRecord
        do {
            tree = try await workspace.prepareWorktree(projectID: job.projectID, attemptID: attempt, kind: .author, base: base)
        } catch {
            try await failBeforeTurn(attempt, errorClass: "worktreeFailed")
            return
        }
        var spec = spec
        spec.workingDirectory = await workspace.path(of: tree)
        if let memory, let manifestID = spec.memoryManifestID {
            // Prepare, render and dispatch in the single handover transaction (it moves the
            // attempt to `starting`); a refusal is a failure before the turn.
            let d = planned.draft
            let query = MemoryQuery(texts: [d.title, d.goal] + d.criteria, paths: (d.writePaths ?? []) + d.readPaths)
            do {
                _ = try await memory.prepare(manifestID, attempt: attempt, reviewerProvider: reviewer, query: query)
                let context = try await memory.dispatch(manifestID)
                if !context.isEmpty { spec.prompt += "\n\n" + context }
            } catch {
                try await failBeforeTurn(attempt, errorClass: "memoryRefused")
                return
            }
        }
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

    static let technicalStartFailures: Set<String> = ["startFailed", "adapterUnavailable", "worktreeFailed", "memoryRefused", "reworkChanged"]

    static func isTechnicalStartFailure(_ attempt: AttemptRecord) -> Bool {
        attempt.state == .failed && attempt.startedAt == nil && technicalStartFailures.contains(attempt.errorClass ?? "")
    }

    /// Author attempts that reached a turn and failed on the substance (ADR 0005 §8), oldest first.
    /// With each counted attempt, the report a repair prompt shows.
    func countedHistory(_ task: TaskRecord, _ attempts: [AttemptRecord], planned: PlannedTask) async throws -> [(CountedAttempt, String)] {
        guard let job = try await store.jobs().first(where: { $0.id == task.jobID }) else { return [] }
        let candidates = try await store.candidates(jobID: job.id)
        var result: [(CountedAttempt, String)] = []
        for attempt in attempts.sorted(by: { $0.ordinal < $1.ordinal }) where attempt.startedAt != nil && attempt.state.isTerminal {
            let tier = attempt.tier ?? planned.tier
            if attempt.state == .failed, attempt.errorClass == "providerFailed" {
                // A forgotten report is no evidence of a repeated failure: its own fingerprint.
                let reason = try await failureReason(attempt.id)
                let fingerprint = reason.map { FailureFingerprint.of($0) } ?? "purged:\(attempt.id.uuidString)"
                result.append((CountedAttempt(tier: tier, failure: .providerFailed(fingerprint: fingerprint)), reason ?? Store.purgedText))
                continue
            }
            guard attempt.state == .succeeded else { continue }
            for candidate in candidates where candidate.authorAttemptID == attempt.id && candidate.state == .rejected {
                let tests = try await store.testResults(candidate: candidate.id)
                if let red = tests.last(where: { [.failed, .crashed, .inputsModified].contains($0.status) }) {
                    let fingerprint = red.summary == Store.purgedText ? "purged:\(red.id.uuidString)" : FailureFingerprint.of(red.summary)
                    result.append((CountedAttempt(tier: tier, failure: .redTest(fingerprint: fingerprint)), "Test: \(red.summary)"))
                    break
                }
                let blocking = try await store.findings(candidate: candidate.id).filter { $0.severity == .blocking }
                if !blocking.isEmpty {
                    let report = blocking.map { "Blocking finding \($0.path ?? "?"):\($0.line.map(String.init) ?? "?"): \($0.impact) – \($0.suggestion)" }
                    result.append((CountedAttempt(tier: tier, failure: .blockingFinding), report.joined(separator: "\n")))
                    break
                }
            }
        }
        return result
    }

    /// The provider's failure reason; nil when the completion's payload was purged by a forget.
    private func failureReason(_ attempt: AttemptID) async throws -> String? {
        let events = try await store.events(attempt: attempt, kind: .attemptCompleted)
        for event in events.reversed() {
            if let data = event.payload, case .completed(.failed(let reason))? = try? JSONDecoder().decode(AgentEvent.self, from: data) {
                return reason
            }
        }
        if events.contains(where: { $0.payload == nil }) { return nil }
        return "providerFailed"
    }

    private func makeSpec(
        _ c: Candidate, task: TaskRecord, profile: ModelProfile, decision: TierDecision, failure: String?, rework: ReworkReason?
    ) -> AttemptSpec {
        let d = c.planned.draft
        var lines = ["Task: \(d.title)", "Goal: \(d.goal)", "Acceptance criteria:"] + d.criteria.map { "- \($0)" }
        if let writes = d.writePaths { lines.append("You may change only: \(writes.joined(separator: ", "))") }
        lines += ReworkPrompt.lines(rework)
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
                _ = try await store.activeBlock(block.accountID, releasingExpired: true)
            } else {
                // Always timed: a failed check renews as a rate limit with the doubling fallback.
                let renewed = try await store.blockAccount(block.accountID, reason: "rateLimited")
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
