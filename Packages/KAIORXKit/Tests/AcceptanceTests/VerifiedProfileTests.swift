import CryptoKit
import Domain
import Foundation
import Testing
@testable import Acceptance
@testable import Providers

/// ADR 0012: the real providers' model profiles come only from `VerifiedModelProfiles`, and every
/// entry rests on a committed owner report, like a `liveVerified` matrix entry.
@Suite struct VerifiedProfileTests {
    static let package = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let repository = package.deletingLastPathComponent().deletingLastPathComponent().path(percentEncoded: false)
    static let catalogPath = package.appending(path: "Sources/Providers/VerifiedModelProfiles.swift").path(percentEncoded: false)

    @Test func everyVerifiedProfileRestsOnCommittedEvidence() {
        #expect(!VerifiedModelProfiles.entries.isEmpty)
        for entry in VerifiedModelProfiles.entries {
            let problems = EvidenceCheck.profileProblems(entry, repositoryRoot: Self.repository)
            #expect(problems.isEmpty, "\(entry.provider) \(entry.version) \(entry.model): \(problems)")
            // Product settings that are not evidence stay "as accepted" until reports record them.
            #expect(entry.effort == nil && entry.typicalTokens == nil, "\(entry.provider) \(entry.version)")
        }
    }

    @Test func theCatalogIsUniqueAndCoversEveryLiveVerifiedVersion() {
        var keys = Set<String>()
        for entry in VerifiedModelProfiles.entries {
            for role in entry.roles {
                let key = "\(entry.provider.rawValue)|\(entry.version)|\(role.rawValue)|\(entry.tier.rawValue)"
                #expect(keys.insert(key).inserted, "doppelt: \(key)")
            }
        }
        for live in CompatibilityMatrix.entries where live.status == .liveVerified {
            #expect(VerifiedModelProfiles.entries.contains { $0.provider == live.provider && $0.version == live.version },
                    "\(live.provider) \(live.version) ohne Modellprofil")
        }
        // The a265 backfill: what the committed report exercised, as author and reviewer.
        let models = VerifiedModelProfiles.entries.map { "\($0.provider.rawValue) \($0.version) \($0.model) \($0.roles.map(\.rawValue))" }
        #expect(models == ["claude 2.1.329 sonnet [\"author\", \"reviewer\"]", "codex 0.170.0 gpt-6.2-sol [\"author\", \"reviewer\"]"])
        #expect(VerifiedModelProfiles.entries.allSatisfy { VerifiedModelProfiles.verifiedAt($0) == 1_795_132_800_000 })
    }

    @Test func profileIDsAreStableNameBasedAndBoundToTheVersion() throws {
        let entry = try #require(VerifiedModelProfiles.entries.first)
        let id = VerifiedModelProfiles.profileID(entry, role: .author)
        #expect(id == VerifiedModelProfiles.profileID(entry, role: .author))
        #expect(id != VerifiedModelProfiles.profileID(entry, role: .reviewer))
        var later = entry
        later.version = "99.0.0"
        #expect(id != VerifiedModelProfiles.profileID(later, role: .author))
        var stronger = entry
        stronger.tier = .intensive
        #expect(id != VerifiedModelProfiles.profileID(stronger, role: .author))
        // Version 5 layout with the RFC 4122 variant.
        let text = id.uuidString
        #expect(Array(text)[14] == "5")
        #expect("89ab".contains(Array(text)[19]))
        var bad = entry
        bad.verifiedOn = "2026-13-01"
        #expect(VerifiedModelProfiles.verifiedAt(bad) == nil)
        bad.verifiedOn = "20.11.2026"
        #expect(VerifiedModelProfiles.verifiedAt(bad) == nil)
    }

    @Test func theReadStepProvesTheReviewerAndTheWriteStepTheAuthor() {
        #expect(StepID.read.exercisedRole == .reviewer)
        #expect(StepID.author.exercisedRole == .author)
        #expect(StepID.allCases.filter { $0.exercisedRole != nil } == [.read, .author])
        #expect(StepID.exercising(.reviewer) == .read && StepID.exercising(.author) == .author)
        // Both are required, so every passed report covers both roles.
        #expect(AttemptRole.allCases.allSatisfy { StepID.exercising($0).required })
    }

    // MARK: Rejections

    struct Fixture {
        let root: String
        var report: AcceptanceReport
        var matrix: [CompatibilityEntry]

        init() throws {
            root = try temporaryRoot("profile-evidence")
            try FileManager.default.createDirectory(atPath: root + "/r", withIntermediateDirectories: true)
            report = AcceptanceReport(
                runID: "r", date: "2026-11-20", macOS: "x", arch: "arm64", kaiorxCommit: nil,
                providers: [AcceptanceReport.Provider(
                    provider: "claude", mode: "claudeSubscription", model: "m", version: "9.0.0", binarySHA256: "bin", nativePath: "~/b",
                    signing: [], verdict: "Abo", steps: StepID.allCases.filter { $0 != .parallel }.map {
                        AcceptanceReport.Step(id: $0.rawValue, title: $0.title, required: $0.required, status: "passed", evidence: [], limitation: nil)
                    },
                    passed: true, restrictions: [], fixtures: []
                )],
                parallel: nil
            )
            matrix = [CompatibilityEntry(provider: .claude, version: "9.0.0", status: .liveVerified, notes: "", schemaDigest: nil, builds: ["bin"])]
        }

        /// Writes the report and returns an entry that matches it.
        func write() throws -> VerifiedModelEntry {
            let data = try report.json()
            try data.write(to: URL(filePath: root + "/r/report.json"))
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return VerifiedModelEntry(
                provider: .claude, version: "9.0.0", model: "m", roles: [.author, .reviewer], tier: .standard, effort: nil, typicalTokens: nil,
                verifiedOn: "2026-11-20", evidence: LiveEvidence(reportPath: "r/report.json", reportSHA256: sha, mode: "claudeSubscription")
            )
        }

        func problems(_ entry: VerifiedModelEntry) -> [String] {
            EvidenceCheck.profileProblems(entry, matrix: matrix, repositoryRoot: root)
        }
    }

    @Test func anEntryWithoutMatchingEvidenceIsRejected() throws {
        var f = try Fixture()
        let entry = try f.write()
        #expect(f.problems(entry).isEmpty)
        // Tier is a product setting: any tier passes.
        var intensive = entry
        intensive.tier = .intensive
        #expect(f.problems(intensive).isEmpty)

        var other = entry
        other.model = "opus"
        #expect(f.problems(other) == ["Modell weicht ab"])
        other = entry
        other.evidence.mode = "codexCliManaged"
        #expect(f.problems(other) == ["Modus weicht ab"])
        other = entry
        other.verifiedOn = "2026-11-21"
        #expect(f.problems(other) == ["Datum weicht ab"])
        other = entry
        other.roles = []
        #expect(f.problems(other) == ["Profil ohne Rolle"])
        other = entry
        other.roles = [.author, .author]
        #expect(f.problems(other) == ["Rolle doppelt"])
        other = entry
        other.evidence.reportSHA256 = String(repeating: "0", count: 64)
        #expect(f.problems(other) == ["Bericht verändert"])
        other = entry
        other.evidence.reportPath = "r/missing.json"
        #expect(f.problems(other) == ["Bericht fehlt: r/missing.json"])
        other = entry
        other.version = "9.0.1"
        #expect(f.problems(other) == ["Bericht deckt claude 9.0.1 nicht ab"])

        // The matrix: the report's build must be listed under a liveVerified entry of the version.
        let matrix = f.matrix
        f.matrix[0].builds = ["another-build"]
        #expect(f.problems(entry) == ["Programm nicht in der Matrix"])
        f.matrix = matrix
        f.matrix[0].status = .offlineVerified
        #expect(f.problems(entry) == ["Matrixeintrag nicht liveVerified"])
        f.matrix = []
        #expect(f.problems(entry) == ["Version nicht in der Matrix"])
        f.matrix = matrix

        // A role counts only when the step that exercises it passed.
        let index = try #require(f.report.providers[0].steps.firstIndex { $0.id == StepID.read.rawValue })
        f.report.providers[0].steps[index].status = "failed"
        let readFailed = try f.write()
        #expect(f.problems(readFailed) == ["Schritt read nicht bestanden (reviewer)"])
        var authorOnly = readFailed
        authorOnly.roles = [.author]
        #expect(f.problems(authorOnly).isEmpty)
        f.report.providers[0].passed = false
        #expect(f.problems(try f.write()).contains("Bericht nicht bestanden"))
    }

    // MARK: Proposal

    @Test func theProfileProposalAndItsEvidenceCheckAgree() throws {
        let source = try String(contentsOfFile: Self.catalogPath, encoding: .utf8)
        // The backfill is exactly what the kit proposes from the committed report.
        for entry in VerifiedModelProfiles.entries {
            let data = try #require(FileManager.default.contents(atPath: Self.repository + "/" + entry.evidence.reportPath))
            let report = try JSONDecoder().decode(AcceptanceReport.self, from: data)
            let provider = try #require(report.providers.first { $0.provider == entry.provider.rawValue && $0.version == entry.version })
            let again = try ProfileProposal.propose(
                source: source, provider: provider.provider, version: entry.version, model: provider.model, roles: ProfileProposal.roles(provider),
                reportPath: entry.evidence.reportPath, reportSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                mode: provider.mode, date: report.date
            )
            #expect(again == source, "\(entry.provider) \(entry.version)")
        }

        var f = try Fixture()
        let entry = try f.write()
        let provider = f.report.providers[0]
        #expect(ProfileProposal.roles(provider) == [.author, .reviewer])
        func propose(_ text: String, model: String) throws -> String {
            try ProfileProposal.propose(
                source: text, provider: "claude", version: "9.0.0", model: model, roles: ProfileProposal.roles(provider),
                reportPath: entry.evidence.reportPath, reportSHA256: entry.evidence.reportSHA256, mode: provider.mode, date: f.report.date
            )
        }
        let proposed = try propose(source, model: "m")
        let block = """
                    VerifiedModelEntry(
                        provider: .claude, version: "9.0.0", model: "m", roles: [.author, .reviewer],
                        tier: .standard, // product setting (ADR 0012); the owner may change it before committing
                        effort: nil, typicalTokens: nil, verifiedOn: "2026-11-20",
                        evidence: LiveEvidence(reportPath: "r/report.json", reportSHA256: "\(entry.evidence.reportSHA256)", mode: "claudeSubscription")
                    ),
                    \(VerifiedModelProfiles.marker)
            """
        #expect(proposed.contains(block))
        // Other entries stay exactly as they are.
        #expect(proposed.replacingOccurrences(of: block, with: "        " + VerifiedModelProfiles.marker) == source)
        // The entry the block describes passes the evidence check against its report.
        #expect(f.problems(entry).isEmpty)

        // A second run of the same version replaces the entry and keeps the tier the owner chose.
        let chosen = proposed.replacingOccurrences(of: "model: \"m\", roles: [.author, .reviewer],\n            tier: .standard",
                                                   with: "model: \"m\", roles: [.author, .reviewer],\n            tier: .intensive")
        #expect(chosen != proposed)
        let replaced = try propose(chosen, model: "m2")
        #expect(replaced.components(separatedBy: "version: \"9.0.0\"").count == 2)
        #expect(replaced.contains("model: \"m2\"") && !replaced.contains("model: \"m\","))
        #expect(replaced.contains("model: \"m2\", roles: [.author, .reviewer],\n            tier: .intensive"))

        // A role whose step failed is not proposed; nothing to propose without a role or marker.
        f.report.providers[0].steps[try #require(f.report.providers[0].steps.firstIndex { $0.id == StepID.read.rawValue })].status = "failed"
        #expect(ProfileProposal.roles(f.report.providers[0]) == [.author])
        #expect(throws: ProfileProposal.Failure.noRoles) {
            try ProfileProposal.propose(source: source, provider: "claude", version: "9.0.0", model: "m", roles: [], reportPath: "x", reportSHA256: "x", mode: "x", date: "x")
        }
        #expect(throws: ProfileProposal.Failure.markerNotFound) {
            try ProfileProposal.propose(source: "", provider: "claude", version: "9.0.0", model: "m", roles: [.author], reportPath: "x", reportSHA256: "x", mode: "x", date: "x")
        }
    }

    // MARK: Source scan

    /// Real profiles are registered only by the catalog sync; hand registration stays in the
    /// store, the UI-test seed and the app's UI-test branch.
    @Test func profileRegistrationStaysWhereItBelongs() throws {
        let sources = Self.package.appending(path: "Sources").path(percentEncoded: false)
        let app = Self.package.deletingLastPathComponent().deletingLastPathComponent().appending(path: "App").path(percentEncoded: false)
        let rules: [(needle: String, allowed: Set<String>)] = [
            ("registerModelProfile(", ["Storage/StorePlanning.swift", "Workbench/UITestSeed.swift", "App/AppModel.swift"]),
            ("syncCatalogModelProfiles(", ["Storage/StorePlanning.swift", "Workbench/ModelProfileSync.swift"]),
            ("ModelProfileSync.run(", ["Workbench/Bootstrap.swift"]),
        ]
        var offenders: [String] = []
        var seen: [String: Set<String>] = [:]
        for (base, prefix) in [(sources, ""), (app, "App/")] {
            let enumerator = FileManager.default.enumerator(atPath: base)
            while let name = enumerator?.nextObject() as? String {
                guard name.hasSuffix(".swift") else { continue }
                let file = prefix + name
                let text = try String(contentsOfFile: base + "/" + name, encoding: .utf8)
                for rule in rules where text.contains(rule.needle) {
                    seen[rule.needle, default: []].insert(file)
                    if !rule.allowed.contains(file) { offenders.append("\(file): \(rule.needle)") }
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
        // The scan sees the files it guards (a moved file must update this test).
        #expect(seen["syncCatalogModelProfiles("] == ["Storage/StorePlanning.swift", "Workbench/ModelProfileSync.swift"])
        #expect(seen["ModelProfileSync.run("] == ["Workbench/Bootstrap.swift"])
        #expect(seen["registerModelProfile("]?.contains("App/AppModel.swift") == true)
    }
}
