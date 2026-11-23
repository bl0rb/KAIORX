import Domain
import Foundation
import ProcessHost
import Providers
import Synchronization
import Testing
import TestSupport
@testable import Orchestration
@testable import Storage
@testable import Workspace

final class ManualClock: Sendable {
    let value = Mutex<Int64>(1_000_000)
    var now: Int64 { value.withLock { $0 } }
    func advance(_ ms: Int64) { value.withLock { $0 += ms } }
}

struct TestGate: CapabilityGate {
    let automatic: Bool
    let access: Bool
    func allowsAutomatic(_ provider: ProviderKind) async -> Bool { automatic }
    func accessRestored(_ provider: ProviderKind, account: AccountID) async -> Bool { access }
}

final class StartCounter: Sendable {
    let starts = Mutex<[AttemptID]>([])
    func record(_ id: AttemptID) { starts.withLock { $0.append(id) } }
    var count: Int { starts.withLock { $0.count } }
}

/// A repository, a store on a manual clock, an author double (as `claude`) and an independent
/// reviewer double (`fake`), consents, verified profiles and budgets.
struct SchedulerHarness {
    let host = ProcessHost()
    let clock = ManualClock()
    let checkout: String
    let git: GitRunner
    let store: Store
    let service: WorkspaceService
    let coordinator: RunCoordinator
    let integration: IntegrationService
    let starts = StartCounter()
    let project = ProjectID()
    let job = JobID()
    let author: AccountID
    let reviewer: AccountID
    let authorConsent: ConsentRecord
    let limits: SchedulerLimits

    init(
        limits: SchedulerLimits = SchedulerLimits(global: 2, perAccount: 2), unconfirmed: Int? = 20, budget: Int = 1_000_000,
        script: @escaping @Sendable (AttemptSpec) -> FakeScript = { _ in .success() }
    ) async throws {
        let base = try Scratch.directory("sched")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = Confinement.resolved(base.path(percentEncoded: false))
        checkout = root + "/user"
        try FileManager.default.createDirectory(atPath: checkout, withIntermediateDirectories: true)
        let layout = WorkspaceLayout(root: root + "/data")
        git = try GitRunner(host: host, home: layout.gitHome)
        let clock = self.clock
        store = try Store(path: root + "/test.sqlite", clock: { clock.now })
        service = WorkspaceService(store: store, git: git, layout: layout)
        let starts = self.starts
        let authorAdapter = FakeAdapter(provider: .claude) { spec in
            starts.record(spec.attemptID)
            return script(spec)
        }
        coordinator = RunCoordinator(store: store, adapters: [authorAdapter, FakeAdapter()])
        integration = IntegrationService(store: store, workspace: service, git: git, coordinator: coordinator)
        self.limits = limits
        try await Self.sh("git init -q -b main && mkdir src && echo 'let a = 1' > src/a.swift && git add -A && git commit -q -m init", in: checkout, git: git, host: host)
        try await store.execute(Command(.openProject(id: project, name: "P", rootLocator: checkout)))
        try await store.execute(Command(.createJob(id: job, projectID: project, goal: "Ziel")))
        author = try await store.registerAccount(provider: .claude, identity: "author")
        reviewer = try await store.registerAccount(provider: .fake, identity: "reviewer")
        authorConsent = try await store.grantConsent(ConsentDraft(
            projectID: project, provider: .claude, accountID: author, roles: [.author], writeRoots: [""], sensitiveRoots: [""],
            unconfirmedAttemptLimit: unconfirmed
        ))
        try await store.grantConsent(ConsentDraft(projectID: project, provider: .fake, accountID: reviewer, roles: [.reviewer], writeRoots: [""]))
        for tier in CapabilityTier.allCases {
            try await store.registerModelProfile(ModelProfile(provider: .claude, role: .author, tier: tier, model: "a-\(tier.rawValue)", typicalTokens: 1_000, verifiedAt: 1))
        }
        try await store.registerModelProfile(ModelProfile(provider: .fake, role: .reviewer, tier: .fast, model: "r", typicalTokens: 500, verifiedAt: 1))
        try await store.createBudget(account: author, job: job, tokenLimit: budget)
        try await store.createBudget(account: reviewer, job: job, tokenLimit: budget)
    }

