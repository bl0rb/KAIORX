import Foundation
import ProcessHost

public struct RepositoryInfo: Sendable, Equatable {
    /// Resolved path of the user's working tree.
    public var topLevel: String
    /// Resolved shared Git directory; identifies the repository across worktrees.
    public var commonDirectory: String
    /// `sha1` or `sha256`.
    public var objectFormat: String
    /// Current branch, `nil` when detached.
    public var headBranch: String?
    /// `nil` for a repository without commits.
    public var headOID: String?
    /// Smallest root commit reachable from HEAD. Survives moving the folder and differs between
    /// unrelated repositories; `nil` without commits.
    public var rootCommit: String?

    /// Stable identity for the project record.
    public var identity: String? { rootCommit.map { "\(objectFormat):\($0)" } }

    public var zeroOID: String { String(repeating: "0", count: objectFormat == "sha256" ? 64 : 40) }

    public func isValidOID(_ text: String) -> Bool {
        text.count == zeroOID.count && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// Something in the repository that would let checkout, staging or merging run programs the
/// host has not approved. M0 pauses before checkout when any is present.
public enum WorkspaceBlocker: Sendable, Equatable, Hashable {
    case submodules
    case configuredFilter(name: String)
    case configuredMergeDriver(name: String)
    case attributeFilter(path: String, driver: String)
    case attributeMergeDriver(path: String, driver: String)
    /// `core.attributesFile` points outside the repository; its rules are not checked.
    case configuredAttributesFile(String)
}

extension GitRunner {
    public func inspect(_ path: String) async throws -> RepositoryInfo {
        let probe = try await run(
            ["rev-parse", "--path-format=absolute", "--is-bare-repository", "--git-common-dir", "--show-object-format"],
            in: path, allowedExitCodes: [0, 128]
        )
        guard probe.termination == .exited(0) else { throw GitError.notARepository(path) }
        let lines = probe.stdout.text.split(separator: "\n").map(String.init)
        guard lines.count == 3 else { throw GitError.unexpectedOutput(probe.stdout.text) }
        if lines[0] == "true" { throw GitError.bareRepository(path) }
        let topLevel = try await output(["rev-parse", "--path-format=absolute", "--show-toplevel"], in: path)
        let head = try await run(["rev-parse", "-q", "--verify", "HEAD^{commit}"], in: path, allowedExitCodes: [0, 1])
        let branch = try await run(["symbolic-ref", "-q", "--short", "HEAD"], in: path, allowedExitCodes: [0, 1])
        let trim = { (text: String) in text.trimmingCharacters(in: .newlines) }
        var rootCommit: String?
        if head.termination == .exited(0) {
            let roots = try await run(["rev-list", "--max-parents=0", "HEAD"], in: path).stdout.text
            rootCommit = roots.split(separator: "\n").map(String.init).min()
        }
        return RepositoryInfo(
            topLevel: Confinement.resolved(topLevel), commonDirectory: Confinement.resolved(lines[1]),
            objectFormat: lines[2], headBranch: branch.termination == .exited(0) ? trim(branch.stdout.text) : nil,
            headOID: head.termination == .exited(0) ? trim(head.stdout.text) : nil, rootCommit: rootCommit
        )
    }

    /// Whether the repository has this commit object.
    public func containsCommit(_ oid: String, in repository: RepositoryInfo) async throws -> Bool {
        guard repository.isValidOID(oid) else { return false }
        let result = try await run(["cat-file", "-e", "\(oid)^{commit}"], in: repository.topLevel, allowedExitCodes: [0, 1, 128])
        return result.termination == .exited(0)
    }

    /// Resolves a commit-ish to a full commit ID.
    public func resolveCommit(_ revision: String, in repository: RepositoryInfo) async throws -> String {
        let oid = try await output(["rev-parse", "--verify", "--end-of-options", "\(revision)^{commit}"], in: repository.topLevel)
        guard repository.isValidOID(oid) else { throw GitError.unexpectedOutput(oid) }
        return oid
    }

    /// Filters, custom merge drivers and submodules at `commit` or in the repository config.
    /// The config check is repeated in the new worktree's own context by `addWorktree`, because
    /// `includeIf "gitdir:"` can differ there.
    public func blockers(at commit: String, in repository: RepositoryInfo) async throws -> Set<WorkspaceBlocker> {
        var found = try await configBlockers { arguments in
            try await self.run(arguments, in: repository.topLevel, allowedExitCodes: [0, 1])
        }
        let tree = try await run(["ls-tree", "-r", "-z", "--full-tree", commit], in: repository.topLevel)
        for entry in nulFields(tree.stdout.data) {
            guard let tab = entry.firstIndex(of: "\t") else { continue }
            let meta = entry[..<tab].split(separator: " ")
            let path = String(entry[entry.index(after: tab)...])
            // Case-insensitive: APFS honours `.GitAttributes` as `.gitattributes`.
            let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
            if meta.first == "160000" || (name == ".gitmodules" && !path.contains("/")) { found.insert(.submodules) }
            if name == ".gitattributes", meta.count == 3 {
                let blob = try await run(["cat-file", "blob", String(meta[2])], in: repository.topLevel)
                found.formUnion(Self.attributeBlockers(blob.stdout.data, path: path))
            }
        }
        let infoAttributes = URL(filePath: repository.commonDirectory).appending(path: "info/attributes")
        if let data = FileManager.default.contents(atPath: infoAttributes.path(percentEncoded: false)) {
            found.formUnion(Self.attributeBlockers(data, path: "info/attributes"))
        }
        return found
    }

    /// Filter and merge drivers and `core.attributesFile` in the effective repository config
    /// (includes and worktree config; system and global config are disabled for host Git).
    func configBlockers(_ git: ([String]) async throws -> ProcessResult) async throws -> Set<WorkspaceBlocker> {
        var found = Set<WorkspaceBlocker>()
        let config = try await git(
            ["config", "--includes", "--null", "--get-regexp", #"^(filter|merge)\..*\.(clean|smudge|process|driver|required)$"#]
        )
        for entry in nulFields(config.stdout.data) {
            let key = entry.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? entry
            let parts = key.split(separator: ".")
            guard parts.count >= 3 else { continue }
            let name = parts.dropFirst().dropLast().joined(separator: ".")
            found.insert(parts[0] == "filter" ? .configuredFilter(name: name) : .configuredMergeDriver(name: name))
        }
        let attributesFile = try await git(["config", "--includes", "--null", "--get", "core.attributesFile"])
        if attributesFile.termination == .exited(0) {
            found.insert(.configuredAttributesFile(nulFields(attributesFile.stdout.data).first ?? ""))
        }
        return found
    }

    static let builtinMergeDrivers: Set<String> = ["text", "binary", "union"]

    /// Parses attribute rules the way Git does: lines end at LF only (bytes), and spaces, tabs
    /// and CR separate tokens.
    static func attributeBlockers(_ data: Data, path: String) -> Set<WorkspaceBlocker> {
        var found = Set<WorkspaceBlocker>()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let tokens = line.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D })
                .map { String(decoding: $0, as: UTF8.self) }
            guard let pattern = tokens.first, !pattern.hasPrefix("#") else { continue }
            for token in tokens.dropFirst() {
                if token.hasPrefix("filter=") {
                    found.insert(.attributeFilter(path: path, driver: String(token.dropFirst(7))))
                } else if token.hasPrefix("merge=") {
                    let driver = String(token.dropFirst(6))
                    if !builtinMergeDrivers.contains(driver) {
                        found.insert(.attributeMergeDriver(path: path, driver: driver))
                    }
                }
            }
        }
        return found
    }
}
