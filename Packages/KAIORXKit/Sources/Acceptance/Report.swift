import CryptoKit
import Domain
import Foundation
import ProcessHost
import Providers

/// The acceptance report: one JSON file is the source; the Markdown is rendered from it. No
/// private values: paths are shown home-relative, the account only as the owner's confirmation.
public struct AcceptanceReport: Codable, Sendable, Equatable {
    public struct Provider: Codable, Sendable, Equatable {
        public var provider: String
        public var mode: String
        public var model: String
        public var version: String?
        public var binarySHA256: String?
        public var nativePath: String
        public var signing: [String]
        public var verdict: String?
        public var steps: [Step]
        public var passed: Bool
        public var restrictions: [String]
        public var fixtures: [String]
    }

    public struct Step: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var required: Bool
        public var status: String
        public var evidence: [String]
        public var limitation: String?
    }

    public var schemaVersion = 1
    public var runID: String
    public var date: String
    public var macOS: String
    public var arch: String
    public var kaiorxCommit: String?
    public var providers: [Provider]
    public var parallel: Step?

    public static func make(_ state: RunState, home: String) -> AcceptanceReport {
        let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        func tilde(_ path: String) -> String { path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return AcceptanceReport(
            runID: state.runID, date: formatter.string(from: Date(timeIntervalSince1970: Double(state.createdAt) / 1000)),
            macOS: state.macOS, arch: state.arch, kaiorxCommit: state.kaiorxCommit,
            providers: state.providers.map { run in
                Provider(
                    provider: run.provider.rawValue, mode: run.mode, model: run.model, version: run.identity?.version,
                    binarySHA256: run.identity?.sha256, nativePath: tilde(run.nativePath), signing: run.signing, verdict: run.verdict,
                    steps: StepID.allCases.filter { $0 != .parallel }.map { step in
                        let result = run.steps[step] ?? StepResult(status: .pending)
                        return Step(id: step.rawValue, title: step.title, required: step.required, status: result.status.rawValue,
                                    evidence: result.evidence.map { $0.replacingOccurrences(of: home + "/", with: "~/") }, limitation: result.limitation)
                    },
                    passed: run.passed, restrictions: run.restrictions, fixtures: run.fixtures
                )
            },
            parallel: state.parallel.map { Step(id: "parallel", title: StepID.parallel.title, required: false, status: $0.status.rawValue, evidence: $0.evidence, limitation: $0.limitation) }
        )
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The Markdown report, deterministic for the same JSON (ARCHITEKTURPLAN: version, date,
    /// macOS, mode, result and remaining restriction first).
    public func markdown() -> String {
        var lines = ["# Live-Abnahme \(runID)", "", "| Anbieter | Version | Modus | Datum | macOS | Ergebnis |", "|---|---|---|---|---|---|"]
        for provider in providers {
            lines.append("| \(provider.provider) | \(provider.version ?? "?") | \(provider.mode) | \(date) | \(macOS) (\(arch)) | \(provider.passed ? "bestanden" : "nicht bestanden") |")
        }
        for provider in providers {
            lines += ["", "## \(provider.provider) \(provider.version ?? "")", "",
                      "- Programm: `\(provider.nativePath)`, SHA-256 `\(provider.binarySHA256 ?? "?")`",
                      "- Modell: \(provider.model)", "- Anmeldung: \(provider.verdict ?? "nicht geprüft")"]
            if !provider.signing.isEmpty { lines.append("- Signatur: " + provider.signing.joined(separator: "; ")) }
            lines += ["", "| Schritt | Pflicht | Ergebnis | Beobachtung |", "|---|---|---|---|"]
            for step in provider.steps {
                let observed = (step.evidence + (step.limitation.map { ["Einschränkung: \($0)"] } ?? [])).joined(separator: "; ")
                    .replacingOccurrences(of: "|", with: "\\|")
                lines.append("| \(step.title) | \(step.required ? "ja" : "nein") | \(step.status) | \(observed) |")
            }
            lines += ["", "Verbleibende Einschränkungen:"] + (provider.restrictions.isEmpty ? ["- keine"] : provider.restrictions.map { "- \($0)" })
            if !provider.fixtures.isEmpty { lines += ["", "Redigierte Aufzeichnungen: " + provider.fixtures.map { "`\($0)`" }.joined(separator: ", ")] }
        }
        if let parallel { lines += ["", "## Zwei Anbieter gleichzeitig", "", "\(parallel.status): " + parallel.evidence.joined(separator: "; ")] }
        lines += ["", "Ein bestandener Bericht erlaubt den Status `liveVerified` nur für genau dieses Programm (SHA-256) und diesen Modus; die Änderung an der Matrix und die vorgeschlagenen Modellprofile prüft und committet ein Mensch."]
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The proposed change to `Compatibility.swift` for a passed provider: status `liveVerified`, the
/// build's SHA-256 and the evidence (report path and its SHA-256). Produced as a whole file and a
/// unified diff; the kit never edits the repository.
public enum MatrixProposal {
    public enum Failure: Error, Equatable, Sendable {
        case notPassed
        case entryNotFound(String)
    }

    /// What the source says about a version before a proposal (ADR 0012 §6): only an
    /// `offlineVerified` entry gets a matrix change; a version that is already `liveVerified`
    /// with the run's build needs none.
    public enum EntryState: Equatable, Sendable {
        case notListed
        case offlineVerified
        case liveVerified(sameBuild: Bool)
    }

    public static func state(source: String, provider: String, version: String, binarySHA256: String) -> EntryState {
        let head = "provider: .\(provider), version: \"\(version)\", status: ."
        guard let start = source.range(of: head) else { return .notListed }
        let rest = source[start.upperBound...]
        if rest.hasPrefix("offlineVerified,") { return .offlineVerified }
        guard rest.hasPrefix("liveVerified,") else { return .notListed }
        let end = source.range(of: "\n        ),", range: start.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        return .liveVerified(sameBuild: source[start.upperBound..<end].contains("\"\(binarySHA256)\""))
    }

    /// The source with the entry for `provider`/`version` changed.
    public static func propose(source: String, provider: String, version: String, binarySHA256: String, reportPath: String, reportSHA256: String, mode: String) throws -> String {
        let anchor = "provider: .\(provider), version: \"\(version)\", status: .offlineVerified,"
        guard let anchorRange = source.range(of: anchor) else { throw Failure.entryNotFound("\(provider) \(version)") }
        var text = source
        text.replaceSubrange(anchorRange, with: "provider: .\(provider), version: \"\(version)\", status: .liveVerified,")
        guard let start = text.range(of: "provider: .\(provider), version: \"\(version)\""),
              let digest = text.range(of: "schemaDigest:", range: start.upperBound..<text.endIndex),
              let lineEnd = text[digest.upperBound...].firstIndex(of: "\n") else { throw Failure.entryNotFound("schemaDigest") }
        let indent = String(text[text[..<digest.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) }!..<digest.lowerBound])
        var line = String(text[digest.lowerBound..<lineEnd])
        if !line.hasSuffix(",") { line += "," }
        let addition = "\n\(indent)builds: [\"\(binarySHA256)\"],\n\(indent)evidence: LiveEvidence(reportPath: \"\(reportPath)\", reportSHA256: \"\(reportSHA256)\", mode: \"\(mode)\")"
        text.replaceSubrange(digest.lowerBound..<lineEnd, with: line + addition)
        return text
    }

    /// A unified diff of two files (`diff -u` through ProcessHost; read-only).
    public static func diff(original: String, proposed: String, label: String, host: ProcessHost, scratch: String) async throws -> String {
        let a = scratch + "/original.swift", b = scratch + "/proposed.swift"
        try Data(original.utf8).write(to: URL(filePath: a))
        try Data(proposed.utf8).write(to: URL(filePath: b))
        let result = try await host.run(LaunchSpec(
            executable: "/usr/bin/diff", arguments: ["-u", "--label", "a/\(label)", "--label", "b/\(label)", a, b], workingDirectory: scratch,
            environment: ["PATH": "/usr/bin:/bin"], outputLimit: 1 << 20, timeout: .seconds(10)
        ))
        return result.stdout.text
    }
}

/// What a `liveVerified` matrix entry must rest on, checked by a test on every build: a committed
/// report whose SHA-256 matches, for this provider, version, build and mode, that passed.
public enum EvidenceCheck {
    public static func problems(_ entry: CompatibilityEntry, repositoryRoot: String) -> [String] {
        guard entry.status == .liveVerified else { return entry.evidence == nil && entry.builds.isEmpty ? [] : ["Belege ohne liveVerified"] }
        guard let evidence = entry.evidence else { return ["liveVerified ohne Beleg"] }
        if entry.builds.isEmpty { return ["liveVerified ohne Programm-SHA"] }
        guard let data = FileManager.default.contents(atPath: repositoryRoot + "/" + evidence.reportPath) else { return ["Bericht fehlt: \(evidence.reportPath)"] }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard sha == evidence.reportSHA256 else { return ["Bericht verändert"] }
        guard let report = try? JSONDecoder().decode(AcceptanceReport.self, from: data) else { return ["Bericht nicht lesbar"] }
        guard let provider = report.providers.first(where: { $0.provider == entry.provider.rawValue && $0.version == entry.version }) else {
            return ["Bericht deckt \(entry.provider.rawValue) \(entry.version) nicht ab"]
        }
        var problems: [String] = []
        if !provider.passed { problems.append("Bericht nicht bestanden") }
        if provider.mode != evidence.mode { problems.append("Modus weicht ab") }
        // Exactly the build the report covers: no extra, unchecked build may ride along.
        if provider.binarySHA256 == nil || entry.builds != [provider.binarySHA256!] { problems.append("Programm-SHA weicht ab") }
        // Required steps as this build defines them, not as the report labels them.
        let statuses = Dictionary(provider.steps.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        if StepID.allCases.contains(where: { $0.required && statuses[$0.rawValue] != "passed" }) { problems.append("Pflichtschritt nicht bestanden") }
        for fixture in provider.fixtures {
            let path = repositoryRoot + "/" + (evidence.reportPath as NSString).deletingLastPathComponent + "/fixtures/" + fixture
            if !FileManager.default.fileExists(atPath: path) { problems.append("Aufzeichnung fehlt: \(fixture)") }
        }
        return problems
    }
}

/// The proposed entry in `VerifiedModelProfiles.swift` for a passed provider (ADR 0012): the model
/// the run exercised, the roles whose step passed, the report's date and evidence. A pure string
/// change like `MatrixProposal`; the kit never edits the repository.
public enum ProfileProposal {
    public enum Failure: Error, Equatable, Sendable {
        case markerNotFound
        case noRoles
    }

    /// The roles a provider's report proves: those whose exercising step passed.
    public static func roles(_ provider: AcceptanceReport.Provider) -> [AttemptRole] {
        let statuses = Dictionary(provider.steps.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        return AttemptRole.allCases.filter { statuses[StepID.exercising($0).rawValue] == "passed" }
    }

    /// The source with an entry for `provider`/`version`/`model` (ADR 0012 §6): the entry of the
    /// same model and version is replaced in place (keeping the tier the owner chose for it); a
    /// new model, also one for a version that already has another model, is added above the marker.
    public static func propose(
        source: String, provider: String, version: String, model: String, roles: [AttemptRole], reportPath: String, reportSHA256: String,
        mode: String, date: String
    ) throws -> String {
        guard !roles.isEmpty else { throw Failure.noRoles }
        let ordered = AttemptRole.allCases.filter(roles.contains)
        let head = "        VerifiedModelEntry(\n            provider: .\(provider), version: \"\(version)\", model: \"\(model)\","
        var text = source
        var tier = "standard"
        var target: Range<String.Index>
        if let start = text.range(of: head), let end = text.range(of: "\n        ),\n", range: start.upperBound..<text.endIndex) {
            target = start.lowerBound..<end.upperBound
            if let chosen = text[target].range(of: #"tier: \.[a-z]+"#, options: .regularExpression) {
                tier = String(text[chosen].dropFirst("tier: .".count))
            }
        } else {
            guard let marker = text.range(of: VerifiedModelProfiles.marker) else { throw Failure.markerNotFound }
            let lineStart = text[..<marker.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            target = lineStart..<lineStart
        }
        let block = """
                    VerifiedModelEntry(
                        provider: .\(provider), version: "\(version)", model: "\(model)", roles: [\(ordered.map { "." + $0.rawValue }.joined(separator: ", "))],
                        tier: .\(tier), // product setting (ADR 0012); the owner may change it before committing
                        effort: nil, typicalTokens: nil, verifiedOn: "\(date)",
                        evidence: LiveEvidence(reportPath: "\(reportPath)", reportSHA256: "\(reportSHA256)", mode: "\(mode)")
                    ),

            """
        text.replaceSubrange(target, with: block)
        return text
    }

    /// The models of other catalog entries for the same provider and version. The catalog allows
    /// one model per (provider, version, role, tier), so the owner chooses the new model's tier.
    public static func otherModels(source: String, provider: String, version: String, model: String) -> [String] {
        let head = "provider: .\(provider), version: \"\(version)\", model: \""
        var models: [String] = []
        var cursor = source.startIndex
        while let found = source.range(of: head, range: cursor..<source.endIndex) {
            cursor = found.upperBound
            guard let close = source[found.upperBound...].firstIndex(of: "\"") else { break }
            let name = String(source[found.upperBound..<close])
            if name != model && !models.contains(name) { models.append(name) }
        }
        return models
    }
}

/// Everything the kit proposes for a report (ADR 0008 §8, ADR 0012 §6): the changed matrix and
/// catalog sources and notes for the owner. Pure; `writeReport` diffs and writes the patch.
public enum ReportProposal {
    public struct Result: Sendable, Equatable {
        /// `Compatibility.swift` with every matrix change.
        public var compatibility: String
        /// `VerifiedModelProfiles.swift` with every proposed entry; nil when it was not found.
        public var profiles: String?
        public var notes: [String]
    }

    /// Per passed provider: an `offlineVerified` version becomes `liveVerified` with the run's
    /// build; a version that is already `liveVerified` with that build stays as it is. Either
    /// way the run's model is proposed for the catalog. A version the matrix does not list, or
    /// lists with another build, gets neither; the other providers still get their proposals.
    public static func make(report: AcceptanceReport, reportPath: String, reportSHA256: String, compatibility: String, profiles: String?) throws -> Result {
        var result = Result(compatibility: compatibility, profiles: profiles, notes: [])
        for provider in report.providers where provider.passed {
            guard let version = provider.version, let build = provider.binarySHA256 else { continue }
            let name = "\(provider.provider) \(version)"
            switch MatrixProposal.state(source: result.compatibility, provider: provider.provider, version: version, binarySHA256: build) {
            case .offlineVerified:
                result.compatibility = try MatrixProposal.propose(
                    source: result.compatibility, provider: provider.provider, version: version, binarySHA256: build,
                    reportPath: reportPath, reportSHA256: reportSHA256, mode: provider.mode
                )
            case .liveVerified(sameBuild: true):
                result.notes.append("\(name) ist mit diesem Programm schon liveVerified: keine Matrixänderung, nur das Modellprofil.")
            case .liveVerified(sameBuild: false):
                result.notes.append("\(name): Die Matrix nennt ein anderes Programm als dieser Lauf; weder Matrixänderung noch Modellprofil.")
                continue
            case .notListed:
                result.notes.append("\(name) steht nicht als offlineVerified oder liveVerified in der Matrix; kein Vorschlag.")
                continue
            }
            guard let catalog = result.profiles else { continue }
            let others = ProfileProposal.otherModels(source: catalog, provider: provider.provider, version: version, model: provider.model)
            result.profiles = try ProfileProposal.propose(
                source: catalog, provider: provider.provider, version: version, model: provider.model, roles: ProfileProposal.roles(provider),
                reportPath: reportPath, reportSHA256: reportSHA256, mode: provider.mode, date: report.date
            )
            if !others.isEmpty {
                result.notes.append(
                    "\(name): \(provider.model) kommt neben \(others.joined(separator: ", ")) in den Katalog. Wähle im Patch eine Stufe, "
                        + "die kein anderes Modell dieser Version mit derselben Rolle hat (ein Modell je Version, Rolle und Stufe)."
                )
            }
        }
        return result
    }
}

extension EvidenceCheck {
    /// What a `VerifiedModelProfiles` entry must rest on (ADR 0012), checked by a test on every
    /// build: a committed, unchanged report in which this provider and version passed with this
    /// mode and model on the entry's date; a `liveVerified` matrix entry that names the report's
    /// build; and, for every role, the step that exercises it passed. Tier, effort and tokens are
    /// product settings, not evidence.
    public static func profileProblems(
        _ entry: VerifiedModelEntry, matrix: [CompatibilityEntry] = CompatibilityMatrix.entries, repositoryRoot: String
    ) -> [String] {
        var problems: [String] = []
        if entry.roles.isEmpty { problems.append("Profil ohne Rolle") }
        if Set(entry.roles).count != entry.roles.count { problems.append("Rolle doppelt") }
        if VerifiedModelProfiles.verifiedAt(entry) == nil { problems.append("Datum unlesbar") }
        let evidence = entry.evidence
        guard let data = FileManager.default.contents(atPath: repositoryRoot + "/" + evidence.reportPath) else {
            return problems + ["Bericht fehlt: \(evidence.reportPath)"]
        }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard sha == evidence.reportSHA256 else { return problems + ["Bericht verändert"] }
        guard let report = try? JSONDecoder().decode(AcceptanceReport.self, from: data) else { return problems + ["Bericht nicht lesbar"] }
        guard let provider = report.providers.first(where: { $0.provider == entry.provider.rawValue && $0.version == entry.version }) else {
            return problems + ["Bericht deckt \(entry.provider.rawValue) \(entry.version) nicht ab"]
        }
        if !provider.passed { problems.append("Bericht nicht bestanden") }
        if provider.mode != evidence.mode { problems.append("Modus weicht ab") }
        if provider.model != entry.model { problems.append("Modell weicht ab") }
        if report.date != entry.verifiedOn { problems.append("Datum weicht ab") }
        if let listed = matrix.first(where: { $0.provider == entry.provider && $0.version == entry.version }) {
            if listed.status != .liveVerified { problems.append("Matrixeintrag nicht liveVerified") }
            if provider.binarySHA256.map(listed.builds.contains) != true { problems.append("Programm nicht in der Matrix") }
        } else {
            problems.append("Version nicht in der Matrix")
        }
        let statuses = Dictionary(provider.steps.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        for role in AttemptRole.allCases where entry.roles.contains(role) {
            let step = StepID.exercising(role)
            if statuses[step.rawValue] != "passed" { problems.append("Schritt \(step.rawValue) nicht bestanden (\(role.rawValue))") }
        }
        return problems
    }
}
