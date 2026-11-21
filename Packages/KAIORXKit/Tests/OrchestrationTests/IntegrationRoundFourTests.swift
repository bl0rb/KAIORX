import Domain
import Foundation
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workspace

/// Regressions from the fourth check round of package E (ADR 0004).
@Suite struct IntegrationRoundFourTests {
    func move(_ h: IntegrationHarness, _ task: TaskID, to state: TaskState) async throws {
        let version = try #require(try await h.base.store.task(task)).version
        try await h.base.store.execute(Command(.transitionTask(id: task, to: state, expectedVersion: version)))
    }

    /// A published change and a second author result that conflicts with it.
    func conflicted(_ h: IntegrationHarness, second script: String = "echo 'let a = 3' > src/a.swift",
                    first firstScript: String = "echo 'let a = 2' > src/a.swift") async throws -> (TaskID, CandidateRecord)? {
        let (_, first) = try await h.authorResult(firstScript)
        let (task, second) = try await h.authorResult(script)
        let a = try await h.accepted(first)
        try await h.integration.publish(a.id, approval: try await h.integration.approve(a.id, actor: "u").id)
        guard case .conflicted(let candidate, _) = try await h.integration.buildCandidate(from: second.id) else {
            Issue.record("expected a conflict"); return nil
        }
        return (task, candidate)
    }

