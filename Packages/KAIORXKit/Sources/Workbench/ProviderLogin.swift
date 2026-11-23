import Domain
import Foundation
import Orchestration
import ProcessHost
import Providers

/// The user's login check for a provider (ADR 0013): the automatic gate's subscription read,
/// run now instead of waiting for the next automatic start. It reads the login state only: no
/// inference, no login, the reviewer's environment and confinement (ADR 0008 §2).
public enum LoginCheck: Sendable, Equatable {
    case checking
    case verdict(SubscriptionVerdict)
    /// No check here (a channel without automation, no adapter); the first run checks it.
    case unavailable(String)
}

/// Logging in for KAIORX's own configuration folders, from the app (ADR 0013).
public enum ProviderLogin {
    /// The terminal that logs in: the CLI itself, interactive, started only by the user's click;
    /// only the user types. Claude starts its session (log in there, then `/exit`), Codex runs
    /// `codex login`. No shell, a fixed environment with the provider's folder, no self-update.
    public static func terminalSpec(
        _ provider: ProviderKind, executable: String, configDirectory: String, home: String = NSHomeDirectory(),
        host: [String: String] = ProcessInfo.processInfo.environment, rows: UInt16 = 30, columns: UInt16 = 100
    ) -> TerminalSpec? {
        let user = ClaudeCommand.accountName
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home, "USER": user, "LOGNAME": user,
            "LANG": host["LANG"] ?? "de_DE.UTF-8", "TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "KAIORX",
        ]
        let arguments: [String]
        switch provider {
        case .claude:
            environment["CLAUDE_CONFIG_DIR"] = configDirectory
            environment["DISABLE_AUTOUPDATER"] = "1"
            arguments = []
        case .codex:
            environment["CODEX_HOME"] = configDirectory
            arguments = ["login"]
        case .fake:
            return nil
        }
        return TerminalSpec(executable: executable, arguments: arguments, workingDirectory: configDirectory, environment: environment, rows: rows, columns: columns)
    }

    /// Runs the check: the configuration's own check (UI tests), else the automatic gate's fresh
    /// subscription read, which also lifts its cached verdict so a waiting task starts at once.
    public static func check(_ provider: ProviderKind, services: AppServices) async -> LoginCheck {
        if let custom = services.configuration.loginCheck {
            return await custom(provider).map(LoginCheck.verdict) ?? .unavailable(unavailableText)
        }
        guard let gate = services.configuration.gate as? AutomationGate, let result = await gate.checkSubscription(provider) else {
            return .unavailable(unavailableText)
        }
        switch result {
        case .verdict(let verdict): return .verdict(verdict)
        case .blocked(let block): return .unavailable("Nicht geprüft: " + (Labels.automation(block, provider: provider) ?? "das Gate lässt \(Labels.provider(provider)) nicht zu") + ".")
        }
    }

    static let unavailableText = "In dieser Ausgabe startet KAIORX keine Anbieter automatisch; die Anmeldung prüft der erste Lauf."

    /// The onboarding row for a provider's login.
    static func item(_ provider: ProviderKind, check: LoginCheck?, command: String) -> OnboardingItem {
        let name = Labels.provider(provider)
        let id = (provider == .claude ? "claude" : "codex") + "-login"
        let remedy = "KAIORX nutzt einen eigenen Konfigurationsordner. Melde dich mit „Im Terminal anmelden …“ an; „Anmeldung prüfen“ liest den Stand, ohne ein Modell aufzurufen."
        func row(_ status: OnboardingItem.Status, _ detail: String, remedy: String? = remedy) -> OnboardingItem {
            OnboardingItem(id: id, title: "\(name)-Anmeldung", status: status, detail: detail, remedy: remedy, command: command, login: provider)
        }
        switch check {
        case nil: return row(.unknown, "Noch nicht geprüft.")
        case .checking: return row(.unknown, "Wird geprüft …", remedy: nil)
        case .unavailable(let reason): return row(.unknown, reason)
        case .verdict(.subscription(let plan)): return row(.ok, "Angemeldet mit Abo" + (plan.map { " (\($0))" } ?? "") + ".", remedy: nil)
        case .verdict(.signedOut): return row(.missing, "Nicht angemeldet.")
        case .verdict(.otherBilling(let source)):
            return row(.warning, "Rechnet nicht nur über das Abo ab (\(source)).", remedy: "Schalte beim Anbieter Zusatzguthaben und API-Schlüssel ab, dann prüfe erneut. Bis dahin startet nichts automatisch.")
        case .verdict(.unclear(let reason)): return row(.warning, "Nicht eindeutig: \(reason).")
        }
    }
}
