import Domain
import Foundation
import Providers
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workbench
@testable import Workspace

extension Tag {
    /// Needs the candidate chain's driver (`CandidateChain`, WP2): fails against its skeleton,
    /// which throws `ChainError.notImplemented`.
    @Tag static var chainDriver: Self
}

/// The app's services on a temporary repository with fake adapters: the author `.fake` (with
/// `writes`, it writes those files into its worktree) and the reviewer `.codex`, which approves
/// exactly the commit its prompt names.
struct ChainFixture {
    let services: AppServices
    let actions: WorkbenchActions
    let repo: String
    let project: ProjectID

    var store: Store { services.store }
    var workspace: WorkspaceService { services.workspace! }
    var integration: IntegrationService { services.integration! }

    init(_ name: String, writes: [String: String] = [:], reviewer: @escaping @Sendable (AttemptSpec) -> FakeScript = ChainFixture.approve) async throws {
        let folder = try temporaryFolder(name)
        repo = folder + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try await sh("git init -q -b main && echo a > README.md && git add -A && git commit -qm start", in: repo)
        let author = FakeAdapter(provider: .fake) { spec in
            if spec.role == .author, let root = spec.workingDirectory {
                for (path, content) in writes {
                    let file = URL(filePath: root).appending(path: path)
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? content.write(to: file, atomically: true, encoding: .utf8)
                }
            }
            return .success()
        }
        let configuration = AppConfiguration(
            databasePath: folder + "/db.sqlite", workspaceRoot: folder + "/ws",
            adapters: { _ in [author, FakeAdapter(provider: .codex, script: reviewer)] }, gate: FakeGate()
        )
        guard case .ready(let services) = await AppBootstrap.start(configuration) else { throw ActionError.unavailable("start") }
        self.services = services
        actions = WorkbenchActions(services: services)
        project = try await actions.openProject(at: repo)
    }

    /// An approving report for the candidate the prompt names ("Review candidate <oid> …").
    static let approve: @Sendable (AttemptSpec) -> FakeScript = { spec in
        let words = spec.prompt.split(separator: " ")
        let oid = words.count > 2 ? String(words[2]) : ""
        return .success(text: "```json\n{\"candidateOID\": \"\(oid)\", \"verdict\": \"approve\", \"summary\": \"passt\", \"findings\": []}\n```")
    }

    /// A confirmed test profile running `script` (the gate only counts confirmed profiles).
    @discardableResult
    func confirmProfile(_ script: String = "exit 0") async throws -> TestProfileRecord {
        let profile = try await actions.proposeTestProfile(project: project, TestProfileSpec(name: "Schnelltest", executable: "/bin/sh", arguments: ["-c", script]))
        return try await actions.confirmTestProfile(profile.id, digest: profile.digest)
    }

    func pending(resultCheck: @escaping @Sendable (TaskID) async throws -> ResultCheck? = { _ in nil }) async throws -> [PendingDecision] {
        let integration = self.integration
        return try await PendingDecisions.collect(
            try await Projector(store: store).load(), project: project, gate: { try await integration.gateItems($0) },
            openFindings: { _ in false }, resultCheck: resultCheck
        )
    }

    func close() async { await AppBootstrap.shutdown(services) }
}

/// The Workbench side of the candidate chain (ADR 0011): pending decisions, sheets, projection,
/// and the actions that do not need the driver.
@Suite struct CandidateChainActionTests {
    @Test func theChainIsBuiltWithTheOtherGitServices() async throws {
        let f = try await ChainFixture("chain-boot")
        #expect(f.services.chain != nil && f.services.scheduler != nil && f.services.integration != nil)
        await f.close()
    }

