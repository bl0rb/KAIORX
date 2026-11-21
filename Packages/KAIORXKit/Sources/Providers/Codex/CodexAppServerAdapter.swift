import Domain
import Foundation
import ProcessHost
import Synchronization

public struct CodexConfiguration: Sendable {
    public enum Authentication: Sendable {
        /// The App Server uses its own login in `codexHome` (existing local/open-source path).
        case cliManaged
        /// Sign in with ChatGPT: KAIORX's short-lived access token is passed as `ACCESS_TOKEN`
        /// to this process only, with the documented provider settings (Plan/anbieter.md §2.3).
        case siwc(baseURL: String, accessToken: @Sendable () async throws -> String)
    }

    /// Absolute path of the native `codex` binary (not the Node wrapper).
    public var executable: String
    /// KAIORX's own `CODEX_HOME`, separate from the user's profile.
    public var codexHome: String
    public var temporaryRoot: String
    public var home: String
    public var authentication: Authentication
    public var policy: AdapterPolicy
    public var confinement: @Sendable (AttemptSpec, _ temporaryDirectory: String) -> Confinement?
    public var stopGrace: Duration
    public var requestTimeout: Duration
    public var clientVersion: String
    /// Keep sent and received messages for contract tests.
    public var recordsTranscript: Bool
    /// Raw protocol lines for the owner's acceptance recording (nil in the product).
    public var lineSink: ProtocolLineSink?
    /// The app server's standard error, line by line, for the same recording (nil in the product).
    public var diagnosticSink: DiagnosticLineSink?

    public init(
        executable: String, codexHome: String, temporaryRoot: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
        authentication: Authentication = .cliManaged, policy: AdapterPolicy = AdapterPolicy(),
        confinement: @escaping @Sendable (AttemptSpec, String) -> Confinement? = { _, _ in nil },
        stopGrace: Duration = .seconds(5), requestTimeout: Duration = .seconds(60), clientVersion: String = "0.1.0",
        recordsTranscript: Bool = false, lineSink: ProtocolLineSink? = nil, diagnosticSink: DiagnosticLineSink? = nil
    ) {
        self.lineSink = lineSink
        self.diagnosticSink = diagnosticSink
        self.executable = executable
        self.codexHome = codexHome
        self.temporaryRoot = temporaryRoot
        self.home = home
        self.authentication = authentication
        self.policy = policy
        self.confinement = confinement
        self.stopGrace = stopGrace
        self.requestTimeout = requestTimeout
        self.clientVersion = clientVersion
        self.recordsTranscript = recordsTranscript
    }
}

/// Drives one `codex app-server` process per attempt over stdio JSON-RPC: initialize, thread,
/// one turn. Approvals follow the attempt's role; anything else the server asks is refused.
public final class CodexAppServerAdapter: AgentAdapter {
    public let provider: ProviderKind = .codex
    public let configuration: CodexConfiguration
    private let host: ProcessHost
    private let identity = BinaryIdentityCache()

    public init(configuration: CodexConfiguration, host: ProcessHost) {
        self.configuration = configuration
        self.host = host
    }

    /// The installed binary as the next start would see it (version and SHA-256, cached per
    /// resolved path and file signature). Runs at most `--version`; no inference.
    public func installedIdentity() async throws -> BinaryIdentity {
        try await identity.current(configuration.executable, host: host)
    }

    public func probe(_ request: ProbeRequest) async throws -> CapabilitySnapshot {
        let identity = try await identity.current(configuration.executable, host: host)
        let entry = CompatibilityMatrix.entry(for: .codex, version: identity.version)
        let automatic = (try? configuration.policy.check(.codex, identity: identity)) != nil
        return CapabilitySnapshot(
            provider: .codex, binaryVersion: identity.version, authState: .unknown,
            planMode: entry?.status.rawValue, runModes: automatic ? [.automatic] : [],
            roles: AttemptRole.allCases, supportsStreaming: true, supportsUsage: true,
            supportsApprovals: true, supportsResume: false
        )
    }

