import Domain
import Foundation
import ProcessHost
import Synchronization

public struct ClaudeCodeConfiguration: Sendable {
    /// Absolute path of the unmodified `claude` binary.
    public var executable: String
    /// KAIORX's own `CLAUDE_CONFIG_DIR`; the user signs in there with the original program.
    public var configDirectory: String
    /// Per-run temporary folders are created below.
    public var temporaryRoot: String
    public var home: String
    public var policy: AdapterPolicy
    /// OS confinement per attempt (`nil`: none). Must keep the config directory writable and
    /// allow network for the CLI itself; the profile has no command-running tools.
    public var confinement: @Sendable (AttemptSpec, _ temporaryDirectory: String) -> Confinement?
    public var stopGrace: Duration
    /// Raw protocol lines for the owner's acceptance recording (nil in the product).
    public var lineSink: ProtocolLineSink?

    public init(
        executable: String, configDirectory: String, temporaryRoot: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
        policy: AdapterPolicy = AdapterPolicy(),
        confinement: @escaping @Sendable (AttemptSpec, String) -> Confinement? = { _, _ in nil },
        stopGrace: Duration = .seconds(5), lineSink: ProtocolLineSink? = nil
    ) {
        self.lineSink = lineSink
        self.executable = executable
        self.configDirectory = configDirectory
        self.temporaryRoot = temporaryRoot
        self.home = home
        self.policy = policy
        self.confinement = confinement
        self.stopGrace = stopGrace
    }
}

/// Runs the original Claude Code CLI once per attempt in headless `stream-json` mode.
public final class ClaudeCodeAdapter: AgentAdapter {
    public let provider: ProviderKind = .claude
    public let configuration: ClaudeCodeConfiguration
    private let host: ProcessHost
    private let identity = BinaryIdentityCache()

    public init(configuration: ClaudeCodeConfiguration, host: ProcessHost) {
        self.configuration = configuration
        self.host = host
    }

    /// The installed binary as the next start would see it (version and SHA-256, cached per
    /// resolved path and file signature). Runs at most `--version`; no inference.
    public func installedIdentity() async throws -> BinaryIdentity {
        try await identity.current(configuration.executable, host: host)
    }

    /// `claude auth status --json` in KAIORX's own config folder, with the run environment and
    /// confinement of a reviewer attempt. Reads the login state; no inference, no login. Only the
    /// owner's acceptance kit and the product preflight call it, never tests (CLAUDE.md).
    public func authStatus(scratch: String) async throws -> ClaudeAuthStatus {
        let identity = try await identity.current(configuration.executable, host: host)
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let spec = AttemptSpec(
            attemptID: AttemptID(), taskID: TaskID(), projectID: ProjectID(), role: .reviewer, provider: .claude, runMode: .automatic,
            modelProfile: "auth", effectiveModel: "none", workingDirectory: scratch, prompt: ""
        )
        let confinement = configuration.confinement(spec, scratch)
        if confinement == nil, configuration.policy.requiresConfinement { throw ProviderError.confinementRequired }
        let result = try await host.run(LaunchSpec(
            executable: identity.resolvedPath, arguments: ["auth", "status", "--json"], workingDirectory: scratch,
            environment: ClaudeCommand.environment(configDirectory: configuration.configDirectory, temporaryDirectory: scratch, home: configuration.home),
            outputLimit: 64 << 10, timeout: .seconds(30), confinement: confinement
        ))
        return ClaudeAuthStatus(output: result.stdout.text, exitCode: { if case .exited(let code) = result.termination { code } else { -1 } }())
    }

    /// Version and matrix status only; no login check (needs package A fixtures) and no inference.
    public func probe(_ request: ProbeRequest) async throws -> CapabilitySnapshot {
        let identity = try await identity.current(configuration.executable, host: host)
        let entry = CompatibilityMatrix.entry(for: .claude, version: identity.version)
        let automatic = (try? configuration.policy.check(.claude, identity: identity)) != nil
        return CapabilitySnapshot(
            provider: .claude, binaryVersion: identity.version, authState: .unknown,
            planMode: entry?.status.rawValue, runModes: automatic ? [.automatic, .manual] : [.manual],
            roles: AttemptRole.allCases, supportsStreaming: true, supportsUsage: true,
            supportsApprovals: false, supportsResume: false
        )
    }

