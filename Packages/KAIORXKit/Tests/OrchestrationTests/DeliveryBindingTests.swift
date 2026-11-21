import Domain
import Foundation
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workspace

@Suite struct DeliveryBindingTests {
    /// The decision sheet binds the delivery to the integration state it showed.
    @Test func aDeliveryBoundToAnOlderStateIsRefused() async throws {
        let h = try await IntegrationHarness()
        let base = try await h.target()
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        let candidate = try await h.accepted(tree)
        try await h.integration.publish(candidate.id, approval: try await h.integration.approve(candidate.id, actor: "u").id)
        let published = try #require(candidate.candidateOID)

        await #expect(throws: IntegrationError.targetMoved(expected: base, actual: published)) {
            _ = try await h.integration.createDeliveryBranch(job: h.base.job, name: "lieferung", expectedTarget: base)
        }
        #expect(try await h.base.sh("git for-each-ref --format='%(refname)' refs/heads/lieferung").isEmpty)
        #expect(try await h.integration.createDeliveryBranch(job: h.base.job, name: "lieferung", expectedTarget: published) == "lieferung")
        #expect(try await h.base.sh("git rev-parse lieferung") == published)
    }

    /// The suffix rule `createBranch` uses, shared with the app's preview.
    @Test func freeNamesFoldCaseNormalisationAndFolders() {
        #expect(GitRunner.freeBranchNames(for: "Main", existing: ["main"]).first == "Main-2")
        #expect(GitRunner.freeBranchNames(for: "ma\u{0308}in", existing: ["m\u{00E4}in"]).first == "ma\u{0308}in-2")
        #expect(GitRunner.freeBranchNames(for: "feature", existing: ["feature/x"]).first == "feature-2")
        #expect(GitRunner.freeBranchNames(for: "feature/x/y", existing: ["feature/x"]).isEmpty)
        #expect(GitRunner.freeBranchNames(for: "neu", existing: ["main"]) == ["neu"] + (2...20).map { "neu-\($0)" })
        #expect(GitRunner.freeBranchNames(for: "neu", existing: ["neu"] + (2...20).map { "NEU-\($0)" }).isEmpty)
    }
}
