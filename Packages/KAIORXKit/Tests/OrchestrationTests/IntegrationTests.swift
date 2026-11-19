import Domain
import Foundation
import ProcessHost
import Synchronization
import Testing
@testable import Orchestration
@testable import Providers
@testable import Storage
@testable import Workspace

/// What the fake reviewer answers; it reads the candidate commit from its prompt.
final class ReviewerScript: Sendable {
    enum Verdict: Sendable { case approve, blocking, minor, wrongOID, prose, crash }
    private let verdict = Mutex(Verdict.approve)
    func set(_ value: Verdict) { verdict.withLock { $0 = value } }

    var adapter: FakeAdapter {
        FakeAdapter { [self] spec in
            let oid = spec.prompt.split(separator: " ").dropFirst(2).first.map(String.init) ?? ""
            let text: String = switch verdict.withLock({ $0 }) {
            case .approve: #"```json\#n{"candidateOID": "\#(oid)", "verdict": "approve", "summary": "fine", "findings": []}\#n```"#
            case .blocking: #"```json\#n{"candidateOID": "\#(oid)", "verdict": "changes", "summary": "bug", "findings": [{"severity": "blocking", "path": "a.txt", "line": 1, "impact": "breaks", "suggestion": "revert line"}]}\#n```"#
            case .minor: #"```json\#n{"candidateOID": "\#(oid)", "verdict": "approve", "summary": "ok", "findings": [{"severity": "minor", "path": "a.txt", "line": 1, "impact": "style", "suggestion": "rename"}]}\#n```"#
            case .wrongOID: #"```json\#n{"candidateOID": "0000000000000000000000000000000000000000", "verdict": "approve", "summary": "x", "findings": []}\#n```"#
            case .prose: "Looks good to me!"
            case .crash: ""
            }
            if case .crash = verdict.withLock({ $0 }) {
                return FakeScript(steps: [.emit(.started(sessionID: "rev")), .emit(.completed(.failed(reason: "crash")))])
            }
            return FakeScript(steps: [.emit(.started(sessionID: "rev")), .emit(.messageFinal(itemID: "m", text: text)), .emit(.completed(.succeeded))])
        }
    }
}

struct IntegrationHarness {
    var base: ServiceHarness
    let reviewer = ReviewerScript()
    let coordinator: RunCoordinator
    let integration: IntegrationService
    let passing = TestProfile(executable: "/bin/sh", arguments: ["-c", "exit 0"])

    init() async throws {
        base = try await ServiceHarness()
        coordinator = RunCoordinator(store: base.store, adapters: [reviewer.adapter])
        integration = IntegrationService(store: base.store, workspace: base.service, git: base.git, coordinator: coordinator)
        _ = try await base.service.openIntegration(base.job, baseRevision: "main")
    }

    var ref: String { "refs/kaiorx/integrations/\(base.job.uuidString)" }

    func target() async throws -> String { try await base.sh("git rev-parse \(ref)") }

    /// A succeeded author attempt (provider claude) on a new or given task, with its sealed result.
    func authorResult(_ script: String, task existing: TaskID? = nil) async throws -> (TaskID, WorktreeRecord) {
        let task = existing ?? TaskID()
        if existing == nil {
            try await base.store.execute(Command(.createTask(id: task, jobID: base.job, title: "Aufgabe \(task.uuidString.prefix(4))")))
            try await base.store.execute(Command(.transitionTask(id: task, to: .ready, expectedVersion: 1)))
        }
        let attempt = AttemptID()
        try await base.store.execute(Command(.reserveAttempt(AttemptReservation(
            attemptID: attempt, taskID: task, projectID: base.project, role: .author, provider: .claude, mode: .automatic,
            model: "m", specDigest: "d"
        ))))
        let tree = try await base.service.prepareWorktree(projectID: base.project, attemptID: attempt, kind: .author, base: try await target())
        try await base.sh(script, in: base.service.path(of: tree))
        try await transitionAttempt(attempt, to: .starting)
        _ = try await base.store.ingest(.started(sessionID: "s"), attemptID: attempt)
        _ = try await base.store.ingest(.completed(.succeeded), attemptID: attempt)
        _ = try await base.service.seal(tree.id, allowedPrefixes: nil, message: "result")
        return (task, try await base.service.worktree(tree.id))
    }

    func transitionAttempt(_ id: AttemptID, to state: AttemptState) async throws {
        let version = try #require(try await base.store.attempt(id)).version
        try await base.store.execute(Command(.transitionAttempt(id: id, to: state, expectedVersion: version, errorClass: nil)))
    }

    /// Build, test, review and accept.
    func accepted(_ tree: WorktreeRecord) async throws -> CandidateRecord {
        guard case .built(let candidate) = try await integration.buildCandidate(from: tree.id) else {
            Issue.record("not built")
            throw IntegrationError.candidateNotIn(CandidateID(), .conflicted)
        }
        try await integration.runTests(candidate.id, profile: passing)
        try await review(candidate.id)
        return try #require(try await base.store.candidate(candidate.id))
    }

    @discardableResult
    func review(_ id: CandidateID) async throws -> ReviewRecord {
        let attempt = try await integration.startReview(id, provider: .fake, model: "reviewer", criteria: "Datei korrekt")
        return try await integration.collectReview(id, attempt: attempt)
    }
}

@Suite struct IntegrationFlowTests {
    @Test func candidateRunsTheWholeChainToADeliveryBranch() async throws {
        let h = try await IntegrationHarness()
        try await h.base.sh("echo 'user edit' >> src/a.swift")  // unsaved user work
        let userStatus = try await h.base.sh("git status --porcelain=v1; git rev-parse HEAD; git symbolic-ref HEAD")
        let p = try await h.target()
        let (task, tree) = try await h.authorResult("echo eins > a.txt")

        guard case .built(let built) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        let c = try #require(built.candidateOID)
        #expect(try await h.base.sh("git rev-parse \(c)^1") == p)
        #expect(try await h.base.sh("git rev-parse \(c)^2") == tree.resultOID)
        #expect(try await h.base.sh("git rev-parse refs/kaiorx/candidates/\(built.id.uuidString)") == c)
        #expect(try await h.base.store.task(task)?.state == .verifying)
        #expect(try await h.integration.gate(built.id).count == 2)

        let test = try await h.integration.runTests(built.id, profile: h.passing)
        #expect(test.status == .passed && test.candidateOID == c)
        let review = try await h.review(built.id)
        #expect(review.status == .approved && review.reviewerProvider == .fake && review.candidateOID == c)
        #expect(try await h.base.store.candidate(built.id)?.state == .accepted)
        #expect(try await h.base.store.task(task)?.state == .awaitingMerge)
        #expect(try await h.integration.gate(built.id) == [])

        let approval = try await h.integration.approve(built.id, actor: "matze")
        #expect(approval.candidateOID == c && approval.expectedOldOID == p)
        try await h.integration.publish(built.id, approval: approval.id)
        #expect(try await h.target() == c)
        #expect(try await h.base.store.candidate(built.id)?.state == .published)
        #expect(try await h.base.store.approval(approval.id)?.state == .consumed)
        #expect(try await h.base.store.task(task)?.state == .integrated)
        #expect(try await h.base.store.events().contains { $0.kind == .integrationApplied })

        // Delivery: a new branch; a taken name gets a suffix; the user's checkout is untouched.
        #expect(try await h.integration.createDeliveryBranch(job: h.base.job, name: "kaiorx/lieferung") == "kaiorx/lieferung")
        #expect(try await h.integration.createDeliveryBranch(job: h.base.job, name: "kaiorx/lieferung") == "kaiorx/lieferung-2")
        #expect(try await h.base.sh("git rev-parse kaiorx/lieferung") == c)
        #expect(try await h.base.sh("git status --porcelain=v1; git rev-parse HEAD; git symbolic-ref HEAD") == userStatus)
        await #expect(throws: MergeError.self) { _ = try await h.integration.createDeliveryBranch(job: h.base.job, name: "-x") }
    }