    @Test func pendingDecisionsAskForTestsThenAReviewThenThePublication() async throws {
        let f = try await ChainFixture("chain-pending")
        let (_, _, candidate) = try await UITestSeed.builtCandidate(services: f.services, project: f.project, title: "Leerwert")
        var pending = try await f.pending()
        #expect(pending.contains(.tests(candidate.id)) && PendingDecision.tests(candidate.id).id == "tests:\(candidate.id.uuidString)")
        try await f.confirmProfile()
        _ = try await f.actions.runTests(candidate.id)
        pending = try await f.pending()
        #expect(pending.contains(.review(candidate.id)) && !pending.contains(.tests(candidate.id)))
        #expect(PendingDecision.review(candidate.id).id == "review:\(candidate.id.uuidString)")
        let commit = try #require(candidate.candidateOID)
        let review = try await f.actions.importReview(
            candidate.id, text: #"{"candidateOID": "\#(commit)", "verdict": "approve", "summary": "ok", "findings": []}"#
        )
        #expect(review.origin == .userImported && review.status == .approved)
        pending = try await f.pending()
        #expect(pending.contains(.publish(candidate.id)) && !pending.contains(.review(candidate.id)))
        await f.close()
    }

    @Test func pendingDecisionsAskForConflictsAndForResultsTheDriverLeavesToTheUser() async throws {
        let f = try await ChainFixture("chain-pending-result")
        let (_, conflictedTask, conflicted) = try await UITestSeed.conflicted(services: f.services, project: f.project, title: "Konflikt")
        #expect(conflicted.state == .conflicted && conflicted.conflicts == ["KONFLIKT.md"])
        #expect(try await f.store.task(conflictedTask)?.state == .conflict)
        let (_, task, _) = try await UITestSeed.undeclared(services: f.services, project: f.project, title: "Doku")
        // Without the chain's check no result decision is derived.
        var pending = try await f.pending()
        #expect(pending.contains(.conflicts(conflicted.id)) && PendingDecision.conflicts(conflicted.id).id == "conflicts:\(conflicted.id.uuidString)")
        #expect(!pending.contains(.result(task)))
        pending = try await f.pending { $0 == task ? .undeclared(resultOID: "abc", rejected: ["NOTIZ.md": "outsideAllowedPaths"]) : nil }
        #expect(pending.contains(.result(task)) && PendingDecision.result(task).id == "result:\(task.uuidString)")
        // A result the driver builds itself is not a decision.
        pending = try await f.pending { _ in .buildable(resultOID: "abc") }
        #expect(!pending.contains(.result(task)))
        #expect(PendingDecisions.needsUser(.empty) && PendingDecisions.needsUser(.contained(tip: "t")) && PendingDecisions.needsUser(.planTaskMissing))
        #expect(!PendingDecisions.needsUser(.awaitingSeal) && !PendingDecisions.needsUser(.candidate(CandidateID())))
        await f.close()
    }

