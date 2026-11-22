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
    /// The installed build of the newest catalog version the owner's acceptance passed (from the
    /// matrix, no binary is read).
    static func verified(_ provider: ProviderKind) throws -> BinaryIdentity {
        let newest = try #require(VerifiedModelProfiles.entries.filter { $0.provider == provider }.max { $0.verifiedOn < $1.verifiedOn })
        let entry = try #require(CompatibilityMatrix.entries.first { $0.provider == provider && $0.version == newest.version && $0.status == .liveVerified })
        return BinaryIdentity(path: "/bin/\(provider.rawValue)", resolvedPath: "/bin/\(provider.rawValue)", sha256: try #require(entry.builds.first), version: entry.version)
    }

    /// What the catalog promises for these installed versions: every role of every entry of the
    /// version, with the entry's date. Derived from the catalog, so a later owner run that adds
    /// entries through `matrix.patch` does not need this test edited (the a265 values are pinned
    /// only in `VerifiedProfileTests.theA265BackfillIsWhatItsReportExercised`).
    static func promised(_ installed: [ProviderKind: BinaryIdentity]) -> [ModelProfileID: (row: String, verifiedAt: Int64?)] {
        var promised: [ModelProfileID: (row: String, verifiedAt: Int64?)] = [:]
        for entry in VerifiedModelProfiles.entries where installed[entry.provider]?.version == entry.version {
            for role in entry.roles {
                promised[VerifiedModelProfiles.profileID(entry, role: role)] = (
                    "\(entry.provider.rawValue)|\(role.rawValue)|\(entry.tier.rawValue)|\(entry.model)", VerifiedModelProfiles.verifiedAt(entry)
                )
            }
        }
        return promised
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
        let promised = Self.promised(identities)
        let rows = usable.map { "\($0.provider.rawValue)|\($0.role.rawValue)|\($0.tier.rawValue)|\($0.model)" }.sorted()
        #expect(!promised.isEmpty && rows == promised.values.map { $0.row }.sorted())
        #expect(usable.allSatisfy { promised[$0.id]?.verifiedAt == $0.verifiedAt && $0.verifiedAt != nil })
        #expect(usable.allSatisfy { $0.typicalTokens == nil && $0.effort == nil && $0.contextLimit == nil })
        guard case .synced(let report)? = services.profileSync else { Issue.record("\(String(describing: services.profileSync))"); return }
        let desired = ModelProfileSync.desired(installed: identities)
        #expect(report.inserted.count == desired.count)
        // What the scheduler and the review sheet look up: an author and a reviewer of each provider.
        for provider in [ProviderKind.claude, .codex] {
            #expect(ModelProfile.smallest(usable, provider: provider, role: .author, atLeast: .fast).map { promised[$0.id] != nil } == true)
            #expect(ReviewerChoice.profile(usable, provider: provider).map { promised[$0.id] != nil } == true)
            // Intensive tasks wait until a profile of that tier is accepted (ADR 0012 D3).
            #expect((ModelProfile.smallest(usable, provider: provider, role: .author, atLeast: .intensive) != nil)
                    == promised.values.contains { $0.row.hasPrefix("\(provider.rawValue)|author|intensive|") })
        }
        await AppBootstrap.shutdown(services)

        // The next start finds everything in place.
        let again = try await start(folder, registration)
        #expect(again.profileSync == .synced(ModelProfileSyncReport()))
        #expect(try await again.store.modelProfiles().count == desired.count)
        await AppBootstrap.shutdown(again)
    }

    /// Finding: a failed start-up sync was recorded but never shown. The onboarding list now
    /// names the usable models or the failure's reason.
    @Test func theOnboardingListShowsTheSyncOutcome() async throws {
        let identities = [ProviderKind.claude: try Self.verified(.claude), .codex: try Self.verified(.codex)]
        let services = try await start(try temporaryFolder("profiles-onboarding"), .verifiedCatalog(installed: { identities[$0] }))
        var probes = ProbeResults(gitPath: "/usr/bin/git")
        probes.profileSync = services.profileSync
        probes.profiles = try await services.store.modelProfiles()
        await AppBootstrap.shutdown(services)
        let item = try #require(Onboarding.checklist(probes).first { $0.id == "profiles" })
        #expect(item.status == .ok && item.detail.contains("Claude: ") && item.detail.contains("Codex: "))
        for row in Self.promised(identities).values {
            #expect(item.detail.contains(String(row.row.split(separator: "|")[3])), "\(row.row)")
        }
        #expect(item.detail.contains("(Autor, Reviewer)"))
        // The order in the list: after the sandbox check, before the project.
        let ids = Onboarding.checklist(probes).map(\.id)
        #expect(ids.firstIndex(of: "profiles").map { $0 == ids.firstIndex(of: "sandbox")! + 1 } == true)

        probes.profileSync = .failed("SQLite busy (5)")
        let failed = try #require(Onboarding.checklist(probes).first { $0.id == "profiles" })
        #expect(failed.status == .missing && failed.detail == "Abgleich beim Start fehlgeschlagen: SQLite busy (5)" && failed.remedy != nil)
        probes.profileSync = .synced(ModelProfileSyncReport())
        probes.profiles = probes.profiles.map { var disabled = $0; disabled.disabledReason = "catalog:removed"; return disabled }
        #expect(Onboarding.checklist(probes).first { $0.id == "profiles" }?.status == .warning)
        probes.profileSync = nil
        #expect(!Onboarding.checklist(probes).contains { $0.id == "profiles" })
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
        let newest = ModelProfileSync.desired(installed: [:]).filter(\.isUsable)
        #expect(!newest.isEmpty)
        #expect(try await distributed.store.modelProfiles().filter(\.isUsable).map(\.id).sorted { $0.uuidString < $1.uuidString }
                == newest.map(\.id).sorted { $0.uuidString < $1.uuidString })
        await AppBootstrap.shutdown(distributed)

        let personal = try await start(try temporaryFolder("profiles-personal"), .verifiedCatalog(installed: nil),
                                       gate: AutomationGate(channel: .personal, sources: sources))
        #expect(calls.withLock { $0 } == 2)
        #expect(try await personal.store.modelProfiles().filter(\.isUsable).count
                == ModelProfileSync.desired(installed: [.claude: identity]).filter(\.isUsable).count)
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
        let identities = [ProviderKind.claude: try Self.verified(.claude), .codex: try Self.verified(.codex)]
        let newest = Set(Self.promised(identities).keys)
        var updated = try Self.verified(.claude)
        updated.version = "2.1.330"
        let profiles = ModelProfileSync.desired(installed: [.claude: updated, .codex: try Self.verified(.codex)])
        #expect(!newest.isEmpty && Set(profiles.filter(\.isUsable).map(\.id)) == newest)
        var otherBuild = try Self.verified(.claude)
        otherBuild.sha256 = "another-build"
        #expect(Set(ModelProfileSync.desired(installed: [.claude: otherBuild]).filter(\.isUsable).map(\.id)) == newest)
    }

    /// Finding: with the installation unknown (distributed channel, a failed probe), the newest
    /// version's profiles are usable even if an older verified build is installed. The profile
    /// may then name a model that never ran with the installed version; the adapter's model
    /// check refuses that start instead of running the unverified pair.
    @Test func aFallbackProfileNeverRunsOnAnotherVerifiedVersion() throws {
        let entries = [entry("1.0", model: "model-a", on: "2026-11-20"), entry("2.0", model: "model-b", on: "2026-11-21")]
        let profiles = ModelProfileSync.desired(entries: entries, matrix: [live("1.0", build: "b1"), live("2.0", build: "b2")], installed: [:])
        let picked = try #require(ModelProfile.smallest(profiles, provider: .claude, role: .author, atLeast: .fast))
        #expect(picked.model == "model-b")
        let installed = BinaryIdentity(path: "/c", resolvedPath: "/c", sha256: "b1", version: "1.0")
        #expect(throws: ProviderError.modelNotLiveVerified(provider: .claude, version: "1.0", model: "model-b")) {
            try AdapterPolicy().checkModel(.claude, identity: installed, model: picked.model, role: .author, catalog: entries)
        }
        try AdapterPolicy().checkModel(.claude, identity: installed, model: "model-a", role: .author, catalog: entries)
    }
}
