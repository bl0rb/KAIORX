import Domain
import Foundation
import Synchronization
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workbench

/// The pending decisions reuse a task's result check (Git calls) while nothing it reads changed.
@Suite struct ResultCheckCacheTests {
    final class Counter: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func hit() { value.withLock { $0 += 1 } }
    }

    struct CheckFailed: Error {}

    func state(_ task: TaskID, version: Int = 3, state taskState: TaskState = .resultReady) -> WorkspaceState {
        var state = WorkspaceState()
        state.tasks[task] = TaskRecord(id: task, jobID: JobID(), title: "A", state: taskState, currentAttemptID: nil, version: version, createdAt: 1)
        return state
    }

    @Test func anUnchangedStateChecksOnceAndAChangedKeyChecksAgain() async throws {
        let cache = ResultCheckCache()
        let counter = Counter()
        let task = TaskID()
        func check(_ state: WorkspaceState, tip: String? = "t1", issue: ChainIssue? = nil) async throws -> ResultCheck? {
            try await cache.check(task, key: ResultCheckCache.key(task, in: state, tip: tip, issue: issue)) {
                counter.hit()
                return .buildable(resultOID: "r")
            }
        }
        let base = state(task)
        #expect(try await check(base) == .buildable(resultOID: "r"))
        #expect(try await check(base) == .buildable(resultOID: "r"))
        #expect(counter.count == 1)
        // The integration tip moved.
        _ = try await check(base, tip: "t2")
        #expect(counter.count == 2)
        _ = try await check(base, tip: "t2")
        #expect(counter.count == 2)
        // The driver's issue changed.
        _ = try await check(base, tip: "t2", issue: .buildFailed("x"))
        #expect(counter.count == 3)
        // The task moved on (new version and state).
        _ = try await check(state(task, version: 4, state: .verifying), tip: "t2", issue: .buildFailed("x"))
        #expect(counter.count == 4)
    }

    @Test func aCandidateOrTheResultTreeChangingChecksAgain() async throws {
        let cache = ResultCheckCache()
        let counter = Counter()
        let task = TaskID()
        var current = state(task)
        let attempt = AttemptID()
        let tree = WorktreeID()
        current.tasks[task]?.currentAttemptID = attempt
        current.attempts[attempt] = AttemptRecord(
            id: attempt, taskID: task, role: .author, ordinal: 1, provider: .fake, mode: .automatic, model: "m", effort: nil, state: .succeeded,
            specDigest: "d", sessionHandle: nil, reservedAt: 1, startedAt: 1, endedAt: 2, errorClass: nil, worktreeID: tree, version: 3
        )
        current.worktrees[tree] = WorktreeRecord(
            id: tree, projectID: ProjectID(), attemptID: attempt, pathToken: "p/t", baseOID: "b", kind: .author, ownerNonce: "n",
            state: .ready, resultOID: nil, savedTree: nil, version: 1, createdAt: 1
        )
        func check() async throws {
            _ = try await cache.check(task, key: ResultCheckCache.key(task, in: current, tip: "t", issue: nil)) {
                counter.hit()
                return .awaitingSeal
            }
        }
        try await check()
        try await check()
        #expect(counter.count == 1)
        // Sealed: state, version, seal status and result commit change.
        current.worktrees[tree]?.state = .frozen
        current.worktrees[tree]?.sealStatus = .committed
        current.worktrees[tree]?.resultOID = "r"
        current.worktrees[tree]?.version = 2
        try await check()
        try await check()
        #expect(counter.count == 2)
        // A candidate of the task appears.
        let candidate = CandidateID()
        current.candidates[candidate] = CandidateRecord(
            id: candidate, projectID: ProjectID(), jobID: JobID(), taskID: task, kind: .implementation, authorAttemptID: attempt,
            authorProvider: .fake, resultOID: "r", revertsCandidateID: nil, previousTargetOID: "t", candidateOID: "c",
            targetRef: "refs/kaiorx/integrations/x", worktreeID: nil, state: .built, conflicts: [], version: 1, createdAt: 1
        )
        try await check()
        #expect(counter.count == 3)
    }

    @Test func aFailingCheckIsNotKept() async throws {
        let cache = ResultCheckCache()
        let counter = Counter()
        let task = TaskID()
        let key = ResultCheckCache.key(task, in: state(task), tip: "t", issue: nil)
        await #expect(throws: CheckFailed.self) {
            _ = try await cache.check(task, key: key) {
                counter.hit()
                throw CheckFailed()
            }
        }
        #expect(try await cache.check(task, key: key) { counter.hit(); return .empty } == .empty)
        #expect(try await cache.check(task, key: key) { counter.hit(); return .notApplicable } == .empty)
        #expect(counter.count == 2)
        // A task the state no longer has is dropped.
        await cache.keep(only: [])
        #expect(try await cache.check(task, key: key) { counter.hit(); return .notApplicable } == .notApplicable)
        #expect(counter.count == 3)
    }

    /// The lookup the app passes to `PendingDecisions.collect` asks the chain's check once for
    /// an unchanged state (key built from the projected state and the job's live integration tip)
    /// and once more after the task moved on.
    @Test(.tags(.chainDriver)) func theLookupReusesTheChainsCheck() async throws {
        let f = try await ChainFixture("chain-check-cache")
        let chain = try #require(f.services.chain)
        let (_, task, _) = try await UITestSeed.empty(services: f.services, project: f.project, title: "Leer")
        let state = try await Projector(store: f.store).load()
        // The projected state yields a key, so the lookup can cache at all.
        let job = try #require(state.tasks[task]?.jobID)
        let tip = try await f.store.integrationTip(job: job)
        #expect(ResultCheckCache.key(task, in: state, tip: tip, issue: await chain.issue(task)) != nil)
        let cache = ResultCheckCache()
        let counter = Counter()
        let countingCheck: @Sendable (CandidateChain, TaskID) async throws -> ResultCheck? = { chain, task in
            counter.hit()
            return try await chain.check(task)
        }
        let lookup = cache.lookup(state: state, store: f.store, chain: chain, chainCheck: countingCheck)
        #expect(try await lookup(task) == .empty)
        #expect(try await lookup(task) == .empty)
        #expect(counter.count == 1)
        let pending = try await PendingDecisions.collect(
            state, project: f.project, gate: { _ in [] }, openFindings: { _ in false }, resultCheck: lookup, chainIssue: { await chain.issue($0) }
        )
        #expect(pending.contains(.result(task)))
        #expect(counter.count == 1)
        // The task moved on: exactly one more check, then cached again.
        var moved = state
        moved.tasks[task]?.version += 1
        let movedLookup = cache.lookup(state: moved, store: f.store, chain: chain, chainCheck: countingCheck)
        #expect(try await movedLookup(task) == .empty)
        #expect(counter.count == 2)
        #expect(try await movedLookup(task) == .empty)
        #expect(counter.count == 2)
        await f.close()
    }
}
