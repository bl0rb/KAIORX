import Domain
import Foundation
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workspace

/// The small leftovers of the candidate chain (ADR 0011): retrying a refused review collect,
/// reporting cleared issues, and removing author worktrees nothing can need any more. Fake
/// providers only.
@Suite struct ChainLeftoverTests {
    /// A reviewing candidate whose finished reviewer the driver refused to collect: reading the
    /// candidate's changes fails while `previous_target_oid` points nowhere. Returns the
    /// candidate; `restore` makes the collect possible again.
    private func refusedCollect(_ h: ChainHarness, _ chain: CandidateChain) async throws -> (CandidateRecord, restore: () async throws -> Void) {
        let candidate = try await h.reviewingCandidate(chain)
        let taskID = try #require(candidate.taskID)
        let fake = try #require(try await chain.reviewOptions(candidate.id).first { $0.provider == .fake })
        let attempt = try await chain.startReview(fake, candidate: candidate.id)
        _ = try await h.coordinator.waitUntilFinished(attempt)
        let zero = String(repeating: "0", count: 40)
        try await h.store.chainTestRun("UPDATE candidate SET previous_target_oid = ? WHERE id = ?", [.text(zero), .text(candidate.id.uuidString)])
        let report = await chain.step()
        #expect(PendingCollect.failed(report.issues[taskID]))
        let store = h.store
        return (candidate, {
            try await store.chainTestRun(
                "UPDATE candidate SET previous_target_oid = ? WHERE id = ?", [.text(candidate.previousTargetOID), .text(candidate.id.uuidString)]
            )
        })
    }

    enum PendingCollect {
        static func failed(_ issue: ChainIssue?) -> Bool {
            if case .collectFailed? = issue { return true }
            return false
        }
    }

    // MARK: Retry a refused collect

    @Test func retryCollectMakesTheNextPassCollectTheRefusedReviewer() async throws {
        let h = try await ChainHarness()
        let chain = h.chain()
        let (candidate, restore) = try await refusedCollect(h, chain)
        let taskID = try #require(candidate.taskID)
        try await restore()
        // Without the retry the refused reviewer stays given up.
        #expect(await chain.step().collected.isEmpty)
        #expect(PendingCollect.failed(await chain.issue(taskID)))

        await chain.retryCollect(taskID)
        #expect(await chain.issue(taskID) == nil)
        let report = await chain.step()
        #expect(report.collected.count == 1)
        // The issue the user call cleared is reported as a change.
        #expect(report.clearedIssues == [taskID])
        #expect(try await h.store.candidate(candidate.id)?.state == .accepted)
        #expect(await chain.issue(taskID) == nil)
    }

    @Test func aRetriedCollectThatFailsAgainIsReportedAgain() async throws {
        let h = try await ChainHarness()
        let chain = h.chain()
        let (candidate, _) = try await refusedCollect(h, chain)
        let taskID = try #require(candidate.taskID)
        await chain.retryCollect(taskID)
        let report = await chain.step()
        #expect(report.collected.isEmpty)
        #expect(PendingCollect.failed(report.issues[taskID]))
        #expect(report.clearedIssues.isEmpty)
        // And then it is quiet again.
        #expect(await chain.step() == ChainReport())
    }

