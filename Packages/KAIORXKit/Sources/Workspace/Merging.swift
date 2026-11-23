import Darwin
import Foundation
import ProcessHost

/// A path Git could not merge, read from the index stages.
public struct ConflictEntry: Sendable, Equatable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case bothModified, bothAdded, deletedByUs, deletedByThem, addedByUs, addedByThem
    }

    public var path: String
    public var kind: Kind
}

public enum MergeOutcome: Sendable, Equatable {
    /// A merge commit with first parent `P` (target) and second parent `R` (result).
    case merged(commit: String)
    /// `R` is already contained in `P`: nothing to integrate.
    case alreadyContained
    case conflicted([ConflictEntry])
}

/// The user's decision for one conflicting path.
public enum ConflictResolution: Sendable, Equatable {
    /// The integration target's version (first parent).
    case ours
    /// The incoming result's (or, for a revert, the reverted state's) version.
    case theirs
    case content(Data)
    case delete
}

public struct ChangedPath: Sendable, Equatable, Hashable {
    /// `A`dded, `M`odified, `D`eleted, `T`ype changed.
    public var status: Character
    public var path: String
}

public enum MergeError: Error, Equatable, Sendable {
    case unresolved([String])
    case resolutionForUnknownPath(String)
    case noMergeInProgress
    case invalidBranchName(String)
    case noFreeBranchName(String)
    /// A folder of the name matches an existing ref folder only case- or normalisation-insensitively
    /// (`feature/y` next to `Feature/x`): on APFS Git would file it as `Feature/y`.
    case branchFolderCaseConflict(String, existing: String)
    /// Git reported conflicts at paths that exist on neither side (file/directory, distinct
    /// types, directory renames: `x~HEAD` and the like). They are not offered for resolution;
    /// the merge is aborted.
    case unsupportedConflict([String])
    /// The resolution leaves nothing to commit (for example a revert resolved to the current state).
    case nothingToCommit
}

extension GitRunner {
    static let mergeEnvironment = [
        "GIT_AUTHOR_NAME": "KAIORX", "GIT_AUTHOR_EMAIL": "kaiorx@localhost",
        "GIT_COMMITTER_NAME": "KAIORX", "GIT_COMMITTER_EMAIL": "kaiorx@localhost",
        "GIT_EDITOR": "true", "GIT_MERGE_AUTOEDIT": "no",
    ]
    static let mergeOverrides = ["-c", "rerere.enabled=false", "-c", "merge.verifySignatures=false", "-c", "merge.ff=false"]

    /// Merges `result` into the worktree's HEAD (the integration target) with a forced merge
    /// commit. Hooks, rerere and editors are off; filters and custom drivers were refused before
    /// the worktree was created.
    public func merge(_ result: String, at worktree: WorktreeLocation, message: String) async throws -> MergeOutcome {
        let contained = try await run(["merge-base", "--is-ancestor", result, "HEAD"], at: worktree, allowedExitCodes: [0, 1])
        if contained.termination == .exited(0) { return .alreadyContained }
        let merge = try await run(
            Self.mergeOverrides + ["merge", "--no-ff", "--no-edit", "-m", message, "--end-of-options", result],
            at: worktree, environment: Self.mergeEnvironment, allowedExitCodes: [0, 1]
        )
        if merge.termination == .exited(0) {
            return .merged(commit: try await output(["rev-parse", "HEAD"], at: worktree))
        }
        let conflicts = try await conflicts(at: worktree)
        guard !conflicts.isEmpty else {
            throw GitError.failed(arguments: ["merge"], termination: merge.termination, stderr: merge.stderr.text)
        }
        try await refuseInventedPaths(conflicts, sides: ["HEAD", "MERGE_HEAD"], at: worktree, abort: ["merge", "--abort"])
        return .conflicted(conflicts)
    }

    /// Aborts when a conflict path exists in none of the given commits.
    private func refuseInventedPaths(_ conflicts: [ConflictEntry], sides: [String], at worktree: WorktreeLocation, abort: [String]) async throws {
        var invented: [String] = []
        for conflict in conflicts {
            var known = false
            for side in sides {
                let probe = try await run(["cat-file", "-e", "\(side):\(conflict.path)"], at: worktree, allowedExitCodes: [0, 1, 128])
                if probe.termination == .exited(0) { known = true; break }
            }
            if !known { invented.append(conflict.path) }
        }
        guard invented.isEmpty else {
            _ = try? await run(abort, at: worktree, environment: Self.mergeEnvironment, allowedExitCodes: [0, 1, 128])
            throw MergeError.unsupportedConflict(invented)
        }
    }