    @Test func aTaskSentBackIsNotPulledIntoVerificationAgain() async throws {
        let h = try await IntegrationHarness()
        let (task, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let first) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await move(h, task, to: .needsChanges)
        #expect(try await h.base.store.candidate(first.id)?.state == .rejected)
        await #expect(throws: IntegrationError.taskNotInVerification(task, .needsChanges)) {
            _ = try await h.integration.buildCandidate(from: tree.id)
        }
        #expect(try await h.base.store.task(task)?.state == .needsChanges)
    }

    @Test func aRevertTaskCannotGoBackToAnAuthor() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        let original = try await h.accepted(tree)
        try await h.integration.publish(original.id, approval: try await h.integration.approve(original.id, actor: "u").id)
        guard case .built(let revert) = try await h.integration.buildRevert(of: original.id) else { Issue.record("no revert"); return }
        let host = try #require(revert.taskID)
        await #expect(throws: StoreError.taskManagedByIntegration(taskID: host, from: .verifying, to: .needsChanges)) {
            try await move(h, host, to: .needsChanges)
        }
        #expect(try await h.base.store.candidate(revert.id)?.state == .built)
        // Cancelling still ends it, with its candidate.
        try await move(h, host, to: .cancelled)
        #expect(try await h.base.store.candidate(revert.id)?.state == .rejected)
    }

    @Test func aConflictedRevertTaskCannotGoBackToAnAuthor() async throws {
        let h = try await IntegrationHarness()
        let (_, first) = try await h.authorResult("echo eins > f")
        let original = try await h.accepted(first)
        try await h.integration.publish(original.id, approval: try await h.integration.approve(original.id, actor: "u").id)
        let (_, later) = try await h.authorResult("echo zwei > f")
        let next = try await h.accepted(later)
        try await h.integration.publish(next.id, approval: try await h.integration.approve(next.id, actor: "u").id)
        guard case .conflicted(let revert, _) = try await h.integration.buildRevert(of: original.id) else { Issue.record("expected a conflict"); return }
        let host = try #require(revert.taskID)
        await #expect(throws: StoreError.taskManagedByIntegration(taskID: host, from: .conflict, to: .ready)) {
            try await move(h, host, to: .ready)
        }
        #expect(try await h.base.store.task(host)?.state == .conflict)
    }

    @Test func aConflictIsLeftOnlyByItsResolution() async throws {
        let h = try await IntegrationHarness()
        guard let (task, candidate) = try await conflicted(h) else { return }
        await #expect(throws: StoreError.taskManagedByIntegration(taskID: task, from: .conflict, to: .verifying)) {
            try await move(h, task, to: .verifying)
        }
        // A hold during the conflict resumes into the conflict, not past it.
        try await move(h, task, to: .blocked)
        let held = try #require(try await h.base.store.task(task))
        try await move(h, task, to: try #require(held.resumeState))
        #expect(try await h.base.store.task(task)?.state == .conflict)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .conflicted)
        let built = try await h.integration.resolveConflicts(candidate.id, ["src/a.swift": .theirs])
        #expect(built.state == .built)
        #expect(try await h.base.store.task(task)?.state == .verifying)
    }

    @Test func anAcceptRefusedByAHoldIsTakenUpByApproval() async throws {
        let h = try await IntegrationHarness()
        let (task, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(candidate.id, profile: h.passing)
        let attempt = try await h.integration.startReview(candidate.id, provider: .fake, model: "r", criteria: "")
        _ = try await h.coordinator.waitUntilFinished(attempt)
        // The review lands, then the hold comes before the automatic accept.
        _ = try await h.base.store.recordReview(
            candidate: candidate.id, oid: try #require(candidate.candidateOID), reviewerAttemptID: attempt, origin: .provider,
            reviewerProvider: .fake, status: .approved, summary: "fine", findings: []
        )
        let version = try #require(try await h.base.store.candidate(candidate.id)).version
        try await move(h, task, to: .blocked)
        await #expect(throws: IntegrationStoreError.taskCannotFollow(task, from: .blocked, to: .awaitingMerge)) {
            _ = try await h.base.store.transitionCandidate(candidate.id, to: .accepted, onlyFrom: [.reviewing], atVersion: version)
        }
        try await move(h, task, to: .verifying)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .reviewing)
        let approval = try await h.integration.approve(candidate.id, actor: "u")
        #expect(approval.state == .granted)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .accepted)
        #expect(try await h.base.store.task(task)?.state == .awaitingMerge)
    }

    @Test func evidenceIsFrozenWhileACandidateIsPublishing() async throws {
        var h = try await IntegrationHarness()
        let (task, tree) = try await h.authorResult("echo eins > a.txt")
        let candidate = try await h.accepted(tree)
        let oid = try #require(candidate.candidateOID)
        let approval = try await h.integration.approve(candidate.id, actor: "u")
        // publish() stalled after preparing: the journal entry stays prepared.
        _ = try await h.base.store.preparePublication(candidate: candidate.id, approval: approval.id)
        let blocking = #"{"candidateOID": "\#(oid)", "verdict": "changes", "summary": "", "findings": [{"severity": "blocking", "path": "a.txt", "line": 1, "impact": "i", "suggestion": "s"}]}"#
        await #expect(throws: IntegrationStoreError.publicationInProgress(candidate.id)) {
            _ = try await h.integration.importReview(candidate.id, text: blocking)
        }
        await #expect(throws: IntegrationStoreError.publicationInProgress(candidate.id)) {
            _ = try await h.base.store.recordTest(
                candidate: candidate.id, oid: oid, profileDigest: "d", status: .failed, exitCode: 1, changedTestInputs: [], summary: "red"
            )
        }
        #expect(try await h.base.store.findings(candidate: candidate.id).isEmpty)
        try await h.base.restart()
        _ = try await h.base.service.reconcile()
        #expect(try await h.target() == oid)
        #expect(try await h.base.store.task(task)?.state == .integrated)
    }

    @Test func recoveryDoesNotPublishForAHeldTask() async throws {
        var h = try await IntegrationHarness()
        let (task, tree) = try await h.authorResult("echo eins > a.txt")
        let candidate = try await h.accepted(tree)
        let approval = try await h.integration.approve(candidate.id, actor: "u")
        let before = try await h.target()
        _ = try await h.base.store.preparePublication(candidate: candidate.id, approval: approval.id)
        try await move(h, task, to: .blocked)
        try await h.base.restart()
        _ = try await h.base.service.reconcile()
        #expect(try await h.target() == before)
        let held = try #require(try await h.base.store.task(task))
        #expect(held.state == .blocked && held.resumeState == .awaitingMerge)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .accepted)
        #expect(try await h.base.store.approval(approval.id)?.state == .granted)
    }

    @Test func aFailedPinCanBeRetriedWithoutARestart() async throws {
        let h = try await IntegrationHarness()
        guard let (task, candidate) = try await conflicted(h) else { return }
        let lock = h.base.checkout + "/.git/refs/kaiorx/candidates/\(candidate.id.uuidString).lock"
        try FileManager.default.createDirectory(atPath: (lock as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: lock, contents: Data())
        await #expect(throws: (any Error).self) { try await h.integration.resolveConflicts(candidate.id, ["src/a.swift": .theirs]) }
        try FileManager.default.removeItem(atPath: lock)
        let built = try await h.integration.resolveConflicts(candidate.id, ["src/a.swift": .theirs])
        #expect(built.state == .built)
        #expect(try await h.base.store.task(task)?.state == .verifying)
    }

    @Test func aHalfStagedResolutionCanBeRetriedWithAllDecisions() async throws {
        let h = try await IntegrationHarness()
        guard let (_, candidate) = try await conflicted(
            h, second: "echo 'let a = 3' > src/a.swift; echo 'b zwei' > src/b.swift",
            first: "echo 'let a = 2' > src/a.swift; echo 'b eins' > src/b.swift"
        ) else { return }
        #expect(candidate.conflicts == ["src/a.swift", "src/b.swift"])
        // Interrupted after the first path was staged (with another content than decided now).
        let dir = h.base.service.path(of: try await h.base.service.worktree(try #require(candidate.worktreeID)))
        _ = try await h.base.sh("git checkout --ours -- src/a.swift && git add src/a.swift", in: dir)
        let built = try await h.integration.resolveConflicts(candidate.id, ["src/a.swift": .theirs, "src/b.swift": .theirs])
        let commit = try #require(built.candidateOID)
        #expect(try await h.base.sh("git show \(commit):src/a.swift") == "let a = 3")
        #expect(try await h.base.sh("git show \(commit):src/b.swift") == "b zwei")
    }

    @Test func aStuckQAWorktreeKeepsTheVerdictAndIsReportedAsStuck() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        let red = try await h.profile(["-c", "echo x > stuck.txt; chflags uchg stuck.txt; exit 1"], writesWorktree: true)
        let result = try await h.integration.runTests(candidate.id, profile: red)
        let (_, recovery) = try await h.integration.recover()
        let qa = try await h.base.store.worktrees().filter { $0.kind == .qa }
        for t in qa { _ = try? await h.base.sh("chflags -R nouchg '\(h.base.service.path(of: t))'") }
        #expect(result.status == .failed)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .rejected)
        #expect(!qa.isEmpty && qa.allSatisfy { recovery.stuckWorktrees.contains($0.id) })
        #expect(recovery.removedWorkWorktrees.allSatisfy { id in qa.first { $0.id == id } == nil })
    }

    @Test func aBlockingFindingCountsWhateverTheVerdict() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(candidate.id, profile: h.passing)
        let oid = try #require(candidate.candidateOID)
        let review = try await h.integration.importReview(
            candidate.id,
            text: #"{"candidateOID": "\#(oid)", "verdict": "reject", "summary": "", "findings": [{"severity": "blocking", "path": "a.txt", "line": 1, "impact": "i", "suggestion": "s"}]}"#
        )
        #expect(review.status == .changesRequested)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .rejected)
    }

    @Test func findingsOfAReportWithAnUnreadableVerdictStillNeedADecision() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(candidate.id, profile: h.passing)
        let oid = try #require(candidate.candidateOID)
        let unclear = try await h.integration.importReview(
            candidate.id,
            text: #"{"candidateOID": "\#(oid)", "verdict": "lgtm", "findings": [{"severity": "major", "path": "a.txt", "line": 1, "impact": "i", "suggestion": "s"}]}"#
        )
        #expect(unclear.status == .invalid)
        _ = try await h.integration.importReview(candidate.id, text: #"{"candidateOID": "\#(oid)", "verdict": "approve", "findings": []}"#)
        #expect(try await h.integration.gate(candidate.id) == ["undecided findings"])
        #expect(try await h.base.store.candidate(candidate.id)?.state == .reviewing)
    }

    @Test func findingSeverityRules() {
        let oid = String(repeating: "c", count: 40)
        func severities(_ finding: String, verdict: String = "changes") -> [FindingSeverity] {
            ReviewReport.parse(
                #"{"candidateOID": "\#(oid)", "verdict": "\#(verdict)", "summary": "", "findings": [\#(finding)]}"#,
                candidateOID: oid, changedPaths: ["a.swift"]
            ).findings.map(\.severity)
        }
        // A located blocking finding stays blocking without a fix or impact.
        #expect(severities(#"{"severity": "blocking", "path": "a.swift", "line": 1, "impact": "x"}"#) == [.blocking])
        #expect(severities(#"{"severity": "blocking", "path": "a.swift", "line": 1, "impact": "", "suggestion": "y"}"#) == [.blocking])
        // A missing or null severity needs a decision.
        #expect(severities(#"{"path": "a.swift", "line": 2, "impact": "nil crash", "suggestion": "guard"}"#, verdict: "approve") == [.major])
        #expect(severities(#"{"severity": null, "path": "a.swift", "line": 2, "impact": "c", "suggestion": "g"}"#, verdict: "approve") == [.major])
        // An unknown verdict with a declared blocking finding is a change request, not invalid.
        let unknown = ReviewReport.parse(
            #"{"candidateOID": "\#(oid)", "verdict": "Reject", "findings": [{"severity": "blocking", "path": "a.swift", "line": 1}]}"#,
            candidateOID: oid, changedPaths: ["a.swift"]
        )
        #expect(unknown.status == .changesRequested)
    }

    @Test func aFindingOfAClosedCandidateCannotBeDecided() async throws {
        let h = try await IntegrationHarness()
        let (task, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(candidate.id, profile: h.passing)
        let oid = try #require(candidate.candidateOID)
        _ = try await h.integration.importReview(
            candidate.id,
            text: #"{"candidateOID": "\#(oid)", "verdict": "approve", "findings": [{"severity": "minor", "path": "a.txt", "line": 1, "impact": "i", "suggestion": "s"}]}"#
        )
        let finding = try #require(try await h.base.store.findings(candidate: candidate.id).first)
        try await move(h, task, to: .cancelled)
        await #expect(throws: IntegrationStoreError.staleEvidence(candidate: candidate.id, oid: oid)) {
            try await h.integration.decideFinding(finding.id, .accepted, reason: "ok")
        }
    }
}
