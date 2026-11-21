import Foundation

/// Package F values shared by store, scheduler and adapters (ADR 0005).

public enum RateLimitKind: String, Sendable, Codable, Hashable {
    /// Requests too fast (`429`).
    case rateLimit
    /// Plan or credit usage exhausted.
    case usageLimit
}

public struct RateLimitSignal: Sendable, Codable, Equatable, Hashable {
    public var kind: RateLimitKind
    public var retryAfterMs: Int64?
    /// UTC milliseconds.
    public var resetAt: Int64?

    public init(kind: RateLimitKind, retryAfterMs: Int64? = nil, resetAt: Int64? = nil) {
        self.kind = kind
        self.retryAfterMs = retryAfterMs
        self.resetAt = resetAt
    }
}

public enum QuotaUnit: String, Sendable, Codable, Hashable {
    case percent, requests, tokens
}

public struct QuotaSignal: Sendable, Codable, Equatable, Hashable {
    public var windowKey: String
    public var unit: QuotaUnit
    public var used: Int?
    public var limit: Int?
    public var resetAt: Int64?

    public init(windowKey: String, unit: QuotaUnit, used: Int?, limit: Int?, resetAt: Int64?) {
        self.windowKey = windowKey
        self.unit = unit
        self.used = used
        self.limit = limit
        self.resetAt = resetAt
    }

    /// Used share in percent, if known.
    public var usedPercent: Int? {
        switch unit {
        case .percent: used
        case .requests, .tokens:
            if let used, let limit, limit > 0 { used * 100 / limit } else { nil }
        }
    }
}

/// Why a ready task is not started. Stored as `kind` or `kind:detail` in `task.wait_reason`.
public struct WaitReason: Sendable, Codable, Equatable, Hashable, CustomStringConvertible {
    public var kind: Kind
    public var detail: String?

    public enum Kind: String, Sendable, Codable, Hashable {
        case slot, writeArea, consent, quota, budget, profileMissing, noIndependentReviewer
        case predecessorEnded, predecessorReverted, awaitingUserStart, userDecision, retryLater, capability
    }

    public init(_ kind: Kind, _ detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }

    public var description: String { detail.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue }

    public init?(stored: String) {
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, let kind = Kind(rawValue: first) else { return nil }
        self.init(kind, parts.count > 1 ? parts[1] : nil)
    }
}

/// Concurrency limits (product settings; ADR 0005 §6).
public struct SchedulerLimits: Sendable, Codable, Equatable {
    public var global: Int
    public var perAccount: Int
    /// Share of a known quota window from which no parallel reservation is made.
    public var warnPercent: Int

    public init(global: Int = 2, perAccount: Int = 1, warnPercent: Int = 80) {
        self.global = global
        self.perAccount = perAccount
        self.warnPercent = warnPercent
    }
}

public struct ConsentDraft: Sendable, Codable, Equatable {
    public var projectID: ProjectID
    public var jobID: JobID?
    public var provider: ProviderKind
    public var accountID: AccountID
    public var mode: RunMode
    public var roles: [AttemptRole]
    /// Relative path prefixes the provider may write; `""` is the whole project.
    public var writeRoots: [String]
    /// Roots for sensitive tasks (security, migration, data loss, authentication).
    public var sensitiveRoots: [String]
    /// Attempts allowed while the quota is unknown; nil allows none.
    public var unconfirmedAttemptLimit: Int?
    public var expiresAt: Int64?

    public init(
        projectID: ProjectID, jobID: JobID? = nil, provider: ProviderKind, accountID: AccountID, mode: RunMode = .automatic,
        roles: [AttemptRole] = [.author, .reviewer], writeRoots: [String], sensitiveRoots: [String] = [],
        unconfirmedAttemptLimit: Int? = nil, expiresAt: Int64? = nil
    ) {
        self.projectID = projectID
        self.jobID = jobID
        self.provider = provider
        self.accountID = accountID
        self.mode = mode
        self.roles = roles
        self.writeRoots = writeRoots
        self.sensitiveRoots = sensitiveRoots
        self.unconfirmedAttemptLimit = unconfirmedAttemptLimit
        self.expiresAt = expiresAt
    }

    public func scopeDigest() throws -> String { Canonical.sha256Hex(try Canonical.encode(self)) }
}

public struct ConsentRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: ConsentID
    public var draft: ConsentDraft
    public var scopeDigest: String
    public var grantedAt: Int64
    public var revokedAt: Int64?

    public init(id: ConsentID, draft: ConsentDraft, scopeDigest: String, grantedAt: Int64, revokedAt: Int64?) {
        self.id = id
        self.draft = draft
        self.scopeDigest = scopeDigest
        self.grantedAt = grantedAt
        self.revokedAt = revokedAt
    }

    public func isValid(at now: Int64) -> Bool { revokedAt == nil && (draft.expiresAt.map { $0 > now } ?? true) }
}

