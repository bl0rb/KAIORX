import Foundation
import ProcessHost

public enum GitError: Error, Equatable, Sendable {
    case gitNotFound
    case notARepository(String)
    case bareRepository(String)
    case failed(arguments: [String], termination: Termination, stderr: String)
    case unexpectedOutput(String)
}

/// Host Git with sanitised settings: no system or global config, no hooks, no fsmonitor, no
/// signing, no network protocols, no terminal prompts, and no optional locks (so reads never
/// refresh the index of the user's checkout). The environment is built from scratch.
public struct GitRunner: Sendable {
    public let executable: String
    let host: ProcessHost
    /// Empty folder used as `HOME`, so no user config or credentials are found.
    let home: String

    public static let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]

    public static func locate() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public init(host: ProcessHost, executable: String? = nil, home: String) throws {
        guard let executable = executable ?? Self.locate() else { throw GitError.gitNotFound }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.host = host
        self.executable = executable
        self.home = home
    }

    static let configOverrides = [
        "core.hooksPath=/dev/null", "core.fsmonitor=false", "core.untrackedCache=false",
        "commit.gpgSign=false", "tag.gpgSign=false", "color.ui=false", "core.quotePath=false",
        "advice.detachedHead=false", "protocol.allow=never", "core.sshCommand=false",
        "credential.helper=", "gc.auto=0", "maintenance.auto=false",
    ]

    var environment: [String: String] {
        [
            "PATH": "/usr/bin:/bin", "HOME": home, "TMPDIR": home, "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_ATTR_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false",
        ]
    }

    /// Runs `git <arguments>` in `directory`. Throws unless the exit code is allowed.
    @discardableResult
    func run(
        _ arguments: [String], in directory: String, input: Data? = nil, environment extra: [String: String] = [:],
        allowedExitCodes: Set<Int32> = [0], timeout: Duration = .seconds(300)
    ) async throws -> ProcessResult {
        let full = Self.configOverrides.flatMap { ["-c", $0] } + arguments
        let result = try await host.run(LaunchSpec(
            executable: executable, arguments: full, workingDirectory: directory,
            environment: environment.merging(extra) { _, new in new }, standardInput: input,
            outputLimit: 256 << 20, timeout: timeout
        ))
        guard case .exited(let code) = result.termination, allowedExitCodes.contains(code), !result.stdout.isTruncated else {
            throw GitError.failed(arguments: arguments, termination: result.termination, stderr: result.stderr.text)
        }
        return result
    }

    /// stdout without the trailing newline.
    func output(_ arguments: [String], in directory: String) async throws -> String {
        let text = try await run(arguments, in: directory).stdout.text
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}

/// Splits NUL-terminated Git output into fields.
func nulFields(_ data: Data) -> [String] {
    data.split(separator: 0, omittingEmptySubsequences: false).dropLast(data.last == 0 ? 1 : 0)
        .map { String(decoding: $0, as: UTF8.self) }
}
