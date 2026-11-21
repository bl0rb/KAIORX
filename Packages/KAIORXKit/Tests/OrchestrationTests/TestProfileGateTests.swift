import Domain
import Foundation
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workspace

/// ADR 0010: tests run only from the confirmed registry, and only tests of a profile confirmed
/// now count for the gate.
@Suite struct TestProfileGateTests {
    func built(_ h: IntegrationHarness) async throws -> CandidateRecord {
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else {
            throw IntegrationError.candidateNotIn(CandidateID(), .conflicted)
        }
        return candidate
    }

    @Test func unconfirmedOrForeignProfilesNeverRun() async throws {
        let h = try await IntegrationHarness()
        let candidate = try await built(h)
        let store = h.base.store
        let proposed = try await store.proposeTestProfile(
            project: h.base.project, TestProfileSpec(name: "Neu", executable: "/bin/sh", arguments: ["-c", "touch /tmp/kaiorx-never; exit 0"])
        )
        await #expect(throws: TestProfileError.notConfirmed("Neu")) { try await h.integration.runTests(candidate.id, profile: proposed.id) }

        // Confirmed, then changed: the change is not confirmed.
        try await store.confirmTestProfile(proposed.id, digest: proposed.digest, actor: "user")
        var changed = proposed.spec
        changed.timeoutSeconds = 5
        try await store.proposeTestProfile(project: h.base.project, changed)
        await #expect(throws: TestProfileError.notConfirmed("Neu")) { try await h.integration.runTests(candidate.id, profile: proposed.id) }

        // Another project's profile, or one that does not exist.
        let other = ProjectID()
        try await store.execute(Command(.openProject(id: other, name: "Andere", rootLocator: h.base.checkout + "-andere")))
        let foreign = try await store.confirmedTestProfile(project: other, arguments: ["-c", "exit 0"])
        await #expect(throws: TestProfileError.unknownProfile(foreign)) { try await h.integration.runTests(candidate.id, profile: foreign) }
        let missing = TestProfileID()
        await #expect(throws: TestProfileError.unknownProfile(missing)) { try await h.integration.runTests(candidate.id, profile: missing) }

        #expect(try await store.testResults(candidate: candidate.id).isEmpty)
        #expect(try await store.candidate(candidate.id)?.state == .built)
    }

    @Test func onlyTestsOfAProfileConfirmedNowCount() async throws {
        let h = try await IntegrationHarness()
        let store = h.base.store
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        let accepted = try await h.accepted(tree)
        let commit = try #require(accepted.candidateOID)
        #expect(accepted.state == .accepted)
        #expect(try await h.integration.gate(accepted.id) == [])
        let test = try #require(try await store.testResults(candidate: accepted.id).last)
        let profile = try #require(try await store.testProfile(h.passing))
        #expect(test.profileDigest == profile.digest)

        // Changing the profile withdraws its results, even after confirming the new content.
        var changed = profile.spec
        changed.arguments = ["-c", "true"]
        let replaced = try await store.proposeTestProfile(project: h.base.project, changed)
        #expect(try await h.integration.gateItems(accepted.id) == [.noPassingTest(commit), .noConfirmedTestProfile])
        await #expect(throws: IntegrationError.gateNotPassed(["no passing test for \(commit)", "no confirmed test profile"])) {
            _ = try await h.integration.approve(accepted.id, actor: "user")
        }
        #expect(try await store.candidate(accepted.id)?.state == .reviewing)
        try await store.confirmTestProfile(replaced.id, digest: replaced.digest, actor: "user")
        #expect(try await h.integration.gateItems(accepted.id) == [.noPassingTest(commit)])

        // Removing a profile withdraws its results the same way.
        let (_, second) = try await h.authorResult("echo zwei > b.txt")
        let other = try await h.accepted(second)
        #expect(try await h.integration.gate(other.id) == [])
        try await store.removeTestProfile(replaced.id)
        #expect(try await h.integration.gateItems(other.id) == [.noPassingTest(try #require(other.candidateOID)), .noConfirmedTestProfile])
    }

    @Test func theProfileIsResolvedForTheCandidate() async throws {
        let h = try await IntegrationHarness()
        let candidate = try await built(h)
        let store = h.base.store
        // The harness profile is the only confirmed one.
        #expect(try await h.integration.testProfile(for: candidate.id).id == h.passing)
        let unconfirmed = try await store.proposeTestProfile(project: h.base.project, TestProfileSpec(name: "Lint", executable: "/usr/bin/true"))
        #expect(try await h.integration.testProfile(for: candidate.id).id == h.passing)
        await #expect(throws: TestProfileError.notConfirmed("Lint")) { try await h.integration.testProfile(for: candidate.id, requested: unconfirmed.id) }
        try await store.confirmTestProfile(unconfirmed.id, digest: unconfirmed.digest, actor: "user")
        await #expect(throws: TestProfileError.ambiguous(["Lint", "passing"])) { try await h.integration.testProfile(for: candidate.id) }
        #expect(try await h.integration.testProfile(for: candidate.id, requested: unconfirmed.id).spec.name == "Lint")
        try await store.removeTestProfile(unconfirmed.id)
        try await store.removeTestProfile(h.passing)
        await #expect(throws: TestProfileError.noneConfirmed) { try await h.integration.testProfile(for: candidate.id) }
        #expect(try await h.integration.gateItems(candidate.id).contains(.noConfirmedTestProfile))
    }

    @Test func aPlanTaskRunsOnlyItsNamedConfirmedProfile() async throws {
        let h = try await SchedulerHarness()
        var task = planTask("A", writes: ["src/A"])
        task.testProfile = "unit"
        try await h.activate([task])
        let tree = try await PlannedIntegrationTests().result(h, "A", "mkdir -p src/A && echo x > src/A/f", writes: ["src/A"])
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        let commit = try #require(candidate.candidateOID)

        // The name resolves through the registry; a missing or unconfirmed profile holds the gate.
        await #expect(throws: TestProfileError.unknownName("unit")) { try await h.integration.testProfile(for: candidate.id) }
        #expect(try await h.integration.gateItems(candidate.id).contains(.testProfileNotConfirmed("unit")))
        let other = try await h.store.confirmedTestProfile(project: h.project, arguments: ["-c", "exit 0"], name: "andere")
        await #expect(throws: TestProfileError.notThePlannedProfile(requested: "andere", planned: "unit")) {
            try await h.integration.runTests(candidate.id, profile: other)
        }
        let unit = try await h.store.proposeTestProfile(project: h.project, TestProfileSpec(name: "unit", executable: "/bin/sh", arguments: ["-c", "exit 0"]))
        await #expect(throws: TestProfileError.notConfirmed("unit")) { try await h.integration.runTests(candidate.id, profile: unit.id) }
        #expect(try await h.integration.gateItems(candidate.id) == [.noPassingTest(commit), .testProfileNotConfirmed("unit"), .noIndependentReview(commit)])

        try await h.store.confirmTestProfile(unit.id, digest: unit.digest, actor: "user")
        #expect(try await h.integration.testProfile(for: candidate.id).id == unit.id)
        let result = try await h.integration.runTests(candidate.id, profile: unit.id)
        #expect(result.status == .passed && result.profileDigest == unit.digest)
        #expect(try await h.integration.gateItems(candidate.id) == [.noIndependentReview(commit)])
    }
}
