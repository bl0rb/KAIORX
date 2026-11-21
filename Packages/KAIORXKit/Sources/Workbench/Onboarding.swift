import Domain
import Foundation
import ProcessHost
import Providers
import Workspace

/// One onboarding check: one status and one way to fix it (Plan/macos-und-git.md: missing tools
/// and an expired login each have a visible remedy).
public struct OnboardingItem: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable {
        case ok, warning, missing, unknown
    }

    public var id: String
    public var title: String
    public var status: Status
    public var detail: String
    /// What the user can do; nil when nothing is needed.
    public var remedy: String?
    /// A command the user may copy and run themselves in their own terminal (never run by KAIORX).
    public var command: String?

    public var label: StatusLabel {
        switch status {
        case .ok: StatusLabel("Bereit", "checkmark.circle", .success)
        case .warning: StatusLabel("Eingeschränkt", "exclamationmark.triangle", .warning)
        case .missing: StatusLabel("Fehlt", "xmark.circle", .failure)
        case .unknown: StatusLabel("Wird beim ersten Lauf geprüft", "questionmark.circle", .neutral)
        }
    }
}

/// What the local probes found. Probes only read versions (`--version`) and test the sandbox;
/// they never log in or run a model (CLAUDE.md).
public struct ProbeResults: Sendable, Equatable {
    public var gitPath: String?
    public var clis: [ProviderKind: BinaryIdentity] = [:]
    public var cliErrors: [ProviderKind: String] = [:]
    public var confinement: ConfinementStatus?
    public var projects: Int = 0

    public init(gitPath: String? = nil) {
        self.gitPath = gitPath
    }
}

