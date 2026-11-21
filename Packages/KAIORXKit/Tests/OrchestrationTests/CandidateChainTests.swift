import Domain
import Foundation
import ProcessHost
import Providers
import Synchronization
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workspace

/// What the fake reviewer (`fake`) does; it reads the candidate commit from its prompt.
final class ChainReviewer: Sendable {
    enum Mode: Sendable { case approve, crash, hang }
    private let mode = Mutex(Mode.approve)
    func set(_ value: Mode) { mode.withLock { $0 = value } }

    var adapter: FakeAdapter {
        FakeAdapter(provider: .fake) { [self] spec in
            let oid = spec.prompt.split(separator: " ").dropFirst(2).first.map(String.init) ?? ""
            switch mode.withLock({ $0 }) {
            case .approve:
                let text = #"```json\#n{"candidateOID": "\#(oid)", "verdict": "approve", "summary": "fine", "findings": []}\#n```"#
                return FakeScript(steps: [.emit(.started(sessionID: "rev")), .emit(.messageFinal(itemID: "m", text: text)), .emit(.completed(.succeeded))])
            case .crash:
                return FakeScript(steps: [.emit(.started(sessionID: "rev")), .emit(.completed(.failed(reason: "crash")))])
            case .hang:
                return .waitsForCancel
            }
        }
    }
}

/// A switch the injected `streaming` closure reads.
final class StreamFlag: Sendable {
    private let value: Mutex<Bool>
    init(_ live: Bool) { value = Mutex(live) }
    var live: Bool { value.withLock { $0 } }
    func set(_ live: Bool) { value.withLock { $0 = live } }
}

/// Counts every question to the automation gate.
final class CountingGate: CapabilityGate {
    let automatic: Bool
    private let calls = Mutex(0)
    init(automatic: Bool) { self.automatic = automatic }
    var count: Int { calls.withLock { $0 } }
    func allowsAutomatic(_ provider: ProviderKind) async -> Bool {
        calls.withLock { $0 += 1 }
        return automatic
    }
    func accessRestored(_ provider: ProviderKind, account: AccountID) async -> Bool { true }
}

extension Store {
    /// Changes a row outside every flow, to put the store into a state the API cannot reach.
    func chainTestRun(_ sql: String, _ values: [SQLValue] = []) throws {
        try connection().run(sql, values)
    }
}

/// The scheduler harness of `SchedulerTests` (author double `claude`, reviewer double `fake`
/// with consents, verified profiles and budgets), with a scripted reviewer, helpers to move the
/// integration target, and a restart on the same database.
struct ChainHarness {
    let host = ProcessHost()
    let clock = ManualClock()
    let checkout: String
    let layout: WorkspaceLayout
    let storePath: String
    let git: GitRunner
    var store: Store
    var service: WorkspaceService
    var coordinator: RunCoordinator
    var integration: IntegrationService
    let adapters: [any AgentAdapter]
    let reviewer = ChainReviewer()
    let project = ProjectID()
    let job = JobID()
    let authorAccount: AccountID
    let reviewerAccount: AccountID
    let limits: SchedulerLimits

