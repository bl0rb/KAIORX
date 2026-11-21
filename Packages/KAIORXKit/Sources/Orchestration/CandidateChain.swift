import Domain
import Foundation
import Storage
import Workspace

public enum ChainError: Error, Sendable, Equatable {
    /// The state changed after the sheet showed it: a new decision is needed.
    case shownStateChanged
    case notImplemented
    /// Another call (the driver or a user action) is working on this task right now.
    case busy(TaskID)
}

/// The candidate chain's driver (ADR 0011). `step()` runs the host-only steps automatically:
/// seal a finished author result, build a clean result, rebuild after the integration target
/// moved, collect finished reviews and remove the worktrees of failed reviewers. It never starts
/// a provider and runs no project code; tests and review starts stay with the user.
///
/// Skeleton (WP0): the public API is frozen; the bodies follow with WP2.
public actor CandidateChain {
    let store: Store
    let workspace: WorkspaceService
    let integration: IntegrationService
    let git: GitRunner
    let coordinator: RunCoordinator
    let limits: SchedulerLimits
    let gate: (any CapabilityGate)?
    /// Whether an attempt's event stream is still being consumed; nil uses the coordinator.
    let streaming: (@Sendable (AttemptID) async -> Bool)?

    public init(
        store: Store, workspace: WorkspaceService, integration: IntegrationService, git: GitRunner,
        coordinator: RunCoordinator, limits: SchedulerLimits, gate: (any CapabilityGate)?,
        streaming: (@Sendable (AttemptID) async -> Bool)? = nil
    ) {
        self.store = store
        self.workspace = workspace
        self.integration = integration
        self.git = git
        self.coordinator = coordinator
        self.limits = limits
        self.gate = gate
        self.streaming = streaming
    }

    /// One pass over all tasks: seal, build, rebuild, collect, clean up. Never throws; problems
    /// end up in `ChainReport.issues`.
    public func step() async -> ChainReport {
        ChainReport()
    }

    /// Where the task's result stands. Read-only; also used by the UI.
    public func check(_ task: TaskID) async throws -> ResultCheck {
        throw ChainError.notImplemented
    }

    /// The task's current issue (for example a build failure in backoff), if any.
    public func issue(_ task: TaskID) -> ChainIssue? {
        nil
    }

    /// Builds the result the sheet showed, accepting its rejected paths.
    public func buildConfirmed(_ shown: ShownResult) async throws -> BuildOutcome {
        throw ChainError.notImplemented
    }

    /// Accepts the empty or already contained result the sheet showed as done.
    public func acceptEmpty(_ shown: ShownResult) async throws {
        throw ChainError.notImplemented
    }

    /// Clears the task's build backoff, so the next pass tries again.
    public func retryBuild(_ task: TaskID) {}

    /// The conflicting paths of a conflicted candidate, read in its integration worktree.
    public func conflictDetails(_ candidate: CandidateID) async throws -> [ConflictEntry] {
        throw ChainError.notImplemented
    }

    /// Resolves the conflicts the sheet showed with the user's choices.
    public func resolveConflicts(_ shown: ShownConflicts, _ resolutions: [String: ConflictResolution]) async throws -> CandidateRecord {
        throw ChainError.notImplemented
    }

    /// The providers a review of the candidate could run with, each with its blockers.
    public func reviewOptions(_ candidate: CandidateID) async throws -> [ReviewOption] {
        throw ChainError.notImplemented
    }

    /// Starts the review the sheet showed, after checking that the option is unchanged.
    public func startReview(_ shown: ReviewOption, candidate: CandidateID) async throws -> AttemptID {
        throw ChainError.notImplemented
    }

    /// The acceptance criteria text a review of the task gets.
    public func reviewCriteria(_ task: TaskID) async throws -> String {
        throw ChainError.notImplemented
    }
}
