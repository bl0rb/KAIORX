import Domain
import Foundation
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workbench

/// Package H: approvals bound to what the sheet showed, with expiry; rejection by the user;
/// what waits for the user.
@Suite struct ApprovalSheetTests {
    func accepted() async throws -> (IntegrationHarness, CandidateRecord) {
        let h = try await IntegrationHarness()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        return (h, try await h.accepted(tree))
    }

    @Test func theApprovalBindsToTheShownStateAndExpires() async throws {
        let (h, candidate) = try await accepted()
        let sheet = DecisionSheet.publish(candidate, task: nil, gate: try await h.integration.gateItems(candidate.id))
        #expect(sheet.canApprove && sheet.scope.contains { $0.contains(candidate.targetRef) })
        let shown = try #require(sheet.shown)
        // A sheet that showed another commit cannot approve.
        var stale = shown
        stale.candidateOID = String(repeating: "0", count: 40)
        await #expect(throws: IntegrationError.shownStateChanged(candidate.id)) {
            _ = try await h.integration.approve(candidate.id, actor: WorkbenchActor.user, shown: stale, ttl: nil)
        }
        // An approval with a time limit that ran out is revoked and does not publish.
        let quick = try await h.integration.approve(candidate.id, actor: WorkbenchActor.user, shown: shown, ttl: 1)
        #expect(quick.expiresAt != nil)
        try await Task.sleep(for: .milliseconds(20))
        await #expect(throws: IntegrationStoreError.approvalExpired(quick.id)) { try await h.integration.publish(candidate.id, approval: quick.id) }
        #expect(try await h.base.store.approval(quick.id)?.state == .revoked)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .accepted)
        // A fresh approval within its time publishes.
        let approval = try await h.integration.approve(candidate.id, actor: WorkbenchActor.user, shown: shown, ttl: 60_000)
        try await h.integration.publish(candidate.id, approval: approval.id)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .published)
    }

    @Test func pendingDecisionsAndRejectionByTheUser() async throws {
        let (h, candidate) = try await accepted()
        let projector = Projector(store: h.base.store)
        let state = try await projector.load()
        let pending = try await PendingDecisions.collect(
            state, project: h.base.project, gate: { try await h.integration.gateItems($0) },
            openFindings: { _ in false }
        )
        #expect(pending.contains(.publish(candidate.id)))
        await #expect(throws: IntegrationError.reasonRequired) { try await h.integration.rejectCandidate(candidate.id, reason: "  ") }
        try await h.integration.rejectCandidate(candidate.id, reason: "Passt nicht zum Ziel")
        #expect(try await h.base.store.candidate(candidate.id)?.state == .rejected)
        let after = try await PendingDecisions.collect(
            try await Projector(store: h.base.store).load(), project: h.base.project, gate: { try await h.integration.gateItems($0) },
            openFindings: { _ in false }
        )
        #expect(!after.contains(.publish(candidate.id)))
        // The typed gate keeps the historical text.
        #expect(GateItem.noPassingTest("abc").description == "no passing test for abc")
        #expect(Labels.gate(.blockingFindings) == "Blockierende Befunde")
    }

    /// The app died after journaling the publication; on restart the approval has expired: the
    /// update is not repeated and the candidate goes back to accepted.
    @Test func recoveryDoesNotPublishWithAnExpiredApproval() async throws {
        let (h, candidate) = try await accepted()
        let before = try await h.target()
        // Long enough to journal the publication even under load, then let it run out.
        let approval = try await h.integration.approve(candidate.id, actor: WorkbenchActor.user, shown: nil, ttl: 3_000)
        _ = try await h.base.store.preparePublication(candidate: candidate.id, approval: approval.id)
        try await Task.sleep(for: .milliseconds(3_100))
        _ = try await h.integration.recover()
        #expect(try await h.target() == before)
        #expect(try await h.base.store.candidate(candidate.id)?.state == .accepted)
    }
}
