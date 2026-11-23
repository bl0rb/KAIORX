import CryptoKit
import Domain
import Foundation
import ProcessHost
import Synchronization

/// Claude Code's native installer keeps each version as `…/claude/versions/<version>` and points
/// `claude` at the newest; it updates itself. When the linked build did not pass the live
/// acceptance but an older kept build did, the app runs the accepted one (ADR 0013). The owner's
/// acceptance kit never does this: it must test exactly the linked build.
public enum VerifiedInstall {
    /// `resolved` itself when it is accepted, not a kept Claude version or nothing better is kept;
    /// otherwise the newest kept version whose build the matrix names as `liveVerified`. Only
    /// files named like a live-verified version are hashed.
    public static func prefer(
        _ resolved: String, provider: ProviderKind, matrix: [CompatibilityEntry] = CompatibilityMatrix.entries,
        sha256: (String) -> String? = VerifiedInstall.cachedSHA256
    ) -> String {
        guard provider == .claude else { return resolved }
        let url = URL(filePath: resolved)
        let folder = url.deletingLastPathComponent()
        guard folder.lastPathComponent == "versions", folder.deletingLastPathComponent().lastPathComponent == "claude" else { return resolved }
        let live = matrix.filter { $0.provider == .claude && $0.status == .liveVerified }
        func accepted(_ path: String, version: String) -> Bool {
            guard let entry = live.first(where: { $0.version == version }), FileManager.default.isExecutableFile(atPath: path),
                  let hash = sha256(path) else { return false }
            return entry.builds.contains(hash)
        }
        if accepted(resolved, version: url.lastPathComponent) { return resolved }
        let newestFirst = live.map(\.version).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in newestFirst where version != url.lastPathComponent {
            let candidate = folder.appending(path: version).path(percentEncoded: false)
            if accepted(candidate, version: version) { return candidate }
        }
        return resolved
    }

    /// `sha256`, remembered per path while the file's device, inode, size and change time stay
    /// the same: the app locates Claude at start, at every check and for the login terminal.
    public static func cachedSHA256(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let signature = [Int(info.st_dev), Int(info.st_ino), Int(info.st_size), Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec),
                         Int(info.st_ctimespec.tv_sec), Int(info.st_ctimespec.tv_nsec)]
        if let known = hashes.withLock({ $0[path] }), known.signature == signature { return known.hash }
        guard let hash = sha256(path) else { return nil }
        hashes.withLock { $0[path] = (signature, hash) }
        return hash
    }

    private static let hashes = Mutex<[String: (signature: [Int], hash: String)]>([:])

    /// SHA-256 of a file, read in 4 MiB pieces.
    public static func sha256(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 4 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