    /// Initialises the server and starts the thread before returning; failures up to here
    /// happen before any turn (safe to fail). The turn is started without waiting for it.
    public func start(_ spec: AttemptSpec) async throws -> any RunHandle {
        guard spec.runMode == .automatic else { throw ProviderError.unsupportedMode(spec.runMode) }
        guard let workingDirectory = spec.workingDirectory else { throw ProviderError.missingWorkingDirectory }
        let identity = try await identity.current(configuration.executable, host: host)
        try configuration.policy.check(.codex, identity: identity)
        let temporary = configuration.temporaryRoot + "/" + spec.attemptID.uuidString
        let confinement = configuration.confinement(spec, temporary)
        if confinement == nil, configuration.policy.requiresConfinement { throw ProviderError.confinementRequired }
        try FileManager.default.createDirectory(atPath: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(atPath: configuration.codexHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": configuration.home, "TMPDIR": temporary,
            "LANG": "en_US.UTF-8", "CODEX_HOME": configuration.codexHome,
        ]
        var arguments = ["app-server", "--listen", "stdio://", "--strict-config"] + Self.baseOverrides
        if case let .siwc(baseURL, token) = configuration.authentication {
            environment["ACCESS_TOKEN"] = try await token()
            arguments += Self.siwcOverrides(baseURL: baseURL)
        }
        // The resolved path that passed the gate, not whatever the configured path points to later.
        let process = try await host.launch(LaunchSpec(
            executable: identity.resolvedPath, arguments: arguments, workingDirectory: workingDirectory,
            environment: environment, outputLimit: 64 << 10, stopGrace: configuration.stopGrace,
            confinement: confinement, streamsOutput: true, interactiveInput: true
        ))
        let handle = CodexRunHandle(
            spec: spec, workingDirectory: workingDirectory, process: process, grace: configuration.stopGrace,
            timeout: configuration.requestTimeout, recordsTranscript: configuration.recordsTranscript, lineSink: configuration.lineSink,
            diagnosticSink: configuration.diagnosticSink, externalSandbox: confinement != nil
        )
        do {
            try await handle.open(clientVersion: configuration.clientVersion)
        } catch {
            await process.stop(grace: configuration.stopGrace)
            throw error
        }
        return handle
    }

    public func reconcile(_ request: ReconcileRequest) async throws -> ReconcileResult {
        .unknown
    }

    /// Reads the signed-in account and its rate limits from the app server, then stops it: no
    /// thread, no turn, no inference. For the owner's acceptance kit and the product preflight.
    public func inspect(scratch: String) async throws -> CodexAccountReport {
        let identity = try await identity.current(configuration.executable, host: host)
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(atPath: configuration.codexHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let spec = AttemptSpec(
            attemptID: AttemptID(), taskID: TaskID(), projectID: ProjectID(), role: .reviewer, provider: .codex, runMode: .automatic,
            modelProfile: "inspect", effectiveModel: "none", workingDirectory: scratch, prompt: ""
        )
        let confinement = configuration.confinement(spec, scratch)
        if confinement == nil, configuration.policy.requiresConfinement { throw ProviderError.confinementRequired }
        let process = try await host.launch(LaunchSpec(
            executable: identity.resolvedPath, arguments: ["app-server", "--listen", "stdio://", "--strict-config"] + Self.baseOverrides,
            workingDirectory: scratch,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": configuration.home, "TMPDIR": scratch, "LANG": "en_US.UTF-8", "CODEX_HOME": configuration.codexHome],
            outputLimit: 64 << 10, stopGrace: configuration.stopGrace, confinement: confinement, streamsOutput: true, interactiveInput: true
        ))
        let connection = JSONRPCConnection(process: process, lineSink: configuration.lineSink)
        await connection.setHandlers(notifications: { _, _ in }, requests: { method, _ in throw JSONRPCConnection.Refusal.unsupported(method) })
        let reader = Task {
            var framer = LineFramer()
            var errors = DiagnosticLines(sink: configuration.diagnosticSink)
            for await chunk in process.output ?? AsyncStream(unfolding: { nil }) {
                switch chunk {
                case .stdout(let data): for line in (try? framer.append(data)) ?? [] { try? await connection.receive(line) }
                case .stderr(let data): errors.append(data)
                }
            }
            errors.finish()
            await connection.close(with: ProviderError.protocolViolation("app server exited"))
        }
        defer { reader.cancel() }
        do {
            _ = try await connection.request("initialize", CodexMessages.initialize(clientVersion: configuration.clientVersion), timeout: configuration.requestTimeout)
            await connection.notify("initialized")
            let account = try await connection.request("account/read", ["refreshToken": false], timeout: configuration.requestTimeout)
            let limits = try? await connection.request("account/rateLimits/read", .null, timeout: configuration.requestTimeout)
            process.closeInput()
            await process.stop(grace: configuration.stopGrace)
            // The reader ends at the pipes' end: all standard error is handed over before returning.
            await reader.value
            return CodexAccountReport(account: account, rateLimits: limits)
        } catch {
            await process.stop(grace: configuration.stopGrace)
            await reader.value
            throw error
        }
    }

    /// Tool processes inherit no environment, only a fixed system `PATH`: Codex runs commands
    /// without the login profile (second live run: `cat` not found, exit 127), so without it
    /// no program is found. Only system folders, never the user's.
    static let baseOverrides = [
        "-c", #"shell_environment_policy.inherit="none""#,
        "-c", #"shell_environment_policy.set.PATH="/usr/bin:/bin:/usr/sbin:/sbin""#,
    ]

    /// The documented provider settings for using the ChatGPT plan through SIWC.
    static func siwcOverrides(baseURL: String) -> [String] {
        [
            "-c", #"model_provider="kaiorx_siwc""#,
            "-c", #"model_providers.kaiorx_siwc.name="KAIORX (ChatGPT plan)""#,
            "-c", "model_providers.kaiorx_siwc.base_url=\"\(baseURL)\"",
            "-c", #"model_providers.kaiorx_siwc.wire_api="responses""#,
            "-c", #"model_providers.kaiorx_siwc.env_key="ACCESS_TOKEN""#,
            "-c", "model_providers.kaiorx_siwc.requires_openai_auth=false",
            "-c", "model_providers.kaiorx_siwc.supports_websockets=false",
        ]
    }
}

/// Messages KAIORX sends, built from the attempt; kept separate for the schema contract test.
enum CodexMessages {
    static func initialize(clientVersion: String) -> JSONValue {
        [
            "clientInfo": ["name": "kaiorx", "title": "KAIORX", "version": .string(clientVersion)],
            "capabilities": ["experimentalApi": false],
        ]
    }

    /// Approval requests always come to KAIORX, never to an AI reviewer from config.
    ///
    /// `externalSandbox`: KAIORX already confines the app server with `sandbox-exec` (ADR 0002).
    /// Codex cannot start its own Seatbelt sandbox inside it (owner's live run, ADR 0008), so it
    /// is told the sandbox is external and asks for every command it does not know to be safe
    /// and for every file change (`untrusted`); the OS confinement enforces the paths.
    static func threadStart(_ spec: AttemptSpec, workingDirectory: String, externalSandbox: Bool = false) -> JSONValue {
        var params: [String: JSONValue] = [
            "cwd": .string(workingDirectory), "model": .string(spec.effectiveModel), "ephemeral": true,
            "approvalPolicy": approvalPolicy(externalSandbox: externalSandbox), "approvalsReviewer": "user",
        ]
        // The thread-level mode has no external variant; the turn sets the sandbox policy.
        if !externalSandbox { params["sandbox"] = spec.role == .author ? "workspace-write" : "read-only" }
        return .object(params)
    }

    static func approvalPolicy(externalSandbox: Bool) -> JSONValue {
        externalSandbox ? "untrusted" : "on-request"
    }

    static func sandboxPolicy(_ spec: AttemptSpec, workingDirectory: String, externalSandbox: Bool) -> JSONValue {
        if externalSandbox { return ["type": "externalSandbox", "networkAccess": "restricted"] }
        // Only the worktree: not /tmp either (TMPDIR is the run's own folder).
        return spec.role == .author
            ? ["type": "workspaceWrite", "writableRoots": [.string(workingDirectory)], "networkAccess": false, "excludeSlashTmp": true]
            : ["type": "readOnly", "networkAccess": false]
    }

    static func turnStart(_ spec: AttemptSpec, threadID: String, workingDirectory: String, externalSandbox: Bool = false) -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID), "cwd": .string(workingDirectory), "model": .string(spec.effectiveModel),
            "input": [["type": "text", "text": .string(spec.prompt)]], "approvalPolicy": approvalPolicy(externalSandbox: externalSandbox),
            "approvalsReviewer": "user",
            "sandboxPolicy": sandboxPolicy(spec, workingDirectory: workingDirectory, externalSandbox: externalSandbox),
        ]
        if let effort = spec.effort { params["effort"] = .string(effort) }
        return .object(params)
    }

    static func turnInterrupt(threadID: String, turnID: String) -> JSONValue {
        ["threadId": .string(threadID), "turnId": .string(turnID)]
    }
}

