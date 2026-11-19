/// A persisted lifecycle with an explicit transition table (Plan/laufzeitvertrag.md, "Zustände und
/// Invarianten"). Terminal states never change; a later run gets a new ID.
///
/// Side states (for example `blocked`) interrupt the main path. Entering one from the main path
/// records that stage as the resume state; leaving a side state back to the main path is allowed
/// only to that recorded stage ("zurück zur betroffenen Stufe"), plus the explicit successors.
public protocol LifecycleState: RawRepresentable, CaseIterable, Hashable, Sendable, Codable
where RawValue == String {
    static var entityName: String { get }
    var isTerminal: Bool { get }
    var isSideState: Bool { get }
    /// The states reachable in one step, not counting the return from a side state to its resume
    /// state. Empty for terminal states.
    var successors: Set<Self> { get }
}

extension LifecycleState {
    public var isSideState: Bool { false }

    /// - Parameter resumeState: the main-path stage recorded when the side state was entered.
    public func allowsTransition(to next: Self, resumeState: Self? = nil) -> Bool {
        if successors.contains(next) { return true }
        return isSideState && next == resumeState && !next.isSideState
    }

    public func validateTransition(to next: Self, resumeState: Self? = nil) throws {
        guard allowsTransition(to: next, resumeState: resumeState) else {
            throw DomainError.invalidTransition(entity: Self.entityName, from: rawValue, to: next.rawValue)
        }
    }

    /// The resume state to store after moving from `self` to `next`.
    public func resumeState(after next: Self, current: Self?) -> Self? {
        guard next.isSideState else { return nil }
        return isSideState ? current : self
    }
}

public enum DomainError: Error, Equatable, Sendable {
    case invalidTransition(entity: String, from: String, to: String)
    /// `paused`, `cancelled` and `needsAttention` must store their reason.
    case reasonRequired(entity: String, state: String)
}

/// Job ("Auftrag"): `draft → planned → active → done`. `paused` and `needsAttention` return only
/// to the stage they interrupted; going back from `active` to `planned` needs a new plan revision
/// and is not a plain transition. `paused`, `cancelled` and `needsAttention` require a reason.
public enum JobState: String, LifecycleState {
    case draft, planned, active, done, paused, cancelled, needsAttention

    public static let entityName = "job"

    public var isTerminal: Bool { self == .done || self == .cancelled }
    public var isSideState: Bool { self == .paused || self == .needsAttention }
    public var requiresReason: Bool { self == .paused || self == .cancelled || self == .needsAttention }

    public var successors: Set<JobState> {
        switch self {
        case .draft: [.planned, .paused, .cancelled, .needsAttention]
        case .planned: [.active, .paused, .cancelled, .needsAttention]
        case .active: [.done, .paused, .cancelled, .needsAttention]
        case .paused: [.cancelled, .needsAttention]
        case .needsAttention: [.paused, .cancelled]
        case .done, .cancelled: []
        }
    }
}

/// Task ("Aufgabe"): `pending → ready → running → resultReady → verifying → awaitingMerge →
/// integrated`; `awaitingMerge → verifying` when the candidate must be checked again (ADR 0004). `blocked` returns to the interrupted stage; `conflict` and `needsChanges` return
/// to that stage or to `ready` for a new author attempt. No result, permanent failure and
/// cancellation are explicit terminal states.
public enum TaskState: String, LifecycleState {
    case pending, ready, running, resultReady, verifying, awaitingMerge, integrated
    case conflict, blocked, needsChanges
    case noResult, failed, cancelled

    public static let entityName = "task"

    public var isTerminal: Bool {
        switch self {
        case .integrated, .noResult, .failed, .cancelled: true
        default: false
        }
    }

    public var isSideState: Bool {
        self == .blocked || self == .conflict || self == .needsChanges
    }

    private static let endings: Set<TaskState> = [.noResult, .failed, .cancelled]

    public var successors: Set<TaskState> {
        if isTerminal { return [] }
        var next: Set<TaskState>
        switch self {
        case .pending: next = [.ready]
        case .ready: next = [.running]
        // An author attempt that ends without a result returns the task to `ready`.
        case .running: next = [.resultReady, .ready]
        case .resultReady: next = [.verifying, .needsChanges]
        case .verifying: next = [.awaitingMerge, .needsChanges, .conflict]
        // A superseded candidate is rebuilt, or new findings reopen the review: back to verifying.
        case .awaitingMerge: next = [.integrated, .verifying, .needsChanges, .conflict]
        case .conflict, .needsChanges: next = [.ready]
        case .blocked: next = []
        case .integrated, .noResult, .failed, .cancelled: next = []
        }
        if self != .blocked { next.insert(.blocked) }
        return next.union(TaskState.endings)
    }
}

/// Agent attempt ("Agentenversuch"): `reserved → starting → running → succeeded/failed/cancelled`,
/// `running ↔ awaitingApproval`, `running → cancelling`. A process lost without a confirmed end is
/// `uncertain` and leaves it only through reconciliation.
public enum AttemptState: String, LifecycleState {
    case reserved, starting, running, awaitingApproval, cancelling
    case succeeded, failed, cancelled
    case uncertain

    public static let entityName = "attempt"

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        default: false
        }
    }

    /// States in which a provider process may exist. They become `uncertain` after a restart.
    public var mayHaveLiveProcess: Bool {
        switch self {
        case .starting, .running, .awaitingApproval, .cancelling: true
        default: false
        }
    }

    public var successors: Set<AttemptState> {
        switch self {
        case .reserved: [.starting, .failed, .cancelled]
        case .starting: [.running, .failed, .cancelling, .uncertain]
        // `cancelled` straight from `running`/`awaitingApproval`: the provider reports an
        // interruption the host did not request.
        case .running: [.awaitingApproval, .cancelling, .succeeded, .failed, .cancelled, .uncertain]
        case .awaitingApproval: [.running, .cancelling, .failed, .cancelled, .uncertain]
        case .cancelling: [.cancelled, .succeeded, .failed, .uncertain]
        case .uncertain: [.succeeded, .failed, .cancelled]
        case .succeeded, .failed, .cancelled: []
        }
    }
}