    init(limits: SchedulerLimits = SchedulerLimits(global: 2, perAccount: 2), extraProviders: [ProviderKind] = []) async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "kaiorx-chain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = Confinement.resolved(base.path(percentEncoded: false))
        checkout = root + "/user"
        try FileManager.default.createDirectory(atPath: checkout, withIntermediateDirectories: true)
        layout = WorkspaceLayout(root: root + "/data")
        git = try GitRunner(host: host, home: layout.gitHome)
        storePath = root + "/test.sqlite"
        let clock = self.clock
        store = try Store(path: storePath, clock: { clock.now })
        service = WorkspaceService(store: store, git: git, layout: layout)
        adapters = [FakeAdapter(provider: .claude), reviewer.adapter] + extraProviders.map { FakeAdapter(provider: $0) }
        coordinator = RunCoordinator(store: store, adapters: adapters)
        integration = IntegrationService(store: store, workspace: service, git: git, coordinator: coordinator)
        self.limits = limits
        try await SchedulerHarness.sh(
            "git init -q -b main && mkdir src && echo 'let a = 1' > src/a.swift && git add -A && git commit -q -m init", in: checkout, git: git, host: host
        )
        try await store.execute(Command(.openProject(id: project, name: "P", rootLocator: checkout)))
        try await store.execute(Command(.createJob(id: job, projectID: project, goal: "Ziel")))
        authorAccount = try await store.registerAccount(provider: .claude, identity: "author")
        reviewerAccount = try await store.registerAccount(provider: .fake, identity: "reviewer")
        try await store.grantConsent(ConsentDraft(
            projectID: project, provider: .claude, accountID: authorAccount, roles: [.author], writeRoots: [""], sensitiveRoots: [""],
            unconfirmedAttemptLimit: 20
        ))
        try await store.grantConsent(ConsentDraft(projectID: project, provider: .fake, accountID: reviewerAccount, roles: [.reviewer], writeRoots: [""]))
        for tier in CapabilityTier.allCases {
            try await store.registerModelProfile(ModelProfile(provider: .claude, role: .author, tier: tier, model: "a-\(tier.rawValue)", typicalTokens: 1_000, verifiedAt: 1))
        }
        try await store.registerModelProfile(ModelProfile(provider: .fake, role: .reviewer, tier: .fast, model: "r", typicalTokens: 500, verifiedAt: 1))
        try await store.createBudget(account: authorAccount, job: job, tokenLimit: 1_000_000)
        try await store.createBudget(account: reviewerAccount, job: job, tokenLimit: 1_000_000)
    }

    var integrationRef: String { "refs/kaiorx/integrations/\(job.uuidString)" }

    @discardableResult
    func sh(_ script: String, in directory: String? = nil) async throws -> String {
        let result = try await host.run(LaunchSpec(
            executable: "/bin/sh", arguments: ["-c", script], workingDirectory: directory ?? checkout,
            environment: [
                "PATH": "/usr/bin:/bin:" + URL(filePath: git.executable).deletingLastPathComponent().path(percentEncoded: false),
                "HOME": layout.gitHome, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_AUTHOR_NAME": "U", "GIT_AUTHOR_EMAIL": "u@e", "GIT_COMMITTER_NAME": "U", "GIT_COMMITTER_EMAIL": "u@e",
            ],
            timeout: .seconds(30)
        ))
        guard result.termination == .exited(0) else {
            throw GitError.failed(arguments: [script], termination: result.termination, stderr: result.stderr.text)
        }
        return result.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func scheduler() -> Scheduler {
        Scheduler(store: store, coordinator: coordinator, workspace: service, gate: TestGate(automatic: true, access: true), limits: limits)
    }

    func chain(limits: SchedulerLimits? = nil, gate: (any CapabilityGate)? = nil, streaming: (@Sendable (AttemptID) async -> Bool)? = nil) -> CandidateChain {
        CandidateChain(
            store: store, workspace: service, integration: integration, git: git, coordinator: coordinator,
            limits: limits ?? self.limits, gate: gate, streaming: streaming
        )
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

    /// One scheduler tick starts the task's author; once its stream ended, `script` writes into
    /// its worktree (the author's changes). Nothing is sealed.
    func runPlanned(_ key: String, _ script: String?) async throws -> (task: TaskID, attempt: AttemptID, tree: WorktreeID) {
        _ = try await scheduler().tick()
        let task = try await self.task(key)
        let attempt = try #require(task.currentAttemptID)
        _ = try await coordinator.waitUntilFinished(attempt)
        let tree = try #require(try await store.attempt(attempt)?.worktreeID)
        if let script { try await sh(script, in: service.path(of: try await service.worktree(tree))) }
        return (task.id, attempt, tree)
    }

    /// What a result sheet would show for the task now.
    func shown(_ chain: CandidateChain, _ taskID: TaskID) async throws -> ShownResult {
        let task = try #require(try await store.task(taskID))
        let attemptID = try #require(task.currentAttemptID)
        let attempt = try #require(try await store.attempt(attemptID))
        let treeID = try #require(attempt.worktreeID)
        let tree = try #require(try await store.worktree(treeID))
        return ShownResult(
            task: taskID, taskVersion: task.version, worktree: tree.id, resultOID: tree.resultOID,
            rejected: tree.rejectedPaths.keys.sorted(), check: try await chain.check(taskID)
        )
    }

    func candidates() async throws -> [CandidateRecord] { try await store.candidates(jobID: job) }

    /// How many merges ran: every build prepares one integration worktree.
    func merges() async throws -> Int { try await store.worktrees().filter { $0.kind == .integration }.count }

    func paths(of commit: String) async throws -> [String] {
        try await sh("git ls-tree -r --name-only \(commit)").split(separator: "\n").map(String.init)
    }

    /// Commits `script` on top of the integration state (outside the user's branch) and moves
    /// the integration ref there through the journal, as a publication would.
    @discardableResult
    func advanceTarget(_ script: String) async throws -> String {
        let old = try #require(try await store.integrationTip(job: job))
        let new = try await sh("git checkout -q --detach \(old) && \(script) && git add -A && git commit -q -m side && git rev-parse HEAD && git checkout -q main")
        try await moveTarget(to: new)
        return new
    }

    func moveTarget(to new: String) async throws {
        let old = try #require(try await store.integrationTip(job: job))
        let repository = try await service.attach(project)
        let operation = try await store.prepareRefUpdate(projectID: project, worktreeID: nil, ref: integrationRef, expectedOld: old, desiredNew: new)
        try await git.updateRef(integrationRef, to: new, expectedOld: old, in: repository)
        try await store.completeGitOperation(operation, as: .applied)
    }

    /// A new store and services on the same database, recovered as at app start; nothing streams.
    mutating func restart() async throws {
        let clock = self.clock
        await store.close()
        store = try Store(path: storePath, clock: { clock.now })
        service = WorkspaceService(store: store, git: git, layout: layout)
        coordinator = RunCoordinator(store: store, adapters: adapters)
        integration = IntegrationService(store: store, workspace: service, git: git, coordinator: coordinator)
        _ = try await coordinator.bootstrap()
        _ = try await integration.recover()
    }

    /// Runs the confirmed profile on the candidate: it moves on to `reviewing`.
    func passTests(_ candidate: CandidateID) async throws {
        let profile = try await store.confirmedTestProfile(project: project, arguments: ["-c", "exit 0"])
        try await integration.runTests(candidate, profile: profile)
    }

    /// Builds A's candidate through the chain and passes its tests: the candidate is reviewing.
    func reviewingCandidate(_ chain: CandidateChain) async throws -> CandidateRecord {
        try await activate([planTask("A", writes: ["src/A"])])
        _ = try await runPlanned("A", "mkdir -p src/A && echo x > src/A/f")
        let report = await chain.step()
        let id = try #require(report.built.first)
        try await passTests(id)
        let candidate = try #require(try await store.candidate(id))
        #expect(candidate.state == .reviewing)
        return candidate
    }
}

@Suite struct CandidateChainTests {
    // 1
    @Test func noSealWhileTheStreamIsLiveSealedOnceItEnds() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, _, tree) = try await h.runPlanned("A", "mkdir -p src/A && echo x > src/A/f")
        let flag = StreamFlag(true)
        let chain = h.chain(streaming: { _ in flag.live })
        var report = await chain.step()
        #expect(report.sealed.isEmpty && report.built.isEmpty)
        #expect(try await h.store.worktree(tree)?.sealStatus == nil)
        #expect(try await chain.check(task) == .awaitingSeal)
        flag.set(false)
        report = await chain.step()
        #expect(report.sealed == [tree])
        #expect(try await h.store.worktree(tree)?.state == .frozen)
    }

    // 2
    @Test func aWriteInsideTheAreaIsSealedAndBuilt() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, _, tree) = try await h.runPlanned("A", "mkdir -p src/A && echo x > src/A/f")
        let chain = h.chain()
        let report = await chain.step()
        #expect(report.sealed == [tree])
        let id = try #require(report.built.first)
        #expect(report.issues.isEmpty)
        let candidate = try #require(try await h.store.candidate(id))
        let oid = try #require(candidate.candidateOID)
        #expect(try await h.store.task(task)?.state == .verifying)
        #expect(try await h.sh("git rev-parse refs/kaiorx/candidates/\(id.uuidString)") == oid)
        #expect(try await h.paths(of: oid).contains("src/A/f"))
        #expect(try await chain.check(task) == .candidate(id))
        // A second pass changes nothing.
        let again = await chain.step()
        #expect(again.built.isEmpty && again.sealed.isEmpty)
        #expect(try await h.candidates().count == 1)
    }

    // 3
    @Test func aWriteOutsideTheAreaNeedsConfirmation() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, _, tree) = try await h.runPlanned("A", "mkdir -p src/A docs && echo x > src/A/f && echo y > docs/g")
        let chain = h.chain()
        let report = await chain.step()
        #expect(report.sealed == [tree] && report.built.isEmpty)
        let result = try #require(try await h.store.worktree(tree)?.resultOID)
        #expect(try await chain.check(task) == .undeclared(resultOID: result, rejected: ["docs/g": RejectionReason.outsideAllowedPaths.rawValue]))
        _ = await chain.step()
        #expect(try await h.candidates().isEmpty)

        let shown = try await h.shown(chain, task)
        var stale = shown
        stale.rejected = []
        await #expect(throws: ChainError.shownStateChanged) { _ = try await chain.buildConfirmed(stale) }
        stale = shown
        stale.taskVersion += 1
        await #expect(throws: ChainError.shownStateChanged) { _ = try await chain.buildConfirmed(stale) }
        stale = shown
        stale.check = .buildable(resultOID: result)
        await #expect(throws: ChainError.shownStateChanged) { _ = try await chain.buildConfirmed(stale) }

        guard case .built(let candidate) = try await chain.buildConfirmed(shown) else { Issue.record("not built"); return }
        let paths = try await h.paths(of: try #require(candidate.candidateOID))
        #expect(paths.contains("src/A/f") && !paths.contains("docs/g"))
        #expect(try await h.store.task(task)?.state == .verifying)
    }

    // 3b: owner decision 3, every task with a rejected path needs the confirmation.
    @Test func aTaskOutsideAPlanAlsoNeedsConfirmation() async throws {
        let h = try await ChainHarness()
        try await h.store.execute(Command(.transitionJob(id: h.job, to: .planned, expectedVersion: 1, reason: nil)))
        try await h.store.execute(Command(.transitionJob(id: h.job, to: .active, expectedVersion: 2, reason: nil)))
        _ = try await h.service.openIntegration(h.job, baseRevision: "main")
        let task = TaskID()
        try await h.store.execute(Command(.createTask(id: task, jobID: h.job, title: "Frei")))
        try await h.store.execute(Command(.transitionTask(id: task, to: .ready, expectedVersion: 1)))
        let attempt = AttemptID()
        try await h.store.execute(Command(.reserveAttempt(AttemptReservation(
            attemptID: attempt, taskID: task, projectID: h.project, role: .author, provider: .claude, mode: .automatic, model: "m", specDigest: "d"
        ))))
        let tip = try #require(try await h.store.integrationTip(job: h.job))
        let tree = try await h.service.prepareWorktree(projectID: h.project, attemptID: attempt, kind: .author, base: tip)
        try await h.sh("echo b > b.txt && ln -s b.txt link", in: h.service.path(of: tree))
        let version = try #require(try await h.store.attempt(attempt)).version
        try await h.store.execute(Command(.transitionAttempt(id: attempt, to: .starting, expectedVersion: version, errorClass: nil)))
        _ = try await h.store.ingest(.started(sessionID: "s"), attemptID: attempt)
        _ = try await h.store.ingest(.completed(.succeeded), attemptID: attempt)

        let chain = h.chain()
        let report = await chain.step()
        #expect(report.sealed == [tree.id] && report.built.isEmpty)
        guard case .undeclared(_, let rejected) = try await chain.check(task) else { Issue.record("not undeclared"); return }
        #expect(rejected == ["link": RejectionReason.symlink.rawValue])
    }

    // 4
    @Test func anEmptyResultIsOnlyAcceptedExplicitly() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, _, tree) = try await h.runPlanned("A", nil)
        let chain = h.chain()
        for _ in 0..<3 { _ = await chain.step() }
        #expect(try await h.store.worktree(tree)?.sealStatus == .empty)
        #expect(try await chain.check(task) == .empty)
        #expect(try await h.store.task(task)?.state == .resultReady)
        #expect(try await h.merges() == 0)

        let shown = try await h.shown(chain, task)
        var stale = shown
        stale.check = .contained(tip: "x")
        await #expect(throws: ChainError.shownStateChanged) { try await chain.acceptEmpty(stale) }
        try await chain.acceptEmpty(shown)
        #expect(try await h.store.task(task)?.state == .integrated)
    }

    // 5
    @Test func anAlreadyContainedResultRunsNoMerge() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, _, tree) = try await h.runPlanned("A", "mkdir -p src/A && echo x > src/A/f")
        _ = try await h.service.seal(tree, allowedPrefixes: ["src/A"], message: "r")
        let result = try #require(try await h.store.worktree(tree)?.resultOID)
        try await h.moveTarget(to: result)
        let chain = h.chain()
        let report = await chain.step()
        #expect(report.built.isEmpty && report.issues.isEmpty)
        #expect(try await h.merges() == 0)
        #expect(try await chain.check(task) == .contained(tip: result))
        try await chain.acceptEmpty(try await h.shown(chain, task))
        #expect(try await h.store.task(task)?.state == .integrated)
    }

    // 6
    @Test func aRejectedOnlyResultIsDiscardedAndTheAuthorRunsAgain() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, _, _) = try await h.runPlanned("A", "mkdir -p docs && echo y > docs/g")
        let chain = h.chain()
        _ = await chain.step()
        #expect(try await chain.check(task) == .rejectedOnly(rejected: ["docs/g": RejectionReason.outsideAllowedPaths.rawValue]))
        #expect(try await h.candidates().isEmpty)
        // Discard (owner decision 5): grant first, then back to the author.
        try await h.scheduler().grant(task, actor: "user")
        let version = try #require(try await h.store.task(task)).version
        try await h.store.execute(Command(.transitionTask(id: task, to: .needsChanges, expectedVersion: version)))
        let tick = try await h.scheduler().tick()
        #expect(tick.reserved.count == 1)
        #expect(try await h.store.attempts(taskID: task).filter { $0.role == .author }.count == 2)
        #expect(try await chain.check(task) == .notApplicable)
    }

    // 7
    @Test func aHeldTaskIsSealedButBuiltOnlyAfterRelease() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, _, tree) = try await h.runPlanned("A", "mkdir -p src/A && echo x > src/A/f")
        var version = try #require(try await h.store.task(task)).version
        try await h.store.execute(Command(.transitionTask(id: task, to: .blocked, expectedVersion: version)))
        let chain = h.chain()
        var report = await chain.step()
        #expect(report.sealed == [tree] && report.built.isEmpty)
        #expect(try await h.merges() == 0)
        guard case .buildable = try await chain.check(task) else { Issue.record("not buildable"); return }
        version = try #require(try await h.store.task(task)).version
        try await h.store.execute(Command(.transitionTask(id: task, to: .resultReady, expectedVersion: version)))
        report = await chain.step()
        #expect(report.built.count == 1)
        #expect(try await h.store.task(task)?.state == .verifying)
    }

    // 8
    @Test func afterARestartARecordedSuccessIsSealed() async throws {
        var h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, _, tree) = try await h.runPlanned("A", "mkdir -p src/A && echo x > src/A/f")
        try await h.restart()
        let chain = h.chain()
        let report = await chain.step()
        #expect(report.sealed == [tree])
        #expect(report.built.count == 1)
        #expect(try await h.store.task(task)?.state == .verifying)
    }

    // 9
    @Test func theWriteAreaComesFromTheAttemptsPlanRevision() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let current = try #require(try await h.store.jobs().first { $0.id == h.job }?.currentPlanID)
        // A revision with another area for A, never accepted: the attempt's revision, not the
        // job's current one, decides what the author was allowed to write.
        let (other, _) = try await h.store.proposePlan(
            job: h.job, draft: PlanDraft(tasks: [planTask("A", writes: ["docs"])]), createdBy: .user, expectedCurrent: current
        )
        let (task, attempt, tree) = try await h.runPlanned("A", "mkdir -p src/A docs && echo x > src/A/f && echo y > docs/g")
        #expect(try await h.store.attempt(attempt)?.planID == current)
        try await h.store.chainTestRun("UPDATE attempt SET plan_id = ? WHERE id = ?", [.text(other.id.uuidString), .text(attempt.uuidString)])
        let chain = h.chain()
        _ = await chain.step()
        #expect(try await h.store.worktree(tree)?.rejectedPaths == ["src/A/f": RejectionReason.outsideAllowedPaths.rawValue])
        guard case .undeclared = try await chain.check(task) else { Issue.record("not undeclared"); return }
    }

    // 10
    @Test func aMissingPlanTaskIsNeverSealed() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let current = try #require(try await h.store.jobs().first { $0.id == h.job }?.currentPlanID)
        let (other, _) = try await h.store.proposePlan(
            job: h.job, draft: PlanDraft(tasks: [planTask("Z")]), createdBy: .user, expectedCurrent: current
        )
        let (task, attempt, tree) = try await h.runPlanned("A", "mkdir -p src/A && echo x > src/A/f")
        try await h.store.chainTestRun("UPDATE attempt SET plan_id = ? WHERE id = ?", [.text(other.id.uuidString), .text(attempt.uuidString)])
        let chain = h.chain()
        let report = await chain.step()
        #expect(report.sealed.isEmpty)
        #expect(report.issues[task] == .planTaskMissing)
        #expect(await chain.issue(task) == .planTaskMissing)
        #expect(try await chain.check(task) == .planTaskMissing)
        #expect(try await h.store.worktree(tree)?.sealStatus == nil)
        #expect(try await h.store.worktree(tree)?.state == .ready)
    }

    // 11
    @Test func aConflictIsResolvedWithTheResultsSide() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, _, _) = try await h.runPlanned("A", "mkdir -p src/A && echo ergebnis > src/A/f")
        try await h.advanceTarget("mkdir -p src/A && echo ziel > src/A/f")
        let chain = h.chain()
        let report = await chain.step()
        let id = try #require(report.conflicted.first)
        #expect(try await h.store.task(task)?.state == .conflict)
        let entries = try await chain.conflictDetails(id)
        #expect(entries.map(\.path) == ["src/A/f"])
        let candidate = try #require(try await h.store.candidate(id))
        let shown = ShownConflicts(candidate: id, version: candidate.version, paths: candidate.conflicts)
        await #expect(throws: ChainError.shownStateChanged) {
            _ = try await chain.resolveConflicts(ShownConflicts(candidate: id, version: candidate.version + 1, paths: candidate.conflicts), ["src/A/f": .theirs])
        }
        let built = try await chain.resolveConflicts(shown, ["src/A/f": .theirs])
        #expect(built.state == .built)
        #expect(try await h.store.task(task)?.state == .verifying)
        let oid = try #require(built.candidateOID)
        #expect(try await h.sh("git show \(oid):src/A/f") == "ergebnis")
    }

    // 12
    @Test func aFinishedReviewIsCollectedAndTheCandidateAccepted() async throws {
        let h = try await ChainHarness()
        let chain = h.chain()
        let candidate = try await h.reviewingCandidate(chain)
        let options = try await chain.reviewOptions(candidate.id)
        let fake = try #require(options.first { $0.provider == .fake })
        #expect(fake.blockers.isEmpty)
        #expect(fake.criteria == "- A erledigt")
        #expect(fake.accountID == h.reviewerAccount && fake.model == "r")
        #expect(fake.candidateOID == candidate.candidateOID && fake.candidateVersion == candidate.version)
        let attempt = try await chain.startReview(fake, candidate: candidate.id)
        _ = try await h.coordinator.waitUntilFinished(attempt)
        let report = await chain.step()
        #expect(report.collected.count == 1)
        #expect(try await h.store.candidate(candidate.id)?.state == .accepted)
        let taskID = try #require(candidate.taskID)
        #expect(try await h.store.task(taskID)?.state == .awaitingMerge)
        // Collected once.
        #expect(await chain.step().collected.isEmpty)
    }

    // 13
    @Test func aReviewIsCollectedAfterARestart() async throws {
        var h = try await ChainHarness()
        let candidate = try await h.reviewingCandidate(h.chain())
        let fake = try #require(try await h.chain().reviewOptions(candidate.id).first { $0.provider == .fake })
        let attempt = try await h.chain().startReview(fake, candidate: candidate.id)
        _ = try await h.coordinator.waitUntilFinished(attempt)
        try await h.restart()
        let report = await h.chain().step()
        #expect(report.collected.count == 1)
        #expect(try await h.store.candidate(candidate.id)?.state == .accepted)
    }

    // 14
    @Test func aReviewerOfAnOlderCommitIsNotCollected() async throws {
        let h = try await ChainHarness()
        let chain = h.chain()
        let first = try await h.reviewingCandidate(chain)
        let fake = try #require(try await chain.reviewOptions(first.id).first { $0.provider == .fake })
        let attempt = try await chain.startReview(fake, candidate: first.id)
        _ = try await h.coordinator.waitUntilFinished(attempt)
        // The target moves before the review is collected: the candidate is superseded and rebuilt.
        try await h.advanceTarget("echo z > z.txt")
        _ = try await h.store.transitionCandidate(first.id, to: .superseded, reason: "target moved", onlyFrom: [.reviewing])
        let rebuilt = await chain.step()
        let second = try #require(rebuilt.built.first)
        #expect(rebuilt.collected.isEmpty)
        try await h.passTests(second)
        let report = await chain.step()
        #expect(report.collected.isEmpty)
        #expect(try await h.store.reviews(candidate: second).isEmpty)
        #expect(try await h.store.reviews(candidate: first.id).isEmpty)
        #expect(try await h.store.candidate(second)?.state == .reviewing)
    }

    // 15
    @Test func aFailedReviewersWorktreeIsRemoved() async throws {
        let h = try await ChainHarness()
        let chain = h.chain()
        let candidate = try await h.reviewingCandidate(chain)
        h.reviewer.set(.crash)
        let fake = try #require(try await chain.reviewOptions(candidate.id).first { $0.provider == .fake })
        let attempt = try await chain.startReview(fake, candidate: candidate.id)
        _ = try await h.coordinator.waitUntilFinished(attempt)
        #expect(try await h.store.attempt(attempt)?.state == .failed)
        let tree = try #require(try await h.store.worktrees().first { $0.attemptID == attempt && $0.kind == .reviewer })
        #expect(tree.state != .removed)
        let report = await chain.step()
        #expect(report.removedReviewerTrees == [tree.id])
        #expect(report.collected.isEmpty)
        #expect(try await h.store.worktree(tree.id)?.state == .removed)
        // A new review can be started.
        #expect(try await chain.reviewOptions(candidate.id).first { $0.provider == .fake }?.blockers == [])
    }

    // 16
    @Test func aSupersededCandidateIsRebuiltWithTheAcceptedPaths() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, _, _) = try await h.runPlanned("A", "mkdir -p src/A docs && echo x > src/A/f && echo y > docs/g")
        let chain = h.chain()
        _ = await chain.step()
        guard case .built(let first) = try await chain.buildConfirmed(try await h.shown(chain, task)) else { Issue.record("not built"); return }
        let tip = try await h.advanceTarget("echo z > z.txt")
        _ = try await h.store.transitionCandidate(first.id, to: .superseded, reason: "target moved", onlyFrom: [.built])
        let report = await chain.step()
        #expect(report.issues.isEmpty)
        let id = try #require(report.built.first)
        let second = try #require(try await h.store.candidate(id))
        #expect(second.previousTargetOID == tip)
        #expect(second.resultOID == first.resultOID)
        let paths = try await h.paths(of: try #require(second.candidateOID))
        #expect(paths.contains("src/A/f") && paths.contains("z.txt") && !paths.contains("docs/g"))
        #expect(try await h.store.task(task)?.state == .verifying)
        #expect(await chain.step().built.isEmpty)
    }

    // 17
    @Test func aPersistentBuildFailureBacksOff() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, _, _) = try await h.runPlanned("A", "mkdir -p src/A/x && echo r > src/A/x/f")
        // A file where the result has a folder: a conflict KAIORX does not offer for resolution.
        try await h.advanceTarget("mkdir -p src/A && echo t > src/A/x")
        let chain = h.chain()
        let first = await chain.step()
        guard case .buildFailed? = first.issues[task] else { Issue.record("no build failure: \(first)"); return }
        #expect(try await h.merges() == 1)
        for _ in 0..<5 { _ = await chain.step() }
        #expect(try await h.merges() == 1)
        guard case .buildFailed? = await chain.issue(task) else { Issue.record("issue cleared"); return }
        h.clock.advance(5_000)
        _ = await chain.step()
        #expect(try await h.merges() == 2)
        // The second failure waits 10 s; retrying clears that at once.
        h.clock.advance(5_000)
        _ = await chain.step()
        #expect(try await h.merges() == 2)
        await chain.retryBuild(task)
        #expect(await chain.issue(task) == nil)
        _ = await chain.step()
        #expect(try await h.merges() == 3)
        #expect(try await h.candidates().isEmpty)
    }

    // 18
    @Test func twoConcurrentStepsBuildOneCandidate() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        _ = try await h.runPlanned("A", "mkdir -p src/A && echo x > src/A/f")
        let chain = h.chain()
        async let one = chain.step()
        async let two = chain.step()
        let (a, b) = await (one, two)
        #expect(a.issues.isEmpty && b.issues.isEmpty)
        #expect(a.sealed.count + b.sealed.count == 1)
        _ = await chain.step()
        #expect(try await h.candidates().count == 1)
        #expect(try await h.merges() == 1)
    }

    // 19
    @Test func reviewOptionsCarryTypedBlockers() async throws {
        let h = try await ChainHarness(extraProviders: [.codex])
        let chain = h.chain(limits: SchedulerLimits(global: 3, perAccount: 1))
        let candidate = try await h.reviewingCandidate(chain)
        let before = try await chain.reviewOptions(candidate.id)
        #expect(before.map(\.provider) == [.claude, .codex, .fake])
        #expect(before[0].blockers.contains(.sameProviderAsAuthor))
        #expect(before[1].blockers.contains(.noReviewerConsent) && before[1].blockers.contains(.noModelProfile))
        #expect(before[2].blockers.isEmpty)

        h.reviewer.set(.hang)
        let attempt = try await chain.startReview(before[2], candidate: candidate.id)
        let options = try await chain.reviewOptions(candidate.id)
        let fake = try #require(options.first { $0.provider == .fake })
        #expect(fake.blockers.contains(.reviewerOpen(attempt)))
        #expect(fake.blockers.contains(.slotsFull(global: false)))
        let tight = try await h.chain(limits: SchedulerLimits(global: 1, perAccount: 5)).reviewOptions(candidate.id)
        #expect(tight.first { $0.provider == .fake }?.blockers.contains(.slotsFull(global: true)) == true)
        // The option the sheet showed before is no longer what it would show.
        await #expect(throws: ChainError.shownStateChanged) { _ = try await chain.startReview(before[2], candidate: candidate.id) }
        let taskID = try #require(candidate.taskID)
        await #expect(throws: StoreError.activeReviewerExists(taskID: taskID, attemptID: attempt)) {
            _ = try await chain.startReview(fake, candidate: candidate.id)
        }
        let claude = try #require(options.first { $0.provider == .claude })
        await #expect(throws: IntegrationError.reviewerNotIndependent(.claude)) {
            _ = try await chain.startReview(claude, candidate: candidate.id)
        }
        try await h.coordinator.cancel(attempt, reason: "test")
        _ = try await h.coordinator.waitUntilFinished(attempt)
    }

    // 20
    @Test func theGateIsNotConsultedForBlocking() async throws {
        let h = try await ChainHarness()
        let gate = CountingGate(automatic: false)
        let chain = h.chain(gate: gate)
        let candidate = try await h.reviewingCandidate(chain)
        // The host-only steps never ask the gate.
        #expect(gate.count == 0)
        let fake = try #require(try await chain.reviewOptions(candidate.id).first { $0.provider == .fake })
        #expect(fake.blockers.isEmpty)
        #expect(fake.automationNote == AutomationBlock.notPermitted.detail(for: .fake))
        let asked = gate.count
        let attempt = try await chain.startReview(fake, candidate: candidate.id)
        _ = try await h.coordinator.waitUntilFinished(attempt)
        _ = await chain.step()
        #expect(try await h.store.candidate(candidate.id)?.state == .accepted)
        // `startReview` re-reads the options (information only); `step` asked nothing.
        #expect(gate.count == asked * 2)
    }
}
