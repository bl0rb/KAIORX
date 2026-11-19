/// A worktree KAIORX created. `uncertain`-like problems end in `needsAttention`; only an explicit
/// decision moves on from there.
public enum WorktreeState: String, LifecycleState {
    case preparing, ready, frozen, removing, removed, needsAttention

    public static let entityName = "worktree"

    public var isTerminal: Bool { self == .removed }

    public var successors: Set<WorktreeState> {
        switch self {
        case .preparing: [.ready, .removed, .needsAttention]
        case .ready: [.frozen, .removing, .needsAttention]
        case .frozen: [.removing, .needsAttention]
        case .removing: [.removed, .needsAttention]
        case .needsAttention: [.ready, .frozen, .removing, .removed]
        case .removed: []
        }
    }
}

public enum SealStatus: String, Sendable, Codable, CaseIterable {
    /// Accepted changes were committed under a result ref.
    case committed
    /// The attempt changed nothing.
    case empty
    /// Every change was rejected (outside the allowed paths, links, Git metadata, conflicts).
    case rejectedOnly
}

public enum WorktreeKind: String, Sendable, Codable, CaseIterable {
    /// One writer: the author attempt.
    case author
    /// Read-only, frozen state for a reviewer.
    case reviewer
    /// Disposable checkout of a commit for a test run.
    case qa
    case integration
}

public struct WorktreeRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: WorktreeID
    public var projectID: ProjectID
    public var attemptID: AttemptID?
    /// `<project>/<worktree>` below the worktrees folder.
    public var pathToken: String
    public var baseOID: String
    public var kind: WorktreeKind
    /// Random per worktree; part of the Git lock reason that proves ownership.
    public var ownerNonce: String
    public var state: WorktreeState
    public var resultOID: String?
    /// Tree of the sealed result (or base); removal checks for changes beyond it.
    public var savedTree: String?
    public var sealStatus: SealStatus?
    /// Rejected paths and why, recorded when sealing.
    public var rejectedPaths: [String: String]
    public var version: Int
    public var createdAt: Int64

    public init(
        id: WorktreeID, projectID: ProjectID, attemptID: AttemptID?, pathToken: String, baseOID: String,
        kind: WorktreeKind, ownerNonce: String, state: WorktreeState, resultOID: String?, savedTree: String?,
        sealStatus: SealStatus? = nil, rejectedPaths: [String: String] = [:], version: Int, createdAt: Int64
    ) {
        self.sealStatus = sealStatus
        self.rejectedPaths = rejectedPaths
        self.id = id
        self.projectID = projectID
        self.attemptID = attemptID
        self.pathToken = pathToken
        self.baseOID = baseOID
        self.kind = kind
        self.ownerNonce = ownerNonce
        self.state = state
        self.resultOID = resultOID
        self.savedTree = savedTree
        self.version = version
        self.createdAt = createdAt
    }

    public var lockReason: String { "kaiorx:\(id.uuidString):\(ownerNonce)" }
}

public enum GitOperationKind: String, Sendable, Codable, CaseIterable {
    case updateRef, addWorktree, removeWorktree
}

public enum GitOperationState: String, Sendable, Codable, CaseIterable {
    /// Journaled before the side effect; recovery decides what happened.
    case prepared, applied, failed, needsAttention
}

/// Journal entry written (and committed) before a Git side effect.
public struct GitOperationRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: GitOperationID
    public var projectID: ProjectID
    public var worktreeID: WorktreeID?
    public var kind: GitOperationKind
    public var ref: String?
    /// `nil` for a create-only ref update.
    public var expectedOld: String?
    public var desiredNew: String?
    public var state: GitOperationState
    public var detail: String?
    /// For removals: decided without the unsaved-work check.
    public var force: Bool
    public var createdAt: Int64
    public var appliedAt: Int64?

    public init(
        id: GitOperationID, projectID: ProjectID, worktreeID: WorktreeID?, kind: GitOperationKind, ref: String?,
        expectedOld: String?, desiredNew: String?, state: GitOperationState, detail: String?, force: Bool = false,
        createdAt: Int64, appliedAt: Int64?
    ) {
        self.force = force
        self.id = id
        self.projectID = projectID
        self.worktreeID = worktreeID
        self.kind = kind
        self.ref = ref
        self.expectedOld = expectedOld
        self.desiredNew = desiredNew
        self.state = state
        self.detail = detail
        self.createdAt = createdAt
        self.appliedAt = appliedAt
    }
}

extension EventKind {
    public static let repositoryAttached: EventKind = "project.repositoryAttached"
    public static let worktreeStateChanged: EventKind = "worktree.stateChanged"
    public static let gitOperationPrepared: EventKind = "git.operationPrepared"
    public static let gitOperationCompleted: EventKind = "git.operationCompleted"
}
