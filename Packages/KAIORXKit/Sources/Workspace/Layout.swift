import Foundation
import ProcessHost

/// Where KAIORX keeps its own files. Worktrees live outside the user's checkout.
public struct WorkspaceLayout: Sendable, Equatable {
    public let root: String

    public init(root: String) {
        self.root = Confinement.resolved(root)
    }

    public var worktreesRoot: String { root + "/worktrees" }
    public var runsRoot: String { root + "/runs" }
    public var gitHome: String { root + "/git-home" }

    /// `<project>/<name>`, stored as the worktree's path token.
    public func worktreePath(token: String) -> String { worktreesRoot + "/" + token }

    public func runTemporaryDirectory(_ id: String) throws -> String {
        let path = runsRoot + "/" + id
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return path
    }

    /// Checks that a path is inside the worktrees folder (after resolving symlinks).
    public func isOwnedWorktreePath(_ path: String) -> Bool {
        Confinement.resolved(path).hasPrefix(worktreesRoot + "/")
    }

    /// Home-relative folders with credentials no confined process may read. KAIORX's own support
    /// folder holds the database and the provider logins (`codex-home/auth.json`); a CLI keeps
    /// only its own state folder there (a visible root, ADR 0002 §5).
    public static let secretHomePaths = [
        ".ssh", ".aws", ".azure", ".gnupg", ".netrc", "_netrc", ".git-credentials", ".config/git/credentials",
        ".config/gh", ".config/gcloud", ".docker", ".kube", ".npmrc", ".pypirc", ".cargo/credentials",
        ".cargo/credentials.toml", ".gem/credentials", ".claude", ".codex", "Library/Keychains",
        "Library/Application Support/KAIORX",
    ]
}

/// What a confined process may touch, by role. All roles: writes only to the listed roots,
/// KAIORX data (database, other worktrees, other runs) and credential folders hidden, no
/// network, no LaunchServices and no preference writes (`Confinement.allowsSessionServices`).
/// `IsolationProbes` checks these rules on the running Mac.
public enum RoleProfile: Sendable, Equatable {
    /// Writes its own worktree.
    case author
    /// Reads a frozen worktree.
    case reviewer
    /// Runs a test profile; writes the worktree only when the profile allows it.
    case testRunner(writesWorktree: Bool)
    /// The provider CLI itself (Claude Code, Codex App Server): writes its worktree and its own
    /// state folder (login, sessions) and needs network to its provider. `needsKeychain` keeps
    /// the login keychain readable (Claude keeps its subscription login there).
    /// `protectedStateFiles` (relative to the state folder, `codexStateFiles` /
    /// `claudeStateFiles`) stay read-only, so the agent cannot change its own configuration, and
    /// so do the worktree's agent folders (`.codex`, `.agents`). Claude's profile has no
    /// command-running tools. Codex runs its commands without its own sandbox under this
    /// confinement (`externalSandbox`, ADR 0008): only this profile limits their writes.
    case agentCLI(stateDirectory: String, writesWorktree: Bool, protectedStateFiles: [String] = [], needsKeychain: Bool = false)

    /// Files in `CODEX_HOME` that configure Codex itself (instructions, rules, skills).
    /// `.env` is loaded at start (proxy, base URL); Codex never writes it.
    public static let codexStateFiles = ["config.toml", "AGENTS.md", "rules/", "skills/", "prompts/", ".env"]
    /// Worktree folders that configure an agent; never written by a provider CLI.
    public static let agentFolders = [".codex", ".agents"]
    /// Files in `CLAUDE_CONFIG_DIR` that configure Claude Code itself.
    public static let claudeStateFiles = ["settings.json", "settings.local.json", "CLAUDE.md", "agents/", "skills/", "commands/", "hooks/", "plugins/"]

