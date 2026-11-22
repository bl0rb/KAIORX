import Domain
import Foundation
import Testing
@testable import Storage

/// ADR 0012: the catalog sync inserts and updates the real providers' profiles, never deletes,
/// owns only `catalog:` reasons and leaves the `fake` provider alone.
@Suite struct ModelProfileSyncStoreTests {
    func profile(_ provider: ProviderKind, _ role: AttemptRole, model: String = "m", reason: String? = nil) -> ModelProfile {
        ModelProfile(provider: provider, role: role, tier: .standard, model: model, verifiedAt: 1_795_132_800_000, disabledReason: reason)
    }

    @Test func theSyncInsertsIsIdempotentAndNeverDeletes() async throws {
        let store = try Fixture().open()
        let author = profile(.claude, .author), reviewer = profile(.codex, .reviewer)
        let first = try await store.syncCatalogModelProfiles([author, reviewer], managed: [.claude, .codex])
        #expect(Set(first.inserted) == [author.id, reviewer.id] && first.updated.isEmpty && first.removed.isEmpty)
        #expect(try await store.modelProfiles().filter(\.isUsable).map(\.id).sorted { $0.uuidString < $1.uuidString }
            == [author.id, reviewer.id].sorted { $0.uuidString < $1.uuidString })
        // Twice gives the same rows and reports no change.
        let second = try await store.syncCatalogModelProfiles([author, reviewer], managed: [.claude, .codex])
        #expect(!second.changed)
        #expect(try await store.modelProfiles().count == 2)

        // Dropped from the catalog: disabled with `catalog:removed`, never deleted.
        let removed = try await store.syncCatalogModelProfiles([author], managed: [.claude, .codex])
        #expect(removed.removed == [reviewer.id] && removed.inserted.isEmpty && removed.updated.isEmpty)
        let stored = try await store.modelProfiles()
        #expect(stored.count == 2)
        #expect(stored.first { $0.id == reviewer.id }?.disabledReason == ModelProfileSyncReport.removed)
        #expect(!(try await store.syncCatalogModelProfiles([author], managed: [.claude, .codex])).changed)

        // Listed again: enabled again.
        let back = try await store.syncCatalogModelProfiles([author, reviewer], managed: [.claude, .codex])
        #expect(back.updated == [reviewer.id])
        #expect(try await store.modelProfiles().allSatisfy(\.isUsable))
    }

    @Test func theSyncUpdatesSettingsAndCatalogReasons() async throws {
        let store = try Fixture().open()
        var author = profile(.claude, .author)
        try await store.syncCatalogModelProfiles([author], managed: [.claude, .codex])
        author.typicalTokens = 40_000
        author.effort = "high"
        author.contextLimit = 200_000
        author.verifiedAt = 1_795_219_200_000
        author.disabledReason = "catalog:otherVersion 2.1.329"
        #expect(try await store.syncCatalogModelProfiles([author], managed: [.claude, .codex]).updated == [author.id])
        let stored = try #require(try await store.modelProfiles().first)
        #expect(stored == author)
        author.disabledReason = nil
        try await store.syncCatalogModelProfiles([author], managed: [.claude, .codex])
        #expect(try await store.modelProfiles().first?.isUsable == true)
    }

    @Test func reasonsSetElsewhereAndFakeRowsAreLeftAlone() async throws {
        let store = try Fixture().open()
        let fake = ModelProfile(provider: .fake, role: .author, tier: .fast, model: "fake", verifiedAt: 1)
        try await store.registerModelProfile(fake)
        // A future user disable on a real provider's row (not a `catalog:` reason).
        let disabledByUser = profile(.codex, .author, model: "other", reason: "user:paused")
        try await store.registerModelProfile(disabledByUser)
        let leftover = profile(.claude, .reviewer, model: "old")
        try await store.registerModelProfile(leftover)
        var author = profile(.claude, .author)
        try await store.syncCatalogModelProfiles([author], managed: [.claude, .codex])
        var stored = Dictionary(uniqueKeysWithValues: try await store.modelProfiles().map { ($0.id, $0) })
        #expect(stored[fake.id] == fake)
        #expect(stored[disabledByUser.id]?.disabledReason == "user:paused")
        #expect(stored[leftover.id]?.disabledReason == ModelProfileSyncReport.removed)

        // Even when the catalog lists the user-disabled row, its reason stays.
        var listed = disabledByUser
        listed.disabledReason = nil
        try await store.syncCatalogModelProfiles([author, listed], managed: [.claude, .codex])
        stored = Dictionary(uniqueKeysWithValues: try await store.modelProfiles().map { ($0.id, $0) })
        #expect(stored[disabledByUser.id]?.disabledReason == "user:paused")
        #expect(stored[author.id]?.isUsable == true)

        // A desired profile outside the managed providers, or a row with the same ID but another
        // model, is refused and changes nothing.
        await #expect(throws: ModelProfileSyncError.unmanagedProvider(.fake)) {
            try await store.syncCatalogModelProfiles([fake], managed: [.claude, .codex])
        }
        author.model = "renamed"
        await #expect(throws: ModelProfileSyncError.identityMismatch(author.id)) {
            try await store.syncCatalogModelProfiles([author, profile(.codex, .reviewer)], managed: [.claude, .codex])
        }
        #expect(try await store.modelProfiles().count == 4)
    }
}
