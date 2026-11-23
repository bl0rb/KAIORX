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

    // Review finding: `git add -A -- .` refuses an empty nested repository, which left the seal
    // entry prepared and the task looping on re-seals that collided with the existing result ref.
    @Test func aRecoveredSealWithAnEmptyNestedRepositoryCompletes() async throws {
        var harness = try await ServiceHarness()
        let (record, operation, commit) = try await interruptedSeal(
            harness, "echo 'let a = 5' > src/a.swift && git init -q src/sub && mkdir docs && echo x > docs/out.md", allowed: ["src"]
        )
        try await harness.restart()

        let report = try await harness.service.reconcile()
        #expect(report.applied == [operation] && report.skipped.isEmpty && report.missingWorktrees.isEmpty)
        let recovered = try await harness.service.worktree(record.id)
        #expect(recovered.state == .frozen && recovered.sealStatus == .committed && recovered.resultOID == commit)
        #expect(recovered.rejectedPaths == ["docs/out.md": "recoveredUnknown", "src/sub": "recoveredUnknown"])
        #expect(try await harness.store.gitOperations(state: .prepared).isEmpty)
        // Nothing re-seals it, and a second recovery has nothing left to do.
        await #expect(throws: WorkspaceServiceError.worktreeNotReady(record.id, .frozen)) {
            _ = try await harness.service.seal(record.id, allowedPrefixes: ["src"], message: "Ergebnis")
        }
        #expect(try await harness.service.reconcile().isEmpty)
        #expect(try await harness.store.gitOperations(state: .needsAttention).isEmpty)
    }

    @Test func differencesListUnstageablePathsInsteadOfFailing() async throws {
        let harness = try await ServiceHarness()
        try await harness.sh("mkdir lib && echo b > lib/b.txt && git add -A && git commit -q -m lib")
        let record = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: try await harness.head())
        // A nested repository without a commit, and a tracked folder replaced by a symlink.
        try await harness.sh("echo 'let a = 7' > src/a.swift && git init -q nested && rm -rf lib && ln -s src lib", in: harness.service.path(of: record))
        let location = try await harness.service.location(of: record)
        let base = try await harness.git.tree(of: record.baseOID, in: try await harness.git.inspect(harness.checkout))
        #expect(try await harness.git.differences(of: location, from: base) == ["lib", "lib/b.txt", "nested", "src/a.swift"])
    }

    @Test func aRecoveredSealWhoseWorktreeIsGoneNeedsConfirmation() async throws {
        var harness = try await ServiceHarness()
        let (record, operation, commit) = try await interruptedSeal(harness, "echo 'let a = 5' > src/a.swift", allowed: ["src"])
        try await harness.sh("rm -rf '\(harness.service.path(of: record))'")
        // A worktree an earlier recovery flagged while it left the entry open.
        let (flagged, flaggedOperation, flaggedCommit) = try await interruptedSeal(harness, "echo 'let a = 6' > src/a.swift", allowed: ["src"])
        try await harness.sh("rm -rf '\(harness.service.path(of: flagged))'")
        try await harness.store.transitionWorktree(flagged.id, to: .needsAttention)
        try await harness.restart()

        let report = try await harness.service.reconcile()
        #expect(Set(report.applied) == [operation, flaggedOperation] && report.skipped.isEmpty)
        #expect(Set(report.missingWorktrees) == [record.id, flagged.id])
        let marker = [RejectionReason.unknownPathsMarker: RejectionReason.recoveredUnknown.rawValue]
        for (id, result) in [(record.id, commit), (flagged.id, flaggedCommit)] {
            let recovered = try await harness.service.worktree(id)
            // Committed with its result, but what it dropped is unknown: building waits for the user.
            #expect(recovered.sealStatus == .committed && recovered.resultOID == result && recovered.state == .needsAttention)
            #expect(recovered.rejectedPaths == marker)
        }
        let details = try await harness.store.gitOperations(state: .applied).filter { $0.id == operation }.compactMap(\.detail)
        #expect(details.count == 1 && details[0].contains("dropped paths unknown"))
        #expect(try await harness.store.gitOperations(state: .prepared).isEmpty)
        #expect(try await harness.service.reconcile().applied.isEmpty)
    }

    /// The chain's author ran; the seal's ref update happened, the database write did not.
    func interruptedChainSeal(_ h: ChainHarness, _ key: String, _ script: String) async throws -> (TaskID, WorktreeID, String) {
        let (task, attempt, treeID) = try await h.runPlanned(key, script)
        let tree = try await h.service.worktree(treeID)
        let outcome = try await h.git.buildResult(
            of: try await h.service.location(of: tree), base: tree.baseOID, allowedPrefixes: ["src/\(key)"], message: "Ergebnis"
        )
        let commit = try #require(outcome.commit)
        let ref = "refs/kaiorx/results/\(attempt.uuidString)"
        _ = try await h.store.prepareRefUpdate(projectID: h.project, worktreeID: treeID, ref: ref, expectedOld: nil, desiredNew: commit)
        try await h.sh("git update-ref \(ref) \(commit)")
        return (task, treeID, commit)
    }

    @Test func theChainNeitherLoopsNorBuildsARecoveredSealWithANestedRepository() async throws {
        var h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, tree, commit) = try await interruptedChainSeal(h, "A", "mkdir -p src/A && echo x > src/A/f && git init -q src/A/sub")
        try await h.restart()

        #expect(try await h.store.gitOperations(state: .prepared).isEmpty)
        let chain = h.chain()
        #expect(try await chain.check(task) == .undeclared(resultOID: commit, rejected: ["src/A/sub": "recoveredUnknown"]))
        for _ in 0..<2 {
            let report = await chain.step()
            #expect(report.sealed.isEmpty && report.built.isEmpty && report.issues.isEmpty)
        }
        #expect(await chain.issue(task) == nil)
        #expect(try await h.candidates().isEmpty)
        #expect(try await h.store.gitOperations(state: .needsAttention).isEmpty)
        #expect(try await h.store.worktree(tree)?.state == .frozen)
    }

    @Test func theChainBuildsARecoveredSealWithUnknownPathsOnlyAfterConfirmation() async throws {
        var h = try await ChainHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let (task, tree, commit) = try await interruptedChainSeal(h, "A", "mkdir -p src/A && echo x > src/A/f")
        try await h.sh("rm -rf '\(h.service.path(of: try await h.service.worktree(tree)))'")
        try await h.restart()

        let chain = h.chain()
        let marker = [RejectionReason.unknownPathsMarker: RejectionReason.recoveredUnknown.rawValue]
        #expect(try await chain.check(task) == .undeclared(resultOID: commit, rejected: marker))
        let report = await chain.step()
        #expect(report.sealed.isEmpty && report.built.isEmpty && report.issues.isEmpty)
        await #expect(throws: IntegrationError.undeclaredChanges([RejectionReason.unknownPathsMarker])) {
            _ = try await h.integration.buildCandidate(from: tree)
        }
        #expect(try await h.candidates().isEmpty)

        guard case .built(let candidate) = try await chain.buildConfirmed(try await h.shown(chain, task)) else {
            Issue.record("not built")
            return
        }
        #expect(try await h.paths(of: try #require(candidate.candidateOID)).contains("src/A/f"))
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
