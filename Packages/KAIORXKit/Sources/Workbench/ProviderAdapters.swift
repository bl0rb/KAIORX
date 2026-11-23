import Domain
import Foundation
import ProcessHost
import Providers
import Workspace

/// The real adapters for the installed CLIs, each confined like the owner's live acceptance
/// measured it (ADR 0002, ADR 0008 point 6). Their policy requires the confinement, so a run
/// without one is refused; automatic runs stay locked by the compatibility gate (ADR 0003).
public enum ProviderAdapters {
    /// `locate` gives the native CLI binary (`Onboarding.locate`); a CLI without one gets no adapter.
    public static func make(
        host: ProcessHost, support: String, home: String = NSHomeDirectory(), locate: (ProviderKind) -> String?
    ) -> [any AgentAdapter] {
        let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        let layout = WorkspaceLayout(root: AppConfiguration.workspaceRoot(support: support))
        let temporary = support + "/tmp"
        var adapters: [any AgentAdapter] = []
        if let claude = locate(.claude) {
            let state = support + "/claude-config"
            adapters.append(ClaudeCodeAdapter(configuration: ClaudeCodeConfiguration(
                executable: claude, configDirectory: state, temporaryRoot: temporary, home: home,
                confinement: confinement(.claude, executable: claude, state: state, layout: layout, home: home)
            ), host: host))
        }
        if let codex = locate(.codex) {
            let state = support + "/codex-home"
            adapters.append(CodexAppServerAdapter(configuration: CodexConfiguration(
                executable: codex, codexHome: state, temporaryRoot: temporary, home: home,
                confinement: confinement(.codex, executable: codex, state: state, layout: layout, home: home)
            ), host: host))
        }
        return adapters
    }

    static func confinement(
        _ cli: RoleProfile.AgentCLI, executable: String, state: String, layout: WorkspaceLayout, home: String
    ) -> @Sendable (AttemptSpec, String) -> Confinement? {
        { spec, temporary in
            RoleProfile.agentCLIConfinement(
                cli, writesWorktree: spec.role == .author, worktree: spec.workingDirectory, runTemporaryDirectory: temporary,
                stateDirectory: state, layout: layout, home: home, executable: executable
            )
        }
    }
}
