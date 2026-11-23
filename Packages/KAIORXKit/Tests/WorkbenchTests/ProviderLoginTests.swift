import Domain
import Foundation
import ProcessHost
@testable import Orchestration
@testable import Providers
import Testing
@testable import Workbench

/// ADR 0013: login buttons in the onboarding and the setup check.
@Suite struct ProviderLoginTests {
    @Test func theLoginTerminalRunsTheCLIInKAIORXsFolderWithAFixedEnvironment() throws {
        let host = ["HOME": "/Users/u", "LANG": "de_DE.UTF-8", "ANTHROPIC_API_KEY": "sk-geheim", "CLAUDE_CONFIG_DIR": "/Users/u/.claude", "SSH_AUTH_SOCK": "/tmp/agent"]
        let claude = try #require(ProviderLogin.terminalSpec(.claude, executable: "/v/2.1.329", configDirectory: "/s/claude-config", home: "/Users/u", host: host))
        #expect(claude.executable == "/v/2.1.329" && claude.arguments.isEmpty && claude.workingDirectory == "/s/claude-config")
        #expect(claude.environment["CLAUDE_CONFIG_DIR"] == "/s/claude-config")
        #expect(claude.environment["DISABLE_AUTOUPDATER"] == "1")
        #expect(claude.environment["HOME"] == "/Users/u" && claude.environment["LANG"] == "de_DE.UTF-8")
        // Nothing else from the app's environment: no key, no agent socket, not the user's own folder.
        #expect(claude.environment["ANTHROPIC_API_KEY"] == nil && claude.environment["SSH_AUTH_SOCK"] == nil)
        #expect(Set(claude.environment.keys) == ["PATH", "HOME", "USER", "LOGNAME", "LANG", "TERM", "COLORTERM", "TERM_PROGRAM", "CLAUDE_CONFIG_DIR", "DISABLE_AUTOUPDATER"])

        let codex = try #require(ProviderLogin.terminalSpec(.codex, executable: "/n/codex", configDirectory: "/s/codex-home", home: "/Users/u", host: host))
        #expect(codex.arguments == ["login"] && codex.environment["CODEX_HOME"] == "/s/codex-home" && codex.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(ProviderLogin.terminalSpec(.fake, executable: "/x", configDirectory: "/y") == nil)
    }

    @Test func theLoginRowShowsTheCheckAndOffersTheButtons() {
        var probes = ProbeResults(gitPath: "/usr/bin/git")
        probes.clis[.claude] = BinaryIdentity(path: "/c", resolvedPath: "/c", sha256: "x", version: "2.1.329")
        func row() -> OnboardingItem? { Onboarding.checklist(probes).first { $0.id == "claude-login" } }
        #expect(row()?.login == .claude && row()?.status == .unknown && row()?.detail == "Noch nicht geprüft.")
        #expect(row()?.command?.hasPrefix("DISABLE_AUTOUPDATER=1 ") == true)
        let cases: [(LoginCheck, OnboardingItem.Status, String)] = [
            (.checking, .unknown, "Wird geprüft …"),
            (.verdict(.subscription(plan: "max")), .ok, "Angemeldet mit Abo (max)."),
            (.verdict(.signedOut), .missing, "Nicht angemeldet."),
            (.verdict(.otherBilling("apiKeySource")), .warning, "Rechnet nicht nur über das Abo ab (apiKeySource)."),
            (.verdict(.unclear("keine JSON-Ausgabe")), .warning, "Nicht eindeutig: keine JSON-Ausgabe."),
            (.unavailable("nicht hier"), .unknown, "nicht hier"),
        ]
        for (check, status, detail) in cases {
            probes.logins[.claude] = check
            #expect(row()?.status == status && row()?.detail == detail, "\(check)")
            #expect(row()?.login == .claude)
        }
        // No CLI, no login row.
        #expect(!Onboarding.checklist(probes).contains { $0.id == "codex-login" })
    }

    @Test func aLinkedBuildOtherThanTheOneKAIORXRunsIsNamed() {
        var probes = ProbeResults(gitPath: "/usr/bin/git")
        probes.clis[.claude] = BinaryIdentity(path: "/c", resolvedPath: "/v/2.1.329", sha256: "x", version: "2.1.329")
        probes.linked[.claude] = "/Users/u/.local/share/claude/versions/2.1.330"
        let item = Onboarding.checklist(probes).first { $0.id == "claude" }
        #expect(item?.detail.contains("zeigt auf einen anderen Build (2.1.330); KAIORX nutzt den abgenommenen") == true)
    }

    @Test func theCheckUsesTheConfiguredCheckOrTheGate() async throws {
        func start(_ folder: String, gate: any CapabilityGate, check: (@Sendable (ProviderKind) async -> SubscriptionVerdict?)?) async throws -> AppServices {
            var configuration = AppConfiguration(databasePath: folder + "/db.sqlite", workspaceRoot: folder + "/ws", adapters: { _ in [] }, gate: gate)
            configuration.loginCheck = check
            guard case .ready(let services) = await AppBootstrap.start(configuration) else { throw ActionError.unavailable("start") }
            return services
        }
        let custom = try await start(try temporaryFolder("login-custom"), gate: AutomationGate(channel: .personal)) { _ in .subscription(plan: "max") }
        #expect(await ProviderLogin.check(.claude, services: custom) == .verdict(.subscription(plan: "max")))
        await AppBootstrap.shutdown(custom)
        // A gate that does not ask the CLI names the reason.
        let blocked = try await start(try temporaryFolder("login-blocked"), gate: AutomationGate(channel: .personal, sources: AutomationGate.Sources(
            installed: { _ in nil }, confinement: { .effective }, subscription: { _ in .subscription(plan: "max") }
        )), check: nil)
        #expect(await ProviderLogin.check(.claude, services: blocked) == .unavailable("Nicht geprüft: Claude ist nicht installiert."))
        await AppBootstrap.shutdown(blocked)
        // A distributed build without a clearance reads nothing about the installation.
        let distributed = try await start(try temporaryFolder("login-distributed"), gate: AutomationGate(channel: .distributed), check: nil)
        #expect(await ProviderLogin.check(.claude, services: distributed) == .unavailable(ProviderLogin.unavailableText))
        await AppBootstrap.shutdown(distributed)
    }
}