/// What an approval decision may rely on: this attempt's thread and turn, and the paths of the
/// file changes the server announced in `item/started`.
struct ApprovalContext: Sendable {
    var role: AttemptRole
    var threadID: String?
    var turnID: String?
    var workingDirectory: String
    var writablePaths: [String]?
    var fileChanges: [String: [String]] = [:]
}

/// Approval decisions of the M0 policy (Plan/anbieter.md §2.5).
/// - File changes: authors only, for a change announced in this turn whose every path resolves
///   inside the worktree (and the writable paths), outside Git and agent metadata, and never
///   with an extra write root.
/// - Commands: only reads (ADR 0008, from the owner's live run: Codex reads files only through
///   commands). Accepted when the command itself passes `ReadCommand` (an allowlisted reading
///   program with allowlisted options, every path operand readable inside the worktree), Codex
///   also classifies every action as read, list or search, the working directory is the worktree,
///   no network is asked for, and the request is for a new command (`kind`). Everything else is
///   declined (Git and tests run on the host; writes only as checked file changes).
/// - Extra permissions: none granted.
/// - Requests with missing required fields, for another thread/turn, or of any other kind:
///   refused.
enum CodexApprovals {
    static let protectedComponents: Set<String> = [".git", ".codex", ".agents"]

    static func decide(_ method: String, params: JSONValue, context: ApprovalContext) throws -> (JSONValue, String) {
        switch method {
        case "item/fileChange/requestApproval":
            let decline: (JSONValue, String) = (["decision": "decline"], "file change decline")
            guard refusal(params, required: ["itemId", "threadId", "turnId", "startedAtMs"], context: context) == nil else { return decline }
            guard context.role == .author, (params["grantRoot"] ?? .null).isNull,
                  let item = params["itemId"]?.string, let paths = context.fileChanges[item], !paths.isEmpty,
                  paths.allSatisfy({ allowed($0, context: context) }) else { return decline }
            return (["decision": "accept"], "file change accept")
        case "item/commandExecution/requestApproval":
            let decline: (JSONValue, String) = (["decision": "decline"], "command declined")
            guard refusal(params, required: ["itemId", "threadId", "turnId", "startedAtMs"], context: context) == nil,
                  // Input for a running terminal or a user shell command is never approved.
                  (params["kind"]?.string ?? "command") == "command",
                  (params["networkApprovalContext"] ?? .null).isNull,
                  let command = params["command"]?.string, plain(command), ReadCommand.accepts(command, context: context),
                  let actions = params["commandActions"]?.array, !actions.isEmpty,
                  actions.allSatisfy({ readOnly($0, context: context) }) else { return decline }
            if let cwd = params["cwd"]?.string, Confinement.resolved(cwd) != Confinement.resolved(context.workingDirectory) { return decline }
            return (["decision": "accept"], "read command accept")
        case "item/permissions/requestApproval":
            return (["permissions": [:], "scope": "turn"], "extra permissions refused")
        default:
            throw JSONRPCConnection.Refusal.unsupported(method)
        }
    }