    @Test func conflictingChangesNeedTheUsersResolution() async throws {
        let h = try await IntegrationHarness()
        let (_, first) = try await h.authorResult("echo 'let a = 2' > src/a.swift")
        let (_, second) = try await h.authorResult("echo 'let a = 3' > src/a.swift")
        let a = try await h.accepted(first)
        try await h.integration.publish(a.id, approval: try await h.integration.approve(a.id, actor: "u").id)

        guard case .conflicted(let candidate, let entries) = try await h.integration.buildCandidate(from: second.id) else {
            Issue.record("expected a conflict"); return
        }
        #expect(entries == [ConflictEntry(path: "src/a.swift", kind: .bothModified)])
        #expect(candidate.state == .conflicted && candidate.candidateOID == nil)
        await #expect(throws: MergeError.unresolved(["src/a.swift"])) { try await h.integration.resolveConflicts(candidate.id, [:]) }
        let resolved = try await h.integration.resolveConflicts(candidate.id, ["src/a.swift": .content(Data("let a = 23\n".utf8))])
        let c = try #require(resolved.candidateOID)
        #expect(resolved.state == .built)
        #expect(try await h.base.sh("git show \(c):src/a.swift") == "let a = 23")
        #expect(try await h.base.sh("git rev-parse \(c)^1") == a.candidateOID)
        // The integration worktree is gone; the commit is pinned.
        #expect(try await h.base.store.worktrees().filter { $0.kind == .integration }.allSatisfy { $0.state == .removed })
    }

    @Test func movedTargetSupersedesAndRevokesTheOldApproval() async throws {
        let h = try await IntegrationHarness()
        let (_, first) = try await h.authorResult("echo eins > a.txt")
        let (taskB, second) = try await h.authorResult("echo zwei > b.txt")
        let a = try await h.accepted(first)
        let b = try await h.accepted(second)
        let approvalA = try await h.integration.approve(a.id, actor: "u")
        let approvalB = try await h.integration.approve(b.id, actor: "u")
        try await h.integration.publish(a.id, approval: approvalA.id)

        await #expect(throws: IntegrationError.targetMoved(expected: b.previousTargetOID, actual: a.candidateOID)) {
            try await h.integration.publish(b.id, approval: approvalB.id)
        }
        #expect(try await h.base.store.candidate(b.id)?.state == .superseded)
        #expect(try await h.base.store.approval(approvalB.id)?.state == .revoked)
        #expect(try await h.target() == a.candidateOID)

        // A rebuilt candidate starts without evidence and needs a new approval.
        guard case .built(let rebuilt) = try await h.integration.buildCandidate(from: second.id) else { Issue.record("not rebuilt"); return }
        #expect(rebuilt.previousTargetOID == a.candidateOID)
        #expect(try await h.integration.gate(rebuilt.id).count == 2)
        await #expect(throws: IntegrationStoreError.self) { try await h.base.store.preparePublication(candidate: rebuilt.id, approval: approvalB.id) }
        _ = taskB
    }

    @Test func evidenceForAnOlderCommitDoesNotCount() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(candidate.id, profile: h.passing)
        h.reviewer.set(.wrongOID)
        let late = try await h.review(candidate.id)
        #expect(late.status == .invalid)
        h.reviewer.set(.prose)
        #expect(try await h.review(candidate.id).status == .invalid)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .reviewing)
        #expect(try await h.integration.gate(candidate.id) == ["no approving independent review for \(candidate.candidateOID!)"])
        await #expect(throws: IntegrationStoreError.self) {
            try await h.base.store.recordTest(candidate: candidate.id, oid: tree.resultOID!, profileDigest: "x", status: .passed,
                                              exitCode: 0, changedTestInputs: [], summary: "old")
        }
    }

    @Test func blockingFindingsRejectAndMinorOnesNeedADecision() async throws {
        let h = try await IntegrationHarness()
        let (task, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let blocked) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(blocked.id, profile: h.passing)
        h.reviewer.set(.blocking)
        try await h.review(blocked.id)
        #expect(try await h.base.store.candidate(blocked.id)?.state == .rejected)
        #expect(try await h.base.store.task(task)?.state == .needsChanges)
        let blocking = try #require(try await h.base.store.findings(candidate: blocked.id).first)
        await #expect(throws: IntegrationStoreError.blockingFindingCannotBeAccepted(blocking.id)) {
            try await h.base.store.decideFinding(blocking.id, .accepted, reason: "egal")
        }

        let (_, minorTree) = try await h.authorResult("echo zwei > a.txt")
        guard case .built(let minor) = try await h.integration.buildCandidate(from: minorTree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(minor.id, profile: h.passing)
        h.reviewer.set(.minor)
        try await h.review(minor.id)
        #expect(try await h.base.store.candidate(minor.id)?.state == .reviewing)
        #expect(try await h.integration.gate(minor.id) == ["undecided findings"])
        let finding = try #require(try await h.base.store.findings(candidate: minor.id).first)
        try await h.integration.decideFinding(finding.id, .accepted, reason: "Name bleibt")
        #expect(try await h.base.store.candidate(minor.id)?.state == .accepted)
    }

    @Test func failingTestsRejectAndInfrastructureErrorsRetry() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt; mkdir -p tests; echo t > tests/t.sh")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        let broken = TestProfile(executable: "/nonexistent/runner")
        #expect(try await h.integration.runTests(candidate.id, profile: broken).status == .infrastructureError)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .built)
        let failing = try await h.integration.runTests(
            candidate.id, profile: TestProfile(executable: "/bin/sh", arguments: ["-c", "exit 4"], testInputPrefixes: ["tests"])
        )
        #expect(failing.status == .failed && failing.exitCode == 4)
        #expect(failing.changedTestInputs == ["tests/t.sh"])
        #expect(try await h.base.store.candidate(candidate.id)?.state == .rejected)
    }

    @Test func authorsProviderCannotReviewItself() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(candidate.id, profile: h.passing)
        await #expect(throws: IntegrationError.reviewerNotIndependent(.claude)) {
            _ = try await h.integration.startReview(candidate.id, provider: .claude, model: "m", criteria: "")
        }
    }

    @Test func alreadyContainedResultsNeedNoCandidate() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        let candidate = try await h.accepted(tree)
        try await h.integration.publish(candidate.id, approval: try await h.integration.approve(candidate.id, actor: "u").id)
        // A new candidate from the same, already integrated result.
        try await h.base.store.transitionWorktree(tree.id, to: .needsAttention)
        #expect(try await h.integration.buildCandidate(from: tree.id) == .alreadyContained)
    }

    @Test func revertAfterDeliveryRunsTheSameChain() async throws {
        let h = try await IntegrationHarness()
        let p = try await h.target()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        let candidate = try await h.accepted(tree)
        try await h.integration.publish(candidate.id, approval: try await h.integration.approve(candidate.id, actor: "u").id)
        _ = try await h.integration.createDeliveryBranch(job: h.base.job, name: "lieferung")

        guard case .built(let revert) = try await h.integration.buildRevert(of: candidate.id) else { Issue.record("no revert"); return }
        #expect(revert.kind == .revert && revert.revertsCandidateID == candidate.id)
        try await h.integration.runTests(revert.id, profile: h.passing)
        _ = try await h.integration.importReview(revert.id, text: #"{"candidateOID": "\#(revert.candidateOID!)", "verdict": "approve", "summary": "revert ok", "findings": []}"#)
        #expect(try await h.base.store.reviews(candidate: revert.id).first?.origin == .userImported)
        try await h.integration.publish(revert.id, approval: try await h.integration.approve(revert.id, actor: "u").id)
        let tip = try await h.target()
        #expect(try await h.base.sh("git rev-parse \(tip)^{tree}") == h.base.sh("git rev-parse \(p)^{tree}"))
        // The delivered branch keeps the published state.
        #expect(try await h.base.sh("git rev-parse lieferung") == candidate.candidateOID)
    }
}

