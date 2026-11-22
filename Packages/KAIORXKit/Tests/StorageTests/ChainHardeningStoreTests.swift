import Domain
import Foundation
import Testing
@testable import Storage

extension Store {
    /// The tasks `reserveScheduled` treats as holding their write area.
    func areaHolderIDs(job: JobID) throws -> Set<TaskID> {
        Set(try areaHolders(try connection(), job: job).map(\.id))
    }

    /// A single integer the query returns (a row count).
    func testCount(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        Int(try connection().query(sql, values) { $0.int(0) }.first ?? 0)
    }
}

/// Store checks the candidate chain relies on (ADR 0011 §5, ADR 0005 §6).
@Suite struct ChainHardeningStoreTests {
    static let candidateOID = String(repeating: "c", count: 40)
    static let olderOID = String(repeating: "b", count: 40)

    /// An author attempt that succeeded: the seeded task waits with its result (`resultReady`).
    func authorResult(_ store: Store, _ seed: Seed) async throws -> AttemptID {
        let attempt = AttemptID()
        var r = reservation(seed, attempt: attempt)
        r.provider = .claude
        try await store.execute(Command(.reserveAttempt(r)))
        try await transition(store, attempt, to: .starting)
        _ = try await store.ingest(.started(sessionID: "s"), attemptID: attempt)
        _ = try await store.ingest(.completed(.succeeded), attemptID: attempt)
        #expect(try await store.task(seed.task)?.state == .resultReady)
        return attempt
    }

    func candidate(_ store: Store, _ seed: Seed, author: AttemptID, oid: String?) async throws -> CandidateRecord {
        try await store.createCandidate(CandidateDraft(
            jobID: seed.job, taskID: seed.task, kind: .implementation, authorAttemptID: author, resultOID: String(repeating: "a", count: 40),
            previousTargetOID: String(repeating: "0", count: 39) + "1", candidateOID: oid, targetRef: "refs/kaiorx/integrations/\(seed.job.uuidString)",
            worktreeID: nil, conflicts: oid == nil ? ["src/a.swift"] : []
        ))
    }

    /// A succeeded reviewer attempt of the seeded task whose worktree was prepared at `base`
    /// (registered first, then linked, as `IntegrationService.startReview` does).
    func reviewer(_ store: Store, _ seed: Seed, base: String?) async throws -> AttemptID {
        let attempt = AttemptID()
        try await store.execute(Command(.reserveAttempt(reservation(seed, attempt: attempt, role: .reviewer))))
        if let base {
            let id = WorktreeID()
            let (_, operation) = try await store.registerWorktree(WorktreeRegistration(
                id: id, projectID: seed.project, attemptID: nil, pathToken: "\(seed.project.uuidString)/\(id.uuidString)",
                baseOID: base, kind: .reviewer, ownerNonce: String(repeating: "f", count: 16)
            ))
            try await store.completeGitOperation(operation, as: .applied, effects: GitOperationEffects(worktreeState: .ready))
            try await store.linkWorktree(id, to: attempt)
        }
        try await transition(store, attempt, to: .starting)
        _ = try await store.ingest(.started(sessionID: "r"), attemptID: attempt)
        _ = try await store.ingest(.completed(.succeeded), attemptID: attempt)
        return attempt
    }

    func record(_ store: Store, _ candidate: CandidateRecord, reviewer: AttemptID) async throws -> ReviewRecord {
        try await store.recordReview(
            candidate: candidate.id, oid: Self.candidateOID, reviewerAttemptID: reviewer, origin: .provider, reviewerProvider: .fake,
            status: .approved, summary: "ok", findings: []
        )
    }

    @Test func aReviewIsRecordedOnlyForTheCommitItsWorktreeWasPreparedAt() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let author = try await authorResult(store, seed)
        let candidate = try await candidate(store, seed, author: author, oid: Self.candidateOID)