    static func sh(_ script: String, in directory: String, git: GitRunner, host: ProcessHost) async throws {
        let result = try await host.run(LaunchSpec(
            executable: "/bin/sh", arguments: ["-c", script], workingDirectory: directory,
            environment: [
                "PATH": "/usr/bin:/bin:" + URL(filePath: git.executable).deletingLastPathComponent().path(percentEncoded: false),
                "HOME": directory, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_AUTHOR_NAME": "U", "GIT_AUTHOR_EMAIL": "u@e", "GIT_COMMITTER_NAME": "U", "GIT_COMMITTER_EMAIL": "u@e",
            ],
            timeout: .seconds(30)
        ))
        guard result.termination == .exited(0) else { throw GitError.failed(arguments: [script], termination: result.termination, stderr: result.stderr.text) }
    }

    func scheduler(automatic: Bool = true, access: Bool = true) -> Scheduler {
        Scheduler(store: store, coordinator: coordinator, workspace: service, gate: TestGate(automatic: automatic, access: access), limits: limits)
    }

    /// Proposes, accepts and activates a plan, and opens the job's integration.
    func activate(_ tasks: [PlanTaskDraft]) async throws {
        let (plan, _) = try await store.proposePlan(job: job, draft: PlanDraft(tasks: tasks), createdBy: .user, expectedCurrent: nil)
        try await store.acceptPlan(plan.id, expectedCurrent: nil)
        let version = try #require(try await store.jobs().first { $0.id == job }).version
        try await store.execute(Command(.transitionJob(id: job, to: .active, expectedVersion: version, reason: nil)))
        _ = try await service.openIntegration(job, baseRevision: "main")
    }

    func task(_ key: String) async throws -> TaskRecord {
        try #require(try await store.tasks(jobID: job).first { $0.planKey == key })
    }

    /// Waits for the task's current author attempt, seals its (unchanged) worktree and accepts
    /// the empty result: the task is integrated.
    func finish(_ key: String) async throws {
        let attemptID = try #require(try await task(key).currentAttemptID)
        _ = try await coordinator.waitUntilFinished(attemptID)
        let tree = try #require(try await store.attempt(attemptID)?.worktreeID)
        _ = try await service.seal(tree, allowedPrefixes: nil, message: "r")
        try await integration.acceptEmptyResult(try await task(key).id)
    }

    func authorAttempts(_ key: String) async throws -> [AttemptRecord] {
        try await store.attempts(taskID: try await task(key).id).filter { $0.role == .author }.sorted { $0.ordinal < $1.ordinal }
    }
}

func planTask(_ key: String, after: [String] = [], writes: [String]? = nil, difficulty: DifficultyEvidence = DifficultyEvidence(
    multipleModules: false, moreThanThreeFiles: false, unclearApproach: false, noReproducibleTest: false
)) -> PlanTaskDraft {
    PlanTaskDraft(key: key, title: key, goal: "Ziel \(key)", criteria: ["\(key) erledigt"], writePaths: writes ?? ["src/\(key)"], predecessors: after, difficulty: difficulty)
}

@Suite struct SchedulerAcceptanceTests {
    @Test func diamondRunsInDependencyOrderOnTheIntegratedState() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A"), planTask("B", after: ["A"]), planTask("C", after: ["A"]), planTask("D", after: ["B", "C"])])
        let scheduler = h.scheduler()
        var report = try await scheduler.tick()
        #expect(report.reserved.count == 1)
        #expect(try await h.authorAttempts("A").count == 1)
        #expect(try await h.task("B").state == .pending)
        try await h.finish("A")

