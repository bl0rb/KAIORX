import Foundation

/// Package F routing (ADR 0005 §8): which tier the next author attempt of a task runs on, from
/// the plan's difficulty and the task's history. Pure and table-tested; the scheduler adds
/// provider, consent, quota and slots.

public enum ModelProfileTag {}
public typealias ModelProfileID = TypedID<ModelProfileTag>

/// A tested model/effort combination of one provider for one role and tier.
public struct ModelProfile: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: ModelProfileID
    public var provider: ProviderKind
    public var role: AttemptRole
    public var tier: CapabilityTier
    public var model: String
    public var effort: String?
    public var contextLimit: Int?
    /// Typical tokens of one attempt; sizes the budget reservation.
    public var typicalTokens: Int?
    public var observedDurationMs: Int64?
    /// Set by a passed live check (package A); only verified profiles are used.
    public var verifiedAt: Int64?
    public var disabledReason: String?

    public init(
        id: ModelProfileID = ModelProfileID(), provider: ProviderKind, role: AttemptRole, tier: CapabilityTier, model: String,
        effort: String? = nil, contextLimit: Int? = nil, typicalTokens: Int? = nil, observedDurationMs: Int64? = nil,
        verifiedAt: Int64? = nil, disabledReason: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.role = role
        self.tier = tier
        self.model = model
        self.effort = effort
        self.contextLimit = contextLimit
        self.typicalTokens = typicalTokens
        self.observedDurationMs = observedDurationMs
        self.verifiedAt = verifiedAt
        self.disabledReason = disabledReason
    }

    public var isUsable: Bool { verifiedAt != nil && disabledReason == nil }

    /// The smallest usable profile of `provider` for `role` at `tier` or above.
    public static func smallest(_ profiles: [ModelProfile], provider: ProviderKind, role: AttemptRole, atLeast tier: CapabilityTier) -> ModelProfile? {
        profiles.filter { $0.isUsable && $0.provider == provider && $0.role == role && $0.tier >= tier }
            .sorted { $0.tier != $1.tier ? $0.tier < $1.tier : ($0.model, $0.id.uuidString) < ($1.model, $1.id.uuidString) }
            .first
    }
}

/// How a counted author attempt (one that reached a turn and failed on the substance) ended.
public enum AuthorFailure: Sendable, Codable, Equatable, Hashable {
    /// The candidate's test was red or crashed; fingerprint of its report.
    case redTest(fingerprint: String)
    /// The provider reported a failed turn; fingerprint of its reason.
    case providerFailed(fingerprint: String)
    /// The candidate was rejected on a blocking review finding.
    case blockingFinding

    var fingerprint: String? {
        switch self {
        case .redTest(let fingerprint), .providerFailed(let fingerprint): fingerprint
        case .blockingFinding: nil
        }
    }
}

public struct CountedAttempt: Sendable, Codable, Equatable, Hashable {
    public var tier: CapabilityTier
    public var failure: AuthorFailure

    public init(tier: CapabilityTier, failure: AuthorFailure) {
        self.tier = tier
        self.failure = failure
    }
}

public enum RoutingOutcome: Sendable, Codable, Equatable, Hashable {
    case first(CapabilityTier)
    /// One repair on the same tier, with the failure report in its prompt.
    case repair(CapabilityTier)
    /// Exactly one tier up after a repeated fingerprint or a second blocking finding.
    case escalate(CapabilityTier)
    /// The user decides: attempt limit, top tier reached.
    case userDecision(reason: String)

    public var tier: CapabilityTier? {
        switch self {
        case .first(let tier), .repair(let tier), .escalate(let tier): tier
        case .userDecision: nil
        }
    }
}

public struct TierDecision: Sendable, Codable, Equatable {
    public var outcome: RoutingOutcome
    public var rule: String
    public var evidence: [String: String]
    public var remainingAttempts: Int
}

public enum Router {
    public static let ruleVersion = 1
    public static let maxAuthorAttempts = 3

    /// The tier for the next author attempt. `planned` already includes the sensitive minimum.
    public static func nextTier(planned: CapabilityTier, history: [CountedAttempt]) -> TierDecision {
        let remaining = max(0, maxAuthorAttempts - history.count)
        guard let last = history.last else {
            return TierDecision(outcome: .first(planned), rule: "difficulty", evidence: ["tier": planned.rawValue], remainingAttempts: remaining)
        }
        if history.count >= maxAuthorAttempts {
            return TierDecision(
                outcome: .userDecision(reason: "attemptLimit"), rule: "attemptLimit",
                evidence: ["attempts": String(history.count)], remainingAttempts: 0
            )
        }
        var counts: [String: Int] = [:]
        for attempt in history { if let fingerprint = attempt.failure.fingerprint { counts[fingerprint, default: 0] += 1 } }
        let repeated = last.failure.fingerprint.map { (counts[$0] ?? 0) >= 2 } ?? false
        let blocking = history.filter { $0.failure == .blockingFinding }.count
        let secondBlocking = last.failure == .blockingFinding && blocking >= 2
        if repeated || secondBlocking {
            let rule = repeated ? "repeatedFingerprint" : "secondBlockingFinding"
            var evidence = ["fromTier": last.tier.rawValue]
            if let fingerprint = last.failure.fingerprint { evidence["fingerprint"] = fingerprint }
            guard let higher = last.tier.next else {
                return TierDecision(outcome: .userDecision(reason: "topTierReached"), rule: rule, evidence: evidence, remainingAttempts: remaining)
            }
            return TierDecision(outcome: .escalate(higher), rule: rule, evidence: evidence, remainingAttempts: remaining)
        }
        var evidence = ["tier": last.tier.rawValue]
        if let fingerprint = last.failure.fingerprint { evidence["fingerprint"] = fingerprint }
        return TierDecision(outcome: .repair(last.tier), rule: "repair", evidence: evidence, remainingAttempts: remaining)
    }
}

public enum FailureFingerprint {
    /// SHA-256 over the normalized failure text: worktree root, absolute paths, hex runs of
    /// seven or more, numbers and whitespace are replaced in this order.
    public static func of(_ text: String, worktreeRoot: String? = nil) -> String {
        Canonical.sha256Hex(Data(normalize(text, worktreeRoot: worktreeRoot).utf8))
    }

    public static func normalize(_ text: String, worktreeRoot: String? = nil) -> String {
        var result = text
        if let root = worktreeRoot, !root.isEmpty { result = result.replacingOccurrences(of: root, with: "<wt>") }
        result = replace(#"(?<![\w<>])/[^\s:'"()\[\],]+"#, in: result, with: "<path>")
        result = replace(#"\b[0-9a-fA-F]{7,}\b"#, in: result, with: "<hex>")
        result = replace(#"\d+"#, in: result, with: "<n>")
        result = replace(#"\s+"#, in: result, with: " ")
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// Delay before technical start retry `n` (0-based): `30 s · 2^n` plus a spread derived from
/// the task, so tests can assert exact times. At most two retries.
public enum StartRetry {
    public static let maxRetries = 2
    public static let baseMs: Int64 = 30_000

    public static func delayMs(task: TaskID, retry n: Int) -> Int64 {
        let base = baseMs << Int64(n)
        let digest = Canonical.sha256Hex(Data("\(task.uuidString)|\(n)".utf8))
        let spread = Int64(UInt64(digest.prefix(12), radix: 16)! % UInt64(base / 2))
        return base + spread
    }
}