/// Crash at each publication boundary, then restart and reconcile.
@Suite struct PublicationRecoveryTests {
    func preparedPublication(_ h: IntegrationHarness) async throws -> (CandidateRecord, ApprovalRecord, GitOperationID) {
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        let candidate = try await h.accepted(tree)
        let approval = try await h.integration.approve(candidate.id, actor: "u")
        let operation = try await h.base.store.preparePublication(candidate: candidate.id, approval: approval.id)
        return (candidate, approval, operation)
    }

    @Test func crashBeforeTheRefUpdateRepeatsItWhileApproved() async throws {
        var h = try await IntegrationHarness()
        let (candidate, approval, operation) = try await preparedPublication(h)
        try await h.base.restart()
        #expect(try await h.base.service.reconcile().applied == [operation])
        #expect(try await h.target() == candidate.candidateOID)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .published)
        #expect(try await h.base.store.approval(approval.id)?.state == .consumed)
        #expect(try await h.base.store.events().filter { $0.kind == .integrationApplied }.count == 1)
    }

    @Test func crashAfterTheRefUpdateOnlyCompletesTheJournal() async throws {
        var h = try await IntegrationHarness()
        let (candidate, _, operation) = try await preparedPublication(h)
        try await h.base.sh("git update-ref \(h.ref) \(candidate.candidateOID!) \(candidate.previousTargetOID)")
        try await h.base.restart()
        #expect(try await h.base.service.reconcile().applied == [operation])
        #expect(try await h.base.store.candidate(candidate.id)?.state == .published)
        #expect(try await h.base.store.task(candidate.taskID!)?.state == .integrated)
    }

    @Test func revokedApprovalIsNotRepeated() async throws {
        var h = try await IntegrationHarness()
        let (candidate, approval, operation) = try await preparedPublication(h)
        try await h.base.store.revokeForTest(approval.id)
        try await h.base.restart()
        // Not repeated without a valid approval; the candidate is released for a new approval.
        #expect(try await h.base.service.reconcile().failed == [operation])
        #expect(try await h.target() == candidate.previousTargetOID)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .accepted)
    }

    @Test func onlyOnePublicationPerTargetAtATime() async throws {
        let h = try await IntegrationHarness()
        let (_, first) = try await h.authorResult("echo eins > a.txt")
        let (_, second) = try await h.authorResult("echo zwei > b.txt")
        let a = try await h.accepted(first)
        let b = try await h.accepted(second)
        let approvalA = try await h.integration.approve(a.id, actor: "u")
        let approvalB = try await h.integration.approve(b.id, actor: "u")
        _ = try await h.base.store.preparePublication(candidate: a.id, approval: approvalA.id)
        await #expect(throws: (any Error).self) { _ = try await h.base.store.preparePublication(candidate: b.id, approval: approvalB.id) }
        #expect(try await h.base.store.candidate(b.id)?.state == .accepted)
    }
}

@Suite struct ReviewReportTests {
    let oid = String(repeating: "a", count: 40)

    @Test func structuredReportsAreValidatedAgainstTheDiff() {
        let text = """
            Here is my review.
            ```json
            {"candidateOID": "\(oid)", "verdict": "approve", "summary": "s", "findings": [
              {"severity": "minor", "path": "a.txt", "line": 2, "impact": "i", "suggestion": "s"},
              {"severity": "major", "path": "elsewhere.txt", "line": 1, "impact": "outside the diff", "suggestion": "s"},
              {"severity": "minor", "path": "a.txt", "impact": "no line", "suggestion": "s"}
            ]}
            ```
            """
        let parsed = ReviewReport.parse(text, candidateOID: oid, changedPaths: ["a.txt"])
        #expect(parsed.status == .approved)
        // A major finding outside the diff still needs a decision; a minor one becomes a comment.
        #expect(parsed.findings.map(\.severity) == [.minor, .major, .comment])
    }

    @Test func approveWithBlockingIsChangesRequestedAndUnreadableIsInvalid() {
        let blocking = #"{"candidateOID": "\#(oid)", "verdict": "approve", "summary": "", "findings": [{"severity": "blocking", "path": "a", "line": 1, "impact": "x", "suggestion": "y"}]}"#
        #expect(ReviewReport.parse(blocking, candidateOID: oid, changedPaths: ["a"]).status == .changesRequested)
        #expect(ReviewReport.parse("LGTM", candidateOID: oid, changedPaths: []).status == .invalid)
        #expect(ReviewReport.parse(#"{"candidateOID": "other", "verdict": "approve"}"#, candidateOID: oid, changedPaths: []).status == .invalid)
        #expect(ReviewReport.parse(#"{"candidateOID": "\#(oid)", "verdict": "maybe"}"#, candidateOID: oid, changedPaths: []).status == .invalid)
    }
}

extension Store {
    /// Simulates a revocation outside this flow (for example by the user in another window).
    func revokeForTest(_ id: ApprovalID) throws {
        try connection().run("UPDATE approval SET state = 'revoked', resolved_at = 1 WHERE id = ?", [.text(id.uuidString)])
    }
}