    @Test func theProjectionSeesSealsCandidatesReviewersAndReviews() async throws {
        let f = try await ChainFixture("chain-projection")
        let seeded = try await UITestSeed.authorResult(services: f.services, project: f.project, title: "Notiz", writes: ["NOTIZ.md": "neu\n"])
        let projector = Projector(store: f.store)
        var state = try await projector.load()
        #expect(state.resultWorktree(of: seeded.task)?.id == seeded.worktree && state.resultWorktree(of: seeded.task)?.sealStatus == nil)
        #expect(try await f.store.task(seeded.task)?.state == .resultReady)

        // The seal arrives through a worktree event (no task, no attempt on it).
        _ = try await f.workspace.seal(seeded.worktree, allowedPrefixes: nil, message: "Notiz")
        var old = state
        state = try #require(try await projector.step()).state
        #expect(state.resultWorktree(of: seeded.task)?.sealStatus == .committed)
        #expect(Announcements.changes(from: old, to: state).contains("Notiz: Ergebnis versiegelt"))

        guard case .built(let candidate) = try await f.integration.buildCandidate(from: seeded.worktree) else { Issue.record("not built"); return }
        old = state
        state = try #require(try await projector.step()).state
        #expect(state.openCandidate(of: seeded.task)?.id == candidate.id)
        #expect(Announcements.changes(from: old, to: state).contains("Notiz: Kandidat gebaut"))
        try await f.confirmProfile()
        _ = try await f.actions.runTests(candidate.id)
        state = try #require(try await projector.step()).state
        let reviewing = try #require(state.candidates[candidate.id])
        #expect(state.needsReview(reviewing))

        // A reviewer reads exactly the candidate's commit; until its review is collected the
        // candidate does not wait for the user.
        let reviewer = try await f.integration.startReview(candidate.id, provider: .codex, model: "r", criteria: "- passt")
        _ = try await f.services.coordinator.waitUntilFinished(reviewer)
        old = state
        state = try #require(try await projector.step()).state
        #expect(state.reviewers(of: reviewing).map(\.id) == [reviewer])
        #expect(state.attempts[reviewer]?.state == .succeeded && state.openReviewer(of: seeded.task) == nil)
        #expect(!state.needsReview(reviewing))
        _ = try await f.integration.collectReview(candidate.id, attempt: reviewer)
        old = state
        state = try #require(try await projector.step()).state
        #expect(state.reviews[candidate.id]?.map(\.status) == [.approved])
        #expect(Announcements.changes(from: old, to: state).contains("Notiz: Review eingegangen"))
        // The removed reviewer worktree still binds the reviewer to the commit.
        #expect(state.reviewers(of: reviewing).map(\.id) == [reviewer])
        #expect(state.candidates[candidate.id]?.state == .accepted)
        // A fresh load shows the same rows.
        let fresh = try await Projector(store: f.store).load()
        #expect(fresh.worktrees == state.worktrees && fresh.reviews == state.reviews)
        await f.close()
    }

    @Test func discardGrantsFirstThenSendsThePlanTaskBack() async throws {
        let f = try await ChainFixture("chain-discard")
        let planTask = PlanTaskDraft(key: "doku", title: "Doku", criteria: ["Leerwert dokumentiert"], writePaths: ["docs/"])
        let seeded = try await UITestSeed.authorResult(
            services: f.services, project: f.project, title: "Doku", writes: ["NOTIZ.md": "außerhalb\n"], planTask: planTask
        )
        let area = try await f.actions.writeArea(of: seeded.task)
        #expect(area == .paths(["docs/"]))
        let report = try await f.workspace.seal(seeded.worktree, allowedPrefixes: ["docs/"], message: "Doku")
        #expect(report.status == .rejectedOnly)
        let task = try #require(try await f.store.task(seeded.task))
        let shown = ShownResult(
            task: task.id, taskVersion: task.version, worktree: seeded.worktree, resultOID: nil, rejected: ["NOTIZ.md"],
            check: .rejectedOnly(rejected: ["NOTIZ.md": "outsideAllowedPaths"])
        )
        let sheet = DecisionSheet.resultDecision(shown, task: task, writeArea: .paths(["docs/"]), issue: nil)
        #expect(sheet.title == "Ergebnis verwerfen" && sheet.canApprove && sheet.result == shown)
        #expect(sheet.scope.contains("Verworfen: NOTIZ.md – außerhalb des Schreibbereichs") && sheet.scope.contains("Die Zählung der Versuche beginnt neu."))

        // A stale sheet grants nothing.
        var stale = shown
        stale.taskVersion -= 1
        await #expect(throws: ChainError.shownStateChanged) { try await f.actions.discardResult(stale) }
        #expect(try await f.store.decisions(task: task.id).allSatisfy { $0.rule != "userGrant" })

        try await f.actions.discardResult(shown)
        let after = try #require(try await f.store.task(task.id))
        #expect(after.state == .needsChanges)
        let grant = try #require(try await f.store.decisions(task: task.id).last { $0.rule == "userGrant" })
        #expect(grant.actor == WorkbenchActor.user && grant.evidence["afterOrdinal"] == "1")
        let events = try await f.store.eventHeaders(after: 0, project: f.project, limit: 10_000).filter { $0.taskID == task.id }
        let granted = try #require(events.last { $0.kind == .policyDecided }?.seq)
        let sentBack = try #require(events.last { $0.kind == .taskStateChanged }?.seq)
        #expect(granted < sentBack)
        // Discarding again refuses: the task is no longer where the sheet saw it.
        await #expect(throws: ChainError.shownStateChanged) { try await f.actions.discardResult(shown) }

        // With consent, the next scheduler tick hands the task to a new author (the seed ran
        // under the local account, which the task keeps).
        for provider in [ProviderKind.fake, .codex] {
            try await f.actions.grantConsent(project: f.project, provider: provider)
            let account = try await f.store.registerAccount(provider: provider, identity: "local")
            if try await f.store.budgetRemaining(account: account, job: seeded.job) == nil {
                try await f.store.createBudget(account: account, job: seeded.job, tokenLimit: 200_000)
            }
        }
        for tier in CapabilityTier.allCases {
            try await f.store.registerModelProfile(ModelProfile(provider: .fake, role: .author, tier: tier, model: "f-\(tier.rawValue)", typicalTokens: 1_000, verifiedAt: 1))
        }
        try await f.store.registerModelProfile(ModelProfile(provider: .codex, role: .reviewer, tier: .fast, model: "r", typicalTokens: 500, verifiedAt: 1))
        let tick = try await f.services.scheduler!.tick()
        #expect(tick.reserved.count == 1, "\(tick)")
        let authors = try await f.store.attempts(taskID: task.id).filter { $0.role == .author }
        #expect(authors.map(\.ordinal).sorted() == [1, 2])
        await f.close()
    }