    /// Reverts a merge commit relative to its first parent on top of the worktree's HEAD.
    public func revertMerge(_ merge: String, at worktree: WorktreeLocation) async throws -> MergeOutcome {
        let revert = try await run(
            Self.mergeOverrides + ["revert", "-m", "1", "--no-edit", "--end-of-options", merge],
            at: worktree, environment: Self.mergeEnvironment, allowedExitCodes: [0, 1]
        )
        if revert.termination == .exited(0) {
            return .merged(commit: try await output(["rev-parse", "HEAD"], at: worktree))
        }
        let conflicts = try await conflicts(at: worktree)
        guard !conflicts.isEmpty else {
            // Nothing left to undo: the reverted change is already gone from the target.
            let staged = try await run(["diff", "--cached", "--quiet", "HEAD"], at: worktree, allowedExitCodes: [0, 1])
            if staged.termination == .exited(0) {
                _ = try? await run(["revert", "--abort"], at: worktree, environment: Self.mergeEnvironment, allowedExitCodes: [0, 1, 128])
                return .alreadyContained
            }
            throw GitError.failed(arguments: ["revert"], termination: revert.termination, stderr: revert.stderr.text)
        }
        // "theirs" of a revert is the state before the merge, its first parent.
        try await refuseInventedPaths(conflicts, sides: ["HEAD", "\(merge)^1", merge], at: worktree, abort: ["revert", "--abort"])
        return .conflicted(conflicts)
    }

    /// Unmerged paths from the index stages (1 base, 2 ours, 3 theirs), NUL-safe.
    public func conflicts(at worktree: WorktreeLocation) async throws -> [ConflictEntry] {
        let fields = nulFields(try await run(["ls-files", "-u", "-z"], at: worktree).stdout.data)
        var stages: [String: Set<Int>] = [:]
        var order: [String] = []
        for field in fields where !field.isEmpty {
            // "<mode> <oid> <stage>\t<path>"
            guard let tab = field.firstIndex(of: "\t") else { throw GitError.unexpectedOutput(field) }
            let meta = field[..<tab].split(separator: " ")
            let path = String(field[field.index(after: tab)...])
            guard meta.count == 3, let stage = Int(meta[2]) else { throw GitError.unexpectedOutput(field) }
            if stages[path] == nil { order.append(path) }
            stages[path, default: []].insert(stage)
        }
        return order.map { path in
            let present = stages[path] ?? []
            let kind: ConflictEntry.Kind = switch (present.contains(1), present.contains(2), present.contains(3)) {
            case (false, true, true): .bothAdded
            case (true, false, true): .deletedByUs
            case (true, true, false): .deletedByThem
            case (false, false, true): .addedByThem
            case (false, true, false): .addedByUs
            default: .bothModified
            }
            return ConflictEntry(path: path, kind: kind)
        }
    }

    /// Applies the user's decisions and finishes the merge or revert with a commit. Every
    /// conflicting path needs a decision; paths that were not in conflict cannot be touched.
    public func resolve(_ resolutions: [String: ConflictResolution], at worktree: WorktreeLocation) async throws -> String {
        let open = Set(try await conflicts(at: worktree).map(\.path))
        if let unknown = resolutions.keys.first(where: { !open.contains($0) }) { throw MergeError.resolutionForUnknownPath(unknown) }
        let missing = open.subtracting(resolutions.keys)
        guard missing.isEmpty else { throw MergeError.unresolved(missing.sorted()) }
        let literal = ["GIT_LITERAL_PATHSPECS": "1"]
        // Every write goes through Git's index (never a filesystem path that could be a symlink),
        // then `checkout-index` replaces the worktree entry without following links.
        for (path, resolution) in resolutions.sorted(by: { $0.key < $1.key }) {
            let stages = try await run(["ls-files", "-u", "-z", "--", path], at: worktree, environment: literal).stdout.text
            switch resolution {
            case .ours, .theirs:
                let stage = resolution == .ours ? "2" : "3"
                let entry = nulFields(Data(stages.utf8)).first { $0.split(separator: "\t").first?.hasSuffix(" \(stage)") == true }
                if let entry, let meta = entry.split(separator: "\t").first?.split(separator: " "), meta.count == 3 {
                    // A side's version: its mode and blob, as recorded in the index.
                    try await stageEntry(mode: String(meta[0]), blob: String(meta[1]), path: path, at: worktree)
                } else {
                    try await removeEntry(path, at: worktree)
                }
            case .content(let data):
                let blob = try await run(["hash-object", "-w", "--stdin"], at: worktree, input: data).stdout.text
                    .trimmingCharacters(in: .newlines)
                try await stageEntry(mode: "100644", blob: blob, path: path, at: worktree)
            case .delete:
                try await removeEntry(path, at: worktree)
            }
        }
        guard try await conflicts(at: worktree).isEmpty else { throw MergeError.unresolved(open.sorted()) }
        let gitDir = URL(filePath: worktree.gitDirectory)
        if FileManager.default.fileExists(atPath: gitDir.appending(path: "MERGE_HEAD").path(percentEncoded: false)) {
            try await run(["commit", "--no-edit", "--no-verify"], at: worktree, environment: Self.mergeEnvironment)
        } else if FileManager.default.fileExists(atPath: gitDir.appending(path: "REVERT_HEAD").path(percentEncoded: false)) {
            // A revert resolved back to the current state has nothing to commit.
            let staged = try await run(["diff", "--cached", "--quiet", "HEAD"], at: worktree, allowedExitCodes: [0, 1])
            if staged.termination == .exited(0) {
                _ = try? await run(["revert", "--abort"], at: worktree, environment: Self.mergeEnvironment, allowedExitCodes: [0, 1, 128])
                throw MergeError.nothingToCommit
            }
            try await run(Self.mergeOverrides + ["revert", "--continue"], at: worktree, environment: Self.mergeEnvironment)
        } else {
            throw MergeError.noMergeInProgress
        }
        return try await output(["rev-parse", "HEAD"], at: worktree)
    }

