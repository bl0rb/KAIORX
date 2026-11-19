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

    public func confinement(
        worktree: String, runTemporaryDirectory: String, layout: WorkspaceLayout,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
        extraHidden: [String] = []
    ) -> Confinement {
        let writable: [String] = switch self {
        case .author: [worktree, runTemporaryDirectory]
        case .reviewer: [runTemporaryDirectory]
        case .testRunner(let writesWorktree): writesWorktree ? [worktree, runTemporaryDirectory] : [runTemporaryDirectory]
        }
        let secrets = WorkspaceLayout.secretHomePaths.map { home + "/" + $0 }
        return Confinement(
            writableRoots: writable, hiddenRoots: [layout.root] + secrets + extraHidden,
            visibleRoots: [worktree], allowsNetwork: false,
            // The link file decides which repository host Git would use; nobody else writes it.
            protectedPaths: [worktree + "/.git"]
        )
    }
}