    @Test func discardIsOnlyForPlanTasksAndOnlyForAResult() async throws {
        let f = try await ChainFixture("chain-discard-plan")
        let (_, task, tree) = try await UITestSeed.empty(services: f.services, project: f.project, title: "Leer")
        let record = try #require(try await f.store.task(task))
        #expect(try await f.actions.writeArea(of: task) == .wholeProject)
        let shown = ShownResult(task: task, taskVersion: record.version, worktree: tree, resultOID: nil, rejected: [], check: .empty)
        await #expect(throws: ChainActionError.notAPlanTask(task)) { try await f.actions.discardResult(shown) }
        var candidate = shown
        candidate.check = .candidate(CandidateID())
        await #expect(throws: ChainActionError.nothingToDecide(task)) { try await f.actions.discardResult(candidate) }
        #expect(try await f.store.task(task)?.state == .resultReady)
        let sheet = DecisionSheet.discardResult(shown, task: record, issue: .buildFailed("kaputt"))
        #expect(sheet.blockers == ["Nur Aufgaben aus einem Plan lassen sich neu bearbeiten lassen."] && !sheet.canApprove)
        #expect(sheet.scope.contains("Bauen fehlgeschlagen: kaputt"))
        await f.close()
    }

    @Test func conflictSideDiffsReadEachSideFromTheMergeBase() async throws {
        let f = try await ChainFixture("chain-sides")
        let (_, _, candidate) = try await UITestSeed.conflicted(services: f.services, project: f.project, title: "Konflikt")
        let authorAttempt = try #require(candidate.authorAttemptID)
        let authorTree = try #require(try await f.store.attempt(authorAttempt)?.worktreeID)
        let base = try #require(try await f.store.worktree(authorTree)?.baseOID)
        let preview = ConflictPreview(
            shown: ShownConflicts(candidate: candidate.id, version: candidate.version, paths: ["KONFLIKT.md"]), kind: .implementation,
            mergeBase: base, target: candidate.previousTargetOID, result: try #require(candidate.resultOID),
            rows: [ConflictRow(path: "KONFLIKT.md", kind: .bothAdded)]
        )
        let ran = try await f.actions.conflictSideDiff(preview, path: "KONFLIKT.md", side: .result)
        let moved = try await f.actions.conflictSideDiff(preview, path: "KONFLIKT.md", side: .target)
        #expect(ran.text.contains("+Stand des Ergebnisses") && !ran.text.contains("Stand der Integration"))
        #expect(moved.text.contains("+Stand der Integration") && !moved.text.contains("Stand des Ergebnisses"))
        #expect(try await f.actions.conflictSideDiff(preview, path: "README.md", side: .result).text.isEmpty)
        var revert = preview
        revert.mergeBase = nil
        #expect(try await f.actions.conflictSideDiff(revert, path: "KONFLIKT.md", side: .result).text.isEmpty)
        // Every shown path needs a choice before anything is resolved.
        await #expect(throws: MergeError.unresolved(["KONFLIKT.md"])) { try await f.actions.resolveConflicts(preview, choices: [:]) }
        #expect(try await f.store.candidate(candidate.id)?.state == .conflicted)

        let task = try await f.store.task(try #require(candidate.taskID))
        var sheet = DecisionSheet.resolveConflicts(preview, candidate: candidate, task: task, choices: [:])
        #expect(sheet.blockers == ["Noch ohne Entscheidung: 1 Datei"] && sheet.conflicts == preview.shown)
        #expect(sheet.scope.contains("KONFLIKT.md: Beide neu angelegt – noch offen"))
        sheet = DecisionSheet.resolveConflicts(preview, candidate: candidate, task: task, choices: ["KONFLIKT.md": .result])
        #expect(sheet.canApprove && sheet.scope.contains("KONFLIKT.md: Beide neu angelegt – Ergebnis übernehmen"))
        await f.close()
    }

    @Test func reviewStartsWithBlockersAndEmptyImportsAreRefusedBeforeTheDriver() async throws {
        let f = try await ChainFixture("chain-review-guard")
        let (_, _, candidate) = try await UITestSeed.builtCandidate(services: f.services, project: f.project, title: "Leerwert")
        let option = ReviewOption(
            provider: .codex, model: "r", modelProfileID: nil, accountID: nil, consentID: nil, criteria: "- passt",
            candidateOID: candidate.candidateOID ?? "", candidateVersion: candidate.version, blockers: [.slotsFull(global: true)], automationNote: nil
        )
        await #expect(throws: ChainActionError.reviewBlocked(["Alle Plätze sind belegt"])) { try await f.actions.startReview(option, candidate: candidate.id) }
        await #expect(throws: ChainActionError.emptyReview) { try await f.actions.importReview(candidate.id, text: "  \n") }
        let taskID = try #require(candidate.taskID)
        #expect(try await f.store.attempts(taskID: taskID).allSatisfy { $0.role == .author })
        await f.close()
    }

    @Test func seedsLeaveTheStatesTheirNamesSay() async throws {
        let f = try await ChainFixture("chain-seeds")
        let undeclared = try await UITestSeed.undeclared(services: f.services, project: f.project, title: "Doku")
        let tree = try await f.workspace.worktree(undeclared.worktree)
        #expect(tree.sealStatus == .committed && tree.rejectedPaths == ["NOTIZ.md": "outsideAllowedPaths"])
        let attemptID = try #require(try await f.store.task(undeclared.task)?.currentAttemptID)
        let attempt = try #require(try await f.store.attempt(attemptID))
        #expect(attempt.planID != nil && attempt.state == .succeeded)
        // The seed's consent is gone again: nothing else starts under it.
        let consents = try await f.store.consents(project: f.project)
        #expect(!consents.isEmpty && consents.allSatisfy { $0.revokedAt != nil })
        let empty = try await UITestSeed.empty(services: f.services, project: f.project, title: "Leer")
        #expect(try await f.workspace.worktree(empty.worktree).sealStatus == .empty)
        #expect(try await f.store.task(empty.task)?.state == .resultReady)
        let built = try await UITestSeed.builtCandidate(services: f.services, project: f.project, title: "Gebaut")
        #expect(built.candidate.state == .built)
        #expect(try await f.store.task(built.task)?.state == .verifying)
        await f.close()
    }
}

/// The sheets, built from typed values only.
@Suite struct ChainSheetTests {
    let task = TaskRecord(id: TaskID(), jobID: JobID(), title: "Doku", state: .resultReady, currentAttemptID: nil, planKey: "doku", version: 3, createdAt: 1)

