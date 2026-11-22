import Domain
import Foundation
import ProcessHost
@testable import Providers
import Synchronization
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workbench

/// ADR 0012: the real app registers the verified catalog's profiles at start.
@Suite struct ModelProfileSyncTests {
    /// The installed builds the owner's acceptance passed (from the matrix, no binary is read).
    static func verified(_ provider: ProviderKind) throws -> BinaryIdentity {
        let entry = try #require(CompatibilityMatrix.entries.first { $0.provider == provider && $0.status == .liveVerified })
        return BinaryIdentity(path: "/bin/\(provider.rawValue)", resolvedPath: "/bin/\(provider.rawValue)", sha256: try #require(entry.builds.first), version: entry.version)
    }

    func start(_ folder: String, _ registration: ProfileRegistration, gate: any CapabilityGate = AutomationGate(channel: .distributed)) async throws -> AppServices {
        let configuration = AppConfiguration(
            databasePath: folder + "/db.sqlite", workspaceRoot: folder + "/ws", adapters: { _ in [] }, gate: gate, profileRegistration: registration
        )
        guard case .ready(let services) = await AppBootstrap.start(configuration) else { throw ActionError.unavailable("start") }
        return services
    }

    @Test func theStandardRegistrationGivesEveryVerifiedModelBothRoles() async throws {
        let folder = try temporaryFolder("profiles")
        let identities = [ProviderKind.claude: try Self.verified(.claude), .codex: try Self.verified(.codex)]
        let registration = ProfileRegistration.verifiedCatalog(installed: { identities[$0] })
        let services = try await start(folder, registration)
        let usable = try await services.store.modelProfiles().filter(\.isUsable)
        let rows = usable.map { "\($0.provider.rawValue)|\($0.role.rawValue)|\($0.tier.rawValue)|\($0.model)" }.sorted()
        #expect(rows == ["claude|author|standard|sonnet", "claude|reviewer|standard|sonnet", "codex|author|standard|gpt-6.2-sol", "codex|reviewer|standard|gpt-6.2-sol"])
        #expect(usable.allSatisfy { $0.verifiedAt == 1_795_132_800_000 && $0.typicalTokens == nil && $0.effort == nil && $0.contextLimit == nil })
        guard case .synced(let report)? = services.profileSync else { Issue.record("\(String(describing: services.profileSync))"); return }
        #expect(report.inserted.count == 4)
        // What the scheduler and the review sheet look up.
        #expect(ModelProfile.smallest(usable, provider: .claude, role: .author, atLeast: .fast)?.model == "sonnet")
        #expect(ReviewerChoice.profile(usable, provider: .codex)?.model == "gpt-6.2-sol")
        #expect(ReviewerChoice.profile(usable, provider: .claude)?.model == "sonnet")
        #expect(ModelProfile.smallest(usable, provider: .claude, role: .author, atLeast: .intensive) == nil)
        await AppBootstrap.shutdown(services)

        // The next start finds everything in place.
        let again = try await start(folder, registration)
        #expect(again.profileSync == .synced(ModelProfileSyncReport()))
        #expect(try await again.store.modelProfiles().count == 4)
        await AppBootstrap.shutdown(again)
    }

    @Test func withoutRegistrationNothingIsRegistered() async throws {
        let services = try await start(try temporaryFolder("profiles-none"), .none)
        #expect(services.profileSync == nil)
        #expect(try await services.store.modelProfiles().isEmpty)
        await AppBootstrap.shutdown(services)
    }

    /// Without an injected lookup the app asks its gate; a distributed build reads nothing about
    /// the installation (ADR 0009 §3) and still registers the newest verified profiles.
    @Test func theGateIsAskedAndTheDistributedChannelReadsNothing() async throws {
        let calls = Mutex(0)
        let identity = try Self.verified(.claude)
        let sources = AutomationGate.Sources(
            installed: { provider in calls.withLock { $0 += 1 }; return provider == .claude ? identity : nil },
            confinement: { .effective }, subscription: { _ in .subscription(plan: "max") }
        )
        let distributed = try await start(try temporaryFolder("profiles-dist"), .verifiedCatalog(installed: nil),
                                          gate: AutomationGate(channel: .distributed, sources: sources))
        #expect(calls.withLock { $0 } == 0)
        #expect(try await distributed.store.modelProfiles().filter(\.isUsable).count == 4)
        await AppBootstrap.shutdown(distributed)

        let personal = try await start(try temporaryFolder("profiles-personal"), .verifiedCatalog(installed: nil),
                                       gate: AutomationGate(channel: .personal, sources: sources))
        #expect(calls.withLock { $0 } == 2)
        #expect(try await personal.store.modelProfiles().filter(\.isUsable).count == 4)
        await AppBootstrap.shutdown(personal)
    }

    // MARK: Which version is active

    func entry(_ version: String, model: String, on day: String, roles: [AttemptRole] = [.author, .reviewer]) -> VerifiedModelEntry {
        VerifiedModelEntry(
            provider: .claude, version: version, model: model, roles: roles, tier: .standard, effort: nil, typicalTokens: nil, verifiedOn: day,
            evidence: LiveEvidence(reportPath: "r.json", reportSHA256: "x", mode: "claudeSubscription")
        )
    }

    func live(_ version: String, build: String) -> CompatibilityEntry {
        CompatibilityEntry(provider: .claude, version: version, status: .liveVerified, notes: "", schemaDigest: nil, builds: [build])
    }

    func reasons(_ profiles: [ModelProfile]) -> [String: String] {
        Dictionary(profiles.filter { $0.role == .author }.map { ($0.model, $0.disabledReason ?? "usable") }, uniquingKeysWith: { a, _ in a })
    }

    @Test func theInstalledVerifiedVersionIsActiveAndOtherVersionsAreDisabled() {
        let entries = [entry("1.0", model: "old", on: "2026-11-20"), entry("2.0", model: "new", on: "2026-11-21"), entry("3.0", model: "unproven", on: "2026-11-22")]
        let matrix = [live("1.0", build: "b1"), live("2.0", build: "b2"),
                      CompatibilityEntry(provider: .claude, version: "3.0", status: .offlineVerified, notes: "", schemaDigest: nil)]
        func installed(_ version: String, _ build: String) -> [ProviderKind: BinaryIdentity] {
            [.claude: BinaryIdentity(path: "/c", resolvedPath: "/c", sha256: build, version: version)]
        }
        let older = ModelProfileSync.desired(entries: entries, matrix: matrix, installed: installed("1.0", "b1"))
        #expect(reasons(older) == ["old": "usable", "new": "catalog:otherVersion 2.0", "unproven": "catalog:versionNotLiveVerified"])
        #expect(older.count == 6 && older.allSatisfy { $0.provider == .claude })
        // Not installed, another build, an unlisted or unproven version: the newest verified one.
        for identities in [[:], installed("1.0", "other-build"), installed("9.9", "b9"), installed("3.0", "b3")] {
            let fallback = ModelProfileSync.desired(entries: entries, matrix: matrix, installed: identities)
            #expect(reasons(fallback) == ["old": "catalog:otherVersion 1.0", "new": "usable", "unproven": "catalog:versionNotLiveVerified"])
        }
        // A verified installed version the catalog does not list has no profile (the evidence
        // test keeps this from happening in the real catalog).
        let unlisted = ModelProfileSync.desired(entries: entries, matrix: matrix + [live("4.0", build: "b4")], installed: installed("4.0", "b4"))
        #expect(unlisted.filter(\.isUsable).isEmpty)
        // Only the roles an entry lists.
        let authorOnly = ModelProfileSync.desired(entries: [entry("1.0", model: "old", on: "2026-11-20", roles: [.author])], matrix: matrix, installed: [:])
        #expect(authorOnly.map(\.role) == [.author])
    }

    /// A self-updated Claude keeps its profiles usable, so the gate's reason shows.
    @Test func anUnverifiedInstallKeepsTheNewestVerifiedProfiles() throws {
        var updated = try Self.verified(.claude)
        updated.version = "2.1.330"
        let profiles = ModelProfileSync.desired(installed: [.claude: updated, .codex: try Self.verified(.codex)])
        #expect(profiles.filter(\.isUsable).count == 4)
        var otherBuild = try Self.verified(.claude)
        otherBuild.sha256 = "another-build"
        #expect(ModelProfileSync.desired(installed: [.claude: otherBuild]).filter(\.isUsable).count == 4)
    }
}