    /// Why a request does not belong to this turn, or `nil`.
    static func refusal(_ params: JSONValue, required: [String], context: ApprovalContext) -> String? {
        for key in required where params[key] == nil { return "missing \(key)" }
        if let thread = context.threadID, params["threadId"]?.string != thread { return "other thread" }
        if let turn = context.turnID, params["turnId"]?.string != turn { return "other turn" }
        return nil
    }

    /// A command without shell operators, substitutions or line breaks (the quoted
    /// `/bin/zsh -lc '…'` wrapper is fine).
    static func plain(_ command: String) -> Bool {
        !command.unicodeScalars.contains { ";|&><$`\\\n\r".unicodeScalars.contains($0) } && command.utf8.count <= 4096
    }

    /// A read, list or search action whose own command is plain and whose path (if any) is
    /// readable inside the worktree.
    static func readOnly(_ action: JSONValue, context: ApprovalContext) -> Bool {
        guard let type = action["type"]?.string, ["read", "listFiles", "search"].contains(type),
              let command = action["command"]?.string, plain(command) else { return false }
        guard let path = action["path"]?.string else { return type != "read" }
        return readable(path, context: context)
    }

    /// Inside the worktree, outside Git and agent metadata, no `..`, no symlink as last part.
    static func readable(_ path: String, context: ApprovalContext) -> Bool {
        var unrestricted = context
        unrestricted.writablePaths = nil
        if path == "." || path == context.workingDirectory { return true }
        return allowed(path, context: unrestricted)
    }