public enum PlanAuthor: String, Sendable, Codable, Hashable {
    case user, planner
}

public struct PlanRevisionRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: PlanRevisionID
    public var jobID: JobID
    public var rev: Int
    public var createdBy: PlanAuthor
    public var digest: String
    public var draft: PlanDraft
    public var estimate: PlanEstimate
    public var createdAt: Int64
    public var acceptedAt: Int64?
    public var supersededAt: Int64?

    public init(id: PlanRevisionID, jobID: JobID, rev: Int, createdBy: PlanAuthor, digest: String, draft: PlanDraft, estimate: PlanEstimate, createdAt: Int64, acceptedAt: Int64?, supersededAt: Int64?) {
        self.id = id
        self.jobID = jobID
        self.rev = rev
        self.createdBy = createdBy
        self.digest = digest
        self.draft = draft
        self.estimate = estimate
        self.createdAt = createdAt
        self.acceptedAt = acceptedAt
        self.supersededAt = supersededAt
    }
}

/// Expected effort of a revision before activation.
public struct PlanEstimate: Sendable, Codable, Equatable {
    public var tasksPerTier: [String: Int] = [:]
    /// Sum of the typical tokens of the smallest usable author profile per task.
    public var expectedTokens: Int = 0
    /// Tasks without a usable profile (or without typical tokens): not in the sum.
    public var unknownTasks: [String] = []
    /// Tasks whose difficulty evidence is incomplete.
    public var uncertainTasks: [String] = []

    public init() {}
}

public struct QuotaBlockRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: QuotaBlockID
    public var accountID: AccountID
    public var reason: String
    public var until: Int64?
    public var sequence: Int
    public var createdAt: Int64
    public var releasedAt: Int64?
    public var releasedBy: String?

    public init(id: QuotaBlockID, accountID: AccountID, reason: String, until: Int64?, sequence: Int, createdAt: Int64, releasedAt: Int64?, releasedBy: String?) {
        self.id = id
        self.accountID = accountID
        self.reason = reason
        self.until = until
        self.sequence = sequence
        self.createdAt = createdAt
        self.releasedAt = releasedAt
        self.releasedBy = releasedBy
    }
}

public struct DecisionRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: DecisionID
    public var taskID: TaskID?
    public var attemptID: AttemptID?
    public var accountID: AccountID?
    public var rule: String
    public var ruleVersion: Int
    public var evidence: [String: String]
    public var outcome: String
    public var actor: String
    public var remainingAttempts: Int?
    public var alternative: String?
    public var at: Int64

    public init(id: DecisionID, taskID: TaskID?, attemptID: AttemptID?, accountID: AccountID?, rule: String, ruleVersion: Int, evidence: [String: String], outcome: String, actor: String, remainingAttempts: Int?, alternative: String?, at: Int64) {
        self.id = id
        self.taskID = taskID
        self.attemptID = attemptID
        self.accountID = accountID
        self.rule = rule
        self.ruleVersion = ruleVersion
        self.evidence = evidence
        self.outcome = outcome
        self.actor = actor
        self.remainingAttempts = remainingAttempts
        self.alternative = alternative
        self.at = at
    }
}

/// What the scheduler asks the store to reserve atomically for an author attempt.
public struct ScheduledReservation: Sendable, Codable, Equatable {
    public var attemptID: AttemptID
    public var taskID: TaskID
    public var planID: PlanRevisionID
    public var consentID: ConsentID
    public var profile: ModelProfile
    public var tier: CapabilityTier
    public var specDigest: String
    public var reservedTokens: Int
    public var sizeUncertain: Bool
    /// Expected review cost, checked against the reviewer account's bucket (not booked).
    public var reviewAccountID: AccountID?
    public var reviewTokens: Int?
    public var decision: TierDecision
    /// `scheduler` or the user who started it.
    public var actor: String

    public init(
        attemptID: AttemptID = AttemptID(), taskID: TaskID, planID: PlanRevisionID, consentID: ConsentID, profile: ModelProfile,
        tier: CapabilityTier, specDigest: String, reservedTokens: Int, sizeUncertain: Bool, reviewAccountID: AccountID? = nil,
        reviewTokens: Int? = nil, decision: TierDecision, actor: String = "scheduler"
    ) {
        self.attemptID = attemptID
        self.taskID = taskID
        self.planID = planID
        self.consentID = consentID
        self.profile = profile
        self.tier = tier
        self.specDigest = specDigest
        self.reservedTokens = reservedTokens
        self.sizeUncertain = sizeUncertain
        self.reviewAccountID = reviewAccountID
        self.reviewTokens = reviewTokens
        self.decision = decision
        self.actor = actor
    }
}

public enum ScheduledOutcome: Sendable, Equatable {
    case reserved(AttemptID)
    case waiting(WaitReason)
    /// Lost a race (the task is no longer ready, another author is active): nothing to do.
    case skipped
}
