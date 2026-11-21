import Domain
import Foundation
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workbench
@testable import Workspace

/// Regressions from the review of the candidate chain in the app (ADR 0011): pending decisions
/// survive a failing check and include lasting seal or build failures, refused collects and the
/// missing chain are shown instead of an endless active status, the rework wait has its own
/// text, and the German texts read correctly. Fake providers only.
@Suite struct ChainUIRegressionTests {
    struct CheckFailed: Error {}

    @Test func oneFailingResultCheckKeepsEveryOtherDecision() async throws {
        let f = try await ChainFixture("chain-ui-check-fails")
        let (_, _, candidate) = try await UITestSeed.builtCandidate(services: f.services, project: f.project, title: "Leerwert")
        let (_, broken, _) = try await UITestSeed.undeclared(services: f.services, project: f.project, title: "Doku")
        let (_, empty, _) = try await UITestSeed.empty(services: f.services, project: f.project, title: "Leer")
        // The check of one task fails (for example a moved checkout); the others stay listed.
        let pending = try await f.pending { id in
            if id == broken { throw CheckFailed() }
            return id == empty ? .empty : nil
        }
        #expect(pending.contains(.tests(candidate.id)))
        #expect(pending.contains(.result(empty)))
        #expect(!pending.contains(.result(broken)))
        await f.close()
    }

    @Test func aLastingSealOrBuildFailureIsAPendingDecision() async throws {
        let f = try await ChainFixture("chain-ui-build-fails")
        let seeded = try await UITestSeed.authorResult(services: f.services, project: f.project, title: "Notiz", writes: ["NOTIZ.md": "neu\n"])
        let task = seeded.task
        func pending(_ check: ResultCheck, _ issue: ChainIssue?) async throws -> Bool {
            try await PendingDecisions.collect(
                try await Projector(store: f.store).load(), project: f.project, gate: { _ in [] }, openFindings: { _ in false },
                resultCheck: { _ in check }, chainIssue: { _ in issue }
            ).contains(.result(task))
        }
        #expect(try await pending(.awaitingSeal, .sealFailed("Worktree gesperrt")))
        #expect(try await pending(.buildable(resultOID: "abc"), .buildFailed("Merge fehlgeschlagen")))
        // Without an issue the driver moves the result on by itself; review and rebuild issues
        // are not result decisions.
        #expect(try await !pending(.buildable(resultOID: "abc"), nil))
        #expect(try await !pending(.awaitingSeal, nil))
        #expect(try await !pending(.buildable(resultOID: "abc"), .collectFailed("x")))
        #expect(try await !pending(.buildable(resultOID: "abc"), .containedAfterRebuild))
        #expect(PendingDecisions.needsUser(ChainIssue.planTaskMissing))
        #expect(!PendingDecisions.needsUser(ChainIssue?.none))
        await f.close()
    }