        report = try await scheduler.tick()
        #expect(report.reserved.count == 2)
        #expect(try await h.authorAttempts("B").count == 1)
        #expect(try await h.authorAttempts("C").count == 1)
        try await h.finish("B")
        _ = try await scheduler.tick()
        #expect(try await h.task("D").state == .pending)
        try await h.finish("C")
        report = try await scheduler.tick()
        #expect(report.reserved.count == 1)
        let d = try #require(try await h.authorAttempts("D").first)
        #expect(d.baseOID == (try await h.store.integrationTip(job: h.job)))
        #expect(try await h.task("D").readyAt != nil)
    }

    @Test func cyclesAreRefusedBeforeAnythingIsStored() async throws {
        let h = try await SchedulerHarness()
        do {
            _ = try await h.store.proposePlan(job: h.job, draft: PlanDraft(tasks: [planTask("A", after: ["B"]), planTask("B", after: ["A"])]), createdBy: .planner, expectedCurrent: nil)
            Issue.record("cycle accepted")
        } catch PlanningError.invalidPlan(let issues) {
            #expect(issues.issues.contains { if case .cycle = $0 { true } else { false } })
        }
        #expect(try await h.store.plans(job: h.job).isEmpty)
    }

    @Test func overlappingWriteAreasRunOneAfterAnother() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A", writes: ["src"]), planTask("B", writes: ["SRC/x"]), planTask("C", writes: ["docs"])])
        let scheduler = h.scheduler()
        let report = try await scheduler.tick()
        #expect(report.reserved.count == 2)
        #expect(try await h.authorAttempts("A").count == 1)
        #expect(try await h.authorAttempts("C").count == 1)
        #expect(report.waiting[try await h.task("B").id]?.kind == .writeArea)
        #expect(try await h.task("B").waitReason == "writeArea:A")
        try await h.finish("A")
        _ = try await scheduler.tick()
        #expect(try await h.authorAttempts("B").count == 1)
    }

    @Test func twoSchedulersStartATaskOnce() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A")])
        let one = h.scheduler(), two = h.scheduler()
        async let a = one.tick()
        async let b = two.tick()
        let reports = try await [a, b]
        #expect(reports.flatMap(\.reserved).count == 1)
        #expect(try await h.authorAttempts("A").count == 1)
        let attempt = try #require(try await h.authorAttempts("A").first)
        _ = try await h.coordinator.waitUntilFinished(attempt.id)
        #expect(h.starts.count == 1)
    }

    @Test func revocationStopsRunningWorkAndNewReservations() async throws {
        let h = try await SchedulerHarness(script: { _ in .waitsForCancel })
        try await h.activate([planTask("A"), planTask("B")])
        let scheduler = h.scheduler()
        let first = try await scheduler.tick()
        #expect(first.reserved.count == 2)
        let attempts = try await h.authorAttempts("A") + h.authorAttempts("B")
        try await h.store.revokeConsent(h.authorConsent.id)
        let report = try await scheduler.tick()
        #expect(Set(report.cancelledForRevocation) == Set(attempts.map(\.id)))
        for attempt in attempts { _ = try await h.coordinator.waitUntilFinished(attempt.id) }
        #expect(try await h.store.attempt(attempts[0].id)?.state == .cancelled)
        let again = try await scheduler.tick()
        #expect(again.reserved.isEmpty)
        #expect(again.waiting[try await h.task("A").id]?.kind == .consent)
    }

    @Test func aRepeatedDiagnosticFailureRepairsEscalatesAndStops() async throws {
        let h = try await SchedulerHarness(script: { spec in
            FakeScript(steps: [
                .emit(.started(sessionID: "s")),
                .emit(.completed(.failed(reason: "XCTAssertEqual failed at /tmp/wt-\(spec.attemptID)/Tests/A.swift:\(Int.random(in: 1...99))"))),
            ])
        })
        try await h.activate([planTask("A")])
        let scheduler = h.scheduler()
        for _ in 0..<3 {
            _ = try await scheduler.tick()
            let last = try #require(try await h.authorAttempts("A").last)
            _ = try await h.coordinator.waitUntilFinished(last.id)
        }
        let report = try await scheduler.tick()
        let tiers = try await h.authorAttempts("A").map(\.tier)
        #expect(tiers == [.fast, .fast, .standard])
        #expect(report.reserved.isEmpty)
        #expect(try await h.task("A").waitReason == "userDecision:attemptLimit")
        let decisions = try await h.store.decisions(task: try await h.task("A").id)
        #expect(decisions.map(\.rule).prefix(3) == ["difficulty", "repair", "repeatedFingerprint"])
        #expect(decisions.last?.outcome == "userDecision:attemptLimit")
    }

    @Test func rateLimitBlocksTheAccountInVirtualTime() async throws {
        let limited = Mutex(true)
        let h = try await SchedulerHarness(script: { _ in
            if limited.withLock({ let first = $0; $0 = false; return first }) {
                return FakeScript(steps: [
                    .emit(.started(sessionID: "s")),
                    .emit(.rateLimited(signal: RateLimitSignal(kind: .rateLimit, retryAfterMs: 30_000))),
                    .emit(.completed(.failed(reason: "429"))),
                ])
            }
            return .success()
        })
        try await h.activate([planTask("A")])
        let scheduler = h.scheduler()
        _ = try await scheduler.tick()
        let first = try #require(try await h.authorAttempts("A").first)
        _ = try await h.coordinator.waitUntilFinished(first.id)
        #expect(try await h.store.attempt(first.id)?.errorClass == "rateLimited")
        #expect(try await h.task("A").state == .ready)

        let blocked = try await scheduler.tick()
        #expect(blocked.reserved.isEmpty)
        #expect(blocked.waiting[try await h.task("A").id] == WaitReason(.quota, "blocked"))
        #expect(blocked.nextWakeAt == h.clock.now + 30_000)
        h.clock.advance(29_999)
        #expect(try await scheduler.tick().reserved.isEmpty)
        h.clock.advance(1)
        let resumed = try await scheduler.tick()
        #expect(resumed.reserved.count == 1)
        // A rate limit is not a failure on the substance: the tier stays.
        #expect(try await h.authorAttempts("A").map(\.tier) == [.fast, .fast])
    }

    @Test func aFailedAccessCheckBlocksAgainWithDoubling() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A")])
        let block = try await h.store.blockAccount(h.author, reason: "rateLimited")
        #expect(block.until == h.clock.now + 60_000)
        h.clock.advance(60_000)
        let report = try await h.scheduler(access: false).tick()
        #expect(report.reserved.isEmpty)
        #expect(report.nextWakeAt == h.clock.now + 120_000)
    }

    @Test func withoutAutomaticPermissionOnlyAUserStartRuns() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A")])
        let scheduler = h.scheduler(automatic: false)
        let report = try await scheduler.tick()
        let a = try await h.task("A")
        #expect(report.reserved.isEmpty && report.awaitingUserStart == [a.id])
        #expect(try await h.store.attempts(taskID: a.id).isEmpty)
        #expect(try await h.store.decisions(task: a.id).last?.outcome == "awaitingUserStart:claude")
        let started = try await scheduler.start(a.id, actor: "matze")
        #expect(started.reserved.count == 1)
        #expect(try await h.store.decisions(task: a.id).last?.actor == "matze")
    }

    @Test func slotsQuotaAndBudgetAreCheckedInTheReservation() async throws {
        let h = try await SchedulerHarness(limits: SchedulerLimits(global: 2, perAccount: 1), unconfirmed: 2, budget: 1_500, script: { _ in .waitsForCancel })
        try await h.activate([planTask("A"), planTask("B")])
        let scheduler = h.scheduler()
        let report = try await scheduler.tick()
        #expect(report.reserved.count == 1)
        #expect(report.waiting.values.contains(WaitReason(.slot, "account")))
        // Cancel the first; the second fits the per-account slot but not the remaining budget.
        let running = try #require(report.reserved.first)
        try await h.coordinator.cancel(running, reason: "test")
        _ = try await h.coordinator.waitUntilFinished(running)
        let next = try await scheduler.tick()
        #expect(next.reserved.isEmpty)
        #expect(next.waiting.values.contains(WaitReason(.budget, "insufficient")))
        #expect(try await h.store.reservation(attempt: running)?.state == "unresolved")
    }

    @Test func unknownQuotaAllowsOnlyTheConfirmedNumberOfAttempts() async throws {
        let h = try await SchedulerHarness(unconfirmed: 1)
        try await h.activate([planTask("A"), planTask("B")])
        let report = try await h.scheduler().tick()
        #expect(report.reserved.count == 1)
        #expect(report.waiting.values.contains(WaitReason(.quota, "unknownQuotaLimit")))
    }

    @Test func aKnownQuotaNearItsLimitStopsParallelWork() async throws {
        let h = try await SchedulerHarness(script: { _ in .waitsForCancel })
        try await h.activate([planTask("A"), planTask("B")])
        try await h.store.recordQuotaObservation(h.author, QuotaSignal(windowKey: "5h", unit: .percent, used: 85, limit: 100, resetAt: nil), source: "test")
        let report = try await h.scheduler().tick()
        #expect(report.reserved.count == 1)
        #expect(report.waiting.values.contains(WaitReason(.quota, "nearLimit")))
        try await h.store.recordQuotaObservation(h.author, QuotaSignal(windowKey: "5h", unit: .percent, used: 100, limit: 100, resetAt: nil), source: "test")
        for attempt in report.reserved { try await h.coordinator.cancel(attempt, reason: "t"); _ = try await h.coordinator.waitUntilFinished(attempt) }
        #expect(try await h.scheduler().tick().waiting.values.contains(WaitReason(.quota, "exhausted")))
    }
}

