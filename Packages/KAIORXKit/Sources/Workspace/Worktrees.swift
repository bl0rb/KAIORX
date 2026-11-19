import Darwin
import Foundation
import ProcessHost

public enum WorkspaceError: Error, Equatable, Sendable {
    case blocked(Set<WorkspaceBlocker>)
    case outsideWorktreeRoot(String)
    case notRegistered(String)
    /// The worktree's lock reason does not name this owner.
    case notOwned(path: String, lockReason: String?)
    case unsavedChanges(String)
    case unexpectedHead(expected: String, actual: String)
    case refConflict(ref: String, expected: String?, actual: String?)
    case invalidRelativePath(String)
    /// Git does not know the folder; without `force` it is kept, since its content cannot be
    /// compared with the sealed result.
    case unregisteredFolder(String)
}

/// One changed path in a worktree, from `git status --porcelain=v2 -z`.
public struct ChangeEntry: Sendable, Equatable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case modified, added, deleted, typeChanged, untracked, unmerged }

    public var path: String
    public var kind: Kind
    /// Octal mode in the worktree (`0` when deleted); symlinks are `0o120000`, gitlinks and
    /// untracked nested repositories `0o160000`.
    public var worktreeMode: Int
    public var isSymlink: Bool { worktreeMode == 0o120000 }
    public var isGitlink: Bool { worktreeMode == 0o160000 }
}

public enum RejectionReason: String, Sendable, Equatable, Codable {
    case outsideAllowedPaths, symlink, gitMetadata, submodule, unmerged
}

public struct SealOutcome: Sendable, Equatable {
    public var accepted: [ChangeEntry]
    public var rejected: [ChangeEntry: RejectionReason]
    /// Tree of the base plus accepted changes.
    public var tree: String
    /// `nil` when the accepted changes are empty (the result equals the base).
    public var commit: String?
    /// Accepted paths whose content Git treats as binary.
    public var binaryPaths: Set<String>
}

public struct RegisteredWorktree: Sendable, Equatable {
    public var path: String
    public var head: String?
    public var lockReason: String?
    public var isLocked: Bool
    public var isPrunable: Bool
}

/// A linked worktree and its administrative folder inside the shared Git directory. Host Git
/// always runs with this explicit `GIT_DIR`: the worktree's `.git` link file is never trusted,
/// because whoever writes the worktree could point it at a repository with its own config.
public struct WorktreeLocation: Sendable, Equatable {
    public let path: String
    public let gitDirectory: String
}

extension GitRunner {
    // MARK: Worktrees

    /// Adds a detached worktree at `base`, locked with `lockReason` (the ownership marker).
    /// Files are checked out only after the config was checked in the worktree's own context
    /// (`includeIf "gitdir:"` may add filters there that the main checkout does not see).
    @discardableResult
    public func addWorktree(at path: String, base: String, lockReason: String, in repository: RepositoryInfo) async throws -> WorktreeLocation {
        let parent = URL(filePath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try await run(
            ["worktree", "add", "--no-checkout", "--detach", "--lock", "--reason", lockReason, "--", path, base],
            in: repository.topLevel
        )
        let location = try locate(worktree: path, in: repository)
        let blockers = try await configBlockers { arguments in
            try await self.run(arguments, at: location, allowedExitCodes: [0, 1])
        }
        guard blockers.isEmpty else {
            try await run(["worktree", "remove", "-f", "-f", "--", location.path], in: repository.topLevel)
            throw WorkspaceError.blocked(blockers)
        }
        try await run(["reset", "-q", "--hard", base], at: location)
        let head = try await output(["rev-parse", "HEAD"], at: location)
        guard head == base else { throw WorkspaceError.unexpectedHead(expected: base, actual: head) }
        return location
    }

    /// Finds the worktree's administrative folder through the shared Git directory (whose
    /// `worktrees/*/gitdir` files only Git and the host write), not through the worktree.
    public func locate(worktree path: String, in repository: RepositoryInfo) throws -> WorktreeLocation {
        let resolved = Confinement.resolved(path)
        let admin = URL(filePath: repository.commonDirectory).appending(path: "worktrees", directoryHint: .isDirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: admin.path(percentEncoded: false))) ?? []
        for name in entries {
            let folder = admin.appending(path: name, directoryHint: .isDirectory)
            guard let pointer = try? String(contentsOf: folder.appending(path: "gitdir"), encoding: .utf8) else { continue }
            // `worktree.useRelativePaths` stores the pointer relative to the admin folder.
            let text = pointer.trimmingCharacters(in: .newlines)
            let target = text.hasPrefix("/") ? URL(filePath: text) : URL(filePath: text, relativeTo: folder).absoluteURL
            if target.lastPathComponent == ".git",
               Confinement.resolved(target.deletingLastPathComponent().path(percentEncoded: false)) == resolved {
                return WorktreeLocation(path: resolved, gitDirectory: Confinement.resolved(folder.path(percentEncoded: false)))
            }
        }
        throw WorkspaceError.notRegistered(path)
    }

