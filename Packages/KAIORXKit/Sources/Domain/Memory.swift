import Foundation

/// Package G (ADR 0006): values of local project memory.

public enum MemoryEntryTag {}
public enum MemoryRevisionTag {}
public enum MemorySourceTag {}
public enum MemoryEdgeTag {}
public enum MemoryGrantTag {}
public enum MemoryManifestTag {}
public enum PurgeJobTag {}
public typealias MemoryEntryID = TypedID<MemoryEntryTag>
public typealias MemoryRevisionID = TypedID<MemoryRevisionTag>
public typealias MemorySourceID = TypedID<MemorySourceTag>
public typealias MemoryEdgeID = TypedID<MemoryEdgeTag>
public typealias MemoryGrantID = TypedID<MemoryGrantTag>
public typealias MemoryManifestID = TypedID<MemoryManifestTag>
public typealias PurgeJobID = TypedID<PurgeJobTag>

public enum MemoryScope: String, Sendable, Codable, CaseIterable, Hashable, Comparable {
    case task, project, global

    /// Task before project before global (tie-break of the selection).
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    var rank: Int { switch self { case .task: 0; case .project: 1; case .global: 2 } }
}

public enum MemoryKind: String, Sendable, Codable, CaseIterable, Hashable {
    case preference, decision, observation, convention
}

public enum MemoryRevisionState: String, Sendable, Codable, CaseIterable, Hashable {
    case proposed, active, retired, rejected
}

public enum MemoryAuthorKind: String, Sendable, Codable, Hashable {
    /// Written by the user.
    case user
    /// Proposed from a run, diff or review and confirmed by the user.
    case proposal
}

public enum MemorySourceKind: String, Sendable, Codable, CaseIterable, Hashable {
    case user, git, test, review, derived
}

public enum MemoryEdgeType: String, Sendable, Codable, CaseIterable, Hashable {
    case dependsOn = "depends_on", verifies, contradicts, relatedTo = "related_to"

    /// `related_to` and `contradicts` read the same in both directions.
    public var isSymmetric: Bool { self == .contradicts || self == .relatedTo }
}

public enum ManifestDelivery: String, Sendable, Codable, Hashable {
    case prepared, dispatched, manual, revoked
}

public enum SelectionReason: String, Sendable, Codable, Hashable {
    case pin, lexical, graph
}

/// One piece of evidence for a revision.
public struct MemorySourceDraft: Sendable, Codable, Equatable, Hashable {
    public var kind: MemorySourceKind
    public var observedAt: Int64
    /// Relative path (git) or artifact reference; never an absolute home path.
    public var locator: String?
    public var gitOID: String?
    public var blobOID: String?
    public var byteFrom: Int?
    public var byteTo: Int?
    public var sourceDigest: String?
    public var originProjectID: ProjectID?
    public var originTaskID: TaskID?
    public var attemptID: AttemptID?
    public var eventSeq: Int64?
    public var upstreamRevisionID: MemoryRevisionID?

    public init(
        kind: MemorySourceKind, observedAt: Int64, locator: String? = nil, gitOID: String? = nil, blobOID: String? = nil,
        byteFrom: Int? = nil, byteTo: Int? = nil, sourceDigest: String? = nil, originProjectID: ProjectID? = nil,
        originTaskID: TaskID? = nil, attemptID: AttemptID? = nil, eventSeq: Int64? = nil, upstreamRevisionID: MemoryRevisionID? = nil
    ) {
        self.kind = kind
        self.observedAt = observedAt
        self.locator = locator
        self.gitOID = gitOID
        self.blobOID = blobOID
        self.byteFrom = byteFrom
        self.byteTo = byteTo
        self.sourceDigest = sourceDigest
        self.originProjectID = originProjectID
        self.originTaskID = originTaskID
        self.attemptID = attemptID
        self.eventSeq = eventSeq
        self.upstreamRevisionID = upstreamRevisionID
    }

    public static func user(at time: Int64) -> MemorySourceDraft { MemorySourceDraft(kind: .user, observedAt: time) }
}

public struct MemoryDraft: Sendable, Codable, Equatable {
    public var scope: MemoryScope
    public var projectID: ProjectID?
    public var taskID: TaskID?
    public var title: String
    public var body: String
    public var kind: MemoryKind
    public var sources: [MemorySourceDraft]
    /// `user`: the user wrote it and it is active at once; `proposal`: lands in the inbox.
    public var author: MemoryAuthorKind
    public var pinned: Bool
    public var validUntil: Int64?

    public init(
        scope: MemoryScope, projectID: ProjectID? = nil, taskID: TaskID? = nil, title: String, body: String, kind: MemoryKind = .observation,
        sources: [MemorySourceDraft], author: MemoryAuthorKind = .user, pinned: Bool = false, validUntil: Int64? = nil
    ) {
        self.scope = scope
        self.projectID = projectID
        self.taskID = taskID
        self.title = title
        self.body = body
        self.kind = kind
        self.sources = sources
        self.author = author
        self.pinned = pinned
        self.validUntil = validUntil
    }
}