@Suite struct PlanRevisionTests {
    @Test func revisionsKeepTaskIdentityAndProtectStartedTasks() async throws {
        let h = try await SchedulerHarness(script: { _ in .waitsForCancel })
        try await h.activate([planTask("A"), planTask("B", after: ["A"]), planTask("C", after: ["A"])])
        _ = try await h.scheduler().tick()
        let aID = try await h.task("A").id
        let current = try #require(try await h.store.jobs().first { $0.id == h.job }?.currentPlanID)

        // Changing the started task A is refused.
        var changedA = planTask("A")
        changedA.goal = "anders"
        let (refused, _) = try await h.store.proposePlan(job: h.job, draft: PlanDraft(tasks: [changedA, planTask("B", after: ["A"])]), createdBy: .user, expectedCurrent: current)
        await #expect(throws: PlanningError.startedTaskChanged("A")) { try await h.store.acceptPlan(refused.id, expectedCurrent: current) }

        // Removing pending C and adding D keeps A's identity; C ends.
        let (next, diff) = try await h.store.proposePlan(job: h.job, draft: PlanDraft(tasks: [planTask("A"), planTask("B", after: ["A"]), planTask("D", after: ["B"])]), createdBy: .user, expectedCurrent: current)
        #expect(diff.addedTasks == ["D"] && diff.removedTasks == ["C"] && diff.changedTasks.isEmpty)
        try await h.store.acceptPlan(next.id, expectedCurrent: current)
        #expect(try await h.task("A").id == aID)
        #expect(try await h.task("C").state == .cancelled)
        #expect(try await h.task("D").state == .pending)
        // A stale revision cannot be accepted.
        await #expect(throws: PlanningError.planRevisionMoved(expected: current, actual: next.id)) { try await h.store.acceptPlan(refused.id, expectedCurrent: current) }
    }

