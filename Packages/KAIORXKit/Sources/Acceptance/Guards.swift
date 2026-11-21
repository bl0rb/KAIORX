import Darwin
import Foundation

/// Who may run the kit: the account owner, by hand, in their own terminal. Never Claude Code,
/// Codex, CI or a test (CLAUDE.md, ADR 0008). These checks refuse every known automated context;
/// the binding opt-in is the phrase the owner types per step.
public enum OwnerGuard {
    /// Variables set by CI systems and test runners.
    static let automationMarkers = ["CI", "GITHUB_ACTIONS", "BUILDKITE", "JENKINS_URL", "TF_BUILD", "GITLAB_CI", "TEAMCITY_VERSION",
                                    "XCTestConfigurationFilePath", "XCTestSessionIdentifier", "SWIFT_TESTING_ENABLED"]
    /// Prefixes of variables set by agent CLIs in their child processes (assumed names, checked
    /// conservatively: any of them refuses).
    static let agentMarkerPrefixes = ["CLAUDECODE", "CLAUDE_CODE_", "CODEX_SANDBOX", "CODEX_MANAGED_", "CODEX_THREAD", "TERM_PROGRAM=KAIORX"]
    /// Processes that must not be an ancestor of the kit.
    static let agentProcessNames: Set<String> = ["claude", "codex", "node", "bun", "Claude", "Codex", "KAIORX", "Claude Helper"]

    public struct Context: Sendable {
        public var environment: [String: String]
        public var interactive: Bool
        public var ancestors: [String]

        public init(environment: [String: String], interactive: Bool, ancestors: [String]) {
            self.environment = environment
            self.interactive = interactive
            self.ancestors = ancestors
        }

        /// The real process context.
        public static func current() -> Context {
            Context(
                environment: ProcessInfo.processInfo.environment,
                interactive: isatty(0) == 1 && isatty(1) == 1 && isatty(2) == 1,
                ancestors: OwnerGuard.ancestorNames()
            )
        }
    }

    /// Why the kit must not run here; empty when it may.
    public static func refusals(_ context: Context) -> [String] {
        var reasons: [String] = []
        if !context.interactive { reasons.append("Keine interaktive Terminalsitzung (stdin, stdout und stderr müssen ein Terminal sein).") }
        for marker in automationMarkers where context.environment[marker] != nil {
            reasons.append("Automatisierte Umgebung erkannt (\(marker)).")
        }
        let agentKeys = context.environment.filter { key, value in agentMarkerPrefixes.contains { key.hasPrefix($0) || "\(key)=\(value)" == $0 } }
            .keys.sorted()
        if let first = agentKeys.first {
            reasons.append("Läuft in einer Agentenumgebung (\(agentKeys.count) Variable\(agentKeys.count == 1 ? "" : "n"), z. B. \(first)).")
        }
        if let agent = context.ancestors.first(where: { name in agentProcessNames.contains(name) || agentProcessNames.contains { name.hasPrefix($0) } }) {
            reasons.append("Ein übergeordneter Prozess ist \(agent): Starte das Kit selbst in Terminal.app.")
        }
        return reasons
    }

    /// Names of the parent process chain (in-process `sysctl`, no child process).
    public static func ancestorNames() -> [String] {
        var names: [String] = []
        var pid = getppid()
        for _ in 0..<32 where pid > 1 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
            let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            names.append(name)
            pid = info.kp_eproc.e_ppid
        }
        return names
    }
}

/// How the kit talks to the owner. The terminal implementation reads typed lines; tests script it.
public protocol OwnerPrompter: Sendable {
    func show(_ text: String)
    /// A typed line, or nil at end of input.
    func ask(_ prompt: String) -> String?
}

/// The phrase that consents to exactly one step with exactly this binary. Consent never carries
/// over to another step, another binary or a resumed run.
public enum Consent {
    public static func phrase(step: StepID, provider: String, version: String, sha256: String) -> String {
        "\(step.rawValue) \(provider) \(version) \(sha256.prefix(6))"
    }

    public static func obtain(_ prompter: OwnerPrompter, step: StepID, provider: String, version: String, sha256: String, details: [String]) -> Bool {
        let phrase = Self.phrase(step: step, provider: provider, version: version, sha256: sha256)
        prompter.show((["", "── \(step.title) ──"] + details + ["Dieser Schritt nutzt dein Abo-Kontingent.", "Zum Fortfahren tippe genau: \(phrase)"]).joined(separator: "\n"))
        return prompter.ask("> ")?.trimmingCharacters(in: .whitespaces) == phrase
    }
}