@Suite struct IntegrationReviewFixTests {
    @Test func deliveryBranchNeverAliasesAnExistingBranch() async throws {
        let h = try await IntegrationHarness()
        try await h.base.sh("git branch feature/x && git pack-refs --all")
        let main = try await h.base.sh("git rev-parse main")
        #expect(try await h.integration.createDeliveryBranch(job: h.base.job, name: "Main") == "Main-2")
        #expect(try await h.integration.createDeliveryBranch(job: h.base.job, name: "feature") == "feature-2")
        // Below an existing branch no name is free: the folder `feature/x` is taken by a branch.
        await #expect(throws: MergeError.noFreeBranchName("feature/x/y")) {
            _ = try await h.integration.createDeliveryBranch(job: h.base.job, name: "feature/x/y")
        }
        #expect(try await h.base.sh("git rev-parse main") == main)
        #expect(try await h.base.sh("git rev-parse HEAD") == main)
    }

    @Test func resolutionNeverWritesThroughASymlink() async throws {
        let h = try await IntegrationHarness()
        let outside = URL(filePath: h.base.checkout).deletingLastPathComponent().path(percentEncoded: false) + "/outside-target"
        try "unberührt\n".write(toFile: outside, atomically: true, encoding: .utf8)
        try await h.base.sh("ln -s /tmp/kaiorx-nowhere s && git add s && git commit -q -m link && git update-ref \(h.ref) HEAD")
        // The author deletes the link; meanwhile the target points it outside the repository.
        let (_, author) = try await h.authorResult("rm s")
        try await h.base.sh("ln -sfn '\(outside)' s && git add s && git commit -q -m retarget && git update-ref \(h.ref) HEAD")
        guard case .conflicted(let candidate, let entries) = try await h.integration.buildCandidate(from: author.id) else {
            Issue.record("expected a conflict"); return
        }
        #expect(entries == [ConflictEntry(path: "s", kind: .deletedByThem)])
        let integration = try #require(try await h.base.store.worktrees().first { $0.id == candidate.worktreeID })
        var info = stat()
        #expect(lstat(h.base.service.path(of: integration) + "/s", &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK)
        let resolved = try await h.integration.resolveConflicts(candidate.id, ["s": .content(Data("ersetzt\n".utf8))])
        #expect(try String(contentsOfFile: outside, encoding: .utf8) == "unberührt\n")
        #expect(try await h.base.sh("git cat-file -p \(resolved.candidateOID!):s") == "ersetzt")
        #expect(try await h.base.sh("git ls-tree \(resolved.candidateOID!) s").hasPrefix("100644"))
    }

    @Test func conflictsAtInventedPathsAreRefused() async throws {
        let h = try await IntegrationHarness()
        try await h.base.sh("echo x > x && git add x && git commit -q -m x && git update-ref \(h.ref) HEAD")
        let (_, target) = try await h.authorResult("echo geändert > x")
        let (_, author) = try await h.authorResult("rm x && mkdir x && echo y > x/y")
        let a = try await h.accepted(target)
        try await h.integration.publish(a.id, approval: try await h.integration.approve(a.id, actor: "u").id)
        await #expect(throws: MergeError.self) { _ = try await h.integration.buildCandidate(from: author.id) }
        let integration = try await h.base.store.worktrees().filter { $0.kind == .integration }
        #expect(integration.allSatisfy { $0.state == .removed })
    }

    @Test func conflictPathsWithSpacesAndNewlinesResolve() async throws {
        let h = try await IntegrationHarness()
        let (_, first) = try await h.authorResult("printf eins > 'mit leer'; printf eins > \"$(printf 'zeilen\\numbruch')\"")
        let (_, second) = try await h.authorResult("printf zwei > 'mit leer'; printf zwei > \"$(printf 'zeilen\\numbruch')\"")
        let a = try await h.accepted(first)
        try await h.integration.publish(a.id, approval: try await h.integration.approve(a.id, actor: "u").id)
        guard case .conflicted(let candidate, let entries) = try await h.integration.buildCandidate(from: second.id) else {
            Issue.record("expected a conflict"); return
        }
        #expect(Set(entries.map(\.path)) == ["mit leer", "zeilen\numbruch"])
        let resolved = try await h.integration.resolveConflicts(candidate.id, ["mit leer": .theirs, "zeilen\numbruch": .ours])
        #expect(try await h.base.sh("git cat-file -p '\(resolved.candidateOID!):mit leer'") == "zwei")
    }

    @Test func heldRefLockIsRetryableNotATargetMove() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        let candidate = try await h.accepted(tree)
        let approval = try await h.integration.approve(candidate.id, actor: "u")
        let lock = h.base.checkout + "/.git/\(h.ref).lock"
        FileManager.default.createFile(atPath: lock, contents: Data())
        await #expect(throws: IntegrationError.self) { try await h.integration.publish(candidate.id, approval: approval.id) }
        #expect(try await h.base.store.candidate(candidate.id)?.state == .accepted)
        #expect(try await h.base.store.approval(approval.id)?.state == .granted)
        try FileManager.default.removeItem(atPath: lock)
        try await h.integration.publish(candidate.id, approval: approval.id)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .published)
    }

    @Test func externalTargetChangeSupersedes() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        let candidate = try await h.accepted(tree)
        let approval = try await h.integration.approve(candidate.id, actor: "u")
        try await h.base.sh("git commit -q --allow-empty -m extern && git update-ref \(h.ref) HEAD")
        await #expect(throws: IntegrationError.self) { try await h.integration.publish(candidate.id, approval: approval.id) }
        #expect(try await h.base.store.candidate(candidate.id)?.state == .superseded)
        #expect(try await h.base.store.approval(approval.id)?.state == .revoked)
    }

    @Test func lateReviewsAfterAcceptanceStillCount() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        let candidate = try await h.accepted(tree)
        let approval = try await h.integration.approve(candidate.id, actor: "u")
        let oid = candidate.candidateOID!
        // A delayed reviewer with a minor finding: back to review, approval revoked.
        _ = try await h.integration.importReview(candidate.id, text: #"{"candidateOID": "\#(oid)", "verdict": "approve", "summary": "", "findings": [{"severity": "minor", "path": "a.txt", "line": 1, "impact": "i", "suggestion": "s"}]}"#)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .reviewing)
        #expect(try await h.base.store.approval(approval.id)?.state == .revoked)
        await #expect(throws: IntegrationError.self) { try await h.integration.publish(candidate.id, approval: approval.id) }
        // And a blocking one rejects it.
        _ = try await h.integration.importReview(candidate.id, text: #"{"candidateOID": "\#(oid)", "verdict": "changes", "summary": "", "findings": [{"severity": "blocking", "path": "a.txt", "line": 1, "impact": "i", "suggestion": "s"}]}"#)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .rejected)
    }

    @Test func evidenceAfterTheGateCheckStopsThePublication() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        let candidate = try await h.accepted(tree)
        let approval = try await h.integration.approve(candidate.id, actor: "u")
        let version = try #require(try await h.base.store.candidate(candidate.id)).version
        try await h.base.store.recordTest(candidate: candidate.id, oid: candidate.candidateOID!, profileDigest: "x", status: .passed,
                                          exitCode: 0, changedTestInputs: [], summary: "again")
        await #expect(throws: IntegrationStoreError.evidenceChanged(candidate.id)) {
            _ = try await h.base.store.preparePublication(candidate: candidate.id, approval: approval.id, expectedVersion: version)
        }
    }

    @Test func revertsAreReviewedAgainstTheOriginalAuthorAndRunOnce() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        let original = try await h.accepted(tree)
        try await h.integration.publish(original.id, approval: try await h.integration.approve(original.id, actor: "u").id)
        guard case .built(let revert) = try await h.integration.buildRevert(of: original.id) else { Issue.record("no revert"); return }
        #expect(revert.authorProvider == .claude)
        await #expect(throws: IntegrationStoreError.self) { _ = try await h.integration.buildRevert(of: original.id) }
        try await h.integration.runTests(revert.id, profile: h.passing)
        await #expect(throws: IntegrationError.reviewerNotIndependent(.claude)) {
            _ = try await h.integration.startReview(revert.id, provider: .claude, model: "m", criteria: "")
        }
        try await h.review(revert.id)
        try await h.integration.publish(revert.id, approval: try await h.integration.approve(revert.id, actor: "u").id)
        #expect(try await h.base.store.task(revert.taskID!)?.state == .integrated)
        // Nothing left to undo: no candidate, no leaked worktree.
        #expect(try await h.integration.buildRevert(of: original.id) == .alreadyContained)
        #expect(try await h.base.store.worktrees().filter { $0.kind == .integration }.allSatisfy { $0.state == .removed })
    }

    @Test func revertResolvedToTheCurrentStateIsRejected() async throws {
        let h = try await IntegrationHarness()
        let (_, first) = try await h.authorResult("echo eins > f")
        let original = try await h.accepted(first)
        try await h.integration.publish(original.id, approval: try await h.integration.approve(original.id, actor: "u").id)
        let (_, later) = try await h.authorResult("echo zwei > f")
        let next = try await h.accepted(later)
        try await h.integration.publish(next.id, approval: try await h.integration.approve(next.id, actor: "u").id)
        guard case .conflicted(let revert, _) = try await h.integration.buildRevert(of: original.id) else { Issue.record("expected a conflict"); return }
        await #expect(throws: MergeError.nothingToCommit) { try await h.integration.resolveConflicts(revert.id, ["f": .ours]) }
        #expect(try await h.base.store.candidate(revert.id)?.state == .rejected)
    }

    @Test func failedReviewCleansUpAndLostTestsReset() async throws {
        var h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(candidate.id, profile: h.passing)
        h.reviewer.set(.crash)
        let attempt = try await h.integration.startReview(candidate.id, provider: .fake, model: "r", criteria: "")
        await #expect(throws: IntegrationError.reviewAttemptNotFinished(attempt)) { _ = try await h.integration.collectReview(candidate.id, attempt: attempt) }
        #expect(try await h.base.store.worktrees().filter { $0.kind == .reviewer }.allSatisfy { $0.state == .removed })

        let (_, other) = try await h.authorResult("echo zwei > b.txt")
        guard case .built(let second) = try await h.integration.buildCandidate(from: other.id) else { Issue.record("not built"); return }
        try await h.base.store.transitionCandidate(second.id, to: .testing)
        try await h.base.restart()
        let restarted = IntegrationService(store: h.base.store, workspace: h.base.service, git: h.base.git, coordinator: RunCoordinator(store: h.base.store, adapters: []))
        #expect(try await restarted.recover().1.resetTests == [second.id])
        #expect(try await h.base.store.candidate(second.id)?.state == .built)
    }

    @Test func publicationThatCannotHappenReleasesItsCandidate() async throws {
        var h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        let candidate = try await h.accepted(tree)
        let approval = try await h.integration.approve(candidate.id, actor: "u")
        _ = try await h.base.store.preparePublication(candidate: candidate.id, approval: approval.id)
        try await h.base.sh("git commit -q --allow-empty -m extern && git update-ref \(h.ref) HEAD")
        try await h.base.restart()
        let report = try await h.base.service.reconcile()
        #expect(report.failed.count == 1)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .superseded)
    }

    @Test func testInputsNamedByTheProfileAreFlagged() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("mkdir -p scripts && echo 'exit 0' > scripts/test.sh && echo x > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        let result = try await h.integration.runTests(candidate.id, profile: TestProfile(executable: "/bin/sh", arguments: ["scripts/test.sh"]))
        #expect(result.changedTestInputs == ["scripts/test.sh"])
    }
}