public enum Onboarding {
    /// Where the provider CLIs are usually installed; the first executable match wins. Node
    /// version managers (nvm) put `codex` under `~/.nvm/versions/node/<v>/bin`, newest first.
    public static func candidatePaths(_ provider: ProviderKind, home: String = NSHomeDirectory()) -> [String] {
        let name = provider == .claude ? "claude" : "codex"
        var paths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)", "\(home)/.npm-global/bin/\(name)"]
        if provider == .claude { paths.append("\(home)/.claude/local/claude") }
        let nvm = home + "/.nvm/versions/node"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        paths += versions.map { "\(nvm)/\($0)/bin/\(name)" }
        return paths
    }

    /// The native executable of the first installed CLI (an npm launcher resolves to its
    /// vendored binary, which the adapters can start without Node).
    public static func locate(_ provider: ProviderKind, home: String = NSHomeDirectory()) -> String? {
        for path in candidatePaths(provider, home: home) where FileManager.default.isExecutableFile(atPath: path) {
            if let native = try? NativeBinary.resolve(path) { return native }
        }
        return nil
    }

    /// Runs the local probes: Git, `--version` of each CLI found, the sandbox check.
    public static func probe(host: ProcessHost, scratch: URL, home: String = NSHomeDirectory(), projects: Int) async -> ProbeResults {
        var results = ProbeResults(gitPath: GitRunner.locate())
        for provider in [ProviderKind.claude, .codex] {
            guard let path = locate(provider, home: home) else { continue }
            do { results.clis[provider] = try await BinaryIdentity.probe(path, host: host) }
            catch { results.cliErrors[provider] = String(describing: error) }
        }
        results.confinement = await Confinement.probe(host: host, scratch: scratch)
        results.projects = projects
        return results
    }

    /// The command that logs in for KAIORX's own CLI configuration folders (the adapters do not
    /// use `~/.claude` or `~/.codex`, ADR 0003). The user runs it in their own terminal.
    public static func loginCommand(_ provider: ProviderKind, configDirectory: String?) -> String {
        let quoted = configDirectory.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        switch provider {
        case .claude: return quoted.map { "CLAUDE_CONFIG_DIR=\($0) claude" } ?? "claude"
        case .codex: return quoted.map { "CODEX_HOME=\($0) codex login" } ?? "codex login"
        case .fake: return ""
        }
    }

    /// The checklist from the probe results; `configDirectories` are the adapters' own folders.
    public static func checklist(_ probes: ProbeResults, configDirectories: [ProviderKind: String] = [:]) -> [OnboardingItem] {
        var items: [OnboardingItem] = []
        items.append(probes.gitPath.map {
            OnboardingItem(id: "git", title: "Git", status: .ok, detail: $0)
        } ?? OnboardingItem(
            id: "git", title: "Git", status: .missing, detail: "Git wurde nicht gefunden.",
            remedy: "Installiere die Command Line Tools und starte KAIORX neu.", command: "xcode-select --install"
        ))
        for provider in [ProviderKind.claude, .codex] {
            let name = Labels.provider(provider)
            let binary = provider == .claude ? "claude" : "codex"
            if let identity = probes.clis[provider] {
                let entry = CompatibilityMatrix.entry(for: provider, version: identity.version)
                switch entry?.status {
                case .liveVerified:
                    items.append(OnboardingItem(id: binary, title: name, status: .ok, detail: "Version \(identity.version), live abgenommen"))
                case .offlineVerified:
                    items.append(OnboardingItem(
                        id: binary, title: name, status: .warning, detail: "Version \(identity.version), offline geprüft",
                        remedy: "Automatik gesperrt bis zur Live-Abnahme durch den Kontoinhaber. Manuelle Übergabe bleibt möglich."
                    ))
                case nil:
                    items.append(OnboardingItem(
                        id: binary, title: name, status: .warning, detail: "Version \(identity.version) ist nicht in der Kompatibilitätsliste",
                        remedy: "Automatik gesperrt. Installiere eine geprüfte Version oder nutze die manuelle Übergabe."
                    ))
                }
                items.append(OnboardingItem(
                    id: "\(binary)-login", title: "\(name)-Anmeldung", status: .unknown,
                    detail: "KAIORX liest keine Anmeldedaten und prüft die Anmeldung erst beim ersten Lauf.",
                    remedy: "KAIORX nutzt einen eigenen Konfigurationsordner. Melde dich dafür selbst im Terminal mit diesem Befehl an.",
                    command: loginCommand(provider, configDirectory: configDirectories[provider])
                ))
            } else if let error = probes.cliErrors[provider] {
                items.append(OnboardingItem(
                    id: binary, title: name, status: .missing, detail: "Gefunden, aber die Versionsabfrage schlug fehl: \(error)",
                    remedy: "Prüfe die Installation im Terminal.", command: "\(binary) --version"
                ))
            } else {
                items.append(OnboardingItem(
                    id: binary, title: name, status: .missing, detail: "Nicht installiert oder nicht gefunden.",
                    remedy: "Installiere \(name) und starte KAIORX neu. Bereits erzeugte Diffs bleiben erreichbar."
                ))
            }
        }
        switch probes.confinement {
        case .effective:
            items.append(OnboardingItem(id: "sandbox", title: "Schreibschutz für Agenten", status: .ok, detail: "sandbox-exec wirkt."))
        case .unavailable(let reason):
            items.append(OnboardingItem(
                id: "sandbox", title: "Schreibschutz für Agenten", status: .missing, detail: reason,
                remedy: "Ohne wirksamen Schreibschutz starten keine automatischen Läufe."
            ))
        case nil:
            items.append(OnboardingItem(id: "sandbox", title: "Schreibschutz für Agenten", status: .unknown, detail: "Noch nicht geprüft."))
        }
        items.append(probes.projects > 0
            ? OnboardingItem(id: "project", title: "Projekt", status: .ok, detail: "\(probes.projects) geöffnet")
            : OnboardingItem(
                id: "project", title: "Projekt", status: .missing, detail: "Noch kein Projekt geöffnet.",
                remedy: "Öffne ein eigenes, vertrauenswürdiges Git-Repository (⌘O)."
            ))
        return items
    }
}