    public func registeredWorktrees(in repository: RepositoryInfo) async throws -> [RegisteredWorktree] {
        let fields = nulFields(try await run(["worktree", "list", "--porcelain", "-z"], in: repository.topLevel).stdout.data)
        var result: [RegisteredWorktree] = []
        var current: RegisteredWorktree?
        for field in fields {
            if field.isEmpty {
                if let current { result.append(current) }
                current = nil
                continue
            }
            if field.hasPrefix("worktree ") {
                if let current { result.append(current) }
                current = RegisteredWorktree(path: Confinement.resolved(String(field.dropFirst(9))), head: nil, lockReason: nil, isLocked: false, isPrunable: false)
            } else if field.hasPrefix("HEAD ") {
                current?.head = String(field.dropFirst(5))
            } else if field == "locked" || field.hasPrefix("locked ") {
                current?.isLocked = true
                current?.lockReason = field == "locked" ? nil : String(field.dropFirst(7))
            } else if field.hasPrefix("prunable") {
                current?.isPrunable = true
            }
        }
        if let current { result.append(current) }
        return result
    }

    /// Removes a worktree this host owns. Without `force` it refuses when the worktree holds
    /// changes beyond `savedTree` (the sealed result's tree, or the base tree if nothing was
    /// sealed), so no work is lost. The worktree stays locked until Git removes it, so an
    /// interrupted removal never leaves an unlocked, unowned-looking worktree behind.
    /// `acceptUnlocked` lets recovery finish a removal an older version left unlocked.
    public func removeWorktree(
        at path: String, lockReason: String, savedTree: String?, force: Bool, acceptUnlocked: Bool = false,
        in repository: RepositoryInfo
    ) async throws {
        let resolved = Confinement.resolved(path)
        let entry = try await registeredWorktrees(in: repository).first { $0.path == resolved }
        guard let entry else {
            // Unregistered: a leftover folder whose content Git can no longer compare.
            guard FileManager.default.fileExists(atPath: resolved) else { throw WorkspaceError.notRegistered(path) }
            guard force else { throw WorkspaceError.unregisteredFolder(path) }
            try Self.setWritable(resolved, writable: true)
            try FileManager.default.removeItem(atPath: resolved)
            return
        }
        guard entry.lockReason == lockReason || (acceptUnlocked && !entry.isLocked) else {
            throw WorkspaceError.notOwned(path: path, lockReason: entry.lockReason)
        }
        let exists = FileManager.default.fileExists(atPath: resolved)
        if exists, !force {
            let location = try locate(worktree: resolved, in: repository)
            let base = try await output(["rev-parse", "HEAD^{tree}"], at: location)
            let current = try await snapshotTree(of: location, base: "HEAD", paths: nil)
            guard current == (savedTree ?? base) else { throw WorkspaceError.unsavedChanges(path) }
        }
        if exists {
            try Self.setWritable(resolved, writable: true)
            // `-f -f` removes a locked worktree in one step.
            try await run(["worktree", "remove", "-f", "-f", "--", resolved], in: repository.topLevel)
        } else {
            if entry.isLocked { try await run(["worktree", "unlock", "--", resolved], in: repository.topLevel) }
            try await run(["worktree", "prune", "--expire", "now"], in: repository.topLevel)
        }
    }