@Suite struct ReviewReportFixTests {
    let oid = String(repeating: "b", count: 40)

    @Test func onlyTheLastBlockCountsAndInlineFencesDoNotEndIt() {
        let text = """
            ```json
            {"candidateOID": "\(oid)", "verdict": "approve", "summary": "first draft", "findings": []}
            ```
            On second look:
            ```json
            {"candidateOID": "\(oid)", "verdict": "changes", "summary": "s", "findings": [{"severity": "blocking", "path": "a", "line": 1, "impact": "i", "suggestion": "use ```swift guard``` here"}]}
            ```
            """
        #expect(ReviewReport.parse(text, candidateOID: oid, changedPaths: ["a"]).status == .changesRequested)
        let brokenLast = """
            ```json
            {"candidateOID": "\(oid)", "verdict": "approve", "summary": "", "findings": []}
            ```
            ```json
            {not json
            ```
            """
        #expect(ReviewReport.parse(brokenLast, candidateOID: oid, changedPaths: []).status == .invalid)
    }

    @Test func diffFenceOutgrowsBackticksInTheDiff() {
        #expect(IntegrationService.longestBacktickRun("a ``` b ```` c") == 4)
    }
}

/// Second review round: tasks follow their candidates, rebuilds cannot launder rejections,
/// recovery cleans up all lost worktrees, review reports are read strictly.
@Suite struct IntegrationRoundTwoTests {
    @Test func refusedOrEmptyRevertsLeaveNoOpenTask() async throws {
        let h = try await IntegrationHarness()
        let (_, first) = try await h.authorResult("echo eins > f")
        let original = try await h.accepted(first)
        try await h.integration.publish(original.id, approval: try await h.integration.approve(original.id, actor: "u").id)
        let (_, later) = try await h.authorResult("echo zwei > f")
        let next = try await h.accepted(later)
        try await h.integration.publish(next.id, approval: try await h.integration.approve(next.id, actor: "u").id)
        let tasksBefore = try await h.base.store.tasks(jobID: h.base.job).count

        guard case .conflicted(let revert, _) = try await h.integration.buildRevert(of: original.id) else { Issue.record("expected a conflict"); return }
        #expect(try await h.base.store.task(revert.taskID!)?.state == .conflict)
        // A second request while the first is open creates nothing.
        await #expect(throws: IntegrationStoreError.openRevertExists(revert.id)) { _ = try await h.integration.buildRevert(of: original.id) }
        #expect(try await h.base.store.tasks(jobID: h.base.job).count == tasksBefore + 1)
        // Resolved to nothing: the candidate is rejected and its host task ends.
        await #expect(throws: MergeError.nothingToCommit) { try await h.integration.resolveConflicts(revert.id, ["f": .ours]) }
        #expect(try await h.base.store.task(revert.taskID!)?.state == .noResult)
        #expect(try await h.base.store.worktrees().filter { $0.kind == .integration }.allSatisfy { $0.state == .removed })
    }