    /// Starts the merge or revert in progress over (abort, then the same merge or revert again),
    /// so every conflict is open again. For a resolution an earlier call left half-staged.
    @discardableResult
    public func restartConflicts(at worktree: WorktreeLocation) async throws -> [ConflictEntry] {
        let gitDir = URL(filePath: worktree.gitDirectory)
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: gitDir.appending(path: name).path(percentEncoded: false)) }
        let outcome: MergeOutcome
        if exists("MERGE_HEAD") {
            let incoming = try await output(["rev-parse", "MERGE_HEAD"], at: worktree)
            let saved = (try? String(contentsOf: gitDir.appending(path: "MERGE_MSG"), encoding: .utf8)) ?? ""
            // The message without Git's appended "# Conflicts:" section.
            let message = saved.components(separatedBy: "\n").prefix { !$0.hasPrefix("#") }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try await run(["merge", "--abort"], at: worktree, environment: Self.mergeEnvironment)
            outcome = try await merge(incoming, at: worktree, message: message.isEmpty ? "KAIORX: integrate \(incoming)" : message)
        } else if exists("REVERT_HEAD") {
            let reverted = try await output(["rev-parse", "REVERT_HEAD"], at: worktree)
            try await run(["revert", "--abort"], at: worktree, environment: Self.mergeEnvironment)
            outcome = try await revertMerge(reverted, at: worktree)
        } else {
            throw MergeError.noMergeInProgress
        }
        guard case .conflicted(let conflicts) = outcome else { throw MergeError.noMergeInProgress }
        return conflicts
    }

    /// The commit an earlier `resolve` made in this worktree, if no merge or revert is in progress
    /// and `HEAD` is exactly that commit: first parent `base`, second parent `secondParent` for a
    /// merge, a single parent for a revert.
    public func finishedResolution(at worktree: WorktreeLocation, base: String, secondParent: String?) async throws -> String? {
        let gitDir = URL(filePath: worktree.gitDirectory)
        for marker in ["MERGE_HEAD", "REVERT_HEAD"]
        where FileManager.default.fileExists(atPath: gitDir.appending(path: marker).path(percentEncoded: false)) { return nil }
        let head = try await output(["rev-parse", "HEAD"], at: worktree)
        guard head != base else { return nil }
        let parents = try await output(["rev-parse", "\(head)^@"], at: worktree).split(separator: "\n").map(String.init)
        let expected = [base] + (secondParent.map { [$0] } ?? [])
        return parents == expected ? head : nil
    }

    private func stageEntry(mode: String, blob: String, path: String, at worktree: WorktreeLocation) async throws {
        try await run(["update-index", "--add", "--cacheinfo", "\(mode),\(blob),\(path)"], at: worktree)
        try await run(["checkout-index", "-f", "-q", "--", path], at: worktree, environment: ["GIT_LITERAL_PATHSPECS": "1"])
    }

    private func removeEntry(_ path: String, at worktree: WorktreeLocation) async throws {
        try await run(["update-index", "--force-remove", "--", path], at: worktree)
        // Only the leaf, never through a symlinked parent: Git refuses paths beyond a symlink.
        var info = stat()
        let full = worktree.path + "/" + path
        let parent = Confinement.resolved(URL(filePath: full).deletingLastPathComponent().path(percentEncoded: false))
        if lstat(full, &info) == 0, parent.hasPrefix(worktree.path) { unlink(full) }
    }

    /// Paths that differ between two commits.
    /// Whether `commit` is contained in `tip` (read-only).
    public func isAncestor(_ commit: String, of tip: String, in repository: RepositoryInfo) async throws -> Bool {
        let result = try await run(["merge-base", "--is-ancestor", commit, tip], in: repository.topLevel, allowedExitCodes: [0, 1])
        return result.termination == .exited(0)
    }

    public func changedPaths(from base: String, to commit: String, in repository: RepositoryInfo) async throws -> [ChangedPath] {
        let fields = nulFields(try await run(
            ["diff", "--name-status", "-z", "--no-renames", "--no-ext-diff", "--no-textconv", base, commit], in: repository.topLevel
        ).stdout.data)
        var result: [ChangedPath] = []
        var index = 0
        while index + 1 < fields.count {
            if let status = fields[index].first { result.append(ChangedPath(status: status, path: fields[index + 1])) }
            index += 2
        }
        return result
    }

    /// Unified diff for a reviewer, bounded.
    public func diff(from base: String, to commit: String, in repository: RepositoryInfo, limit: Int = 512 << 10) async throws -> String {
        let text = try await run(
            ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", base, commit], in: repository.topLevel
        ).stdout.text
        return text.count > limit ? String(text.prefix(limit)) + "\n[diff truncated]\n" : text
    }

    /// Creates `refs/heads/<name>` at `commit` without touching any checkout, index or existing
    /// branch. A taken name gets a numbered suffix; returns the name used.
    public func createBranch(_ name: String, at commit: String, in repository: RepositoryInfo) async throws -> String {
        try await checkBranchName(name, in: repository)
        for candidate in Self.freeBranchNames(for: name, existing: try await branchNames(in: repository)) {
            do {
                try await updateRef("refs/heads/\(candidate)", to: commit, expectedOld: nil, in: repository)
                return candidate
            } catch WorkspaceError.refConflict {
                continue
            }
        }
        throw MergeError.noFreeBranchName(name)
    }

    /// Refuses a name `createBranch` would refuse: `git check-ref-format --branch`, and literal
    /// only (`--branch` expands `@{-1}` and similar; `@` and a leading `-` are refused too).
    /// A folder spelled differently from an existing ref folder is refused as well
    /// (`caseVariantFolder`): Git would list the branch under the existing spelling.
    public func checkBranchName(_ name: String, in repository: RepositoryInfo) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("@{"), name != "@" else { throw MergeError.invalidBranchName(name) }
        let valid = try await run(["check-ref-format", "--branch", name], in: repository.topLevel, allowedExitCodes: [0, 1, 128])
        guard valid.termination == .exited(0) else { throw MergeError.invalidBranchName(name) }
        if let existing = Self.caseVariantFolder(for: name, existing: try await branchNames(in: repository)) {
            throw MergeError.branchFolderCaseConflict(name, existing: existing)
        }
    }

    /// The names of `refs/heads/*` in the repository (read only).
    public func branchNames(in repository: RepositoryInfo) async throws -> [String] {
        try await run(["for-each-ref", "--format=%(refname)", "refs/heads/"], in: repository.topLevel)
            .stdout.text.split(separator: "\n").map { String($0.dropFirst("refs/heads/".count)) }
    }

    /// The names `createBranch` would try for `name`, in order: the name itself, then `name-2`
    /// up to `name-20`, without those already taken. On a case-insensitive file system `Main`
    /// would alias a packed `main`: names are compared case- and normalisation-insensitively,
    /// including folder/file clashes (`a` vs `a/b`).
    public static func freeBranchNames(for name: String, existing: [String]) -> [String] {
        let folded = Set(existing.map(foldedBranch))
        func taken(_ candidate: String) -> Bool {
            let candidate = foldedBranch(candidate)
            return folded.contains { $0 == candidate || $0.hasPrefix(candidate + "/") || candidate.hasPrefix($0 + "/") }
        }
        return ([name] + (2...20).map { "\(name)-\($0)" }).filter { !taken($0) }
    }

    /// The existing ref folder that a folder of `name` matches case- and normalisation-insensitively
    /// but not byte for byte (`Feature` for `feature/y` next to `Feature/x`), if any. On a
    /// case-insensitive file system the new loose ref would land in that folder and Git would list
    /// it under the existing spelling; compared by name, independent of the file system at hand.
    public static func caseVariantFolder(for name: String, existing: [String]) -> String? {
        let folders = existing.flatMap(folderPrefixes(of:))
        for prefix in folderPrefixes(of: name) {
            let folded = foldedBranch(prefix)
            if let other = folders.first(where: { foldedBranch($0) == folded && !$0.utf8.elementsEqual(prefix.utf8) }) { return other }
        }
        return nil
    }

    /// `a`, `a/b` for `a/b/c`: the folders a loose ref of that name lives in.
    static func folderPrefixes(of name: String) -> [String] {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count < 2 ? [] : (1..<parts.count).map { parts[..<$0].joined(separator: "/") }
    }

    static func foldedBranch(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
