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
    }

    /// The a265 backfill (ADR 0012 D1): what the committed report exercised, as author and
    /// reviewer. Only the entries resting on that report: later owner runs add their own entries
    /// through `matrix.patch`, proven by `profileProblems`, without touching this test.
    @Test func theA265BackfillIsWhatItsReportExercised() {
        let a265 = VerifiedModelProfiles.entries.filter { $0.evidence.reportPath == Self.a265Report }
        let models = a265.map { "\($0.provider.rawValue) \($0.version) \($0.model) \($0.roles.map(\.rawValue))" }
        #expect(models == ["claude 2.1.329 sonnet [\"author\", \"reviewer\"]", "codex 0.170.0 gpt-6.2-sol [\"author\", \"reviewer\"]"])
        #expect(a265.allSatisfy { VerifiedModelProfiles.verifiedAt($0) == 1_795_132_800_000 })
    }

    static let a265Report = "docs/live-acceptance/20261120-1429-a265/report.json"

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

        // A second run of the same model and version replaces the entry and keeps the tier the
        // owner chose (ADR 0012 §6).
        let chosen = proposed.replacingOccurrences(of: "model: \"m\", roles: [.author, .reviewer],\n            tier: .standard",
                                                   with: "model: \"m\", roles: [.author, .reviewer],\n            tier: .intensive")
        #expect(chosen != proposed)
        let rerun = try ProfileProposal.propose(
            source: chosen, provider: "claude", version: "9.0.0", model: "m", roles: [.author], reportPath: "r2/report.json",
            reportSHA256: "new-sha", mode: provider.mode, date: "2026-11-21"
        )
        #expect(rerun.components(separatedBy: "version: \"9.0.0\"").count == 2)
        #expect(rerun.contains("model: \"m\", roles: [.author],\n            tier: .intensive"))
        #expect(rerun.contains("verifiedOn: \"2026-11-21\"") && rerun.contains("reportSHA256: \"new-sha\"") && !rerun.contains("r/report.json"))
        // Another model of the same version is added beside it, not swapped in.
        let beside = try propose(chosen, model: "m2")
        #expect(beside.components(separatedBy: "version: \"9.0.0\"").count == 3)
        #expect(beside.contains("model: \"m\", roles: [.author, .reviewer],\n            tier: .intensive"))
        #expect(beside.contains("model: \"m2\", roles: [.author, .reviewer],\n            tier: .standard"))
        #expect(ProfileProposal.otherModels(source: beside, provider: "claude", version: "9.0.0", model: "m2") == ["m"])
        #expect(ProfileProposal.otherModels(source: beside, provider: "claude", version: "9.0.1", model: "m2").isEmpty)

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

    /// The kit's whole proposal for a report (`writeReport`), against the real sources. Finding:
    /// a rerun on a version that is already `liveVerified` threw in the matrix proposal and left
    /// no `matrix.patch`, so no stronger model could ever be proposed for that version.
    @Test func aRunOnAnAlreadyLiveVersionProposesOnlyItsProfile() throws {
        let compatibility = try String(contentsOfFile: Self.package.appending(path: "Sources/Providers/Compatibility.swift").path(percentEncoded: false), encoding: .utf8)
        let catalog = try String(contentsOfFile: Self.catalogPath, encoding: .utf8)
        let claude = try #require(CompatibilityMatrix.entry(for: .claude, version: "2.1.329"))
        let codex = try #require(CompatibilityMatrix.entry(for: .codex, version: "0.170.0"))
        let offline = try #require(CompatibilityMatrix.entries.first { $0.provider == .claude && $0.status == .offlineVerified })
        let root = try temporaryRoot("profile-rerun")
        let reportPath = "docs/live-acceptance/r2/report.json"
        func provider(_ kind: ProviderKind, version: String, build: String, model: String, mode: String) -> AcceptanceReport.Provider {
            AcceptanceReport.Provider(
                provider: kind.rawValue, mode: mode, model: model, version: version, binarySHA256: build, nativePath: "~/b", signing: [], verdict: "Abo",
                steps: StepID.allCases.filter { $0 != .parallel }.map {
                    AcceptanceReport.Step(id: $0.rawValue, title: $0.title, required: $0.required, status: "passed", evidence: [], limitation: nil)
                },
                passed: true, restrictions: [], fixtures: []
            )
        }
        func make(_ providers: [AcceptanceReport.Provider]) throws -> (ReportProposal.Result, String) {
            let report = AcceptanceReport(runID: "r2", date: "2026-11-22", macOS: "x", arch: "arm64", kaiorxCommit: nil, providers: providers, parallel: nil)
            let data = try report.json()
            try FileManager.default.createDirectory(atPath: root + "/docs/live-acceptance/r2", withIntermediateDirectories: true)
            try data.write(to: URL(filePath: root + "/" + reportPath))
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return (try ReportProposal.make(report: report, reportPath: reportPath, reportSHA256: sha, compatibility: compatibility, profiles: catalog), sha)
        }

        // `run both` with a stronger Claude model on the live builds of both versions.
        let (both, sha) = try make([
            provider(.claude, version: claude.version, build: claude.builds[0], model: "opus", mode: "claudeSubscription"),
            provider(.codex, version: codex.version, build: codex.builds[0], model: "gpt-6.2-sol", mode: "codexCliManaged"),
        ])
        #expect(both.compatibility == compatibility)
        let proposed = try #require(both.profiles)
        #expect(both.notes.count == 3)
        #expect(both.notes.filter { $0.contains("schon liveVerified") }.count == 2)
        #expect(both.notes.contains { $0.contains("opus kommt neben sonnet") })
        // opus is added beside sonnet; the sonnet entry stays as it is.
        let sonnet = try #require(VerifiedModelProfiles.entries.first { $0.provider == .claude && $0.model == "sonnet" })
        #expect(proposed.contains(#"provider: .claude, version: "2.1.329", model: "sonnet", roles: [.author, .reviewer],"#))
        #expect(proposed.contains("reportSHA256: \"\(sonnet.evidence.reportSHA256)\", mode: \"claudeSubscription\""))
        #expect(proposed.contains(#"provider: .claude, version: "2.1.329", model: "opus", roles: [.author, .reviewer],"#))
        // The same Codex model is replaced in place with the new report, keeping its tier.
        #expect(proposed.components(separatedBy: #"provider: .codex, version: "0.170.0""#).count == 2)
        #expect(proposed.components(separatedBy: "reportSHA256: \"\(sha)\"").count == 3)
        // What the patch adds passes the evidence check against the unchanged matrix.
        let opus = VerifiedModelEntry(
            provider: .claude, version: claude.version, model: "opus", roles: [.author, .reviewer], tier: .intensive, effort: nil, typicalTokens: nil,
            verifiedOn: "2026-11-22", evidence: LiveEvidence(reportPath: reportPath, reportSHA256: sha, mode: "claudeSubscription")
        )
        #expect(EvidenceCheck.profileProblems(opus, repositoryRoot: root).isEmpty)

        // An offline version still gets its matrix change and its profile; a live version with
        // another build gets neither, and neither blocks the other provider.
        let (mixed, _) = try make([
            provider(.claude, version: offline.version, build: "new-build", model: "sonnet", mode: "claudeSubscription"),
            provider(.codex, version: codex.version, build: "another-build", model: "gpt-6.2-sol", mode: "codexCliManaged"),
        ])
        #expect(mixed.compatibility.contains("provider: .claude, version: \"\(offline.version)\", status: .liveVerified,"))
        #expect(mixed.compatibility.contains(#"builds: ["new-build"],"#))
        #expect(mixed.profiles?.contains("provider: .claude, version: \"\(offline.version)\", model: \"sonnet\",") == true)
        #expect(mixed.profiles?.components(separatedBy: #"provider: .codex, version: "0.170.0""#).count == 2)
        #expect(mixed.profiles?.contains("another-build") == false)
        #expect(mixed.notes.count == 1 && mixed.notes[0].contains("anderes Programm"))

        // A version the matrix does not list: a note, no proposal; no catalog source: matrix only.
        let (unlisted, _) = try make([provider(.claude, version: "9.9.9", build: "x", model: "sonnet", mode: "claudeSubscription")])
        #expect(unlisted.compatibility == compatibility && unlisted.profiles == catalog)
        #expect(unlisted.notes.count == 1 && unlisted.notes[0].contains("nicht als offlineVerified"))
        let report = AcceptanceReport(runID: "r3", date: "2026-11-22", macOS: "x", arch: "arm64", kaiorxCommit: nil,
                                      providers: [provider(.claude, version: offline.version, build: "b", model: "sonnet", mode: "claudeSubscription")], parallel: nil)
        let matrixOnly = try ReportProposal.make(report: report, reportPath: "x", reportSHA256: "y", compatibility: compatibility, profiles: nil)
        #expect(matrixOnly.profiles == nil && matrixOnly.compatibility != compatibility)
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
