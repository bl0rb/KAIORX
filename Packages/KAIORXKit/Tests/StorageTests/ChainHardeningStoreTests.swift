import Domain
import Foundation
import Testing
@testable import Storage

extension Store {
    /// The tasks `reserveScheduled` treats as holding their write area.
    func areaHolderIDs(job: JobID) throws -> Set<TaskID> {
        Set(try areaHolders(try connection(), job: job).map(\.id))
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
}
