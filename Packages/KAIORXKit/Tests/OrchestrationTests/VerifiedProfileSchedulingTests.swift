import Domain
import Foundation
@testable import Providers
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workbench

/// ADR 0012 with the scheduler: the catalog's profiles let a verified install run, and an
/// unverified install waits with the gate's precise reason, not for a model profile.
@Suite struct VerifiedProfileSchedulingTests {
    @Test func aSelfUpdatedClaudeWaitsWithTheGatesReasonAndTheVerifiedBuildRuns() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A")])
        var updated = try FakeGateSources.verifiedClaude()
        updated.version = "2.1.330"
        // The catalog sync replaces the harness's hand-made Claude profiles (`catalog:removed`).
        try await ModelProfileSync.run(store: h.store, installed: [.claude: updated])
        let profiles = try await h.store.modelProfiles()
        #expect(profiles.filter { $0.provider == .claude && $0.isUsable }.map(\.model) == ["sonnet", "sonnet"])
        #expect(profiles.filter { $0.provider == .claude && $0.disabledReason == ModelProfileSyncReport.removed }.count == CapabilityTier.allCases.count)

        let fake = FakeGateSources(identity: updated)
        let scheduler = h.scheduler(gate: h.gate(.personal, fake))
        #expect(try await scheduler.tick().reserved.isEmpty)
        #expect(try await h.task("A").waitReason == "awaitingUserStart:claude:versionNotListed:2.1.330")
        // Another build of the verified version waits the same way.
        var otherBuild = try FakeGateSources.verifiedClaude()
        otherBuild.sha256 = "another-build"
        fake.set { $0.identity = otherBuild }
        h.clock.advance(1_000)
        #expect(try await scheduler.tick().reserved.isEmpty)
        #expect(try await h.task("A").waitReason == "awaitingUserStart:claude:buildNotVerified:2.1.329")

        // The verified build runs on the catalog profile: model `sonnet`, tier standard.
        fake.set { $0.identity = try? FakeGateSources.verifiedClaude() }
        h.clock.advance(1_000)
        let report = try await scheduler.tick()
        #expect(report.reserved.count == 1)
        let attempt = try #require(try await h.store.attempts(taskID: try await h.task("A").id).first)
        #expect(attempt.model == "sonnet" && attempt.tier == .standard)
        let profileID = try #require(attempt.modelProfileID)

        // A later catalog without the profile disables it; the row an attempt references stays.
        try await ModelProfileSync.run(store: h.store, installed: [:], entries: [])
        let after = try await h.store.modelProfiles()
        #expect(after.first { $0.id == profileID }?.disabledReason == ModelProfileSyncReport.removed)
        #expect(try await h.store.attempts(taskID: try await h.task("A").id).first?.modelProfileID == profileID)
    }

    @Test func aGateWithoutAutomationReadsNoInstallationForTheProfiles() async throws {
        let fake = FakeGateSources(identity: try FakeGateSources.verifiedClaude())
        #expect(await AutomationGate(channel: .distributed, sources: fake.sources).installedIdentity(.claude) == nil)
        #expect(fake.snapshot.identityCalls == 0)
        let personal = AutomationGate(channel: .personal, sources: fake.sources)
        #expect(await personal.installedIdentity(.claude) == (try FakeGateSources.verifiedClaude()))
        #expect(await personal.installedIdentity(.fake) == nil)
        fake.set { $0.identityFails = true }
        #expect(await personal.installedIdentity(.claude) == nil)
        #expect(fake.snapshot.identityCalls == 2)
    }
}
