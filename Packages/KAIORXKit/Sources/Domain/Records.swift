import Foundation

/// Read models returned by the store. Times are UTC milliseconds.
public struct ProjectRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: ProjectID
    public var name: String
    public var rootLocator: String
    /// Resolved shared Git directory, once the repository is attached.
    public var gitCommonIdentity: String?
    public var objectFormat: String?
    public var createdAt: Int64

    public init(
        id: ProjectID, name: String, rootLocator: String, gitCommonIdentity: String? = nil,
        objectFormat: String? = nil, createdAt: Int64
    ) {
        self.id = id
        self.name = name
        self.rootLocator = rootLocator
        self.gitCommonIdentity = gitCommonIdentity
        self.objectFormat = objectFormat
        self.createdAt = createdAt
    }
}

public struct JobRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: JobID
    public var projectID: ProjectID
    public var goalArtifactID: ArtifactID
    public var state: JobState
    public var stateReason: String?
    /// Stage a side state returns to.
    public var resumeState: JobState?
    /// Commit the job starts from, and the private ref its integrations advance.
    public var baseOID: String?
    public var integrationRef: String?
    public var version: Int
    public var createdAt: Int64

    public init(
        id: JobID, projectID: ProjectID, goalArtifactID: ArtifactID, state: JobState,
        stateReason: String?, resumeState: JobState? = nil, baseOID: String? = nil, integrationRef: String? = nil,
        version: Int, createdAt: Int64
    ) {
        self.baseOID = baseOID
        self.integrationRef = integrationRef
        self.id = id
        self.projectID = projectID
        self.goalArtifactID = goalArtifactID
        self.state = state
        self.stateReason = stateReason
        self.resumeState = resumeState
        self.version = version
        self.createdAt = createdAt
    }
}

public struct TaskRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: TaskID
    public var jobID: JobID
    public var title: String
    public var state: TaskState
    public var currentAttemptID: AttemptID?
    /// Stage a side state returns to.
    public var resumeState: TaskState?
    public var version: Int
    public var createdAt: Int64

    public init(
        id: TaskID, jobID: JobID, title: String, state: TaskState, currentAttemptID: AttemptID?,
        resumeState: TaskState? = nil, version: Int, createdAt: Int64
    ) {
        self.id = id
        self.jobID = jobID
        self.title = title
        self.state = state
        self.currentAttemptID = currentAttemptID
        self.resumeState = resumeState
        self.version = version
        self.createdAt = createdAt
    }
}

public struct AttemptRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: AttemptID
    public var taskID: TaskID
    public var role: AttemptRole
    public var ordinal: Int
    public var provider: ProviderKind
    public var mode: RunMode
    public var model: String
    public var effort: String?
    public var state: AttemptState
    public var specDigest: String
    public var sessionHandle: String?
    public var reservedAt: Int64
    public var startedAt: Int64?
    public var endedAt: Int64?
    public var errorClass: String?
    public var worktreeID: WorktreeID?
    public var version: Int

    public init(
        id: AttemptID, taskID: TaskID, role: AttemptRole, ordinal: Int, provider: ProviderKind,
        mode: RunMode, model: String, effort: String?, state: AttemptState, specDigest: String,
        sessionHandle: String?, reservedAt: Int64, startedAt: Int64?, endedAt: Int64?,
        errorClass: String?, worktreeID: WorktreeID? = nil, version: Int
    ) {
        self.worktreeID = worktreeID
        self.id = id
        self.taskID = taskID
        self.role = role
        self.ordinal = ordinal
        self.provider = provider
        self.mode = mode
        self.model = model
        self.effort = effort
        self.state = state
        self.specDigest = specDigest
        self.sessionHandle = sessionHandle
        self.reservedAt = reservedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.errorClass = errorClass
        self.version = version
    }
}

/// One row of the event journal. `seq` is the replay cursor, `ordinal` orders events within an
/// attempt. `payload` is `nil` once its artifact content has been purged.
public struct EventRecord: Sendable, Equatable, Codable {
    public static let schemaVersion = 1

    public var seq: Int64
    public var eventID: EventID
    public var schemaVersion: Int
    public var projectID: ProjectID
    public var taskID: TaskID?
    public var attemptID: AttemptID?
    public var ordinal: Int?
    public var kind: EventKind
    public var at: Int64
    public var payloadID: ArtifactID?
    public var payload: Data?
    public var dedupKey: String?

    public init(
        seq: Int64, eventID: EventID, schemaVersion: Int, projectID: ProjectID, taskID: TaskID?,
        attemptID: AttemptID?, ordinal: Int?, kind: EventKind, at: Int64, payloadID: ArtifactID?,
        payload: Data?, dedupKey: String?
    ) {
        self.seq = seq
        self.eventID = eventID
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.taskID = taskID
        self.attemptID = attemptID
        self.ordinal = ordinal
        self.kind = kind
        self.at = at
        self.payloadID = payloadID
        self.payload = payload
        self.dedupKey = dedupKey
    }
}
