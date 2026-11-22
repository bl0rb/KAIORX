import Foundation

/// Shared values of the candidate chain (ADR 0011): what the host-only driver found for a task's
/// result, what it did in one pass, what a decision sheet showed, and the one reviewer rule that
/// the scheduler and the review sheet both use. Pure values, no I/O.

/// Where a task's result stands on its way to a candidate.
public enum ResultCheck: Sendable, Equatable {
    /// The task is not waiting with a result (not `resultReady`, no succeeded author attempt).
    case notApplicable
    /// The author's stream is still live, or the result is not sealed yet.
    case awaitingSeal
    /// The task has a plan key, but the attempt's plan revision does not know it: no seal.
    case planTaskMissing
    /// The run changed nothing.
    case empty
    /// The result is already part of the integration state `tip`.
    case contained(tip: String)
    /// Sealing dropped every change; path -> `RejectionReason` raw value.
    case rejectedOnly(rejected: [String: String])
    /// A commit exists, but sealing dropped these paths: building needs the user's confirmation.
    case undeclared(resultOID: String, rejected: [String: String])
    /// The driver builds this result on its next pass.
    case buildable(resultOID: String)
    /// The result already has an open candidate.
    case candidate(CandidateID)
    /// The task is past its result (`verifying`/`awaitingMerge`), has no open candidate, a candidate of
    /// its current result was superseded (none published or rejected), and the integration state `tip`
    /// already contains the result: a rebuild builds nothing; only the user accepts it as done
    /// (ADR 0011 §10).
    case supersededContained(tip: String)
}

/// Why the driver could not move a task on; shown in the task until it clears.
public enum ChainIssue: Sendable, Equatable {
    case sealFailed(String)
    case buildFailed(String)
    case collectFailed(String)
    case planTaskMissing
    /// A rebuild found the result already contained; the user may accept it as done
    /// (`ResultCheck.supersededContained`).
    case containedAfterRebuild
}

/// What one pass of the driver did.
public struct ChainReport: Sendable, Equatable {
    public var sealed: [WorktreeID] = []
    public var built: [CandidateID] = []
    public var conflicted: [CandidateID] = []
    public var collected: [ReviewID] = []
    public var removedReviewerTrees: [WorktreeID] = []
    public var issues: [TaskID: ChainIssue] = [:]

    public init() {}
}

/// Binds a result sheet to what it showed: a decision on a changed state is refused.
public struct ShownResult: Sendable, Equatable {
    public var task: TaskID
    public var taskVersion: Int
    public var worktree: WorktreeID
    public var resultOID: String?
    public var rejected: [String]
    public var check: ResultCheck

    public init(task: TaskID, taskVersion: Int, worktree: WorktreeID, resultOID: String?, rejected: [String], check: ResultCheck) {
        self.task = task
        self.taskVersion = taskVersion
        self.worktree = worktree
        self.resultOID = resultOID
        self.rejected = rejected
        self.check = check
    }
}

/// The user's own reason for sending a task's last result back (ADR 0011, rework reason): a
/// rejection of a candidate built from it, or a discard of it. It goes into the next author
/// prompt; automatic rejections never yield one.
public struct ReworkReason: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case rejected(CandidateID)
        case discarded
    }

    public var source: Source
    /// The author attempt whose result the reason is about.
    public var attemptID: AttemptID
    public var text: String
    /// When the user gave it (store clock).
    public var at: Int64

    public init(source: Source, attemptID: AttemptID, text: String, at: Int64) {
        self.source = source
        self.attemptID = attemptID
        self.text = text
        self.at = at
    }
}

/// Binds a conflict sheet to the candidate version and paths it showed.
public struct ShownConflicts: Sendable, Equatable {
    public var candidate: CandidateID
    public var version: Int
    public var paths: [String]

    public init(candidate: CandidateID, version: Int, paths: [String]) {
        self.candidate = candidate
        self.version = version
        self.paths = paths
    }
}

/// Why an explicit review start is not possible right now.
public enum ReviewBlocker: Sendable, Equatable {
    case noReviewerConsent
    case noModelProfile
    case accountBlocked
    /// Every slot is taken, globally or for the reviewer's account (ADR 0005 §6).
    case slotsFull(global: Bool)
    case reviewerOpen(AttemptID)
    case contentPurged
    case adapterMissing
    case candidateNotReviewing
    case sameProviderAsAuthor
}

/// One provider the user can start a review with, as the review sheet shows it.
public struct ReviewOption: Sendable, Equatable, Identifiable {
    public var provider: ProviderKind
    public var model: String
    public var modelProfileID: ModelProfileID?
    public var accountID: AccountID?
    public var consentID: ConsentID?
    public var criteria: String
    public var candidateOID: String
    public var candidateVersion: Int
    public var blockers: [ReviewBlocker]
    /// The automation gate's verdict, information only: it never blocks an explicit start
    /// (ADR 0009 §8).
    public var automationNote: String?

    public var id: String { provider.rawValue }

    public init(
        provider: ProviderKind, model: String, modelProfileID: ModelProfileID?, accountID: AccountID?, consentID: ConsentID?,
        criteria: String, candidateOID: String, candidateVersion: Int, blockers: [ReviewBlocker], automationNote: String?
    ) {
        self.provider = provider
        self.model = model
        self.modelProfileID = modelProfileID
        self.accountID = accountID
        self.consentID = consentID
        self.criteria = criteria
        self.candidateOID = candidateOID
        self.candidateVersion = candidateVersion
        self.blockers = blockers
        self.automationNote = automationNote
    }
}

/// The one reviewer rule, shared by the scheduler (the reviewer budgeted when the author is
/// reserved) and the candidate chain (the reviewer the review sheet offers), so both pick the
/// same consent and profile.
public enum ReviewerChoice {
    /// A consent counts if it is valid at `now` and is for the whole project or for `job`.
    public static func usable(_ consent: ConsentRecord, job: JobID?, now: Int64) -> Bool {
        consent.isValid(at: now) && (consent.draft.jobID == nil || consent.draft.jobID == job)
    }

    /// The first usable reviewer consent from another provider than `author` (ADR 0005 §7: an
    /// independent reviewer must be possible before the author starts).
    public static func reviewer(consents: [ConsentRecord], author: ProviderKind?, job: JobID?, now: Int64) -> ConsentRecord? {
        consents.first { usable($0, job: job, now: now) && $0.draft.roles.contains(.reviewer) && $0.draft.provider != author }
    }

    /// The first usable reviewer consent of exactly `provider`, the consent a plan task's review
    /// runs under (`IntegrationService.startReview`).
    public static func consent(consents: [ConsentRecord], provider: ProviderKind, job: JobID?, now: Int64) -> ConsentRecord? {
        consents.first { usable($0, job: job, now: now) && $0.draft.provider == provider && $0.draft.roles.contains(.reviewer) }
    }

    /// The smallest usable reviewer profile of `provider`, at least `fast`.
    public static func profile(_ profiles: [ModelProfile], provider: ProviderKind) -> ModelProfile? {
        ModelProfile.smallest(profiles, provider: provider, role: .reviewer, atLeast: .fast)
    }
}
