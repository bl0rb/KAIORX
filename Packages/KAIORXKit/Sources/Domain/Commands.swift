/// A typed write request. Every command carries an idempotency key; the store applies it at most
/// once and answers a repeat with the original result.
public struct Command: Sendable, Codable, Equatable {
    public let id: CommandID
    public let action: CommandAction

    public init(id: CommandID = CommandID(), _ action: CommandAction) {
        self.id = id
        self.action = action
    }
}

public struct AttemptReservation: Sendable, Codable, Equatable {
    public var attemptID: AttemptID
    public var taskID: TaskID
    /// Must match the task's project; the store rejects a mismatch.
    public var projectID: ProjectID
    public var role: AttemptRole
    public var provider: ProviderKind
    public var mode: RunMode
    public var model: String
    public var effort: String?
    public var specDigest: String
    /// The provider account and consent the attempt runs under (package F); counted for its slot.
    public var accountID: AccountID?
    public var consentID: ConsentID?

    public init(
        attemptID: AttemptID, taskID: TaskID, projectID: ProjectID, role: AttemptRole, provider: ProviderKind,
        mode: RunMode, model: String, effort: String? = nil, specDigest: String, accountID: AccountID? = nil, consentID: ConsentID? = nil
    ) {
        self.accountID = accountID
        self.consentID = consentID
        self.attemptID = attemptID
        self.taskID = taskID
        self.projectID = projectID
        self.role = role
        self.provider = provider
        self.mode = mode
        self.model = model
        self.effort = effort
        self.specDigest = specDigest
    }
}

public enum CommandAction: Sendable, Codable, Equatable {
    /// Opens a project folder. Reopening the same root returns the existing project.
    case openProject(id: ProjectID, name: String, rootLocator: String)
    case createJob(id: JobID, projectID: ProjectID, goal: String)
    case createTask(id: TaskID, jobID: JobID, title: String)
    case transitionJob(id: JobID, to: JobState, expectedVersion: Int, reason: String?)
    case transitionTask(id: TaskID, to: TaskState, expectedVersion: Int)
    /// An author attempt needs an active job and a `ready` task, which moves to `running`.
    case reserveAttempt(AttemptReservation)
    case transitionAttempt(id: AttemptID, to: AttemptState, expectedVersion: Int, errorClass: String?)
    /// Records the Git identity of a project folder. A project keeps its first identity; a
    /// different repository at the same folder is refused.
    case attachRepository(projectID: ProjectID, gitCommonIdentity: String, objectFormat: String)

    // Stable JSON key for the persisted request digest instead of the synthesized `_0`.
    enum ReserveAttemptCodingKeys: String, CodingKey { case _0 = "reservation" }

    public var kind: String {
        switch self {
        case .openProject: "openProject"
        case .createJob: "createJob"
        case .createTask: "createTask"
        case .transitionJob: "transitionJob"
        case .transitionTask: "transitionTask"
        case .reserveAttempt: "reserveAttempt"
        case .transitionAttempt: "transitionAttempt"
        case .attachRepository: "attachRepository"
        }
    }
}

public struct CommandOutcome: Sendable, Equatable {
    public let commandID: CommandID
    /// ID of the created or changed object (for `openProject` possibly an existing project).
    public let objectID: String
    /// `true` if the command had already been applied and this is the stored answer.
    public let isReplay: Bool

    public init(commandID: CommandID, objectID: String, isReplay: Bool) {
        self.commandID = commandID
        self.objectID = objectID
        self.isReplay = isReplay
    }
}