    func shown(_ check: ResultCheck, rejected: [String] = []) -> ShownResult {
        ShownResult(task: task.id, taskVersion: 3, worktree: WorktreeID(), resultOID: "abc123", rejected: rejected, check: check)
    }

    func candidate(_ state: CandidateState, kind: CandidateKind = .implementation) -> CandidateRecord {
        CandidateRecord(
            id: CandidateID(), projectID: ProjectID(), jobID: task.jobID, taskID: task.id, kind: kind, authorAttemptID: AttemptID(),
            authorProvider: .claude, resultOID: "r", revertsCandidateID: nil, previousTargetOID: "p", candidateOID: state == .conflicted ? nil : "c",
            targetRef: "refs/kaiorx/integrations/x", worktreeID: nil, state: state, conflicts: [], version: 2, createdAt: 1
        )
    }

    @Test func undeclaredPathsNameEachPathItsReasonAndTheWriteArea() {
        let check = ResultCheck.undeclared(resultOID: "abc123", rejected: ["NOTIZ.md": "outsideAllowedPaths", "link": "symlink", "x": "recoveredUnknown"])
        let result = shown(check, rejected: ["x", "NOTIZ.md", "link"])
        let sheet = DecisionSheet.resultDecision(result, task: task, writeArea: .paths(["docs/"]), issue: nil)
        #expect(sheet.title == "Abweichende Änderungen" && sheet.approveLabel == "Ohne diese Pfade bauen" && sheet.rejectLabel == "Nicht bauen")
        #expect(sheet.scope.contains("Schreibbereich: docs/") && sheet.scope.contains("Ergebniscommit: abc123"))
        #expect(sheet.scope.filter { $0.hasPrefix("Verworfen: ") } == [
            "Verworfen: NOTIZ.md – außerhalb des Schreibbereichs", "Verworfen: link – symbolischer Link", "Verworfen: x – nach Neustart ermittelt",
        ])
        #expect(sheet.canApprove && sheet.result == result && sheet.shown == nil && sheet.ifRejected.contains("kein Kandidat"))
        var held = task
        held.state = .blocked
        #expect(DecisionSheet.undeclaredPaths(result, task: held, writeArea: .wholeProject).blockers == ["Aufgabe angehalten"])
        #expect(!DecisionSheet.undeclaredPaths(shown(.empty), task: task, writeArea: .wholeProject).canApprove)
    }

    @Test func emptyAndContainedResultsAreAcceptedAsDone() {
        let empty = DecisionSheet.resultDecision(shown(.empty), task: task, writeArea: .wholeProject, issue: nil, tip: "tip1")
        #expect(empty.title == "Leeres Ergebnis" && empty.scope.contains("Integrationsstand: tip1") && empty.canApprove)
        let contained = DecisionSheet.resultDecision(shown(.contained(tip: "tip2")), task: task, writeArea: .wholeProject, issue: nil)
        #expect(contained.title == "Schon enthalten" && contained.scope.contains("Integrationsstand: tip2"))
        #expect(contained.approveLabel == "Als erledigt annehmen" && contained.rejectLabel == "Nicht annehmen")
        #expect(!DecisionSheet.emptyResult(shown(.buildable(resultOID: "x")), task: task).canApprove)
    }

    @Test func aDiscardSaysTheCountRestartsAndMayUseQuota() {
        let sheet = DecisionSheet.resultDecision(shown(.planTaskMissing), task: task, writeArea: .planTaskMissing, issue: .planTaskMissing)
        #expect(sheet.title == "Ergebnis verwerfen" && sheet.approveLabel == "Verwerfen und neu bearbeiten lassen")
        #expect(sheet.scope.contains("Ein neuer Lauf kann Kontingent verbrauchen.") && sheet.canApprove)
        #expect(!DecisionSheet.discardResult(shown(.notApplicable), task: task, issue: nil).canApprove)
    }

    @Test func aReviewStartShowsTheReviewerAndItsBlockersButTheGateOnlyAsInformation() {
        let built = candidate(.reviewing)
        var option = ReviewOption(
            provider: .codex, model: "gpt-r", modelProfileID: nil, accountID: nil, consentID: nil, criteria: "- Leerwert dokumentiert",
            candidateOID: "c", candidateVersion: 2, blockers: [], automationNote: "Codex startet nicht automatisch"
        )
        var sheet = DecisionSheet.startReview(option, candidate: built, task: task)
        #expect(sheet.canApprove && sheet.review == option && sheet.approveLabel == "Review starten" && sheet.rejectLabel == "Nicht jetzt")
        #expect(sheet.scope.contains("Prüfer: Codex · gpt-r") && sheet.scope.contains("Autor: Claude – der Prüfer kommt von einem anderen Anbieter"))
        #expect(sheet.scope.contains("Diff und Testbelege gehen an Codex.") && sheet.scope.contains { $0.contains("Codex startet nicht automatisch") })
        option.blockers = [.noReviewerConsent, .slotsFull(global: false)]
        sheet = DecisionSheet.startReview(option, candidate: built, task: task)
        #expect(sheet.blockers == ["Für Codex fehlt die Zustimmung als Prüfer", "Alle Plätze des Prüferkontos bei Codex sind belegt"])
        option.blockers = []
        option.candidateVersion = 1
        #expect(!DecisionSheet.startReview(option, candidate: built, task: task).canApprove)
        #expect(DecisionSheet.startReview(nil, candidate: built, task: task).blockers == ["Kein Prüfer von einem anderen Anbieter verfügbar"])
    }

    @Test func anImportedReviewIsReportedText() {
        let reviewing = candidate(.reviewing)
        let sheet = DecisionSheet.importReview(reviewing, task: task, text: "{\"verdict\": \"approve\"}")
        #expect(sheet.reported == "{\"verdict\": \"approve\"}" && sheet.canApprove && !sheet.scope.contains { $0.contains("approve") })
        #expect(DecisionSheet.importReview(reviewing, task: task, text: " ").blockers == ["Füge den Text des Reviews ein."])
        #expect(!DecisionSheet.importReview(candidate(.built), task: task, text: "x").canApprove)
    }

    @Test func aRevertsConflictTakesTheReversal() {
        let conflicted = candidate(.conflicted, kind: .revert)
        let preview = ConflictPreview(
            shown: ShownConflicts(candidate: conflicted.id, version: 2, paths: ["a", "b"]), kind: .revert, mergeBase: nil, target: "p", result: "q",
            rows: [ConflictRow(path: "a", kind: .bothModified), ConflictRow(path: "b", kind: .deletedByThem)]
        )
        var sheet = DecisionSheet.resolveConflicts(preview, candidate: conflicted, task: task, choices: ["a": .result])
        #expect(sheet.blockers == ["Noch ohne Entscheidung: 1 Datei"] && sheet.scope.contains("a: Beide geändert – Rücknahme übernehmen"))
        #expect(sheet.scope.contains("Rücknahme: q"))
        sheet = DecisionSheet.resolveConflicts(preview, candidate: conflicted, task: task, choices: ["a": .target, "b": .delete])
        #expect(sheet.canApprove && sheet.scope.contains("b: Im Ergebnis gelöscht, im Integrationsstand geändert – Datei löschen"))
        var moved = conflicted
        moved.version = 3
        #expect(!DecisionSheet.resolveConflicts(preview, candidate: moved, task: task, choices: ["a": .target, "b": .delete]).canApprove)
    }

    @Test func chainErrorsReadInGerman() {
        #expect(ChainMessages.text(ChainError.shownStateChanged).hasPrefix("Der Stand hat sich geändert"))
        #expect(ChainMessages.text(ChainError.busy(TaskID())).contains("gerade bearbeitet"))
        #expect(ChainMessages.text(MergeError.unresolved(["a", "b"])) == "Für diese Dateien fehlt noch eine Entscheidung: a, b")
        #expect(ChainMessages.text(MergeError.nothingToCommit).contains("nichts zu integrieren"))
        #expect(ChainMessages.text(PlanningError.noReviewerConsent(.codex)) == "Für Codex fehlt die Zustimmung als Prüfer.")
        #expect(ChainMessages.text(ChainActionError.notAPlanTask(TaskID())).hasPrefix("Nur Aufgaben aus einem Plan"))
        #expect(ChainMessages.text(ActionError.unavailable("Kandidatenkette")) == "Nicht verfügbar: Kandidatenkette.")
    }
}

