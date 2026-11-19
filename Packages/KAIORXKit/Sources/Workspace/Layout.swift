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

    /// Home-relative folders with credentials no confined process may read.
    public static let secretHomePaths = [
        ".ssh", ".aws", ".azure", ".gnupg", ".netrc", "_netrc", ".git-credentials", ".config/git/credentials",
        ".config/gh", ".config/gcloud", ".docker", ".kube", ".npmrc", ".pypirc", ".cargo/credentials",
        ".cargo/credentials.toml", ".gem/credentials", ".claude", ".codex", "Library/Keychains",
    ]
}

/// What a confined process may touch, by role. All roles: writes only to the listed roots,
/// KAIORX data (database, other worktrees, other runs) and credential folders hidden, no
/// network.
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
    /// `claudeStateFiles`) stay read-only, so the agent cannot change its own configuration. Claude's profile has no command-running tools; Codex sandboxes the
    /// commands it runs itself.
    case agentCLI(stateDirectory: String, writesWorktree: Bool, protectedStateFiles: [String] = [], needsKeychain: Bool = false)

    /// Files in `CODEX_HOME` that configure Codex itself (instructions, rules, skills).
    public static let codexStateFiles = ["config.toml", "AGENTS.md", "rules/", "skills/", "prompts/"]
    /// Files in `CLAUDE_CONFIG_DIR` that configure Claude Code itself.
    public static let claudeStateFiles = ["settings.json", "settings.local.json", "CLAUDE.md", "agents/", "skills/", "commands/", "hooks/", "plugins/"]

    public func confinement(
        worktree: String, runTemporaryDirectory: String, layout: WorkspaceLayout,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
        extraHidden: [String] = []
    ) -> Confinement {
        let writable: [String] = switch self {
        case .author: [worktree, runTemporaryDirectory]
        case .reviewer: [runTemporaryDirectory]
        case .testRunner(let writesWorktree): writesWorktree ? [worktree, runTemporaryDirectory] : [runTemporaryDirectory]
        case .agentCLI(let state, let writesWorktree, _, _): (writesWorktree ? [worktree] : []) + [runTemporaryDirectory, state]
        }
        var visible = [worktree]
        var network = false
        // The link file decides which repository host Git would use; nobody else writes it.
        var protected = [worktree + "/.git"]
        var secretPaths = WorkspaceLayout.secretHomePaths
        if case .agentCLI(let state, _, let files, let keychain) = self {
            visible.append(state)
            network = true
            protected += files.map { state + "/" + $0 }
            // Only for a CLI that keeps its login there (Claude Code).
            if keychain { secretPaths.removeAll { $0 == "Library/Keychains" } }
        }
        let secrets = secretPaths.map { home + "/" + $0 }
        return Confinement(
            writableRoots: writable, hiddenRoots: [layout.root] + secrets + extraHidden,
            visibleRoots: visible, allowsNetwork: network, protectedPaths: protected
        )
    }
}