    @Test func planTasksAreNotMadeReadyByCommandAndTheJobEndsOnlyWhenComplete() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A"), planTask("B", after: ["A"])])
        let b = try await h.task("B")
        await #expect(throws: PlanningError.taskManagedByScheduler(b.id)) {
            try await h.store.execute(Command(.transitionTask(id: b.id, to: .ready, expectedVersion: b.version)))
        }
        await #expect(throws: PlanningError.jobHasPlan(h.job)) {
            try await h.store.execute(Command(.createTask(id: TaskID(), jobID: h.job, title: "frei")))
        }
        let version = try #require(try await h.store.jobs().first { $0.id == h.job }).version
        await #expect(throws: PlanningError.jobNotComplete(h.job, openTasks: 2)) {
            try await h.store.execute(Command(.transitionJob(id: h.job, to: .done, expectedVersion: version, reason: nil)))
        }
        let scheduler = h.scheduler()
        _ = try await scheduler.tick()
        try await h.finish("A")
        _ = try await scheduler.tick()
        try await h.finish("B")
        let finalVersion = try #require(try await h.store.jobs().first { $0.id == h.job }).version
        try await h.store.execute(Command(.transitionJob(id: h.job, to: .done, expectedVersion: finalVersion, reason: nil)))
    }

    @Test func anEndedPredecessorMakesItsSuccessorsWait() async throws {
        let h = try await SchedulerHarness(script: { _ in .waitsForCancel })
        try await h.activate([planTask("A"), planTask("B", after: ["A"])])
        _ = try await h.scheduler().tick()
        let a = try await h.task("A")
        let attempt = try #require(a.currentAttemptID)
        try await h.coordinator.cancel(attempt, reason: "t")
        _ = try await h.coordinator.waitUntilFinished(attempt)
        let ready = try await h.task("A")
        try await h.store.execute(Command(.transitionTask(id: ready.id, to: .cancelled, expectedVersion: ready.version)))
        _ = try await h.scheduler().tick()
        #expect(try await h.task("B").waitReason == "predecessorEnded:A")
        #expect(try await h.task("B").state == .pending)
    }

    @Test func estimateCountsTiersAndTokens() async throws {
        let h = try await SchedulerHarness()
        let hard = DifficultyEvidence(multipleModules: true, moreThanThreeFiles: true, unclearApproach: true, noReproducibleTest: nil)
        let (plan, _) = try await h.store.proposePlan(job: h.job, draft: PlanDraft(tasks: [planTask("A"), planTask("B", difficulty: hard)]), createdBy: .planner, expectedCurrent: nil)
        #expect(plan.estimate.tasksPerTier == ["fast": 1, "intensive": 1])
        #expect(plan.estimate.expectedTokens == 2_000)
        #expect(plan.estimate.uncertainTasks == ["B"])
    }
}