    @Test func aResultRejectedOnEvidenceCannotBeRebuilt() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let blocked) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(blocked.id, profile: h.passing)
        h.reviewer.set(.blocking)
        try await h.review(blocked.id)
        #expect(try await h.base.store.candidate(blocked.id)?.state == .rejected)
        await #expect(throws: IntegrationStoreError.rejectedBefore(blocked.id)) { _ = try await h.integration.buildCandidate(from: tree.id) }

        let (_, red) = try await h.authorResult("echo zwei > b.txt")
        guard case .built(let failing) = try await h.integration.buildCandidate(from: red.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(failing.id, profile: TestProfile(executable: "/bin/sh", arguments: ["-c", "exit 1"]))
        await #expect(throws: IntegrationStoreError.rejectedBefore(failing.id)) { _ = try await h.integration.buildCandidate(from: red.id) }
        #expect(try await h.base.store.worktrees().filter { $0.kind == .integration }.allSatisfy { $0.state == .removed })
    }

    @Test func taskFollowsARebuiltCandidateThroughConflictAndRejection() async throws {
        let h = try await IntegrationHarness()
        let (_, first) = try await h.authorResult("echo 'let a = 2' > src/a.swift")
        let (taskB, second) = try await h.authorResult("echo 'let a = 3' > src/a.swift")
        let a = try await h.accepted(first)
        let b = try await h.accepted(second)
        #expect(try await h.base.store.task(taskB)?.state == .awaitingMerge)
        let approvalB = try await h.integration.approve(b.id, actor: "u")
        try await h.integration.publish(a.id, approval: try await h.integration.approve(a.id, actor: "u").id)
        await #expect(throws: IntegrationError.self) { try await h.integration.publish(b.id, approval: approvalB.id) }

        guard case .conflicted(let rebuilt, _) = try await h.integration.buildCandidate(from: second.id) else { Issue.record("expected a conflict"); return }
        var task = try #require(try await h.base.store.task(taskB))
        #expect(task.state == .conflict && task.resumeState == .verifying)
        try await h.integration.resolveConflicts(rebuilt.id, ["src/a.swift": .theirs])
        #expect(try await h.base.store.task(taskB)?.state == .verifying)
        try await h.integration.runTests(rebuilt.id, profile: TestProfile(executable: "/bin/sh", arguments: ["-c", "exit 1"]))
        task = try #require(try await h.base.store.task(taskB))
        #expect(task.state == .needsChanges)
    }

    @Test func reopenedReviewMovesTheTaskBack() async throws {
        let h = try await IntegrationHarness()
        let (task, tree) = try await h.authorResult("echo eins > a.txt")
        let candidate = try await h.accepted(tree)
        #expect(try await h.base.store.task(task)?.state == .awaitingMerge)
        let oid = candidate.candidateOID!
        _ = try await h.integration.importReview(candidate.id, text: #"{"candidateOID": "\#(oid)", "verdict": "approve", "summary": "", "findings": [{"severity": "minor", "path": "a.txt", "line": 1, "impact": "i", "suggestion": "s"}]}"#)
        #expect(try await h.base.store.task(task)?.state == .verifying)
        let finding = try #require(try await h.base.store.findings(candidate: candidate.id).first)
        try await h.integration.decideFinding(finding.id, .accepted, reason: "ok")
        #expect(try await h.base.store.task(task)?.state == .awaitingMerge)
    }

    @Test func recoveryRemovesWorktreesOfLostTestsAndBuilds() async throws {
        var h = try await IntegrationHarness()
        let (_, first) = try await h.authorResult("echo 'let a = 2' > src/a.swift")
        let (_, second) = try await h.authorResult("echo 'let a = 3' > src/a.swift")
        let a = try await h.accepted(first)
        try await h.integration.publish(a.id, approval: try await h.integration.approve(a.id, actor: "u").id)
        guard case .conflicted(let conflicted, _) = try await h.integration.buildCandidate(from: second.id) else { Issue.record("expected a conflict"); return }
        let target = try await h.target()
        let lostQA = try await h.base.service.prepareWorktree(projectID: h.base.project, attemptID: nil, kind: .qa, base: target)
        let lostBuild = try await h.base.service.prepareWorktree(projectID: h.base.project, attemptID: nil, kind: .integration, base: target)
        try await h.base.restart()
        let restarted = IntegrationService(store: h.base.store, workspace: h.base.service, git: h.base.git, coordinator: RunCoordinator(store: h.base.store, adapters: []))
        let report = try await restarted.recover().1
        #expect(Set(report.removedWorkWorktrees) == [lostQA.id, lostBuild.id])
        let trees = try await h.base.store.worktrees()
        #expect(trees.first { $0.id == conflicted.worktreeID }?.state != .removed)
        #expect(trees.filter { $0.id == lostQA.id || $0.id == lostBuild.id }.allSatisfy { $0.state == .removed })
    }

    @Test func doubleApprovalIsSpentWithThePublication() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        let candidate = try await h.accepted(tree)
        let one = try await h.integration.approve(candidate.id, actor: "u")
        let two = try await h.integration.approve(candidate.id, actor: "u")
        try await h.integration.publish(candidate.id, approval: two.id)
        #expect(try await h.base.store.approvals(candidate: candidate.id).map(\.state).sorted { $0.rawValue < $1.rawValue } == [.consumed, .revoked])
        #expect(try await h.base.store.approval(one.id)?.state == .revoked)
    }

    @Test func aReviewerAttemptCountsOnceAndOnlyAsReviewer() async throws {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(candidate.id, profile: h.passing)
        h.reviewer.set(.minor)
        let attempt = try await h.integration.startReview(candidate.id, provider: .fake, model: "r", criteria: "")
        try await h.integration.collectReview(candidate.id, attempt: attempt)
        await #expect(throws: IntegrationStoreError.reviewAttemptNotUsable(attempt)) {
            _ = try await h.integration.collectReview(candidate.id, attempt: attempt)
        }
        let author = try #require(tree.attemptID)
        await #expect(throws: IntegrationStoreError.reviewAttemptNotUsable(author)) {
            _ = try await h.base.store.recordReview(
                candidate: candidate.id, oid: candidate.candidateOID!, reviewerAttemptID: author, origin: .provider,
                reviewerProvider: .claude, status: .approved, summary: "", findings: []
            )
        }
        #expect(try await h.base.store.reviews(candidate: candidate.id).count == 1)
    }

    @Test func deliveryBranchNamesAreLiteral() async throws {
        let h = try await IntegrationHarness()
        for name in ["@{-1}", "x@{u}", "@"] {
            await #expect(throws: MergeError.invalidBranchName(name)) { _ = try await h.integration.createDeliveryBranch(job: h.base.job, name: name) }
        }
    }

    @Test func reviewReportsAreReadStrictly() {
        let oid = String(repeating: "b", count: 40)
        let approve = #"{"candidateOID": "\#(oid)", "verdict": "approve", "summary": "s", "findings": []}"#
        // CRLF answers read like LF.
        let crlf = "Review:\r\n```json\r\n\(approve)\r\n```\r\n"
        #expect(ReviewReport.parse(crlf, candidateOID: oid, changedPaths: []).status == .approved)
        // An unterminated last block does not fall back to the earlier approval.
        let changed = #"{"candidateOID": "\#(oid)", "verdict": "changes", "summary": "s", "findings": []}"#
        let unterminated = "```json\n\(approve)\n```\nWait, actually:\n```json\n\(changed)\n"
        #expect(ReviewReport.parse(unterminated, candidateOID: oid, changedPaths: []).status == .invalid)
        // A blocking finding outside the diff is no approval and still needs a decision.
        let outside = #"{"candidateOID": "\#(oid)", "verdict": "approve", "summary": "s", "findings": [{"severity": "blocking", "path": "caller.swift", "line": 3, "impact": "breaks callers", "suggestion": "s"}]}"#
        let parsed = ReviewReport.parse(outside, candidateOID: oid, changedPaths: ["a.swift"])
        #expect(parsed.status == .changesRequested)
        #expect(parsed.findings.map(\.severity) == [.major])
    }
}

