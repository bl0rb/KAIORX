import Foundation

/// Everything a child process gets. Nothing is inherited implicitly: no environment, no file
/// descriptors besides stdin/stdout/stderr, no working directory.
public struct LaunchSpec: Sendable, Equatable {
    /// Absolute path; no `PATH` lookup.
    public var executable: String
    public var arguments: [String]
    /// Absolute path.
    public var workingDirectory: String
    /// The complete environment (positive list; see `Environment`).
    public var environment: [String: String]
    /// Written to stdin, then stdin is closed. `nil` connects `/dev/null`.
    public var standardInput: Data?
    /// Bytes kept per stream. Output beyond the limit is still read (so the child never blocks)
    /// but dropped and counted.
    public var outputLimit: Int
    /// Stops the process (interrupt, terminate, kill) when exceeded.
    public var timeout: Duration?
    /// Grace period between the steps of a stop.
    public var stopGrace: Duration
    /// OS-level file and network restrictions (see `Confinement`).
    public var confinement: Confinement?
    /// Also deliver output chunks while the process runs.
    public var streamsOutput: Bool
    /// Keep stdin open for `ManagedProcess.send` (for example JSON-RPC); `standardInput`, if
    /// set, is written first.
    public var interactiveInput: Bool

    public init(
        executable: String, arguments: [String] = [], workingDirectory: String,
        environment: [String: String] = [:], standardInput: Data? = nil, outputLimit: Int = 1 << 20,
        timeout: Duration? = nil, stopGrace: Duration = .seconds(2), confinement: Confinement? = nil,
        streamsOutput: Bool = false, interactiveInput: Bool = false
    ) {
        self.interactiveInput = interactiveInput
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.standardInput = standardInput
        self.outputLimit = outputLimit
        self.timeout = timeout
        self.stopGrace = stopGrace
        self.confinement = confinement
        self.streamsOutput = streamsOutput
    }
}

public enum Environment {
    /// Values a child may get from the host environment when the caller asks for them. Secrets
    /// such as provider tokens or `SSH_AUTH_SOCK` are never on it.
    public static let inheritable: Set<String> = ["HOME", "LANG", "LC_ALL", "LC_CTYPE", "USER", "LOGNAME", "TERM"]

    /// A minimal environment: fixed `PATH`, the given temp folder and selected host values.
    public static func minimal(
        temporaryDirectory: String, inherit names: Set<String> = ["HOME", "LANG"],
        extra: [String: String] = [:]
    ) -> [String: String] {
        let host = ProcessInfo.processInfo.environment
        var result: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": temporaryDirectory]
        for name in names.intersection(inheritable) {
            if let value = host[name] { result[name] = value }
        }
        result.merge(extra) { _, new in new }
        return result
    }
}

public enum Termination: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)

    public var isSuccess: Bool { self == .exited(0) }
}

public struct CapturedOutput: Sendable, Equatable {
    /// The first `outputLimit` bytes.
    public var data: Data
    /// Everything the process wrote, including dropped bytes.
    public var totalBytes: Int

    public init(data: Data = Data(), totalBytes: Int = 0) {
        self.data = data
        self.totalBytes = totalBytes
    }

    public var isTruncated: Bool { totalBytes > data.count }
    public var text: String { String(decoding: data, as: UTF8.self) }
}

public enum OutputChunk: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
}

public enum StopReason: String, Sendable, Equatable {
    case requested, timeout, drain
}

public struct ProcessResult: Sendable, Equatable {
    public var termination: Termination
    public var stdout: CapturedOutput
    public var stderr: CapturedOutput
    /// Set when the host stopped the process.
    public var stopReason: StopReason?
    /// Output was still open after the process group ended (a process outside the group kept a
    /// pipe); reading was cut off.
    public var outputCutOff: Bool
    public var duration: Duration

    public var timedOut: Bool { stopReason == .timeout }
}

public enum ProcessHostError: Error, Equatable, Sendable {
    case notAbsolute(String)
    case spawnFailed(errno: Int32, executable: String)
    case pipeFailed(errno: Int32)
    /// `drain` has started; no new processes.
    case draining
    case confinementUnavailable(String)
    /// Empty key, `=` or NUL in a key, or NUL in a value: it could shadow another variable.
    case invalidEnvironment(String)
    case invalidArgument(String)
    /// `send` on a process without interactive input, or after `closeInput`.
    case inputClosed
    case writeFailed(errno: Int32)
}