    /// Checks that a path stays in the worktree. No `..` parts at all (they could climb out
    /// through a symlink before being removed textually); the parent folder is resolved with
    /// symlinks; the last part must not itself be a symlink, dangling or not.
    static func allowed(_ path: String, context: ApprovalContext) -> Bool {
        let root = Confinement.resolved(context.workingDirectory)
        let absolute = path.hasPrefix("/") ? path : context.workingDirectory + "/" + path
        let parts = absolute.split(separator: "/")
        guard !parts.contains(".."), let last = parts.last, last != "." else { return false }
        let parent = "/" + parts.dropLast().filter { $0 != "." }.joined(separator: "/")
        let resolvedParent = Confinement.resolved(parent)
        let target = resolvedParent + "/" + last
        var info = stat()
        if lstat(target, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { return false }
        guard target.hasPrefix(root + "/") else { return false }
        let relative = String(target.dropFirst(root.count + 1))
        if relative.split(separator: "/").contains(where: { protectedComponents.contains($0.lowercased()) }) { return false }
        guard let writable = context.writablePaths else { return true }
        return writable.contains { prefix in
            let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed.isEmpty || trimmed == "." || relative == trimmed || relative.hasPrefix(trimmed + "/")
        }
    }
}

final class CodexRunHandle: RunHandle {
    let attemptID: AttemptID
    let events: AsyncThrowingStream<AgentEvent, any Error>
    let connection: JSONRPCConnection
    private let continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation
    private let process: ManagedProcess
    private let spec: AttemptSpec
    private let grace: Duration
    private let timeout: Duration
    private let diagnosticSink: DiagnosticLineSink?
    /// KAIORX confines the process; Codex must not start its own sandbox (see `CodexMessages`).
    private let externalSandbox: Bool
    private let state: Mutex<State>

    private struct State {
        var approval: ApprovalContext
        var completed = false
        var cancelRequested = false
    }