/// Third review round: a task and its candidate move together, in one store transaction.
@Suite struct IntegrationTaskCouplingTests {
    func move(_ h: IntegrationHarness, _ task: TaskID, to state: TaskState) async throws {
        let version = try #require(try await h.base.store.task(task)).version
        try await h.base.store.execute(Command(.transitionTask(id: task, to: state, expectedVersion: version)))
    }

    @Test func conflictBackToTheAuthorClosesTheCandidate() async throws {
        var h = try await IntegrationHarness()
        let (_, first) = try await h.authorResult("echo 'let a = 2' > src/a.swift")
        let (taskB, second) = try await h.authorResult("echo 'let a = 3' > src/a.swift")
        let a = try await h.accepted(first)
        try await h.integration.publish(a.id, approval: try await h.integration.approve(a.id, actor: "u").id)
        guard case .conflicted(let stale, _) = try await h.integration.buildCandidate(from: second.id) else { Issue.record("expected a conflict"); return }
        try await move(h, taskB, to: .ready)
        #expect(try await h.base.store.candidate(stale.id)?.state == .rejected)
        // Resolving the closed candidate does nothing.
        await #expect(throws: IntegrationError.candidateNotIn(stale.id, .rejected)) {
            try await h.integration.resolveConflicts(stale.id, ["src/a.swift": .theirs])
        }
        // A new author result (on the current target) integrates; the old conflict does not block it.
        let (_, again) = try await h.authorResult("echo 'let a = 4' > src/a.swift", task: taskB)
        guard case .built = try await h.integration.buildCandidate(from: again.id) else { Issue.record("not built"); return }
        // Recovery removes the closed candidate's worktree.
        #expect(try await h.base.store.worktrees().first { $0.id == stale.worktreeID }?.state != .removed)
        try await h.base.restart()
        let restarted = IntegrationService(store: h.base.store, workspace: h.base.service, git: h.base.git, coordinator: RunCoordinator(store: h.base.store, adapters: []))
        _ = try await restarted.recover()
        #expect(try await h.base.store.worktrees().first { $0.id == stale.worktreeID }?.state == .removed)
    }

    @Test func aHeldTaskStopsTheChainWithoutPartialState() async throws {
        let h = try await IntegrationHarness()
        let (task, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(candidate.id, profile: h.passing)
        let attempt = try await h.integration.startReview(candidate.id, provider: .fake, model: "r", criteria: "")
        try await move(h, task, to: .blocked)
        await #expect(throws: IntegrationError.taskNotInVerification(task, .blocked)) {
            _ = try await h.integration.collectReview(candidate.id, attempt: attempt)
        }
        #expect(try await h.base.store.reviews(candidate: candidate.id).isEmpty)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .reviewing)
        // Unblocked, the same review is collected and the task follows its candidate.
        try await move(h, task, to: .verifying)
        try await h.integration.collectReview(candidate.id, attempt: attempt)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .accepted)
        #expect(try await h.base.store.task(task)?.state == .awaitingMerge)
        // Held again while awaiting the merge: no approval, no publication.
        let approval = try await h.integration.approve(candidate.id, actor: "u")
        try await move(h, task, to: .blocked)
        await #expect(throws: IntegrationError.taskNotInVerification(task, .blocked)) { try await h.integration.publish(candidate.id, approval: approval.id) }
        await #expect(throws: IntegrationStoreError.taskCannotFollow(task, from: .blocked, to: .integrated)) {
            _ = try await h.base.store.preparePublication(candidate: candidate.id, approval: approval.id)
        }
        #expect(try await h.base.store.candidate(candidate.id)?.state == .accepted)
    }

    @Test func anEndedTaskCannotPublish() async throws {
        let h = try await IntegrationHarness()
        let (task, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        let target = try await h.target()
        try await move(h, task, to: .cancelled)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .rejected)
        await #expect(throws: IntegrationError.self) { try await h.integration.runTests(candidate.id, profile: h.passing) }
        await #expect(throws: IntegrationError.self) {
            _ = try await h.integration.importReview(candidate.id, text: #"{"candidateOID": "\#(candidate.candidateOID!)", "verdict": "approve", "summary": "", "findings": []}"#)
        }
        #expect(try await h.target() == target)
    }

    @Test func aResultOfATaskBackWithItsAuthorIsNotBuilt() async throws {
        let h = try await IntegrationHarness()
        let (task, tree) = try await h.authorResult("echo eins > a.txt")
        try await move(h, task, to: .needsChanges)
        try await move(h, task, to: .ready)
        try await move(h, task, to: .blocked)
        await #expect(throws: IntegrationError.taskNotInVerification(task, .blocked)) { _ = try await h.integration.buildCandidate(from: tree.id) }
        #expect(try await h.base.store.worktrees().filter { $0.kind == .integration }.allSatisfy { $0.state == .removed })
    }

    @Test func malformedOrUnknownFindingsDoNotApprove() {
        let oid = String(repeating: "c", count: 40)
        let mixed = #"{"candidateOID": "\#(oid)", "verdict": "approve", "summary": "", "findings": [{"severity": "blocking", "path": "a.swift", "line": 1, "impact": "x", "suggestion": "y"}, "also note this"]}"#
        let parsedMixed = ReviewReport.parse(mixed, candidateOID: oid, changedPaths: ["a.swift"])
        #expect(parsedMixed.status == .changesRequested)
        #expect(parsedMixed.findings.map(\.severity) == [.blocking, .comment])
        let single = #"{"candidateOID": "\#(oid)", "verdict": "approve", "summary": "", "findings": {"severity": "blocking"}}"#
        #expect(ReviewReport.parse(single, candidateOID: oid, changedPaths: []).status == .invalid)
        let cased = #"{"candidateOID": "\#(oid)", "verdict": "approve", "summary": "", "findings": [{"severity": "Blocking", "path": "a.swift", "line": 1, "impact": "x", "suggestion": "y"}, {"severity": "critical", "path": "a.swift", "line": 2, "impact": "x", "suggestion": "y"}]}"#
        let parsedCased = ReviewReport.parse(cased, candidateOID: oid, changedPaths: ["a.swift"])
        #expect(parsedCased.status == .changesRequested)
        #expect(parsedCased.findings.map(\.severity) == [.blocking, .major])
    }
}

