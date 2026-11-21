import Domain
import Foundation
import Testing
@testable import Storage

extension Store {
    /// Changes the database behind the store's back (tampering, a foreign tool).
    func rawExecute(_ sql: String) throws {
        try connection().execute(sql)
    }
}

/// ADR 0010: the per-project test profile registry and its digest-bound confirmation.
@Suite struct TestProfileStoreTests {
    static let unit = TestProfileSpec(name: "Unit", executable: "/bin/sh", arguments: ["-c", "exit 0"], testInputPrefixes: ["Tests"])

    @Test func aVersionEightDatabaseGetsTheRegistryAndKeepsItsData() async throws {
        let fixture = try Fixture()
        let old = try fixture.open(Array(CoreSchema.migrations.prefix(8)))
        let seed = try await fixture.seed(old)
        await old.close()

        let store = try fixture.open()
        #expect(store.migrationReport.previousVersion == 8)
        #expect(store.migrationReport.appliedVersions == Array(9...CoreSchema.migrations.count))
        #expect(try #require(store.migrationReport.backupPath).contains(".backup-v8-"))
        #expect(try await store.projects().map(\.id) == [seed.project])
        #expect(try await store.task(seed.task)?.title == "Aufgabe")
        #expect(try await store.tableExists("test_profile"))
        #expect(try await store.testProfiles(project: seed.project).isEmpty)
        let profile = try await store.proposeTestProfile(project: seed.project, Self.unit)
        #expect(try await store.testProfiles(project: seed.project) == [profile])
        // The migration is part of the shipped sequence; reopening applies nothing.
        await store.close()
        #expect(try fixture.open().migrationReport.appliedVersions.isEmpty)
    }

    @Test func theConfirmationIsBoundToTheDigest() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let proposed = try await store.proposeTestProfile(project: seed.project, Self.unit)
        #expect(!proposed.isConfirmed && proposed.confirmedAt == nil && proposed.digest == Self.unit.digest)

        // Only the digest the sheet showed confirms.
        await #expect(throws: TestProfileStoreError.digestChanged(shown: "0", stored: proposed.digest)) {
            try await store.confirmTestProfile(proposed.id, digest: "0", actor: "user")
        }
        await #expect(throws: TestProfileStoreError.actorRequired) {
            try await store.confirmTestProfile(proposed.id, digest: proposed.digest, actor: " ")
        }
        let confirmed = try await store.confirmTestProfile(proposed.id, digest: proposed.digest, actor: "user")
        #expect(confirmed.isConfirmed && confirmed.confirmedBy == "user" && confirmed.confirmedDigest == proposed.digest)

        // The same content keeps the confirmation; any change drops it.
        #expect(try await store.proposeTestProfile(project: seed.project, Self.unit).isConfirmed)
        var changed = Self.unit
        changed.arguments = ["-c", "exit 0; rm -rf ~"]
        let replaced = try await store.proposeTestProfile(project: seed.project, changed)
        #expect(replaced.id == proposed.id && replaced.digest != proposed.digest && !replaced.isConfirmed && replaced.confirmedBy == nil)
        await #expect(throws: TestProfileStoreError.digestChanged(shown: proposed.digest, stored: replaced.digest)) {
            try await store.confirmTestProfile(proposed.id, digest: proposed.digest, actor: "user")
        }
        // Renaming is a change too: the digest covers the name.
        var renamed = Self.unit
        renamed.name = "Unit2"
        #expect(renamed.digest != Self.unit.digest)
    }

    @Test func contentChangedBehindTheStoresBackIsNotConfirmed() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let profile = try await store.proposeTestProfile(project: seed.project, Self.unit)
        try await store.confirmTestProfile(profile.id, digest: profile.digest, actor: "user")

        // A changed command under the old digest: the stored content no longer has that digest.
        try await store.rawExecute("UPDATE test_profile SET executable = '/bin/rm'")
        let tampered = try #require(try await store.testProfile(profile.id))
        #expect(tampered.confirmedDigest == profile.digest && !tampered.isConfirmed)
        await #expect(throws: TestProfileStoreError.self) {
            try await store.confirmTestProfile(profile.id, digest: profile.digest, actor: "user")
        }
        // The schema refuses a confirmation that does not cover the stored digest.
        await #expect(throws: SQLiteError.self) {
            try await store.rawExecute("UPDATE test_profile SET digest = '\(String(repeating: "a", count: 64))'")
        }
        // Proposing again recomputes the digest and asks for a new confirmation.
        let again = try await store.proposeTestProfile(project: seed.project, Self.unit)
        #expect(again.confirmedAt == nil && !again.isConfirmed)
    }

    @Test func invalidProfilesAreRefusedAndNamesArePerProject() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let bad = TestProfileSpec(name: "  ", executable: "sh", workingDirectory: "../other", timeoutSeconds: 0, testInputPrefixes: ["/etc"])
        await #expect(throws: TestProfileStoreError.invalid([
            .emptyName, .executableNotAbsolute, .workingDirectoryLeavesWorktree, .invalidTimeout, .invalidTestInputPrefix("/etc"),
        ])) { try await store.proposeTestProfile(project: seed.project, bad) }
        #expect(TestProfileSpec(name: "x", executable: "/usr/bin/../bin/sh").issues == [.executableNotAbsolute])
        #expect(TestProfileSpec(name: "x\n", executable: "/bin/sh").normalized().issues.isEmpty)
        #expect(TestProfileSpec(name: "a\u{7}b", executable: "/bin/sh").issues == [.controlCharacters("name")])
        let missing = ProjectID()
        await #expect(throws: StoreError.notFound(entity: "project", id: missing.uuidString)) {
            try await store.proposeTestProfile(project: missing, Self.unit)
        }

        let other = ProjectID()
        try await store.execute(Command(.openProject(id: other, name: "Andere", rootLocator: fixture.directory.path(percentEncoded: false) + "/b")))
        let first = try await store.proposeTestProfile(project: seed.project, Self.unit)
        let second = try await store.proposeTestProfile(project: other, Self.unit)
        #expect(first.id != second.id)
        #expect(try await store.testProfiles(project: other).map(\.id) == [second.id])

        let before = try await store.events(limit: 10_000).filter { $0.kind == .policyDecided }.count
        try await store.removeTestProfile(first.id)
        #expect(try await store.testProfile(first.id) == nil)
        #expect(try await store.testProfiles(project: seed.project).isEmpty)
        #expect(try await store.events(limit: 10_000).filter { $0.kind == .policyDecided }.count == before + 1)
    }
}
