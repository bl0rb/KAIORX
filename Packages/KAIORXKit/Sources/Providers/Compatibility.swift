import CryptoKit
import Domain
import Foundation
import ProcessHost
import Synchronization

/// Identity of an installed provider binary, as recorded in the compatibility matrix.
public struct BinaryIdentity: Sendable, Equatable, Codable {
    /// Path the adapter was configured with.
    public var path: String
    /// After resolving symlinks.
    public var resolvedPath: String
    public var sha256: String
    /// Version string reported by the binary (`--version`), without the product name.
    public var version: String

    /// Version probe: hashes the file and runs `--version`. Consumes no inference.
    public static func probe(_ path: String, host: ProcessHost) async throws -> BinaryIdentity {
        guard path.hasPrefix("/") else { throw ProcessHostError.notAbsolute(path) }
        let resolved = Confinement.resolved(path)
        guard let data = FileManager.default.contents(atPath: resolved) else {
            throw ProviderError.binaryMissing(path)
        }
        let result = try await host.run(LaunchSpec(
            executable: resolved, arguments: ["--version"], workingDirectory: "/",
            environment: Environment.minimal(temporaryDirectory: NSTemporaryDirectory(), inherit: ["HOME"]),
            outputLimit: 4096, timeout: .seconds(20)
        ))
        guard result.termination.isSuccess else { throw ProviderError.versionProbeFailed(result.stderr.text) }
        return BinaryIdentity(
            path: path, resolvedPath: resolved,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            version: Self.parseVersion(result.stdout.text)
        )
    }

    /// `2.1.328 (Claude Code)` → `2.1.328`; `codex-cli 0.170.0` → `0.170.0`.
    static func parseVersion(_ text: String) -> String {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "(" || $0 == ")" })
        return tokens.first { $0.first?.isNumber == true && $0.contains(".") }.map(String.init)
            ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum VerificationStatus: String, Sendable, Codable {
    /// Flags or protocol schema checked against this exact version; no live subscription run.
    case offlineVerified
    /// A live, user-authorised subscription run passed (package A acceptance).
    case liveVerified
}

/// One version the adapter was checked against. Automatic runs need `liveVerified`; a version
/// that is not listed blocks automatic runs until its contract test passes.
public struct CompatibilityEntry: Sendable, Equatable, Codable {
    public var provider: ProviderKind
    public var version: String
    public var status: VerificationStatus
    /// What was checked, and what is still open.
    public var notes: String
    /// SHA-256 over the generated protocol schema (Codex), if any.
    public var schemaDigest: String?
}

public enum CompatibilityMatrix {
    public static let entries: [CompatibilityEntry] = [
        CompatibilityEntry(
            provider: .claude, version: "2.1.328", status: .offlineVerified,
            notes: """
                All flags of the automatic profile exist in `claude --help` of this version. The stream-json \
                event shapes are not published as a schema; the parser follows the Agent SDK message types and is \
                tested with synthetic fixtures. Open: recorded fixtures from a live run, `claude auth status --json` \
                fields, permission rule syntax for `--allowedTools` path rules.
                """,
            schemaDigest: nil
        ),
        CompatibilityEntry(
            provider: .codex, version: "0.170.0", status: .offlineVerified,
            notes: """
                Requests sent and fixture messages validated against `app-server generate-json-schema` of this \
                binary. Open: SIWC login and token refresh, live turn with approvals, `account/rateLimits/read`.
                """,
            schemaDigest: "22b6df4324c33a4945cab3ba72870108aca2745fe617552ccb85e46966091bf0"
        ),
    ]

    public static func entry(for provider: ProviderKind, version: String) -> CompatibilityEntry? {
        entries.first { $0.provider == provider && $0.version == version }
    }
}

/// Whether an adapter may start automatic runs.
public struct AdapterPolicy: Sendable, Equatable {
    /// Require a `liveVerified` matrix entry for the probed version (the product default).
    public var requiresLiveVerification: Bool
    /// Refuse to start without OS confinement for the provider process (the product default).
    public var requiresConfinement: Bool

    public init(requiresLiveVerification: Bool = true, requiresConfinement: Bool = true) {
        self.requiresLiveVerification = requiresLiveVerification
        self.requiresConfinement = requiresConfinement
    }

    /// Test fixtures stand in for the real binaries; never use this for a provider binary.
    public static let fixtureTesting = AdapterPolicy(requiresLiveVerification: false, requiresConfinement: false)

    func check(_ provider: ProviderKind, identity: BinaryIdentity) throws {
        guard requiresLiveVerification else { return }
        guard let entry = CompatibilityMatrix.entry(for: provider, version: identity.version) else {
            throw ProviderError.versionNotInMatrix(provider: provider, version: identity.version)
        }
        guard entry.status == .liveVerified else {
            throw ProviderError.notLiveVerified(provider: provider, version: identity.version)
        }
    }
}

public enum ProviderError: Error, Equatable, Sendable {
    case binaryMissing(String)
    case versionProbeFailed(String)
    case versionNotInMatrix(provider: ProviderKind, version: String)
    /// Automatic runs wait for package A's live verification of this version.
    case notLiveVerified(provider: ProviderKind, version: String)
    case missingWorkingDirectory
    case unsupportedMode(RunMode)
    /// The provider broke its protocol (invalid frame, unknown terminal status, …).
    case protocolViolation(String)
    /// The provider answered a request with an error before the turn began.
    case requestFailed(method: String, message: String)
    case confinementRequired
    /// The binary kept changing while it was being checked.
    case binaryChanged(String)
}

/// Re-checks the binary before every start: the path may point somewhere else now (for example
/// after a self-update that switched a symlink), and only the version that passed the gate may
/// run. The resolved path is launched, so a later switch does not affect a started run.
final class BinaryIdentityCache: Sendable {
    private struct Entry {
        var identity: BinaryIdentity
        var signature: [Int64]
    }

    private let entry = Mutex<Entry?>(nil)

    func current(_ path: String, host: ProcessHost) async throws -> BinaryIdentity {
        let resolved = Confinement.resolved(path)
        let signature = Self.signature(resolved)
        if let cached = entry.withLock({ $0 }), cached.identity.resolvedPath == resolved, cached.signature == signature {
            return cached.identity
        }
        // The file must stay the same while it is hashed and asked for its version; otherwise
        // the cached version would describe a different file.
        for _ in 0..<3 {
            let before = Self.signature(resolved)
            let identity = try await BinaryIdentity.probe(path, host: host)
            let after = Self.signature(identity.resolvedPath)
            if identity.resolvedPath == resolved, before == after, !before.isEmpty {
                entry.withLock { $0 = Entry(identity: identity, signature: after) }
                return identity
            }
        }
        throw ProviderError.binaryChanged(path)
    }

    /// Device, inode, size and modification time: any replacement changes it.
    static func signature(_ path: String) -> [Int64] {
        var info = stat()
        guard stat(path, &info) == 0 else { return [] }
        return [Int64(info.st_dev), Int64(info.st_ino), Int64(info.st_size), Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec)]
    }
}
