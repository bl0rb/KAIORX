import CryptoKit
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
        lines += ["", "Ein bestandener Bericht erlaubt den Status `liveVerified` nur für genau dieses Programm (SHA-256) und diesen Modus; die Änderung an der Matrix prüft und committet ein Mensch."]
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