    @Test func retryCollectLeavesABuildBackoffAlone() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, _, _) = try await h.runPlanned("A", "mkdir -p src/A/x && echo r > src/A/x/f")
        try await h.advanceTarget("mkdir -p src/A && echo t > src/A/x")
        let chain = h.chain()
        guard case .buildFailed? = await chain.step().issues[task] else { Issue.record("no build failure"); return }
        await chain.retryCollect(task)
        guard case .buildFailed? = await chain.issue(task) else { Issue.record("backoff cleared"); return }
        _ = await chain.step()
        #expect(try await h.merges() == 1)
    }

    // MARK: Cleared issues are reported

    @Test func anIssueTheDriverClearsQuietlyIsReported() async throws {
        let h = try await ChainHarness()
        let chain = h.chain()
        let (candidate, restore) = try await refusedCollect(h, chain)
        let taskID = try #require(candidate.taskID)
        try await restore()
        // Superseded without a target move: no candidate waits for the reviewer any more.
        _ = try await h.store.transitionCandidate(candidate.id, to: .superseded, reason: "test", onlyFrom: [.reviewing])
        let report = await chain.step()
        #expect(report.built.isEmpty && report.collected.isEmpty)
        #expect(report.clearedIssues == [taskID])
        #expect(report != ChainReport())
        #expect(await chain.issue(taskID) == nil)
        // Reported once.
        #expect(await chain.step().clearedIssues.isEmpty)
    }

    @Test func aRetryBuildBetweenPassesIsReportedAsACleared() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, _, _) = try await h.runPlanned("A", "mkdir -p src/A/x && echo r > src/A/x/f")
        try await h.advanceTarget("mkdir -p src/A && echo t > src/A/x")
        let chain = h.chain()
        guard case .buildFailed? = await chain.step().issues[task] else { Issue.record("no build failure"); return }
        // The conflicting file goes away: the retried build succeeds and the issue is gone.
        try await h.advanceTarget("git rm -q src/A/x")
        await chain.retryBuild(task)
        let report = await chain.step()
        #expect(report.built.count == 1)
        #expect(report.clearedIssues == [task])
    }

    // MARK: Author worktree cleanup

    @Test func anIntegratedTasksAuthorTreeIsRemovedAndItsResultStaysReachable() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, attempt, tree) = try await h.runPlanned("A", "mkdir -p src/A && echo x > src/A/f")
        _ = try await h.service.seal(tree, allowedPrefixes: ["src/A"], message: "r")
        let result = try #require(try await h.store.worktree(tree)?.resultOID)
        try await h.moveTarget(to: result)
        let flag = StreamFlag(false)
        let chain = h.chain(streaming: { _ in flag.live })
        // While the task waits with its result, the tree stays.
        for _ in 0..<2 { #expect(await chain.step().removedAuthorTrees.isEmpty) }
        try await chain.acceptEmpty(try await h.shown(chain, task))
        #expect(try await h.store.task(task)?.state == .integrated)
        // Never under a live stream.
        flag.set(true)
        #expect(await chain.step().removedAuthorTrees.isEmpty)
        flag.set(false)
        let path = h.service.path(of: try await h.service.worktree(tree))
        let report = await chain.step()
        #expect(report.removedAuthorTrees == [tree])
        let removed = try #require(try await h.store.worktree(tree))
        #expect(removed.state == .removed)
        // The stored record keeps the result; the commit stays reachable through its ref.
        #expect(removed.resultOID == result && removed.sealStatus == .committed)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try await h.sh("git rev-parse refs/kaiorx/results/\(attempt.uuidString)") == result)
        try await h.sh("git cat-file -e \(result)^{commit}")
        #expect(try await h.store.gitOperations(state: .failed).isEmpty)
        // Once.
        #expect(await chain.step() == ChainReport())
    }

    @Test func aDiscardedResultsTreeGoesOnceANewAuthorTookOver() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, attempt, tree) = try await h.runPlanned("A", "mkdir -p src/A docs && echo x > src/A/f && echo y > docs/g")
        let chain = h.chain()
        _ = await chain.step()
        let shown = try await h.shown(chain, task)
        guard case .undeclared(let result, _) = shown.check else { Issue.record("not undeclared: \(shown.check)"); return }
        try await chain.discard(shown, actor: "user")
        #expect(try await h.store.task(task)?.state == .needsChanges)
        // Still the task's current attempt: kept until a new author is reserved.
        #expect(await chain.step().removedAuthorTrees.isEmpty)
        #expect(try await h.store.worktree(tree)?.state == .frozen)

        _ = try await h.scheduler().tick()
        let next = try #require(try await h.store.task(task)?.currentAttemptID)
        #expect(next != attempt)
        _ = try await h.coordinator.waitUntilFinished(next)
        let report = await chain.step()
        #expect(report.removedAuthorTrees == [tree])
        #expect(try await h.sh("git rev-parse refs/kaiorx/results/\(attempt.uuidString)") == result)
        // The new author's tree is the task's current result: it stays.
        let newTree = try #require(try await h.store.attempt(next)?.worktreeID)
        #expect(try await h.store.worktree(newTree)?.state != .removed)
        for _ in 0..<2 { #expect(await chain.step().removedAuthorTrees.isEmpty) }
        #expect(try await h.store.worktree(newTree)?.state != .removed)
    }

    @Test func anAuthorTreeOfAnOpenCandidateOrAWaitingTaskStays() async throws {
        let h = try await ChainHarness()
        let chain = h.chain()
        let candidate = try await h.reviewingCandidate(chain)
        let attempt = try #require(candidate.authorAttemptID)
        let tree = try #require(try await h.store.attempt(attempt)?.worktreeID)
        for _ in 0..<2 { #expect(await chain.step().removedAuthorTrees.isEmpty) }
        // Superseded because the target moved: the rebuild starts from this attempt again.
        try await h.advanceTarget("echo z > z.txt")
        _ = try await h.store.transitionCandidate(candidate.id, to: .superseded, reason: "target moved", onlyFrom: [.reviewing])
        let report = await chain.step()
        #expect(report.built.count == 1 && report.removedAuthorTrees.isEmpty)
        #expect(try await h.store.worktree(tree)?.state == .frozen)
        // Rejected: the task goes back for changes, the attempt stays current until a new author.
        let rebuilt = try #require(report.built.first)
        try await h.integration.rejectCandidate(rebuilt, reason: "nein")
        #expect(await chain.step().removedAuthorTrees.isEmpty)
        #expect(try await h.store.worktree(tree)?.state == .frozen)
    }

    @Test func aRefusedAuthorTreeRemovalIsNotRepeated() async throws {
        let h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, _, tree) = try await h.runPlanned("A", nil)
        let chain = h.chain()
        _ = await chain.step()
        try await chain.acceptEmpty(try await h.shown(chain, task))
        // Someone unlocked the worktree: it no longer looks like ours, Git's removal is refused.
        try await h.sh("git worktree unlock -- '\(h.service.path(of: try await h.service.worktree(tree)))'")
        let first = await chain.step()
        #expect(first.removedAuthorTrees.isEmpty)
        #expect(try await h.store.worktree(tree)?.state == .needsAttention)
        #expect(try await h.store.gitOperations(state: .failed).count == 1)
        let events = try await h.store.eventHeaders(after: 0, limit: 100_000).count
        for _ in 0..<3 { #expect(await chain.step() == ChainReport()) }
        #expect(try await h.store.gitOperations(state: .failed).count == 1)
        #expect(try await h.store.eventHeaders(after: 0, limit: 100_000).count == events)
    }
}
