import Foundation

/// OS-level restrictions for a child and all its descendants, enforced with the macOS sandbox
/// (`sandbox-exec`, see ADR 0002). Writes are denied everywhere except `writableRoots`; reads and
/// writes are denied below `hiddenRoots` except below `visibleRoots`. Rules are resolved to real
/// paths, because the sandbox matches resolved paths (`/tmp` is `/private/tmp`).
public struct Confinement: Sendable, Equatable {
    public var writableRoots: [String]
    public var hiddenRoots: [String]
    /// Re-allowed for reading inside a hidden root (for example the attempt's own worktree inside
    /// the hidden worktrees folder).
    public var visibleRoots: [String]
    public var allowsNetwork: Bool
    /// Paths that stay read-only even inside a writable root (for example a worktree's `.git`
    /// link file); a trailing `/` protects a whole folder.
    public var protectedPaths: [String]
    /// Session services that act outside the sandbox on the process's behalf: LaunchServices
    /// (`open` starts an app that is not confined) and preference writes (cfprefsd writes the
    /// user's real preferences). Denied unless set (ADR 0002 §5); reading preferences stays allowed.
    public var allowsSessionServices: Bool

    public init(
        writableRoots: [String], hiddenRoots: [String] = [], visibleRoots: [String] = [], allowsNetwork: Bool = false,
        protectedPaths: [String] = [], allowsSessionServices: Bool = false
    ) {
        self.writableRoots = writableRoots
        self.hiddenRoots = hiddenRoots
        self.visibleRoots = visibleRoots
        self.allowsNetwork = allowsNetwork
        self.protectedPaths = protectedPaths
        self.allowsSessionServices = allowsSessionServices
    }

    public static let sandboxExecutable = "/usr/bin/sandbox-exec"

    /// The sandbox profile. Later rules win: denials first, then what stays allowed.
    func profile() -> String {
        let writable = (writableRoots + ["/dev"]).map(Self.resolved)
        let readable = (visibleRoots + writableRoots).map(Self.resolved)
        var lines = ["(version 1)", "(allow default)", "(deny file-write*)"]
        for root in hiddenRoots.map(Self.resolved) {
            lines.append("(deny file-read* file-write* (subpath \(Self.quoted(root))))")
        }
        if !readable.isEmpty {
            lines.append("(allow file-read* \(readable.map { "(subpath \(Self.quoted($0)))" }.joined(separator: " ")))")
            // Resolving a visible path (`realpath`, Codex canonicalizing `CODEX_HOME`) needs the
            // metadata of each folder above it, also inside a hidden root; never their contents.
            let ancestors = Set(readable.flatMap(Self.ancestors)).subtracting(readable).sorted()
            if !ancestors.isEmpty {
                lines.append("(allow file-read-metadata \(ancestors.map { "(literal \(Self.quoted($0)))" }.joined(separator: " ")))")
            }
        }
        lines.append("(allow file-write* \(writable.map { "(subpath \(Self.quoted($0)))" }.joined(separator: " ")))")
        for path in protectedPaths {
            // A trailing slash protects a whole folder.
            let resolved = Self.resolved(path.hasSuffix("/") ? String(path.dropLast()) : path)
            let filter = path.hasSuffix("/") ? "subpath" : "literal"
            lines.append("(deny file-write* (\(filter) \(Self.quoted(resolved))))")
        }
        if !allowsNetwork {
            lines.append("(deny network*)")
        }
        if !allowsSessionServices {
            // cfprefsd honours `user-preference-write` only together with the file-write denial above.
            lines.append("(deny lsopen)")
            lines.append("(deny user-preference-write)")
        }
        return lines.joined(separator: "\n")
    }

    /// Launch arguments for the confined process.
    func wrap(executable: String, arguments: [String]) -> (String, [String]) {
        (Self.sandboxExecutable, ["-p", profile(), "--", executable] + arguments)
    }

    /// Real path with symlinks resolved; for a missing path, of its closest existing parent.
    public static func resolved(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buffer) != nil {
            return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
        // Not existing yet: resolve the closest existing parent.
        let url = URL(filePath: path)
        let parent = url.deletingLastPathComponent().path(percentEncoded: false)
        guard parent != path, !parent.isEmpty else { return path }
        return URL(filePath: resolved(parent)).appending(path: url.lastPathComponent).path(percentEncoded: false)
    }

    /// The folders above an absolute path, `/` included.
    static func ancestors(_ path: String) -> [String] {
        var result: [String] = []
        var current = path
        while let slash = current.lastIndex(of: "/") {
            current = slash == current.startIndex ? "/" : String(current[..<slash])
            result.append(current)
            if current == "/" { break }
        }
        return result
    }

    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public enum ConfinementStatus: Sendable, Equatable {
    case effective
    case unavailable(String)
}

extension Confinement {
    /// Verifies that the sandbox actually blocks a write outside the writable roots on this Mac.
    /// Callers must not grant automatic write access to agents when this is not `.effective`.
    public static func probe(host: ProcessHost, scratch: URL) async -> ConfinementStatus {
        guard FileManager.default.isExecutableFile(atPath: sandboxExecutable) else {
            return .unavailable("\(sandboxExecutable) not found")
        }
        let allowed = scratch.appending(path: "allowed-\(UUID().uuidString)")
        let denied = scratch.appending(path: "denied-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: allowed)
                try? FileManager.default.removeItem(at: denied)
            }
            let allowedFile = allowed.appending(path: "ok").path(percentEncoded: false)
            let deniedFile = denied.appending(path: "blocked").path(percentEncoded: false)
            let result = try await host.run(LaunchSpec(
                executable: "/bin/sh",
                arguments: ["-c", "echo ok > \"$1\" && { echo no > \"$2\"; exit 0; }", "probe", allowedFile, deniedFile],
                workingDirectory: allowed.path(percentEncoded: false),
                environment: Environment.minimal(temporaryDirectory: allowed.path(percentEncoded: false)),
                timeout: .seconds(10),
                confinement: Confinement(writableRoots: [allowed.path(percentEncoded: false)])
            ))
            guard result.termination.isSuccess else {
                return .unavailable("probe exited with \(result.termination): \(result.stderr.text)")
            }
            guard FileManager.default.fileExists(atPath: allowedFile) else {
                return .unavailable("allowed write did not happen")
            }
            guard !FileManager.default.fileExists(atPath: deniedFile) else {
                return .unavailable("write outside the writable roots was not blocked")
            }
            return .effective
        } catch {
            return .unavailable("probe failed: \(error)")
        }
    }
}
