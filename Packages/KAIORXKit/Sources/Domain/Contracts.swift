import Foundation

public enum ProviderKind: String, Sendable, Codable, CaseIterable, Hashable {
    case claude, codex
    /// Deterministic test double; never talks to a model.
    case fake
}

public enum AttemptRole: String, Sendable, Codable, CaseIterable, Hashable {
    case author, reviewer
}

public enum RunMode: String, Sendable, Codable, CaseIterable, Hashable {
    /// The host drives the provider process.
    case automatic
    /// The user runs the original CLI; KAIORX only manages the handover.
    case manual
}

public enum TerminalStatus: Sendable, Codable, Equatable {
    case succeeded
    case failed(reason: String)
    case cancelled

    public var attemptState: AttemptState {
        switch self {
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}

/// Token counts as reported by the provider. Missing values stay `nil`; nothing is estimated.
public struct UsageSample: Sendable, Codable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedTokens: Int?
    /// `true` if the provider reports running totals instead of deltas.
    public var cumulative: Bool

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cachedTokens: Int? = nil, cumulative: Bool = false) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.cumulative = cumulative
    }
}

/// Provider-neutral event emitted by an adapter. Provider wire objects stay inside the adapter.
public enum AgentEvent: Sendable, Codable, Equatable {
    case started(sessionID: String?)
    case messageDelta(itemID: String, text: String)
    case messageFinal(itemID: String, text: String)
    case toolStarted(itemID: String, toolClass: String)
    case toolEnded(itemID: String, status: String)
    case usage(UsageSample)
    /// A passive provider notification the adapter does not understand (type and version only).
    case diagnostic(message: String)
    /// The provider refused for a rate or usage limit (package F): the account is blocked.
    case rateLimited(signal: RateLimitSignal)
    /// A provider quota window as reported (package F).
    case quotaObserved(signal: QuotaSignal)
    case completed(TerminalStatus)

    // Stable JSON keys for the persisted journal instead of the synthesized `_0`.
    enum UsageCodingKeys: String, CodingKey { case _0 = "sample" }
    enum CompletedCodingKeys: String, CodingKey { case _0 = "status" }

    public var kind: EventKind {
        switch self {
        case .started: .attemptStarted
        case .messageDelta: .messageDelta
        case .messageFinal: .messageFinal
        case .toolStarted: .toolStarted
        case .toolEnded: .toolEnded
        case .usage: .usageObserved
        case .diagnostic: .providerDiagnostic
        case .rateLimited: .quotaBlocked
        case .quotaObserved: .quotaObserved
        case .completed: .attemptCompleted
        }
    }
}

/// Fully validated input for `AgentAdapter.start`. Package B subset of the contract's AttemptSpec:
/// consent, policy, budget reservation, worktree and memory manifest arrive with packages A, C, F
/// and G.
public struct AttemptSpec: Sendable, Codable, Equatable {
    public var attemptID: AttemptID
    public var taskID: TaskID
    public var projectID: ProjectID
    public var role: AttemptRole
    public var provider: ProviderKind
    public var runMode: RunMode
    public var modelProfile: String
    public var effectiveModel: String
    public var effort: String?
    public var workingDirectory: String?
    /// Paths (relative to the working directory) an author may write; `nil`: the whole
    /// working directory.
    public var writablePaths: [String]?
    public var deadline: Int64?
    public var prompt: String
    /// The memory manifest whose rendered context is appended at start (ADR 0006 §6); the spec
    /// digest covers this ID, not the rendered text.
    public var memoryManifestID: MemoryManifestID?

    public init(
        attemptID: AttemptID, taskID: TaskID, projectID: ProjectID, role: AttemptRole,
        provider: ProviderKind, runMode: RunMode, modelProfile: String, effectiveModel: String,
        effort: String? = nil, workingDirectory: String? = nil, writablePaths: [String]? = nil, deadline: Int64? = nil,
        prompt: String
    ) {
        self.writablePaths = writablePaths
        self.attemptID = attemptID
        self.taskID = taskID
        self.projectID = projectID
        self.role = role
        self.provider = provider
        self.runMode = runMode
        self.modelProfile = modelProfile
        self.effectiveModel = effectiveModel
        self.effort = effort
        self.workingDirectory = workingDirectory
        self.deadline = deadline
        self.prompt = prompt
    }

    public func digest() throws -> String {
        try Canonical.sha256Hex(Canonical.encode(self))
    }
}

public struct ProbeRequest: Sendable, Equatable {
    public var binaryPath: String?
    public var profile: String
    public var mode: RunMode

    public init(binaryPath: String? = nil, profile: String, mode: RunMode) {
        self.binaryPath = binaryPath
        self.profile = profile
        self.mode = mode
    }
}

public enum AuthState: String, Sendable, Codable {
    case signedIn, signedOut, unknown
}

/// Result of a probe. A version probe consumes no inference.
public struct CapabilitySnapshot: Sendable, Codable, Equatable {
    public var provider: ProviderKind
    public var binaryVersion: String
    public var authState: AuthState
    public var planMode: String?
    public var runModes: [RunMode]
    public var roles: [AttemptRole]
    public var supportsStreaming: Bool
    public var supportsUsage: Bool
    public var supportsApprovals: Bool
    public var supportsResume: Bool

    public init(
        provider: ProviderKind, binaryVersion: String, authState: AuthState, planMode: String?,
        runModes: [RunMode], roles: [AttemptRole], supportsStreaming: Bool, supportsUsage: Bool,
        supportsApprovals: Bool, supportsResume: Bool
    ) {
        self.provider = provider
        self.binaryVersion = binaryVersion
        self.authState = authState
        self.planMode = planMode
        self.runModes = runModes
        self.roles = roles
        self.supportsStreaming = supportsStreaming
        self.supportsUsage = supportsUsage
        self.supportsApprovals = supportsApprovals
        self.supportsResume = supportsResume
    }
}

public struct ReconcileRequest: Sendable, Equatable {
    public var attemptID: AttemptID
    public var lastKnownState: AttemptState
    public var sessionHandle: String?

    public init(attemptID: AttemptID, lastKnownState: AttemptState, sessionHandle: String?) {
        self.attemptID = attemptID
        self.lastKnownState = lastKnownState
        self.sessionHandle = sessionHandle
    }
}

public enum ReconcileResult: Sendable, Equatable {
    case terminal(TerminalStatus)
    case active
    case interrupted
    case unknown
}