    // MARK: Inventory and sealing

    public func inventory(of worktree: WorktreeLocation) async throws -> [ChangeEntry] {
        let data = try await run(
            ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignored=no", "--no-renames"], at: worktree
        ).stdout.data
        var entries: [ChangeEntry] = []
        for field in nulFields(data) where !field.isEmpty {
            switch field.first {
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let parts = field.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { throw GitError.unexpectedOutput(field) }
                let xy = Array(parts[1])
                let worktreeMode = Int(parts[5], radix: 8) ?? 0
                let headMode = Int(parts[3], radix: 8) ?? 0
                let code = xy.count == 2 ? (xy[1] != "." ? xy[1] : xy[0]) : "M"
                let kind: ChangeEntry.Kind = switch code {
                case "D": .deleted
                case "A": .added
                case "T": .typeChanged
                default: headMode != worktreeMode && worktreeMode != 0 ? .typeChanged : .modified
                }
                entries.append(ChangeEntry(path: String(parts[8]), kind: kind, worktreeMode: worktreeMode))
            case "u":
                let parts = field.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { throw GitError.unexpectedOutput(field) }
                entries.append(ChangeEntry(path: String(parts[10]), kind: .unmerged, worktreeMode: Int(parts[6], radix: 8) ?? 0))
            case "?":
                var path = String(field.dropFirst(2))
                if path.hasSuffix("/") {
                    // With --untracked-files=all only a nested repository is listed as a folder.
                    path.removeLast()
                    entries.append(ChangeEntry(path: path, kind: .untracked, worktreeMode: 0o160000))
                    continue
                }
                var info = stat()
                let isLink = lstat(worktree.path + "/" + path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
                entries.append(ChangeEntry(path: path, kind: .untracked, worktreeMode: isLink ? 0o120000 : 0o100644))
            default:
                // "2" (renames) cannot occur with --no-renames; "!" is excluded.
                throw GitError.unexpectedOutput(field)
            }
        }
        return entries
    }

    /// Commits the accepted changes of an attempt on top of `base` without touching the
    /// worktree, its index or any branch. Paths outside `allowedPrefixes` (nil: whole project),
    /// symlinks, Git metadata, submodules and conflicts are rejected and reported.
    public func buildResult(
        of worktree: WorktreeLocation, base: String, allowedPrefixes: [String]?, message: String
    ) async throws -> SealOutcome {
        let changes = try await inventory(of: worktree)
        var accepted: [ChangeEntry] = []
        var rejected: [ChangeEntry: RejectionReason] = [:]
        for change in changes {
            if let reason = Self.rejection(for: change, allowedPrefixes: allowedPrefixes) {
                rejected[change] = reason
            } else {
                accepted.append(change)
            }
        }
        // A folder replaced by a symlink: its former contents cannot be staged through the link.
        let links = rejected.filter { $0.value == .symlink || $0.value == .submodule }.map(\.key.path)
        accepted.removeAll { change in
            guard let link = links.first(where: { change.path.hasPrefix($0 + "/") }) else { return false }
            rejected[change] = rejected.first { $0.key.path == link }?.value ?? .symlink
            return true
        }
        var tree = try await snapshotTree(of: worktree, base: base, paths: accepted.map(\.path))
        // Defence in depth: whatever Git staged as a link or gitlink is rejected after all.
        let unexpected = try await linkEntries(from: base, to: tree, at: worktree)
        if !unexpected.isEmpty {
            for (path, mode) in unexpected {
                guard let index = accepted.firstIndex(where: { $0.path == path || path.hasPrefix($0.path + "/") }) else { continue }
                let entry = accepted.remove(at: index)
                rejected[entry] = mode == 0o160000 ? .submodule : .symlink
            }
            tree = try await snapshotTree(of: worktree, base: base, paths: accepted.map(\.path))
            guard try await linkEntries(from: base, to: tree, at: worktree).isEmpty else {
                throw GitError.unexpectedOutput("link entries remain in the result tree")
            }
        }
        let baseTree = try await output(["rev-parse", "\(base)^{tree}"], at: worktree)
        guard tree != baseTree else {
            return SealOutcome(accepted: accepted, rejected: rejected, tree: tree, commit: nil, binaryPaths: [])
        }
        let commit = try await run(
            ["commit-tree", tree, "-p", base, "-F", "-"], at: worktree, input: Data(message.utf8),
            environment: [
                "GIT_AUTHOR_NAME": "KAIORX", "GIT_AUTHOR_EMAIL": "kaiorx@localhost",
                "GIT_COMMITTER_NAME": "KAIORX", "GIT_COMMITTER_EMAIL": "kaiorx@localhost",
            ]
        ).stdout.text.trimmingCharacters(in: .newlines)
        let numstat = nulFields(try await run(
            ["diff", "--numstat", "-z", "--no-renames", "--no-ext-diff", "--no-textconv", base, commit], at: worktree
        ).stdout.data)
        let binary = Set(numstat.compactMap { field -> String? in
            field.hasPrefix("-\t-\t") ? String(field.dropFirst(4)) : nil
        })
        return SealOutcome(accepted: accepted, rejected: rejected, tree: tree, commit: commit, binaryPaths: binary)
    }

    /// Paths that are symlinks or gitlinks in `tree` but not identical in `base`.
    func linkEntries(from base: String, to tree: String, at worktree: WorktreeLocation) async throws -> [String: Int] {
        let fields = nulFields(try await run(["diff-tree", "-r", "-z", "--no-renames", base, tree], at: worktree).stdout.data)
        var result: [String: Int] = [:]
        var index = 0
        while index + 1 < fields.count {
            // ":<old mode> <new mode> <old oid> <new oid> <status>" then the path.
            let meta = fields[index].split(separator: " ")
            let path = fields[index + 1]
            index += 2
            guard meta.count >= 2, let mode = Int(meta[1], radix: 8) else { continue }
            if mode == 0o120000 || mode == 0o160000 { result[path] = mode }
        }
        return result
    }

    /// Code points HFS+ ignores in names; Git's `core.protectHFS` treats `.git` spelled with them
    /// as `.git`.
    static let hfsIgnorable: Set<UInt32> = Set(Array(0x200C...0x200F) + Array(0x202A...0x202E) + Array(0x206A...0x206F) + [0xFEFF])

    static func isGitMetadataComponent(_ component: Substring) -> Bool {
        let scalars = component.unicodeScalars.filter { !hfsIgnorable.contains($0.value) }
        let name = String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping.lowercased()
        // Trailing dots and spaces are dropped by NTFS; `git~1` is its short name for `.git`.
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        // NTFS: `git~1` is the short name of `.git`; `.git:stream` and `.git::$INDEX_ALLOCATION`
        // name it too (Git's core.protectNTFS refuses all of them).
        let shortName = name.range(of: #"^git~[0-9]+(:.*)?$"#, options: .regularExpression) != nil
        return name == ".git" || (trimmed == "git" && name.hasPrefix(".")) || name.hasPrefix(".git:") || shortName
            || name == ".gitmodules"
    }

    static func rejection(for change: ChangeEntry, allowedPrefixes: [String]?) -> RejectionReason? {
        let components = change.path.split(separator: "/")
        if components.contains(where: isGitMetadataComponent) { return .gitMetadata }
        if change.kind == .unmerged { return .unmerged }
        if change.isGitlink { return .submodule }
        if change.isSymlink { return .symlink }
        if let allowedPrefixes, !allowedPrefixes.contains(where: { prefix in
            prefix.isEmpty || change.path == prefix || change.path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
        }) {
            return .outsideAllowedPaths
        }
        return nil
    }

    /// Tree of `base` plus the worktree state of `paths` (nil: every change), built in a
    /// temporary index so the worktree's own index stays untouched.
    func snapshotTree(of worktree: WorktreeLocation, base: String, paths: [String]?) async throws -> String {
        let index = URL(filePath: home).appending(path: "index-\(UUID().uuidString)").path(percentEncoded: false)
        defer { try? FileManager.default.removeItem(atPath: index) }
        let env = ["GIT_INDEX_FILE": index, "GIT_LITERAL_PATHSPECS": "1"]
        try await run(["read-tree", base], at: worktree, environment: env)
        if let paths {
            if !paths.isEmpty {
                let list = Data(paths.joined(separator: "\0").utf8) + Data([0])
                try await run(["add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul"], at: worktree, input: list, environment: env)
            }
        } else {
            try await run(["add", "-A", "--", "."], at: worktree, environment: env)
        }
        return try await run(["write-tree"], at: worktree, environment: env).stdout.text.trimmingCharacters(in: .newlines)
    }

    // MARK: Refs

    /// Tree ID of a commit.
    public func tree(of commit: String, in repository: RepositoryInfo) async throws -> String {
        try await output(["rev-parse", "--verify", "--end-of-options", "\(commit)^{tree}"], in: repository.topLevel)
    }

    public func readRef(_ name: String, in repository: RepositoryInfo) async throws -> String? {
        let result = try await run(["rev-parse", "-q", "--verify", "--end-of-options", name], in: repository.topLevel, allowedExitCodes: [0, 1])
        guard result.termination == .exited(0) else { return nil }
        return result.stdout.text.trimmingCharacters(in: .newlines)
    }

    /// Sets `name` to `new` only if it currently points to `expectedOld` (`nil`: must not exist).
    public func updateRef(_ name: String, to new: String, expectedOld: String?, in repository: RepositoryInfo) async throws {
        guard name.hasPrefix("refs/") else { throw GitError.unexpectedOutput("invalid ref \(name)") }
        let result = try await run(
            ["update-ref", "-m", "kaiorx", "--", name, new, expectedOld ?? repository.zeroOID],
            in: repository.topLevel, allowedExitCodes: [0, 1, 128]
        )
        guard result.termination == .exited(0) else {
            let actual = try await readRef(name, in: repository)
            throw WorkspaceError.refConflict(ref: name, expected: expectedOld, actual: actual)
        }
    }

    /// HEAD at `commit` and nothing changed or missing.
    public func isClean(_ worktree: WorktreeLocation, at commit: String) async throws -> Bool {
        let head = try await output(["rev-parse", "HEAD"], at: worktree)
        guard head == commit else { return false }
        return try await inventory(of: worktree).isEmpty
    }

    // MARK: Running inside a worktree

    @discardableResult
    func run(
        _ arguments: [String], at worktree: WorktreeLocation, input: Data? = nil, environment extra: [String: String] = [:],
        allowedExitCodes: Set<Int32> = [0]
    ) async throws -> ProcessResult {
        try await run(
            arguments, in: worktree.path, input: input,
            environment: extra.merging(["GIT_DIR": worktree.gitDirectory, "GIT_WORK_TREE": worktree.path]) { _, new in new },
            allowedExitCodes: allowedExitCodes
        )
    }

    func output(_ arguments: [String], at worktree: WorktreeLocation) async throws -> String {
        let text = try await run(arguments, at: worktree).stdout.text
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    // MARK: Freezing

    /// Removes write permission on every file and folder in a worktree (except Git's `.git` link
    /// file), or restores the owner's access. Symlinks are left alone. Restoring gives folders
    /// `rwx` back first, so folders an agent made inaccessible can be entered and removed.
    public static func setWritable(_ root: String, writable: Bool) throws {
        func apply(_ path: String, isDirectory: Bool) {
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return }
            let mode = info.st_mode & 0o7777
            let restored = mode | (isDirectory ? 0o700 : 0o200)
            chmod(path, writable ? restored : mode & ~0o222)
        }
        func isDirectory(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        }
        if writable {
            // Depth-first with folders opened before they are listed.
            var pending = [root]
            while let folder = pending.popLast() {
                apply(folder, isDirectory: true)
                for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                    if folder == root && name == ".git" { continue }
                    let path = folder + "/" + name
                    if isDirectory(path) { pending.append(path) } else { apply(path, isDirectory: false) }
                }
            }
            return
        }
        var folders: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: root)
        while let relative = enumerator?.nextObject() as? String {
            if relative == ".git" { continue }
            let path = root + "/" + relative
            if isDirectory(path) { folders.append(path) } else { apply(path, isDirectory: false) }
        }
        for folder in folders.reversed() { apply(folder, isDirectory: true) }
        apply(root, isDirectory: true)
    }
}