    /// `hideHome` hides the whole home folder except `homeExceptions` (read-only) and the roots
    /// the role writes or sees; without it only the credential folders are hidden. `nil` is the
    /// role's default: `agentCLI` hides home (ADR 0008, point 6: both CLIs ran that way in the
    /// owner's live run), the other roles do not. For `agentCLI`, `executable` (the native CLI
    /// binary) adds its install folder below home to the exceptions (`homeExceptions(executable:home:)`).
    public func confinement(
        worktree: String, runTemporaryDirectory: String, layout: WorkspaceLayout,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
        extraHidden: [String] = [], hideHome: Bool? = nil, homeExceptions: [String] = [], executable: String? = nil
    ) -> Confinement {
        let writable: [String] = switch self {
        case .author: [worktree, runTemporaryDirectory]
        case .reviewer: [runTemporaryDirectory]
        case .testRunner(let writesWorktree): writesWorktree ? [worktree, runTemporaryDirectory] : [runTemporaryDirectory]
        case .agentCLI(let state, let writesWorktree, _, _): (writesWorktree ? [worktree] : []) + [runTemporaryDirectory, state]
        }
        var visible = [worktree]
        var network = false
        // The link file decides which repository host Git would use; nobody else writes it. In a
        // plain checkout `.git` is the repository itself: the whole folder stays read-only.
        var protected = [worktree + "/.git"]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: worktree + "/.git", isDirectory: &isDirectory), isDirectory.boolValue { protected.append(worktree + "/.git/") }
        var secretPaths = WorkspaceLayout.secretHomePaths
        if case .agentCLI(let state, _, let files, let keychain) = self {
            visible.append(state)
            network = true
            protected += files.map { state + "/" + $0 }
            // The folder itself (no replacing it with a link) and everything below it.
            protected += Self.agentFolders.flatMap { [worktree + "/" + $0, worktree + "/" + $0 + "/"] }
            // Only for a CLI that keeps its login there (Claude Code).
            if keychain { secretPaths.removeAll { $0 == "Library/Keychains" } }
        }
        var secrets = secretPaths.map { home + "/" + $0 }
        var hidesHome = false
        if case .agentCLI = self { hidesHome = true }
        if hideHome ?? hidesHome {
            secrets.append(home)
            visible += homeExceptions
            if case .agentCLI = self, let executable { visible += Self.homeExceptions(executable: executable, home: home) }
            // Keychains stay readable for a CLI that keeps its login there.
            if case .agentCLI(_, _, _, true) = self { visible.append(home + "/Library/Keychains") }
        }
        return Confinement(
            writableRoots: writable, hiddenRoots: [layout.root] + secrets + extraHidden,
            visibleRoots: visible, allowsNetwork: network, protectedPaths: protected
        )
    }
    /// Folders below home a CLI needs to read when home is hidden: its own install folder
    /// (`~/.local/share/claude/versions/<v>` → `~/.local/share/claude`; with nvm the node version
    /// folder; otherwise the binary's folder). Empty when the binary is not below home. A folder
    /// that is home itself, holds a credential folder or lies inside one is never opened; then
    /// only the binary itself stays readable. `home` may end with `/` (a directory URL's path).
    public static func homeExceptions(executable: String, home: String) -> [String] {
        let resolved = Confinement.resolved(executable)
        let home = Confinement.resolved(home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home)
        guard resolved.hasPrefix(home + "/") else { return [] }
        let secrets = WorkspaceLayout.secretHomePaths.map { home + "/" + $0 }
        func opens(_ folder: String) -> Bool {
            folder.hasPrefix(home + "/") && !secrets.contains { $0 == folder || $0.hasPrefix(folder + "/") || folder.hasPrefix($0 + "/") }
        }
        var candidate = Confinement.resolved(URL(filePath: resolved).deletingLastPathComponent().path(percentEncoded: false))
        var url = URL(filePath: resolved).deletingLastPathComponent()
        while url.path(percentEncoded: false).count > home.count + 1 {
            let name = url.lastPathComponent
            if name == "claude" || name.hasPrefix("v") && url.deletingLastPathComponent().lastPathComponent == "node" {
                candidate = Confinement.resolved(url.path(percentEncoded: false))
                break
            }
            url.deleteLastPathComponent()
        }
        return [opens(candidate) ? candidate : resolved]
    }

    /// A provider CLI KAIORX runs (ADR 0003 role `agentCLI`).
    public enum AgentCLI: Sendable {
        case claude, codex
    }

    /// The product confinement of a provider CLI: the app's adapters and the owner's acceptance
    /// kit both build it here, so the kit measures exactly what the product runs. Home hidden
    /// except the CLI's install folder (ADR 0008, point 6); the state folder writable; the
    /// worktree writable only for an author. `nil` without a worktree: the adapter then refuses
    /// to start (fail closed).
    public static func agentCLIConfinement(
        _ cli: AgentCLI, writesWorktree: Bool, worktree: String?, runTemporaryDirectory: String, stateDirectory: String,
        layout: WorkspaceLayout, home: String, executable: String, extraHidden: [String] = []
    ) -> Confinement? {
        guard let worktree else { return nil }
        let profile = RoleProfile.agentCLI(
            stateDirectory: stateDirectory, writesWorktree: writesWorktree,
            protectedStateFiles: cli == .claude ? claudeStateFiles : codexStateFiles, needsKeychain: cli == .claude
        )
        return profile.confinement(
            worktree: worktree, runTemporaryDirectory: runTemporaryDirectory, layout: layout, home: home, extraHidden: extraHidden,
            executable: executable
        )
    }
}