/// Fourth review round: the publishing window, host-only task moves, retryable resolutions.
@Suite struct IntegrationPublishingWindowTests {
    func move(_ h: IntegrationHarness, _ task: TaskID, to state: TaskState) async throws {
        let version = try #require(try await h.base.store.task(task)).version
        try await h.base.store.execute(Command(.transitionTask(id: task, to: state, expectedVersion: version)))
    }

    @Test func aPublishingTaskCanOnlyBeHeldAndARetryKeepsTheHold() async throws {
        let h = try await IntegrationHarness()
        let (task, tree) = try await h.authorResult("echo eins > a.txt")
        let candidate = try await h.accepted(tree)
        let approval = try await h.integration.approve(candidate.id, actor: "u")
        let operation = try await h.base.store.preparePublication(candidate: candidate.id, approval: approval.id)
        for target in [TaskState.cancelled, .needsChanges] {
            await #expect(throws: StoreError.taskManagedByIntegration(taskID: task, from: .awaitingMerge, to: target)) {
                try await move(h, task, to: target)
            }
        }
        try await move(h, task, to: .blocked)
        // The update failed with the target unchanged: back to accepted, the hold stays.
        try await h.base.store.completeGitOperation(operation, as: .failed, effects: GitOperationEffects(candidateReleased: (candidate.id, .accepted)))
        #expect(try await h.base.store.candidate(candidate.id)?.state == .accepted)
        let held = try #require(try await h.base.store.task(task))
        #expect(held.state == .blocked && held.resumeState == .awaitingMerge)
    }

    @Test func integrationStagesAreNotCommands() async throws {
        let h = try await IntegrationHarness()
        let (task, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        for target in [TaskState.conflict, .awaitingMerge] {
            await #expect(throws: StoreError.taskManagedByIntegration(taskID: task, from: .verifying, to: target)) { try await move(h, task, to: target) }
        }
        // Sending the task back closes its candidate.
        try await move(h, task, to: .needsChanges)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .rejected)

        let (other, second) = try await h.authorResult("echo zwei > b.txt")
        let accepted = try await h.accepted(second)
        await #expect(throws: StoreError.taskManagedByIntegration(taskID: other, from: .awaitingMerge, to: .integrated)) {
            try await move(h, other, to: .integrated)
        }
        await #expect(throws: StoreError.taskManagedByIntegration(taskID: other, from: .awaitingMerge, to: .verifying)) {
            try await move(h, other, to: .verifying)
        }
        #expect(try await h.base.store.candidate(accepted.id)?.state == .accepted)
    }

    @Test func aResolutionInterruptedAfterItsCommitCanBeRetried() async throws {
        let h = try await IntegrationHarness()
        let (_, first) = try await h.authorResult("echo 'let a = 2' > src/a.swift")
        let (task, second) = try await h.authorResult("echo 'let a = 3' > src/a.swift")
        let a = try await h.accepted(first)
        try await h.integration.publish(a.id, approval: try await h.integration.approve(a.id, actor: "u").id)
        guard case .conflicted(let candidate, _) = try await h.integration.buildCandidate(from: second.id) else { Issue.record("expected a conflict"); return }
        let lock = h.base.checkout + "/.git/refs/kaiorx/candidates/\(candidate.id.uuidString).lock"
        try FileManager.default.createDirectory(atPath: (lock as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: lock, contents: Data())
        await #expect(throws: (any Error).self) { try await h.integration.resolveConflicts(candidate.id, ["src/a.swift": .theirs]) }
        #expect(try await h.base.store.candidate(candidate.id)?.state == .conflicted)
        try FileManager.default.removeItem(atPath: lock)
        _ = try await h.base.service.reconcile()
        let built = try await h.integration.resolveConflicts(candidate.id, ["src/a.swift": .theirs])
        #expect(built.state == .built)
        #expect(try await h.base.sh("git rev-parse refs/kaiorx/candidates/\(candidate.id.uuidString)") == built.candidateOID)
        #expect(try await h.base.sh("git rev-parse \(built.candidateOID!)^2") == second.resultOID)
        #expect(try await h.base.store.task(task)?.state == .verifying)
    }

    @Test func findingDecisionsFollowTheFindingsOwnCandidate() async throws {
        let h = try await IntegrationHarness()
        let (task, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(candidate.id, profile: h.passing)
        h.reviewer.set(.minor)
        try await h.review(candidate.id)
        let finding = try #require(try await h.base.store.findings(candidate: candidate.id).first)
        try await move(h, task, to: .blocked)
        await #expect(throws: IntegrationStoreError.taskNotInVerification(task, .blocked)) {
            try await h.integration.decideFinding(finding.id, .accepted, reason: "ok")
        }
        try await move(h, task, to: .verifying)
        try await h.integration.decideFinding(finding.id, .accepted, reason: "ok")
        #expect(try await h.base.store.candidate(candidate.id)?.state == .accepted)
    }

    @Test func severityAndLineAreReadStrictly() {
        let oid = String(repeating: "d", count: 40)
        func parse(_ finding: String) -> ReviewReport.Parsed {
            ReviewReport.parse(#"{"candidateOID": "\#(oid)", "verdict": "approve", "summary": "", "findings": [\#(finding)]}"#, candidateOID: oid, changedPaths: ["a.swift"])
        }
        let newline = parse(#"{"severity": "blocking\n", "path": "a.swift", "line": 1, "impact": "x", "suggestion": "y"}"#)
        #expect(newline.status == .changesRequested && newline.findings.map(\.severity) == [.blocking])
        #expect(parse(#"{"severity": 1, "path": "a.swift", "line": 1, "impact": "x", "suggestion": "y"}"#).findings.map(\.severity) == [.major])
        #expect(parse(#"{"severity": "minor", "path": "a.swift", "line": true, "impact": "x", "suggestion": "y"}"#).findings.map(\.severity) == [.comment])
        #expect(parse(#"{"severity": "minor", "path": "a.swift", "line": 2.5, "impact": "x", "suggestion": "y"}"#).findings.map(\.severity) == [.comment])
    }
}
