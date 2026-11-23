import Domain
import Foundation
import Testing
@testable import Orchestration
@testable import Workbench

/// ADR 0013 (run 0.7): the first Claude run was started by hand while Claude was signed out and
/// failed at once. The start sheet names why the task waits and blocks a start that must fail.
@Suite struct StartSheetTests {
    let task = TaskRecord(id: TaskID(), jobID: JobID(), title: "hallo.txt anlegen", state: .ready, currentAttemptID: nil, version: 1, createdAt: 1)

    func sheet(_ detail: String) -> DecisionSheet {
        DecisionSheet.start(task, provider: nil, writePaths: ["hallo.txt"], reason: WaitReason(.awaitingUserStart, detail))
    }

    @Test func aSignedOutProviderBlocksTheStartAndPointsToTheLogin() {
        let signedOut = sheet("claude:subscription:signedOut")
        #expect(!signedOut.canApprove)
        #expect(signedOut.scope.first == "Wartet: Wartet auf deinen Start: Claude ist in KAIORX nicht angemeldet")
        #expect(signedOut.blockers.count == 1 && signedOut.blockers[0].hasPrefix("Claude ist in KAIORX nicht angemeldet. Melde dich zuerst an"))
        #expect(signedOut.blockers[0].contains("„Im Terminal anmelden …“"))
    }

    @Test func startsThatMustFailAreBlockedOthersStayAllowed() {
        for detail in ["claude:versionNotListed:2.1.330", "claude:versionNotLiveVerified:2.1.330", "claude:buildNotVerified:2.1.329",
                       "codex:notInstalled", "codex:identityUnknown", "claude:confinement"] {
            #expect(!sheet(detail).canApprove, "\(detail)")
        }
        // The distributed channel's way is the user's start (ADR 0009 §8); unclear billing is the owner's call.
        for detail in ["claude:channel:distributed", "claude", "claude:subscription:otherBilling", "claude:subscription:unclear"] {
            #expect(sheet(detail).canApprove, "\(detail)")
        }
        // Other wait reasons, or none, change nothing.
        #expect(DecisionSheet.start(task, provider: nil, writePaths: [], reason: WaitReason(.quota)).canApprove)
        #expect(DecisionSheet.start(task, provider: nil, writePaths: []).canApprove)
        #expect(DecisionSheet.start(task, provider: nil, writePaths: []).scope.first == "Anbieter: nach Plan")
    }
}
