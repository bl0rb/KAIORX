import Foundation

/// Read-only Git access for memory sources (ADR 0006 §2, §5): blobs come from commits, never
/// from a worktree.
public struct TreeEntry: Sendable, Equatable {
    public var mode: String
    public var type: String
    public var oid: String
}

extension GitRunner {
    /// The entry at `path` in `commit`, or nil if there is none.
    public func treeEntry(_ path: String, in commit: String, repository: RepositoryInfo) async throws -> TreeEntry? {
        let fields = nulFields(try await run(
            ["ls-tree", "-z", "--full-tree", commit, "--", path], in: repository.topLevel, environment: ["GIT_LITERAL_PATHSPECS": "1"]
        ).stdout.data)
        guard let field = fields.first(where: { !$0.isEmpty }), let tab = field.firstIndex(of: "\t") else { return nil }
        let meta = field[..<tab].split(separator: " ")
        guard meta.count == 3, String(field[field.index(after: tab)...]) == path else { return nil }
        return TreeEntry(mode: String(meta[0]), type: String(meta[1]), oid: String(meta[2]))
    }

    public func blobSize(_ oid: String, repository: RepositoryInfo) async throws -> Int {
        Int(try await output(["cat-file", "-s", oid], in: repository.topLevel)) ?? .max
    }

    public func blob(_ oid: String, repository: RepositoryInfo) async throws -> Data {
        try await run(["cat-file", "blob", oid], in: repository.topLevel).stdout.data
    }

    /// The blob OID at each path in `commit` (nil where there is none), in one batch.
    public func blobs(at paths: [String], in commit: String, repository: RepositoryInfo) async throws -> [String: String?] {
        guard !paths.isEmpty else { return [:] }
        let unique = Array(Set(paths)).sorted()
        let input = unique.map { "\(commit):\($0)" }.joined(separator: "\n") + "\n"
        let lines = try await run(["cat-file", "--batch-check=%(objectname) %(objecttype)"], in: repository.topLevel, input: Data(input.utf8))
            .stdout.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String: String?] = [:]
        for (index, path) in unique.enumerated() {
            let parts = index < lines.count ? lines[index].split(separator: " ") : []
            result[path] = parts.count == 2 && parts[1] == "blob" ? String(parts[0]) : nil
        }
        return result
    }
}