@Suite struct PlannedIntegrationTests {
    /// Runs the task's attempt, writes `script` in its worktree and seals within its write area.
    func result(_ h: SchedulerHarness, _ key: String, _ script: String, writes: [String]?) async throws -> WorktreeRecord {
        _ = try await h.scheduler().tick()
        let attempt = try #require(try await h.task(key).currentAttemptID)
        _ = try await h.coordinator.waitUntilFinished(attempt)
        let tree = try #require(try await h.store.attempt(attempt)?.worktreeID)
        try await SchedulerHarness.sh(script, in: h.service.path(of: try await h.service.worktree(tree)), git: h.git, host: h.host)
        _ = try await h.service.seal(tree, allowedPrefixes: writes, message: "r")
        return try await h.service.worktree(tree)
    }

    @Test func changesOutsideTheWriteAreaNeedConfirmation() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let tree = try await result(h, "A", "mkdir -p src/A docs && echo x > src/A/f && echo y > docs/g", writes: ["src/A"])
        #expect(tree.rejectedPaths.keys.sorted() == ["docs/g"])
        await #expect(throws: IntegrationError.undeclaredChanges(["docs/g"])) { _ = try await h.integration.buildCandidate(from: tree.id) }
        guard case .built = try await h.integration.buildCandidate(from: tree.id, acceptingRejectedPaths: true) else { Issue.record("not built"); return }
    }

    @Test func sensitiveTasksNeedATestProfileAndAHumanReview() async throws {
        let h = try await SchedulerHarness()
        var sensitive = planTask("A", writes: ["src/A"])
        sensitive.risk = .sensitive
        try await h.activate([sensitive])
        let tree = try await result(h, "A", "mkdir -p src/A && echo x > src/A/f", writes: ["src/A"])
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(candidate.id, profile: try await h.store.confirmedTestProfile(project: h.project, arguments: ["-c", "exit 0"]))
        let oid = try #require(candidate.candidateOID)
        #expect(try await h.integration.gate(candidate.id).contains("no approving human review for a sensitive task"))
        _ = try await h.integration.importReview(candidate.id, text: #"{"candidateOID": "\#(oid)", "verdict": "approve", "findings": []}"#)
        // The imported review is the human one; it cannot also be the independent provider review.
        #expect(try await h.integration.gate(candidate.id) == ["no approving independent review for \(oid)", "no test profile for a sensitive task"])
        #expect(try await h.store.candidate(candidate.id)?.state == .reviewing)
    }

    @Test func aRejectionWithoutACountedFailureWaitsForTheUsersRework() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let tree = try await result(h, "A", "mkdir -p src/A && echo x > src/A/f", writes: ["src/A"])
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        // A user rejection is no failure on the substance: nothing counts, nothing is granted.
        try await h.integration.rejectCandidate(candidate.id, reason: "passt nicht")
        #expect(try await h.task("A").state == .needsChanges)

        let scheduler = h.scheduler()
        let report = try await scheduler.tick()
        let a = try await h.task("A")
        #expect(report.reserved.isEmpty)
        #expect(report.waiting[a.id] == WaitReason(.userDecision, "rework"))
        #expect(a.waitReason == "userDecision:rework" && a.state == .needsChanges)
        #expect(try await h.authorAttempts("A").count == 1)
        // Waiting again records nothing new.
        let decisions = try await h.store.decisions(task: a.id).count
        _ = try await scheduler.tick()
        #expect(try await h.store.decisions(task: a.id).count == decisions)

        // The user's decision sends it back to its author, with a fresh count.
        try await scheduler.grant(a.id, actor: "matze")
        let resumed = try await scheduler.tick()
        #expect(resumed.reserved.count == 1)
        #expect(try await h.authorAttempts("A").count == 2)
        #expect(try await h.task("A").waitReason == nil)
    }

    @Test func onlyEmptyOrContainedResultsAreAcceptedAsDone() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let tree = try await result(h, "A", "mkdir -p src/A && echo x > src/A/f", writes: ["src/A"])
        #expect(tree.sealStatus == .committed)
        let a = try await h.task("A")
        await #expect(throws: IntegrationError.resultNotEmpty(a.id)) { try await h.integration.acceptEmptyResult(a.id) }
        #expect(try await h.task("A").state == .resultReady)
    }
}