public struct MemoryRevisionRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: MemoryRevisionID
    public var entryID: MemoryEntryID
    public var scope: MemoryScope
    public var projectID: ProjectID?
    public var taskID: TaskID?
    public var number: Int
    public var previousID: MemoryRevisionID?
    public var title: String
    public var body: String
    public var kind: MemoryKind
    public var state: MemoryRevisionState
    public var author: MemoryAuthorKind
    public var createdAt: Int64
    public var confirmedAt: Int64?
    public var validUntil: Int64?
    public var contentDigest: String

    public init(
        id: MemoryRevisionID, entryID: MemoryEntryID, scope: MemoryScope, projectID: ProjectID?, taskID: TaskID?, number: Int,
        previousID: MemoryRevisionID?, title: String, body: String, kind: MemoryKind, state: MemoryRevisionState, author: MemoryAuthorKind,
        createdAt: Int64, confirmedAt: Int64?, validUntil: Int64?, contentDigest: String
    ) {
        self.id = id
        self.entryID = entryID
        self.scope = scope
        self.projectID = projectID
        self.taskID = taskID
        self.number = number
        self.previousID = previousID
        self.title = title
        self.body = body
        self.kind = kind
        self.state = state
        self.author = author
        self.createdAt = createdAt
        self.confirmedAt = confirmedAt
        self.validUntil = validUntil
        self.contentDigest = contentDigest
    }
}

public struct MemorySourceRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: MemorySourceID
    public var revisionID: MemoryRevisionID
    public var draft: MemorySourceDraft

    public init(id: MemorySourceID, revisionID: MemoryRevisionID, draft: MemorySourceDraft) {
        self.id = id
        self.revisionID = revisionID
        self.draft = draft
    }
}

public struct MemoryEdgeRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: MemoryEdgeID
    public var from: MemoryRevisionID
    public var to: MemoryRevisionID
    public var type: MemoryEdgeType
    public var evidence: MemorySourceID

    public init(id: MemoryEdgeID, from: MemoryRevisionID, to: MemoryRevisionID, type: MemoryEdgeType, evidence: MemorySourceID) {
        self.id = id
        self.from = from
        self.to = to
        self.type = type
        self.evidence = evidence
    }
}

public struct MemoryGrantRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: MemoryGrantID
    public var revisionID: MemoryRevisionID
    public var targetProjectID: ProjectID
    public var provider: ProviderKind
    public var grantedAt: Int64
    public var revokedAt: Int64?

    public init(id: MemoryGrantID, revisionID: MemoryRevisionID, targetProjectID: ProjectID, provider: ProviderKind, grantedAt: Int64, revokedAt: Int64?) {
        self.id = id
        self.revisionID = revisionID
        self.targetProjectID = targetProjectID
        self.provider = provider
        self.grantedAt = grantedAt
        self.revokedAt = revokedAt
    }
}

public struct ManifestItemRecord: Sendable, Codable, Equatable {
    public var position: Int
    public var revisionID: MemoryRevisionID
    public var byteFrom: Int
    public var byteTo: Int
    public var excerptDigest: String
    public var tokenEstimate: Int
    public var reason: SelectionReason
    public var rank: Int

    public init(position: Int, revisionID: MemoryRevisionID, byteFrom: Int, byteTo: Int, excerptDigest: String, tokenEstimate: Int, reason: SelectionReason, rank: Int) {
        self.position = position
        self.revisionID = revisionID
        self.byteFrom = byteFrom
        self.byteTo = byteTo
        self.excerptDigest = excerptDigest
        self.tokenEstimate = tokenEstimate
        self.reason = reason
        self.rank = rank
    }
}

public struct ManifestRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: MemoryManifestID
    public var attemptID: AttemptID
    public var provider: ProviderKind
    public var reviewerProvider: ProviderKind?
    public var policyVersion: Int
    public var retrieverVersion: Int
    public var baseOID: String?
    public var delivery: ManifestDelivery
    public var tokenEstimate: Int
    public var revokedReason: String?
    public var items: [ManifestItemRecord]

    public init(
        id: MemoryManifestID, attemptID: AttemptID, provider: ProviderKind, reviewerProvider: ProviderKind?, policyVersion: Int,
        retrieverVersion: Int, baseOID: String?, delivery: ManifestDelivery, tokenEstimate: Int, revokedReason: String?, items: [ManifestItemRecord]
    ) {
        self.id = id
        self.attemptID = attemptID
        self.provider = provider
        self.reviewerProvider = reviewerProvider
        self.policyVersion = policyVersion
        self.retrieverVersion = retrieverVersion
        self.baseOID = baseOID
        self.delivery = delivery
        self.tokenEstimate = tokenEstimate
        self.revokedReason = revokedReason
        self.items = items
    }
}