    init(
        spec: AttemptSpec, workingDirectory: String, process: ManagedProcess, grace: Duration, timeout: Duration, recordsTranscript: Bool,
        lineSink: ProtocolLineSink? = nil, diagnosticSink: DiagnosticLineSink? = nil, externalSandbox: Bool = false
    ) {
        self.attemptID = spec.attemptID
        self.diagnosticSink = diagnosticSink
        self.externalSandbox = externalSandbox
        self.spec = spec
        self.process = process
        self.grace = grace
        self.timeout = timeout
        self.state = Mutex(State(approval: ApprovalContext(role: spec.role, workingDirectory: workingDirectory, writablePaths: spec.writablePaths)))
        self.connection = JSONRPCConnection(process: process, recordsTranscript: recordsTranscript, lineSink: lineSink)
        (events, continuation) = AsyncThrowingStream<AgentEvent, any Error>.makeStream()
    }

    var isCompleted: Bool { state.withLock { $0.completed } }

    func open(clientVersion: String) async throws {
        await connection.setHandlers(
            notifications: { [self] method, params in self.handleNotification(method, params) },
            requests: { [self] method, params in
                let context = state.withLock { $0.approval }
                let (result, note) = try CodexApprovals.decide(method, params: params, context: context)
                continuation.yield(.diagnostic(message: "codex approval: \(note)"))
                return result
            }
        )
        startReader()
        let workingDirectory = state.withLock { $0.approval.workingDirectory }
        _ = try await request("initialize", CodexMessages.initialize(clientVersion: clientVersion))
        await connection.notify("initialized")
        let thread = try await request("thread/start", CodexMessages.threadStart(spec, workingDirectory: workingDirectory, externalSandbox: externalSandbox))
        guard let threadID = thread["thread"]?["id"]?.string else { throw ProviderError.protocolViolation("thread/start without thread id") }
        state.withLock { $0.approval.threadID = threadID }
        continuation.yield(.started(sessionID: threadID))

        // From here a turn may run: only a refusal by the server is a safe end; anything else
        // leaves the outcome unknown.
        let turnParams = CodexMessages.turnStart(spec, threadID: threadID, workingDirectory: workingDirectory, externalSandbox: externalSandbox)
        Task { [self] in
            do {
                let turn = try await connection.request("turn/start", turnParams, timeout: timeout)
                guard let turnID = turn["turn"]?["id"]?.string else { throw ProviderError.protocolViolation("turn/start without turn id") }
                let cancelled = state.withLock { state -> Bool in
                    state.approval.turnID = turnID
                    return state.cancelRequested
                }
                if cancelled { await interrupt() }
            } catch let refused as JSONRPCConnection.RemoteError {
                let cancelled = state.withLock { $0.cancelRequested }
                finish(cancelled ? .cancelled : .failed(reason: "turn/start refused: \(refused.message)"))
            } catch {
                abandon("turn/start: \(error)")
            }
        }
    }

    /// Orderly interrupt with a deadline; signals to the process group after it. Repeated and
    /// early calls are allowed.
    func cancel(reason: String) async {
        let turnKnown = state.withLock { state -> Bool in
            state.cancelRequested = true
            return state.approval.turnID != nil
        }
        if turnKnown {
            await interrupt()
        } else {
            // turn/start is still unanswered: wait for it (it interrupts once it knows the turn),
            // then stop the process. The outcome stays unknown unless the server confirms it.
            await waitForCompletion()
            if !isCompleted { await process.stop(grace: grace, interruptFirst: false) }
        }
    }

    /// `turn/interrupt`, then wait for the terminal status; stop the process if none arrives.
    private func interrupt() async {
        guard !isCompleted,
              let (threadID, turnID) = state.withLock({ state in
                  state.approval.threadID.flatMap { thread in state.approval.turnID.map { (thread, $0) } }
              }) else { return }
        let connection = connection
        let timeout = timeout
        Task { _ = try? await connection.request("turn/interrupt", CodexMessages.turnInterrupt(threadID: threadID, turnID: turnID), timeout: timeout) }
        await waitForCompletion()
        // The interrupt was the polite step already: terminate, then kill.
        if !isCompleted { await process.stop(grace: grace, interruptFirst: false) }
    }

