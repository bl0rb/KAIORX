import Domain
import Orchestration
import Testing
@testable import Workbench

@Suite struct AutomationLabelTests {
    @Test func aBlockedProviderSaysWhyItWaitsForYourStart() {
        #expect(Labels.wait(stored: "awaitingUserStart:claude")?.text == "Wartet auf deinen Start")
        #expect(Labels.wait(stored: "awaitingUserStart:claude:versionNotListed:2.1.330")?.text
            == "Wartet auf deinen Start: Die installierte Version Claude 2.1.330 ist nicht live abgenommen")
        #expect(Labels.wait(stored: "awaitingUserStart:codex:channel:distributed")?.text
            == "Wartet auf deinen Start: Codex startet in dieser Ausgabe von KAIORX nie automatisch (keine Anbieterfreigabe)")
        #expect(Labels.wait(stored: "awaitingUserStart:claude:subscription:signedOut")?.text
            == "Wartet auf deinen Start: Claude ist in KAIORX nicht angemeldet")
        // Unknown details fall back to the plain label.
        #expect(Labels.wait(stored: "awaitingUserStart:claude:somethingNew")?.text == "Wartet auf deinen Start")
        let blocks: [AutomationBlock] = [
            .channel(.distributed), .notInstalled, .identityUnknown, .versionNotListed("1"), .versionNotLiveVerified("1"), .buildNotVerified("1"),
            .confinementIneffective, .notSubscribed("signedOut"), .notSubscribed("otherBilling"), .notSubscribed("unclear"),
        ]
        let texts = blocks.compactMap { Labels.automation($0, provider: .codex) }
        #expect(texts.count == blocks.count && texts.allSatisfy { !$0.isEmpty })
        #expect(Labels.automation(.notPermitted, provider: .codex) == nil)
    }
}
