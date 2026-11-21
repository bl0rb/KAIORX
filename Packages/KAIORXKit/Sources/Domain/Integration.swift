public enum CandidateTag {}
public enum TestResultTag {}
public enum ReviewTag {}
public enum FindingTag {}
public enum ApprovalTag {}
public typealias CandidateID = TypedID<CandidateTag>
public typealias TestResultID = TypedID<TestResultTag>
public typealias ReviewID = TypedID<ReviewTag>
public typealias FindingID = TypedID<FindingTag>
public typealias ApprovalID = TypedID<ApprovalTag>

/// Integration candidate (Plan/laufzeitvertrag.md): `built → testing → reviewing → accepted →
/// publishing → published`. Findings, failed checks, a moved target or changed content end it as
/// `rejected` or `superseded`; a correction is a new candidate with new evidence. `conflicted`
/// precedes `built` while a merge waits for the user's resolution.
public enum CandidateState: String, LifecycleState {
    case conflicted, built, testing, reviewing, accepted, publishing, published, rejected, superseded

    public static let entityName = "candidate"

    public var isTerminal: Bool {
        switch self {
        case .published, .rejected, .superseded: true
        default: false
        }
    }

    public var successors: Set<CandidateState> {
        switch self {
        case .conflicted: [.built, .rejected, .superseded]
        case .built: [.testing, .rejected, .superseded]
        case .testing: [.reviewing, .built, .rejected, .superseded]
        case .reviewing: [.accepted, .rejected, .superseded]
        // New evidence after acceptance (a late review, a reopened finding) needs a new look.
        case .accepted: [.publishing, .reviewing, .rejected, .superseded]
        // A failed compare-and-swap supersedes; an unclear one waits for recovery.
        case .publishing: [.published, .superseded, .accepted]
        case .published, .rejected, .superseded: []
        }
    }
}

public enum CandidateKind: String, Sendable, Codable, CaseIterable {
    /// Merges an attempt's result into the integration target.
    case implementation
    /// Reverts an earlier published candidate (first parent as mainline).
    case revert
}

/// Distinct outcomes: infrastructure, stopped, red and changed inputs are not the same.
public enum TestStatus: String, Sendable, Codable, CaseIterable {
    case passed, failed, crashed, timedOut, inputsModified, infrastructureError
}

public enum ReviewOrigin: String, Sendable, Codable, CaseIterable {
    /// A reviewer attempt at a provider, through the adapter protocol.
    case provider
    /// A review the user ran elsewhere and imported; shown as such.
    case userImported
}

public enum ReviewStatus: String, Sendable, Codable, CaseIterable {
    case approved, changesRequested
    /// The report did not name this candidate's OID or could not be read.
    case invalid
}

public enum FindingSeverity: String, Sendable, Codable, CaseIterable {
    /// Prevents publication until fixed in a new candidate.
    case blocking
    case major, minor
    /// Free text without a valid location.
    case comment

    /// Needs an explicit decision before publication.
    public var needsDecision: Bool { self == .major || self == .minor }
}

public enum FindingDisposition: String, Sendable, Codable, CaseIterable {
    case open
    /// Accepted with a reason; does not block.
    case accepted
    case rejected
}

public enum ApprovalAction: String, Sendable, Codable, CaseIterable {
    case publishIntegration
}

public enum ApprovalState: String, Sendable, Codable, CaseIterable {
    case granted, consumed, revoked
}

public struct CandidateRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: CandidateID
    public var projectID: ProjectID
    public var jobID: JobID
    public var taskID: TaskID?
    public var kind: CandidateKind
    public var authorAttemptID: AttemptID?
    /// Provider of the author attempt; the reviewer must be a different one.
    public var authorProvider: ProviderKind?
    public var resultOID: String?
    public var revertsCandidateID: CandidateID?
    /// Integration target the candidate was built on (first parent).
    public var previousTargetOID: String
    /// `nil` while conflicted.
    public var candidateOID: String?
    public var targetRef: String
    public var worktreeID: WorktreeID?
    public var state: CandidateState
    /// Conflicting paths while `conflicted` (JSON in the store).
    public var conflicts: [String]
    public var version: Int
    public var createdAt: Int64

    public init(
        id: CandidateID, projectID: ProjectID, jobID: JobID, taskID: TaskID?, kind: CandidateKind, authorAttemptID: AttemptID?,
        authorProvider: ProviderKind?, resultOID: String?, revertsCandidateID: CandidateID?, previousTargetOID: String,
        candidateOID: String?, targetRef: String, worktreeID: WorktreeID?, state: CandidateState, conflicts: [String],
        version: Int, createdAt: Int64
    ) {
        self.id = id
        self.projectID = projectID
        self.jobID = jobID
        self.taskID = taskID
        self.kind = kind
        self.authorAttemptID = authorAttemptID
        self.authorProvider = authorProvider
        self.resultOID = resultOID
        self.revertsCandidateID = revertsCandidateID
        self.previousTargetOID = previousTargetOID
        self.candidateOID = candidateOID
        self.targetRef = targetRef
        self.worktreeID = worktreeID
        self.state = state
        self.conflicts = conflicts
        self.version = version
        self.createdAt = createdAt
    }
}

