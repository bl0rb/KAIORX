import Foundation

/// One changed file between two commits, for the review screen (read-only Git).
public struct DiffFile: Sendable, Equatable, Hashable {
    public enum Status: String, Sendable, Equatable, Hashable {
        case added, modified, deleted, renamed, copied, typeChanged, unmerged, unknown
    }

    public var status: Status
    public var oldPath: String?
    public var newPath: String?
    public var oldMode: String
    public var newMode: String
    /// Line counts; nil for binary files.
    public var added: Int?
    public var deleted: Int?
    /// Rename or copy similarity in percent.
    public var similarity: Int?

    /// Git reported no line counts (`-` in numstat): binary content.
    public var isBinary: Bool
    public var isSymlink: Bool { oldMode == "120000" || newMode == "120000" }
    public var isSubmodule: Bool { oldMode == "160000" || newMode == "160000" }
    /// The path shown: the new path, or the old one for a deletion.
    public var path: String { newPath ?? oldPath ?? "" }

    public init(
        status: Status, oldPath: String?, newPath: String?, oldMode: String, newMode: String, added: Int?, deleted: Int?, similarity: Int? = nil,
        isBinary: Bool = false
    ) {
        self.isBinary = isBinary
        self.status = status
        self.oldPath = oldPath
        self.newPath = newPath
        self.oldMode = oldMode
        self.newMode = newMode
        self.added = added
        self.deleted = deleted
        self.similarity = similarity
    }
}

/// A bounded unified diff of one file.
public struct FileDiffText: Sendable, Equatable {
    public var text: String
    /// The diff was cut at the byte limit (at a line boundary).
    public var truncated: Bool

    public init(text: String, truncated: Bool) {
        self.text = text
        self.truncated = truncated
    }
}

extension GitRunner {
    /// Changed files between two commits with renames detected, line counts and modes. Read-only.
    public func fileChanges(from base: String, to commit: String, in repository: RepositoryInfo) async throws -> [DiffFile] {
        let common = ["--no-ext-diff", "--no-textconv", "-M", "-z", base, commit]
        let raw = nulFields(try await run(["diff", "--raw", "--no-abbrev"] + common, in: repository.topLevel).stdout.data)
        let numstat = nulFields(try await run(["diff", "--numstat"] + common, in: repository.topLevel).stdout.data)
        // numstat: "a\td\tpath" or, for renames, "a\td\t" followed by old and new path.
        var counts: [String: (Int?, Int?, Bool)] = [:]
        var index = 0
        while index < numstat.count {
            let parts = numstat[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { index += 1; continue }
            let value = (Int(parts[0]), Int(parts[1]), parts[0] == "-" && parts[1] == "-")
            if parts[2].isEmpty, index + 2 < numstat.count {
                counts[numstat[index + 2]] = value
                index += 3
            } else {
                counts[parts[2]] = value
                index += 1
            }
        }
        var result: [DiffFile] = []
        index = 0
        while index < raw.count {
            let meta = raw[index]
            guard meta.hasPrefix(":") else { index += 1; continue }
            let fields = meta.dropFirst().split(separator: " ").map(String.init)
            guard fields.count >= 5, let code = fields[4].first else { index += 1; continue }
            let similarity = Int(fields[4].dropFirst())
            let status: DiffFile.Status = switch code {
            case "A": .added
            case "M": .modified
            case "D": .deleted
            case "R": .renamed
            case "C": .copied
            case "T": .typeChanged
            case "U": .unmerged
            default: .unknown
            }
            if status == .renamed || status == .copied, index + 2 < raw.count {
                let old = raw[index + 1], new = raw[index + 2]
                let count = counts[new]
                result.append(DiffFile(status: status, oldPath: old, newPath: new, oldMode: fields[0], newMode: fields[1],
                                       added: count?.0, deleted: count?.1, similarity: similarity, isBinary: count?.2 ?? false))
                index += 3
            } else if index + 1 < raw.count {
                let path = raw[index + 1]
                let count = counts[path]
                result.append(DiffFile(status: status, oldPath: status == .added ? nil : path, newPath: status == .deleted ? nil : path,
                                       oldMode: fields[0], newMode: fields[1], added: count?.0, deleted: count?.1, isBinary: count?.2 ?? false))
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }

    /// The unified diff of one file (both paths for a rename), cut at `byteLimit` at a line
    /// boundary with a typed flag. Read-only.
    public func fileDiff(from base: String, to commit: String, file: DiffFile, in repository: RepositoryInfo, byteLimit: Int = 512 << 10) async throws -> FileDiffText {
        let paths = Array(Set([file.oldPath, file.newPath].compactMap { $0 })).sorted()
        let data = try await run(
            ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "-M", base, commit, "--"] + paths, in: repository.topLevel,
            environment: ["GIT_LITERAL_PATHSPECS": "1"]
        ).stdout.data
        guard data.count > byteLimit else { return FileDiffText(text: String(decoding: data, as: UTF8.self), truncated: false) }
        var cut = byteLimit
        while cut > 0, data[data.startIndex + cut - 1] != 0x0A { cut -= 1 }
        if cut == 0 { cut = byteLimit }
        return FileDiffText(text: String(decoding: data.prefix(cut), as: UTF8.self), truncated: true)
    }
}