@Suite struct PlanProposalTests {
    @Test func theLastJSONBlockIsMappedLeniently() throws {
        let text = """
            Erster Entwurf:
            ```json
            {"tasks": [{"key": "old", "title": "x"}]}
            ```
            Überarbeitet:
            ```json
            {"tasks": [
              {"key": "parser", "title": "Parser", "criteria": ["Tests grün"], "writePaths": ["Sources/Parser"],
               "risk": "sensitive", "difficulty": {"multipleModules": true, "moreThanThreeFiles": true}},
              {"key": "docs", "title": "Doku", "criteria": ["README"], "predecessors": ["parser"]}
            ]}
            ```
            """
        let draft = try PlanProposal.parse(text)
        #expect(draft.tasks.map(\.key) == ["parser", "docs"])
        #expect(draft.tasks[0].risk == .sensitive && draft.tasks[0].difficulty.points == 2 && draft.tasks[0].difficulty.isUncertain)
        #expect(draft.tasks[1].writePaths == nil && draft.tasks[1].predecessors == ["parser"])
        #expect(throws: PlanProposal.ParseError.invalidTask(0, "criteria")) { try PlanProposal.parse(#"{"tasks": [{"key": "a", "title": "a", "criteria": "nein"}]}"#) }
        #expect(throws: PlanProposal.ParseError.noReadableBlock) { try PlanProposal.parse("```json\n{\"tasks\": []") }
    }
}