    public func start(_ spec: AttemptSpec) async throws -> any RunHandle {
        guard let workingDirectory = spec.workingDirectory else { throw ProviderError.missingWorkingDirectory }
        let arguments = try ClaudeCommand.arguments(for: spec)
        let identity = try await identity.current(configuration.executable, host: host)
        try configuration.policy.check(.claude, identity: identity)
        let temporary = configuration.temporaryRoot + "/" + spec.attemptID.uuidString
        let confinement = configuration.confinement(spec, temporary)
        if confinement == nil, configuration.policy.requiresConfinement { throw ProviderError.confinementRequired }
        try FileManager.default.createDirectory(atPath: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The resolved path that passed the gate, not whatever the configured path points to later.
        let process = try await host.launch(LaunchSpec(
            executable: identity.resolvedPath, arguments: arguments, workingDirectory: workingDirectory,
            environment: ClaudeCommand.environment(configDirectory: configuration.configDirectory, temporaryDirectory: temporary, home: configuration.home),
            standardInput: Data(spec.prompt.utf8), outputLimit: 64 << 10, stopGrace: configuration.stopGrace,
            confinement: confinement, streamsOutput: true
        ))
        configuration.lineSink?(true, spec.prompt)
        return ClaudeRunHandle(attemptID: spec.attemptID, process: process, grace: configuration.stopGrace, lineSink: configuration.lineSink)
    }

    /// Runs without session persistence cannot be resumed; after a restart only a local
    /// reconciliation and a new attempt are possible.
    public func reconcile(_ request: ReconcileRequest) async throws -> ReconcileResult {
        .unknown
    }
}

final class ClaudeRunHandle: RunHandle {
    let attemptID: AttemptID
    let events: AsyncThrowingStream<AgentEvent, any Error>
    private let process: ManagedProcess
    private let grace: Duration
    private let cancelRequested = Flag()

    init(attemptID: AttemptID, process: ManagedProcess, grace: Duration, lineSink: ProtocolLineSink? = nil) {
        self.attemptID = attemptID
        self.process = process
        self.grace = grace
        let (stream, continuation) = AsyncThrowingStream<AgentEvent, any Error>.makeStream()
        self.events = stream
        let cancelled = cancelRequested
        Task {
            var framer = LineFramer()
            var parser = ClaudeStreamParser()
            do {
                for await chunk in process.output ?? AsyncStream(unfolding: { nil }) {
                    guard case .stdout(let data) = chunk else { continue }
                    for line in try framer.append(data) {
                        lineSink?(false, line)
                        for event in try parser.parse(line, cancelRequested: cancelled.isSet) {
                            continuation.yield(event)
                        }
                    }
                }
                let result = await process.wait()
                if !framer.remainder.isEmpty { throw ProviderError.protocolViolation("stream ended inside a line") }
                if !parser.completed {
                    // Only the CLI's `result` confirms a cancellation; a process killed after the
                    // grace period leaves the outcome unknown.
                    if !parser.sessionStarted, result.termination != .exited(0), !cancelled.isSet {
                        // Exited before a session existed (missing login, bad flag): no turn began.
                        let reason = String(result.stderr.text.suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.yield(.completed(.failed(reason: "exited before session start: \(reason)")))
                    }
                    // Otherwise the outcome is unknown: the stream ends without a terminal event.
                }
                continuation.finish()
            } catch {
                await process.stop(grace: grace)
                continuation.finish(throwing: error)
            }
        }
    }

    /// SIGINT first ends the turn; then terminate and kill the process group.
    func cancel(reason: String) async {
        cancelRequested.set()
        await process.stop(reason: .requested, grace: grace)
    }
}

/// A thread-safe flag that is set once.
final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