public struct TestResultRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: TestResultID
    public var candidateID: CandidateID
    public var candidateOID: String
    public var profileDigest: String
    public var status: TestStatus
    public var exitCode: Int?
    /// Paths of tests, fixtures or build scripts the candidate changes: shown for review.
    public var changedTestInputs: [String]
    public var summary: String
    public var at: Int64

    public init(id: TestResultID, candidateID: CandidateID, candidateOID: String, profileDigest: String, status: TestStatus, exitCode: Int? = nil, changedTestInputs: [String], summary: String, at: Int64) {
        self.id = id
        self.candidateID = candidateID
        self.candidateOID = candidateOID
        self.profileDigest = profileDigest
        self.status = status
        self.exitCode = exitCode
        self.changedTestInputs = changedTestInputs
        self.summary = summary
        self.at = at
    }
}

public struct ReviewRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: ReviewID
    public var candidateID: CandidateID
    public var candidateOID: String
    public var reviewerAttemptID: AttemptID?
    public var origin: ReviewOrigin
    public var reviewerProvider: ProviderKind?
    public var status: ReviewStatus
    public var summary: String
    public var at: Int64

    public init(id: ReviewID, candidateID: CandidateID, candidateOID: String, reviewerAttemptID: AttemptID? = nil, origin: ReviewOrigin, reviewerProvider: ProviderKind? = nil, status: ReviewStatus, summary: String, at: Int64) {
        self.id = id
        self.candidateID = candidateID
        self.candidateOID = candidateOID
        self.reviewerAttemptID = reviewerAttemptID
        self.origin = origin
        self.reviewerProvider = reviewerProvider
        self.status = status
        self.summary = summary
        self.at = at
    }
}

public struct FindingRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: FindingID
    public var reviewID: ReviewID
    public var severity: FindingSeverity
    public var path: String?
    public var line: Int?
    public var impact: String
    public var suggestion: String
    public var disposition: FindingDisposition
    public var reason: String?

    public init(id: FindingID, reviewID: ReviewID, severity: FindingSeverity, path: String? = nil, line: Int? = nil, impact: String, suggestion: String, disposition: FindingDisposition, reason: String? = nil) {
        self.id = id
        self.reviewID = reviewID
        self.severity = severity
        self.path = path
        self.line = line
        self.impact = impact
        self.suggestion = suggestion
        self.disposition = disposition
        self.reason = reason
    }
}

public struct ApprovalRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: ApprovalID
    public var candidateID: CandidateID
    /// The exact commit the user approved.
    public var candidateOID: String
    /// The target state the approval assumes; publication refuses any other.
    public var expectedOldOID: String
    public var targetRef: String
    public var action: ApprovalAction
    public var policyVersion: Int
    public var actor: String
    public var state: ApprovalState
    public var grantedAt: Int64
    public var resolvedAt: Int64?
    /// After this time the approval no longer allows publication (nil: rows from before v8).
    public var expiresAt: Int64?

    public init(id: ApprovalID, candidateID: CandidateID, candidateOID: String, expectedOldOID: String, targetRef: String, action: ApprovalAction, policyVersion: Int, actor: String, state: ApprovalState, grantedAt: Int64, resolvedAt: Int64? = nil, expiresAt: Int64? = nil) {
        self.id = id
        self.candidateID = candidateID
        self.candidateOID = candidateOID
        self.expectedOldOID = expectedOldOID
        self.targetRef = targetRef
        self.action = action
        self.policyVersion = policyVersion
        self.actor = actor
        self.state = state
        self.grantedAt = grantedAt
        self.resolvedAt = resolvedAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at time: Int64) -> Bool { expiresAt.map { time >= $0 } ?? false }
}

extension EventKind {
    public static let candidateBuilt: EventKind = "candidate.built"
    public static let candidateStateChanged: EventKind = "candidate.stateChanged"
    public static let testFinished: EventKind = "test.finished"
    public static let reviewFinished: EventKind = "review.finished"
    public static let findingDecided: EventKind = "finding.decided"
    public static let approvalResolved: EventKind = "approval.resolved"
    public static let integrationApplied: EventKind = "integration.applied"
}
