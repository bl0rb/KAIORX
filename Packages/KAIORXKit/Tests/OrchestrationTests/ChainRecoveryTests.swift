import Domain
import Foundation
import ProcessHost
import Testing
@testable import Orchestration
@testable import Providers
@testable import Storage
@testable import Workspace

/// Recovery and start failures the candidate chain depends on (ADR 0011 §6): a recovered seal
/// keeps what it dropped, a candidate never loses its commit, a refused review says why.
@Suite struct ChainRecoveryTests {
    /// The seal's ref update happened, the database write did not: an app crash in between.
    func interruptedSeal(_ harness: ServiceHarness, _ script: String, allowed: [String]?) async throws -> (WorktreeRecord, GitOperationID, String) {
        let record = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: try await harness.head())
        try await harness.sh(script, in: harness.service.path(of: record))
        let outcome = try await harness.git.buildResult(
            of: try await harness.service.location(of: record), base: record.baseOID, allowedPrefixes: allowed, message: "Ergebnis"
        )
        let commit = try #require(outcome.commit)
        let ref = "refs/kaiorx/results/\(record.id.uuidString)"
        let operation = try await harness.store.prepareRefUpdate(projectID: harness.project, worktreeID: record.id, ref: ref, expectedOld: nil, desiredNew: commit)
        try await harness.sh("git update-ref \(ref) \(commit)")
        return (record, operation, commit)
    }

    @Test func aRecoveredSealKeepsItsDroppedPathsAsUnknown() async throws {
        var harness = try await ServiceHarness()
        let (dropping, droppingOperation, commit) = try await interruptedSeal(
            harness, "echo 'let a = 5' > src/a.swift && mkdir docs && echo x > docs/out.md && ln -s /tmp src/link", allowed: ["src"]
        )
        let (clean, cleanOperation, _) = try await interruptedSeal(harness, "echo 'let a = 6' > src/a.swift", allowed: ["src"])
        try await harness.restart()

        let report = try await harness.service.reconcile()
        #expect(Set(report.applied) == [droppingOperation, cleanOperation])
        let recovered = try await harness.service.worktree(dropping.id)
        #expect(recovered.state == .frozen && recovered.sealStatus == .committed && recovered.resultOID == commit)
        // Why they were dropped is lost; that they were is not.
        #expect(recovered.rejectedPaths == ["docs/out.md": "recoveredUnknown", "src/link": "recoveredUnknown"])
        #expect(RejectionReason(rawValue: "recoveredUnknown") == .recoveredUnknown)
        // A result that dropped nothing stays clean.
        let unchanged = try await harness.service.worktree(clean.id)
        #expect(unchanged.sealStatus == .committed && unchanged.rejectedPaths.isEmpty)
        // The frozen worktree itself is left as it was.
        let location = try await harness.service.location(of: recovered)
        #expect(try await harness.git.differences(of: location, from: try #require(recovered.savedTree)) == ["docs/out.md", "src/link"])
        #expect(try await harness.sh("git status --porcelain", in: harness.service.path(of: recovered)).contains("docs/"))
    }

    @Test func recoveryPinsACandidateBeforeItRemovesTheIntegrationWorktree() async throws {
        var h = try await IntegrationHarness()
        let (task, tree) = try await h.authorResult("echo eins > a.txt")
        let result = try #require(tree.resultOID)
        let target = try await h.target()
        // `buildCandidate` up to the crash: merged and recorded, not pinned.
        let integration = try await h.base.service.prepareWorktree(projectID: h.base.project, attemptID: nil, kind: .integration, base: target)
        guard case .merged(let commit) = try await h.base.git.merge(result, at: try await h.base.service.location(of: integration), message: "m") else {
            Issue.record("not merged")
            return
        }
        let candidate = try await h.base.store.createCandidate(CandidateDraft(
            jobID: h.base.job, taskID: task, kind: .implementation, authorAttemptID: tree.attemptID, resultOID: result,
            previousTargetOID: target, candidateOID: commit, targetRef: h.ref, worktreeID: nil
        ))
        let pin = "refs/kaiorx/candidates/\(candidate.id.uuidString)"
        #expect(try await h.base.git.readRef(pin, in: try await h.base.git.inspect(h.base.checkout)) == nil)
        try await h.base.restart()

        let restarted = IntegrationService(
            store: h.base.store, workspace: h.base.service, git: h.base.git, coordinator: RunCoordinator(store: h.base.store, adapters: [])
        )
        let report = try await restarted.recover().1
        #expect(report.repinned == [candidate.id] && report.lostCandidates.isEmpty)
        #expect(report.removedWorkWorktrees == [integration.id])
        #expect(try await h.base.sh("git rev-parse \(pin)") == commit)
        #expect(try await h.base.store.worktree(integration.id)?.state == .removed)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .built)
        #expect(try await h.base.store.gitOperations(state: .prepared).isEmpty)
        // A second recovery finds the pin in place.
        #expect(try await restarted.recover().1.repinned.isEmpty)
        // The candidate goes on through the chain.
        try await restarted.runTests(candidate.id, profile: h.passing)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .reviewing)
    }

    @Test func aCandidateWhoseCommitIsGoneIsRejected() async throws {
        var h = try await IntegrationHarness()
        let (task, tree) = try await h.authorResult("echo zwei > b.txt")
        let target = try await h.target()
        let missing = String(repeating: "d", count: 40)
        let candidate = try await h.base.store.createCandidate(CandidateDraft(
            jobID: h.base.job, taskID: task, kind: .implementation, authorAttemptID: tree.attemptID, resultOID: tree.resultOID,
            previousTargetOID: target, candidateOID: missing, targetRef: h.ref, worktreeID: nil
        ))
        try await h.base.restart()

        let restarted = IntegrationService(
            store: h.base.store, workspace: h.base.service, git: h.base.git, coordinator: RunCoordinator(store: h.base.store, adapters: [])
        )
        let report = try await restarted.recover().1
        #expect(report.lostCandidates == [candidate.id] && report.repinned.isEmpty)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .rejected)
        // The task goes back to its author.
        #expect(try await h.base.store.task(task)?.state == .needsChanges)
        #expect(try await h.base.git.readRef("refs/kaiorx/candidates/\(candidate.id.uuidString)", in: try await h.base.git.inspect(h.base.checkout)) == nil)
        #expect(try await h.base.store.gitOperations(state: .prepared).isEmpty)
    }

    @Test func aRefusedReviewStartCarriesTheAdaptersReason() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(candidate.id, profile: h.passing)

        let refusing = FakeAdapter(provider: .codex) { _ in FakeScript(startError: "nicht angemeldet", steps: []) }
        let integration = IntegrationService(
            store: h.base.store, workspace: h.base.service, git: h.base.git, coordinator: RunCoordinator(store: h.base.store, adapters: [refusing])
        )
        do {
            _ = try await integration.startReview(candidate.id, provider: .codex, model: "r", criteria: "Datei korrekt")
            Issue.record("review started")
        } catch IntegrationError.reviewStartFailed(let attempt, let reason) {
            #expect(reason.contains("nicht angemeldet"))
            #expect(try await h.base.store.attempt(attempt)?.state == .failed)
        }
        // Without any adapter for the provider, the coordinator's reason is carried.
        let none = IntegrationService(
            store: h.base.store, workspace: h.base.service, git: h.base.git, coordinator: RunCoordinator(store: h.base.store, adapters: [])
        )
        do {
            _ = try await none.startReview(candidate.id, provider: .codex, model: "r", criteria: "Datei korrekt")
            Issue.record("review started")
        } catch IntegrationError.reviewStartFailed(_, let reason) {
            #expect(reason == "No adapter for codex")
        }
        // No reviewer worktree is left behind, and the candidate still waits for its review.
        #expect(try await h.base.store.worktrees().filter { $0.kind == .reviewer }.allSatisfy { $0.state == .removed })
        #expect(try await h.base.store.candidate(candidate.id)?.state == .reviewing)
    }
}
