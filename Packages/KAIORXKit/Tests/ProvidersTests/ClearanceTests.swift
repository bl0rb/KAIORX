import CryptoKit
import Domain
import Foundation
import Testing
@testable import Providers

@Suite struct DistributionChannelTests {
    @Test func onlyAnExplicitPersonalValueMakesAPersonalBuild() {
        #expect(DistributionChannel.from(info: [DistributionChannel.infoKey: "personal"]) == .personal)
        #expect(DistributionChannel.from(info: [DistributionChannel.infoKey: "distributed"]) == .distributed)
        // Missing, unknown, unsubstituted or mistyped values fail closed.
        #expect(DistributionChannel.from(info: nil) == .distributed)
        #expect(DistributionChannel.from(info: [:]) == .distributed)
        #expect(DistributionChannel.from(info: [DistributionChannel.infoKey: "$(KAIORX_DISTRIBUTION_CHANNEL)"]) == .distributed)
        #expect(DistributionChannel.from(info: [DistributionChannel.infoKey: "Personal"]) == .distributed)
        #expect(DistributionChannel.from(info: [DistributionChannel.infoKey: true]) == .distributed)
        // The test runner is no app bundle with the key.
        #expect(DistributionChannel.current() == .distributed)
    }
}

@Suite struct ProviderClearanceTests {
    static let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().path(percentEncoded: false)

    /// No clearance exists today; any entry the owner adds must rest on its committed document.
    @Test func everyClearanceIsBackedByItsDocument() {
        for entry in ProviderClearance.entries {
            let problems = ClearanceCheck.problems(entry, repositoryRoot: Self.repository)
            #expect(problems.isEmpty, "\(entry.provider) \(entry.channel): \(problems)")
        }
    }

    @Test func theCheckFindsMissingChangedAndMalformedEntries() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "kaiorx-clearance-\(UUID().uuidString)").path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: root + "/docs/provider-clearance", withIntermediateDirectories: true)
        let text = Data("Schriftliche Freigabe (redigiert)\n".utf8)
        try text.write(to: URL(filePath: root + "/docs/provider-clearance/codex.md"))
        let sha = SHA256.hash(data: text).map { String(format: "%02x", $0) }.joined()
        let good = ProviderClearance(
            provider: .codex, channel: .distributed, scope: "Autor und Reviewer, cliManaged", documentPath: "docs/provider-clearance/codex.md",
            documentSHA256: sha, expiresOn: "2027-03-31"
        )
        #expect(ClearanceCheck.problems(good, repositoryRoot: root).isEmpty)
        var changed = good
        changed.documentSHA256 = String(repeating: "0", count: 64)
        #expect(ClearanceCheck.problems(changed, repositoryRoot: root) == ["Dokument verändert"])
        var missing = good
        missing.documentPath = "docs/provider-clearance/claude.md"
        #expect(ClearanceCheck.problems(missing, repositoryRoot: root) == ["Dokument fehlt: docs/provider-clearance/claude.md"])
        var outside = good
        outside.documentPath = "docs/provider-clearance/../../secret"
        #expect(ClearanceCheck.problems(outside, repositoryRoot: root) == ["Dokument liegt nicht unter docs/provider-clearance/"])
        var personal = good
        personal.channel = .personal
        personal.expiresOn = "2027-02-30"
        personal.scope = " "
        #expect(Set(ClearanceCheck.problems(personal, repositoryRoot: root)) == [
            "Freigabe nur für den vertriebenen Kanal", "Umfang fehlt", "Ablaufdatum unlesbar: 2027-02-30",
        ])
    }

    @Test func aClearanceCountsUntilTheEndOfItsLastDay() throws {
        let entry = ProviderClearance(provider: .codex, channel: .distributed, scope: "s", documentPath: "d", documentSHA256: "x", expiresOn: "2026-11-30")
        let end = try #require(entry.expiresAt)
        #expect(end == 1_796_083_200_000) // 2026-12-01T00:00:00Z
        #expect(entry.permits(.codex, in: .distributed, at: end - 1))
        #expect(!entry.permits(.codex, in: .distributed, at: end))
        #expect(!entry.permits(.claude, in: .distributed, at: end - 1))
        #expect(!entry.permits(.codex, in: .personal, at: end - 1))
        for malformed in ["2026-13-01", "2026-1-01", "26-11-30", "2026-11-30T00:00", ""] {
            var bad = entry
            bad.expiresOn = malformed
            #expect(bad.expiresAt == nil, "\(malformed)")
        }
    }
}

@Suite struct LiveVerificationTests {
    @Test func theSharedCheckBindsVersionAndBuild() throws {
        for entry in CompatibilityMatrix.entries {
            let identity = BinaryIdentity(path: "/x", resolvedPath: "/x", sha256: entry.builds.first ?? "none", version: entry.version)
            let expected: LiveVerification = entry.status == .liveVerified ? .verified : .versionNotLiveVerified
            #expect(CompatibilityMatrix.liveVerification(entry.provider, identity: identity) == expected)
            var other = identity
            other.sha256 = "another-build"
            if entry.status == .liveVerified {
                #expect(CompatibilityMatrix.liveVerification(entry.provider, identity: other) == .buildNotVerified)
            }
        }
        let unknown = BinaryIdentity(path: "/x", resolvedPath: "/x", sha256: "s", version: "0.0.0-none")
        #expect(CompatibilityMatrix.liveVerification(.codex, identity: unknown) == .versionNotListed)
    }
}