        // A reviewer of an older candidate of the same task, same provider, finished: refused.
        let older = try await reviewer(store, seed, base: Self.olderOID)
        await #expect(throws: IntegrationStoreError.reviewAttemptNotUsable(older)) { _ = try await record(store, candidate, reviewer: older) }
        // Without any worktree there is nothing that binds it to the commit: refused as well.
        let unbound = try await reviewer(store, seed, base: nil)
        await #expect(throws: IntegrationStoreError.reviewAttemptNotUsable(unbound)) { _ = try await record(store, candidate, reviewer: unbound) }
        #expect(try await store.reviews(candidate: candidate.id).isEmpty)

        // The reviewer prepared at exactly the candidate commit counts.
        let current = try await reviewer(store, seed, base: Self.candidateOID)
        let review = try await record(store, candidate, reviewer: current)
        #expect(review.reviewerAttemptID == current && review.candidateOID == Self.candidateOID)
        // An imported review has no reviewer attempt and is not affected.
        _ = try await store.recordReview(
            candidate: candidate.id, oid: Self.candidateOID, reviewerAttemptID: nil, origin: .userImported, reviewerProvider: nil,
            status: .approved, summary: "von Hand", findings: []
        )
        #expect(try await store.reviews(candidate: candidate.id).count == 2)
    }

    @Test func aHeldConflictKeepsItsWriteArea() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let author = try await authorResult(store, seed)
        let conflicted = try await candidate(store, seed, author: author, oid: nil)
        #expect(conflicted.state == .conflicted)
        #expect(try await store.task(seed.task)?.state == .conflict)
        #expect(try await store.areaHolderIDs(job: seed.job) == [seed.task])

        // The user holds the conflicted task: it still holds its area (ADR 0005 §6). The hold
        // keeps the conflict's own resume stage (`verifying`; the schema allows no `conflict`
        // there), so the area stays held whichever of the two the row names.
        try await moveTask(store, seed.task, to: .blocked)
        let held = try #require(try await store.task(seed.task))
        #expect(held.state == .blocked && held.resumeState == .verifying)
        #expect(try await store.areaHolderIDs(job: seed.job) == [seed.task])
        // Ended, it lets go.
        try await moveTask(store, seed.task, to: .cancelled)
        #expect(try await store.areaHolderIDs(job: seed.job).isEmpty)
    }

    @Test func activeAttemptsAreCountedGloballyAndPerAccount() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let account = try await store.registerAccount(provider: .fake, identity: "a")
        var r = reservation(seed)
        r.accountID = account
        try await store.execute(Command(.reserveAttempt(r)))
        #expect(try await store.activeAttemptCount(account: nil) == 1)
        #expect(try await store.activeAttemptCount(account: account) == 1)
        #expect(try await store.activeAttemptCount(account: AccountID()) == 0)
    }

    // MARK: Atomic discard (ADR 0011 §7)

    func grants(_ store: Store, _ task: TaskID) async throws -> [DecisionRecord] {
        try await store.decisions(task: task).filter { $0.rule == Store.userGrantRule }
    }

    func lastSeq(_ store: Store) async throws -> Int64 {
        try await store.events(after: 0, limit: 100_000).last?.seq ?? 0
    }

    /// Simulates a crash between the grant and the move: the task's move to `needsChanges` fails.
    static let failingMove = """
        CREATE TEMP TRIGGER failing_move BEFORE UPDATE OF state ON task WHEN NEW.state = 'needsChanges'
        BEGIN SELECT RAISE(ABORT, 'crash'); END
        """

    @Test func discardGrantsAndSendsBackInOneTransaction() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        _ = try await authorResult(store, seed)
        let before = try #require(try await store.task(seed.task))
        let from = try await lastSeq(store)

        let decision = try await store.discardResult(task: seed.task, expectedVersion: before.version, actor: "user")
        let after = try #require(try await store.task(seed.task))
        #expect(after.state == .needsChanges && after.version == before.version + 1)
        let grants = try await grants(store, seed.task)
        #expect(grants.count == 1)
        let grant = try #require(grants.first)
        #expect(grant.id == decision && grant.outcome == "granted" && grant.actor == "user")
        #expect(grant.evidence["afterOrdinal"] == "1" && grant.remainingAttempts == 3)
        let events = try await store.events(after: from, limit: 100).filter { $0.taskID == seed.task }
        let granted = try #require(events.first { $0.kind == .policyDecided }?.seq)
        let sentBack = try #require(events.first { $0.kind == .taskStateChanged }?.seq)
        #expect(granted < sentBack)
    }

    @Test func aStaleDiscardWritesNothing() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        _ = try await authorResult(store, seed)
        let task = try #require(try await store.task(seed.task))
        let seq = try await lastSeq(store)
        await #expect {
            try await store.discardResult(task: seed.task, expectedVersion: task.version - 1, actor: "user")
        } throws: { ($0 as? StoreError)?.isVersionConflict == true }
        #expect(try await grants(store, seed.task).isEmpty)
        #expect(try await lastSeq(store) == seq)
        #expect(try await store.task(seed.task) == task)
    }

    @Test func aDiscardOutsideResultReadyWritesNothing() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        _ = try await authorResult(store, seed)
        try await moveTask(store, seed.task, to: .blocked)
        let held = try #require(try await store.task(seed.task))
        let seq = try await lastSeq(store)
        await #expect(throws: DomainError.invalidTransition(entity: "task", from: "blocked", to: "needsChanges")) {
            try await store.discardResult(task: seed.task, expectedVersion: held.version, actor: "user")
        }
        #expect(try await grants(store, seed.task).isEmpty)
        #expect(try await lastSeq(store) == seq)
        #expect(try await store.task(seed.task) == held)
    }

    @Test func aFailedMoveRollsBackTheGrant() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        _ = try await authorResult(store, seed)
        let task = try #require(try await store.task(seed.task))
        let seq = try await lastSeq(store)
        try await store.rawExecute(Self.failingMove)
        await #expect(throws: (any Error).self) {
            try await store.discardResult(task: seed.task, expectedVersion: task.version, actor: "user")
        }
        #expect(try await grants(store, seed.task).isEmpty)
        #expect(try await store.events(after: seq, limit: 100).isEmpty)
        #expect(try await store.task(seed.task) == task)

        try await store.rawExecute("DROP TRIGGER failing_move")
        try await store.discardResult(task: seed.task, expectedVersion: task.version, actor: "user")
        #expect(try await grants(store, seed.task).count == 1)
        #expect(try await store.task(seed.task)?.state == .needsChanges)
    }

    @Test func grantAttemptsIsOneTransaction() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        _ = try await authorResult(store, seed)
        try await store.setWaitReason(seed.task, WaitReason(.userDecision))
        let waiting = try #require(try await store.task(seed.task))
        #expect(waiting.waitReason != nil)

        // Clearing the wait reason fails: the decision is not kept either.
        try await store.rawExecute("""
            CREATE TEMP TRIGGER failing_clear BEFORE UPDATE OF wait_reason ON task WHEN NEW.wait_reason IS NULL
            BEGIN SELECT RAISE(ABORT, 'crash'); END
            """)
        await #expect(throws: (any Error).self) { try await store.grantAttempts(task: seed.task, tier: .intensive, actor: "user") }
        #expect(try await grants(store, seed.task).isEmpty)
        #expect(try await store.task(seed.task) == waiting)
        try await store.rawExecute("DROP TRIGGER failing_clear")

        let from = try await lastSeq(store)
        try await store.grantAttempts(task: seed.task, tier: .intensive, actor: "user")
        let after = try #require(try await store.task(seed.task))
        #expect(after.waitReason == nil && after.version == waiting.version && after.state == waiting.state)
        let grant = try #require(try await grants(store, seed.task).first)
        #expect(grant.evidence == ["afterOrdinal": "1", "tier": CapabilityTier.intensive.rawValue] && grant.outcome == "granted")
        let kinds = try await store.events(after: from, limit: 100).map(\.kind)
        #expect(kinds == [.policyDecided, .taskReady])
    }
}