/// Actions that go through the driver. They fail against the WP0 skeleton
/// (`ChainError.notImplemented`) and pass once `CandidateChain` (WP2) is in.
@Suite(.tags(.chainDriver)) struct CandidateChainDriverActionTests {
    @Test func aResultCheckBindsTheSheetAndConfirmingBuildsWithoutTheDroppedPath() async throws {
        let f = try await ChainFixture("chain-driver-undeclared")
        let seeded = try await UITestSeed.undeclared(services: f.services, project: f.project, title: "Doku")
        _ = await f.services.chain!.step()
        #expect(try await f.store.candidates(jobID: seeded.job).isEmpty)
        let (shown, issue) = try await f.actions.resultCheck(seeded.task)
        guard case .undeclared(_, let rejected) = shown.check else { Issue.record("\(shown.check)"); return }
        #expect(rejected == ["NOTIZ.md": "outsideAllowedPaths"] && shown.rejected == ["NOTIZ.md"] && issue == nil)
        let chain = f.services.chain!
        let pending = try await f.pending { try await chain.check($0) }
        #expect(pending.contains(.result(seeded.task)))
        var stale = shown
        stale.taskVersion -= 1
        await #expect(throws: (any Error).self) { try await f.actions.confirmUndeclared(stale) }
        guard case .built(let candidate) = try await f.actions.confirmUndeclared(shown) else { Issue.record("not built"); return }
        let files = try await f.actions.changes(of: candidate).map(\.path)
        #expect(files == ["docs/LEERWERT.md"])
        await f.close()
    }

    @Test func anEmptyResultIsAcceptedOnlyByTheUser() async throws {
        let f = try await ChainFixture("chain-driver-empty")
        let seeded = try await UITestSeed.empty(services: f.services, project: f.project, title: "Leer")
        for _ in 0..<3 { _ = await f.services.chain!.step() }
        #expect(try await f.store.task(seeded.task)?.state == .resultReady)
        let (shown, _) = try await f.actions.resultCheck(seeded.task)
        #expect(shown.check == .empty)
        try await f.actions.acceptEmptyResult(shown)
        #expect(try await f.store.task(seeded.task)?.state == .integrated)
        await f.close()
    }

    @Test func aConflictIsPreviewedAndResolvedIntoACandidate() async throws {
        let f = try await ChainFixture("chain-driver-conflict")
        let (_, _, candidate) = try await UITestSeed.conflicted(services: f.services, project: f.project, title: "Konflikt")
        let preview = try await f.actions.conflictPreview(candidate.id)
        #expect(preview.rows == [ConflictRow(path: "KONFLIKT.md", kind: .bothAdded)] && preview.mergeBase != nil)
        #expect(preview.shown == ShownConflicts(candidate: candidate.id, version: candidate.version, paths: ["KONFLIKT.md"]))
        let resolved = try await f.actions.resolveConflicts(preview, choices: ["KONFLIKT.md": .result])
        #expect(resolved.state == .built && resolved.candidateOID != nil)
        await f.close()
    }
}