    private func waitForCompletion() async {
        let deadline = ContinuousClock.now + grace
        while ContinuousClock.now < deadline, !isCompleted, !process.hasExited {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        do {
            return try await connection.request(method, params, timeout: timeout)
        } catch let error as JSONRPCConnection.RemoteError {
            throw ProviderError.requestFailed(method: method, message: error.message)
        } catch is JSONRPCConnection.Timeout {
            throw ProviderError.requestFailed(method: method, message: "no response within \(timeout)")
        }
    }

    private func startReader() {
        let connection = connection
        let process = process
        let diagnosticSink = diagnosticSink
        Task { [self] in
            var framer = LineFramer()
            var errors = DiagnosticLines(sink: diagnosticSink)
            defer { errors.finish() }
            do {
                for await chunk in process.output ?? AsyncStream(unfolding: { nil }) {
                    switch chunk {
                    case .stdout(let data): for line in try framer.append(data) { try await connection.receive(line) }
                    case .stderr(let data): errors.append(data)
                    }
                }
                errors.finish()
                _ = await process.wait()
                await connection.close(with: ProviderError.protocolViolation("app server exited"))
                if !framer.remainder.isEmpty { throw ProviderError.protocolViolation("stream ended inside a line") }
                // Without a confirmed terminal status the stream ends without one: unknown.
                continuation.finish()
            } catch {
                await connection.close(with: error)
                await process.stop(grace: grace)
                continuation.finish(throwing: error)
            }
        }
    }

    private func finish(_ status: TerminalStatus) {
        let first = state.withLock { state -> Bool in
            defer { state.completed = true }
            return !state.completed
        }
        guard first else { return }
        continuation.yield(.completed(status))
        endProcess()
    }

    /// The protocol left the turn's outcome unknown: stop without a terminal event.
    private func abandon(_ reason: String) {
        continuation.yield(.diagnostic(message: "codex outcome unknown: \(reason)"))
        endProcess()
    }

    /// The server exits when stdin closes; if it does not, it is stopped after the grace period.
    private func endProcess() {
        process.closeInput()
        let process = process
        let grace = grace
        Task {
            try? await Task.sleep(for: grace)
            if !process.hasExited { await process.stop(grace: grace) }
        }
    }

    private func handleNotification(_ method: String, _ params: JSONValue) {
        let context = state.withLock { $0.approval }
        // Only this thread's turn.
        if let thread = params["threadId"]?.string, let threadID = context.threadID, thread != threadID { return }
        if let turn = params["turnId"]?.string, let turnID = context.turnID, turn != turnID { return }
        switch method {
        case "item/agentMessage/delta":
            if let item = params["itemId"]?.string, let delta = params["delta"]?.string {
                continuation.yield(.messageDelta(itemID: item, text: delta))
            }
        case "item/started":
            guard let item = params["item"], let id = item["id"]?.string, let type = item["type"]?.string else { return }
            if type == "fileChange" { recordChanges(item["changes"], for: id) }
            if Self.toolItemTypes.contains(type) { continuation.yield(.toolStarted(itemID: id, toolClass: type)) }
        case "item/fileChange/patchUpdated":
            // A patch can grow after it was announced; the approval must cover every path.
            if let id = params["itemId"]?.string { recordChanges(params["changes"], for: id) }
        case "item/completed":
            guard let item = params["item"], let id = item["id"]?.string, let type = item["type"]?.string else { return }
            if type == "agentMessage" {
                continuation.yield(.messageFinal(itemID: id, text: item["text"]?.string ?? ""))
            } else if Self.toolItemTypes.contains(type) {
                continuation.yield(.toolEnded(itemID: id, status: item["status"]?.string ?? "unknown"))
            }
        case "thread/tokenUsage/updated":
            // Cumulative per thread.
            if let total = params["tokenUsage"]?["total"] {
                continuation.yield(.usage(UsageSample(
                    inputTokens: total["inputTokens"]?.int, outputTokens: total["outputTokens"]?.int,
                    cachedTokens: total["cachedInputTokens"]?.int, cumulative: true
                )))
            }
        case "turn/completed":
            guard let turn = params["turn"] else {
                abandon("turn/completed without turn")
                return
            }
            if let expected = context.turnID, turn["id"]?.string != expected { return }
            switch turn["status"]?.string {
            case "completed": finish(.succeeded)
            case "interrupted": finish(.cancelled)
            case "failed": finish(.failed(reason: turn["error"]?["message"]?.string ?? "turn failed"))
            default: abandon("turn/completed with status \(turn["status"]?.string ?? "nil")")
            }
        case "error":
            let willRetry = params["willRetry"]?.bool ?? false
            continuation.yield(.diagnostic(message: "codex error (retry: \(willRetry)): \(params["error"]?["message"]?.string ?? "")"))
            // A limit Codex does not retry itself blocks the account (ADR 0005 §10). Codex names
            // no Retry-After; the block falls back to the last known reset.
            if !willRetry, let kind = Self.limitKind(params["error"]?["codexErrorInfo"]) {
                continuation.yield(.rateLimited(signal: RateLimitSignal(kind: kind)))
            }
        case "account/rateLimits/updated":
            for signal in Self.quotaSignals(params["rateLimits"]) { continuation.yield(.quotaObserved(signal: signal)) }
        default:
            if !Self.passiveNotifications.contains(method) {
                continuation.yield(.diagnostic(message: "codex notification \(method)"))
            }
        }
    }

    /// Adds the paths of a file change (moves count with both paths); never removes any.
    private func recordChanges(_ changes: JSONValue?, for item: String) {
        let paths = (changes?.array ?? []).flatMap { change in
            [change["path"]?.string, change["kind"]?["move_path"]?.string].compactMap { $0 }
        }
        state.withLock { $0.approval.fileChanges[item, default: []].append(contentsOf: paths) }
    }

    static let toolItemTypes: Set<String> = ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall"]
    static let passiveNotifications: Set<String> = [
        "thread/started", "thread/status/changed", "thread/settings/updated", "turn/started", "turn/diff/updated",
        "turn/plan/updated", "item/reasoning/summaryTextDelta", "item/reasoning/summaryPartAdded", "item/reasoning/textDelta",
        "item/commandExecution/outputDelta", "item/fileChange/outputDelta",
        "serverRequest/resolved", "mcpServer/startupStatus/updated", "skills/changed",
    ]

    /// `usageLimitExceeded` and `rateLimitExceeded`, or an HTTP 429, as a limit; anything else nil.
    static func limitKind(_ info: JSONValue?) -> RateLimitKind? {
        switch info?.string {
        case "usageLimitExceeded": return .usageLimit
        case "rateLimitExceeded": return .rateLimit
        default: break
        }
        // Any HTTP variant (connection failed, stream failed or dropped, retries exhausted) with 429.
        for variant in ["httpConnectionFailed", "responseStreamConnectionFailed", "responseStreamDisconnected", "responseTooManyFailedAttempts"]
        where info?[variant]?["httpStatusCode"]?.int == 429 { return .rateLimit }
        return nil
    }

    /// The primary and secondary windows of a (sparse) `RateLimitSnapshot`, in percent. Missing
    /// windows are skipped, not cleared. `resetsAt` is read as Unix seconds (milliseconds if
    /// already that large).
    static func quotaSignals(_ snapshot: JSONValue?) -> [QuotaSignal] {
        guard let snapshot else { return [] }
        let limit = snapshot["limitId"]?.string ?? "codex"
        return ["primary", "secondary"].compactMap { name in
            guard let window = snapshot[name], let used = window["usedPercent"]?.int else { return nil }
            let reset = window["resetsAt"]?.int.map { Int64($0) }.map { $0 < 100_000_000_000 ? $0 * 1000 : $0 }
            let minutes = window["windowDurationMins"]?.int.map(String.init) ?? "?"
            return QuotaSignal(windowKey: "\(limit):\(name):\(minutes)m", unit: .percent, used: used, limit: 100, resetAt: reset)
        }
    }
}
