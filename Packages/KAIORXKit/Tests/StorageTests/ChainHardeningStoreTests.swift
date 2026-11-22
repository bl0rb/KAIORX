import Domain
import Foundation
import Testing
@testable import Storage

extension Store {
    /// The tasks `reserveScheduled` treats as holding their write area.
    func areaHolderIDs(job: JobID) throws -> Set<TaskID> {
        Set(try areaHolders(try connection(), job: job).map(\.id))
    }

    /// Changes a row outside every flow, to put the store into a state the API cannot reach.
    func chainHardeningRun(_ sql: String, _ values: [SQLValue] = []) throws {
        try connection().run(sql, values)
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

    /// ADR 0011 §10: a superseded candidate's result the integration state already contains is
    /// integrated only by the user, only past a superseded candidate of exactly the current
    /// result, and only at the integration state the store knows.
    @Test func aContainedResultIsAcceptedOnlyPastASupersededCandidate() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let tip = String(repeating: "d", count: 40)
        try await store.chainHardeningRun("UPDATE job SET base_oid = ? WHERE id = ?", [.text(tip), .text(seed.job.uuidString)])
        #expect(try await store.integrationTip(job: seed.job) == tip)
        func accept(_ task: TaskID, author: AttemptID, oid: String = tip, version: Int? = nil) async throws {
            let current = try #require(try await store.task(task)).version
            try await store.acceptContainedResult(task, expectedVersion: version ?? current, authorAttempt: author, integratedOID: oid)
        }
        func refused(_ task: TaskID, author: AttemptID, oid: String = tip) async throws {
            let state = try #require(try await store.task(task)).state
            await #expect(throws: PlanningError.emptyResultNotAcceptable(task, state)) { try await accept(task, author: author, oid: oid) }
        }

        // From `verifying`: still the result, an open candidate, then a superseded one.
        let author = try await authorResult(store, seed)
        try await refused(seed.task, author: author)
        let first = try await candidate(store, seed, author: author, oid: Self.candidateOID)
        try await refused(seed.task, author: author)
        _ = try await store.transitionCandidate(first.id, to: .superseded, reason: "target moved", onlyFrom: [.built])
        #expect(try await store.task(seed.task)?.state == .verifying)
        try await refused(seed.task, author: author, oid: String(repeating: "e", count: 40))
        try await refused(seed.task, author: AttemptID())
        let version = try #require(try await store.task(seed.task)).version
        await #expect(throws: StoreError.versionConflict(entity: "task", id: seed.task.uuidString, expected: version - 1, actual: version)) {
            try await accept(seed.task, author: author, version: version - 1)
        }
        // Held, it is refused; released, it is accepted through `awaitingMerge`.
        try await moveTask(store, seed.task, to: .blocked)
        try await refused(seed.task, author: author)
        try await moveTask(store, seed.task, to: .verifying)
        let verifying = try #require(try await store.task(seed.task))
        try await accept(seed.task, author: author)
        let done = try #require(try await store.task(seed.task))
        #expect(done.state == .integrated && done.version == verifying.version + 2 && done.integratedOID == tip)

        // From `awaitingMerge`: one transition.
        let second = Seed(project: seed.project, job: seed.job, task: try await fixture.readyTask(store, job: seed.job))
        let secondAuthor = try await authorResult(store, second)
        let accepted = try await candidate(store, second, author: secondAuthor, oid: Self.candidateOID)
        for (from, to) in [(CandidateState.built, CandidateState.testing), (.testing, .reviewing), (.reviewing, .accepted), (.accepted, .superseded)] {
            _ = try await store.transitionCandidate(accepted.id, to: to, onlyFrom: [from])
        }
        let waiting = try #require(try await store.task(second.task))
        #expect(waiting.state == .awaitingMerge)
        try await accept(second.task, author: secondAuthor)
        let merged = try #require(try await store.task(second.task))
        #expect(merged.state == .integrated && merged.version == waiting.version + 1 && merged.integratedOID == tip)

        // A candidate of the result that ended the chain (rejected, published) refuses it.
        let third = Seed(project: seed.project, job: seed.job, task: try await fixture.readyTask(store, job: seed.job))
        let thirdAuthor = try await authorResult(store, third)
        let rejected = try await candidate(store, third, author: thirdAuthor, oid: Self.candidateOID)
        try await moveTask(store, third.task, to: .blocked)
        _ = try await store.transitionCandidate(rejected.id, to: .rejected, reason: "nein", onlyFrom: [.built])
        try await moveTask(store, third.task, to: .verifying)
        // No superseded candidate at all.
        try await refused(third.task, author: thirdAuthor)
        let superseded = try await candidate(store, third, author: thirdAuthor, oid: Self.candidateOID)
        _ = try await store.transitionCandidate(superseded.id, to: .superseded, reason: "target moved", onlyFrom: [.built])
        try await refused(third.task, author: thirdAuthor)
        try await store.chainHardeningRun("UPDATE candidate SET state = 'published' WHERE id = ?", [.text(rejected.id.uuidString)])
        try await refused(third.task, author: thirdAuthor)
        // Without the ended candidate it is accepted.
        try await store.chainHardeningRun("UPDATE candidate SET state = 'superseded' WHERE id = ?", [.text(rejected.id.uuidString)])
        try await accept(third.task, author: thirdAuthor)
        #expect(try await store.task(third.task)?.state == .integrated)
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