    @Test func aRefusedCollectIsShownAndOffersANewReview() async throws {
        let f = try await ChainFixture("chain-ui-collect")
        let (_, task, candidate) = try await UITestSeed.builtCandidate(services: f.services, project: f.project, title: "Leerwert")
        try await f.confirmProfile()
        _ = try await f.actions.runTests(candidate.id)
        let reviewer = try await f.integration.startReview(candidate.id, provider: .codex, model: "r", criteria: "- passt")
        _ = try await f.services.coordinator.waitUntilFinished(reviewer)
        let state = try await Projector(store: f.store).load()
        let reviewing = try #require(state.candidates[candidate.id])
        #expect(reviewing.state == .reviewing && state.attempts[reviewer]?.state == .succeeded)

        // A finished, not yet collected reviewer: on its way while the chain collects it.
        #expect(state.reviewStatus(of: reviewing, issue: nil, chainAvailable: true).text == "Review wird übernommen …")
        #expect(!state.needsReview(reviewing))
        // The driver gave up collecting it: the status says so and a new review is offered.
        let refused = ChainIssue.collectFailed("Store gesperrt")
        #expect(state.reviewStatus(of: reviewing, issue: refused, chainAvailable: true) == WorkspaceState.reviewNotCollected)
        #expect(state.needsReview(reviewing, collectFailed: true))
        var pending = try await f.pending()
        #expect(!pending.contains(.review(candidate.id)))
        pending = try await PendingDecisions.collect(
            state, project: f.project, gate: { _ in [] }, openFindings: { _ in false }, chainIssue: { $0 == task ? refused : nil }
        )
        #expect(pending.contains(.review(candidate.id)))
        // Without the chain nothing is collected: never „wird übernommen“.
        let unavailable = state.reviewStatus(of: reviewing, issue: nil, chainAvailable: false)
        #expect(unavailable.text.contains("nicht verfügbar") && unavailable.tone == .failure)
        // A review recorded meanwhile wins over the refused collect.
        let commit = try #require(reviewing.candidateOID)
        _ = try await f.actions.importReview(candidate.id, text: #"{"candidateOID": "\#(commit)", "verdict": "approve", "summary": "ok", "findings": []}"#)
        let later = try await Projector(store: f.store).load()
        let accepted = try #require(later.candidates[candidate.id])
        #expect(later.reviewStatus(of: accepted, issue: refused, chainAvailable: true).text == "Zugestimmt")
        await f.close()
    }

    @Test func theResultStatusIsNeverSealingWithoutTheChain() {
        let shown = ShownResult(task: TaskID(), taskVersion: 1, worktree: WorktreeID(), resultOID: "abc", rejected: [], check: .buildable(resultOID: "abc"))
        #expect(Labels.resultStatus(nil, issue: nil, chainAvailable: false) == Labels.chainUnavailable)
        #expect(Labels.resultStatus(shown, issue: nil, chainAvailable: false) == Labels.chainUnavailable)
        #expect(Labels.chainUnavailable.tone == .failure && Labels.chainUnavailable.text.contains("Git-Arbeit angehalten"))
        #expect(Labels.resultStatus(nil, issue: nil, chainAvailable: true).text == "Wird versiegelt …")
        #expect(Labels.resultStatus(nil, issue: .sealFailed("gesperrt"), chainAvailable: true).text == "Versiegeln fehlgeschlagen: gesperrt")
        #expect(Labels.resultStatus(shown, issue: nil, chainAvailable: true) == Labels.result(.buildable(resultOID: "abc"), issue: nil))
    }

    @Test func chainTextsAreGrammaticalAndNameOnlyActionsThatExist() {
        let task = TaskRecord(id: TaskID(), jobID: JobID(), title: "T", state: .resultReady, currentAttemptID: nil, version: 1, createdAt: 1)
        let shown = ShownResult(task: task.id, taskVersion: 1, worktree: WorktreeID(), resultOID: nil, rejected: [], check: .empty)
        let sheet = DecisionSheet.discardResult(shown, task: task, issue: nil)
        #expect(sheet.blockers == ["Nur Aufgaben aus einem Plan lassen sich neu bearbeiten."])
        let message = ChainMessages.text(ChainActionError.notAPlanTask(task.id))
        #expect(message == "Nur Aufgaben aus einem Plan lassen sich neu bearbeiten.")
        #expect(ChainMessages.text(IntegrationError.undeclaredChanges(["NOTIZ.md"])).hasPrefix("Beim Versiegeln wurden Änderungen"))
        // A superseded candidate cannot be rejected; the rebuild text does not ask for it.
        let contained = Labels.chainIssue(.containedAfterRebuild)
        #expect(!contained.contains("Lehne") && contained.contains("kein neuer Kandidat"))
        let texts = sheet.blockers + [message, contained] + sheet.scope
        #expect(texts.allSatisfy { !$0.contains("lassen sich neu bearbeiten lassen") })
    }

    @Test func theReworkWaitHasItsOwnTextAndGrantsTheRework() async throws {
        let f = try await ChainFixture("chain-ui-rework")
        let planTask = PlanTaskDraft(key: "doku", title: "Doku", criteria: ["Leerwert dokumentiert"], writePaths: ["docs/"])
        let seeded = try await UITestSeed.authorResult(
            services: f.services, project: f.project, title: "Doku", writes: ["docs/LEERWERT.md": "nil\n"], planTask: planTask
        )
        _ = try await f.workspace.seal(seeded.worktree, allowedPrefixes: ["docs/"], message: "Doku")
        guard case .built(let candidate) = try await f.integration.buildCandidate(from: seeded.worktree) else { Issue.record("not built"); return }
        try await f.actions.reject(candidate.id, reason: "passt nicht")
        let scheduler = try #require(f.services.scheduler)
        _ = try await scheduler.tick()
        let waiting = try #require(try await f.store.task(seeded.task))
        #expect(waiting.state == .needsChanges && waiting.waitReason == "userDecision:rework")

        let reason = WaitReason(.userDecision, "rework")
        #expect(try await f.pending().contains(.task(seeded.task, reason)))
        #expect(Labels.wait(reason).text == "Wartet auf deine Freigabe zur Nacharbeit")
        let sheet = DecisionSheet.moreAttempts(waiting, reason: reason)
        #expect(sheet.title == "Nacharbeit erlauben" && sheet.approveLabel == "Nacharbeit erlauben" && sheet.canApprove)
        #expect(sheet.scope.contains { $0.contains("Kandidat abgelehnt") })
        #expect(sheet.scope.allSatisfy { !$0.contains("Startfehler") })
        // The other user decisions keep their reasons; an unknown one claims no cause.
        #expect(DecisionSheet.moreAttempts(waiting, reason: WaitReason(.userDecision, "startRetries")).scope.contains("Grund des Halts: Wiederholte Startfehler"))
        #expect(DecisionSheet.moreAttempts(waiting, reason: WaitReason(.userDecision, "neu")).scope.contains("Grund des Halts: Entscheidung nötig"))
        #expect(Labels.wait(WaitReason(.userDecision, "attemptLimit")).text == "Wartet auf deine Entscheidung")

        // Approving the sheet is the grant the rework needs: the wait ends.
        try await f.actions.allowMoreAttempts(seeded.task)
        #expect(try await f.store.task(seeded.task)?.waitReason == nil)
        #expect(try await f.store.decisions(task: seeded.task).contains { $0.rule == "userGrant" })
        await f.close()
    }
}
