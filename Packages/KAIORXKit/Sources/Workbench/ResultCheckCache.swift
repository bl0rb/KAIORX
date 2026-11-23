import Domain
import Foundation
import Orchestration
import Storage

/// The last result check (`CandidateChain.check`, which asks Git) per task, reused while nothing
/// it depends on changed. The pending decisions are rebuilt on every coalesced publish; without
/// this every waiting task would cost Git calls each time.
///
/// The key holds everything a check reads: the task (version, state, current attempt), that
/// attempt and its result worktree (state, version, seal status, result commit, dropped paths),
/// the task's candidates, the integration tip of its job, and the driver's issue with the task.
/// A check that throws is not kept, so the next refresh asks again.
public actor ResultCheckCache {
    public struct Key: Sendable, Equatable {
        var taskVersion: Int
        var taskState: TaskState
        var resumeState: TaskState?
        var attempt: AttemptID?
        var attemptState: AttemptState?
        var attemptVersion: Int?
        var worktree: WorktreeID?
        var worktreeState: WorktreeState?
        var worktreeVersion: Int?
        var sealStatus: SealStatus?
        var resultOID: String?
        var rejected: [String]
        var candidates: [String]
        var tip: String?
        var issue: ChainIssue?
    }

    private var entries: [TaskID: (key: Key, check: ResultCheck?)] = [:]

    public init() {}

    /// The key of the task's check in `state`; nil when the state does not know the task.
    public static func key(_ task: TaskID, in state: WorkspaceState, tip: String?, issue: ChainIssue?) -> Key? {
        guard let record = state.tasks[task] else { return nil }
        let attempt = record.currentAttemptID.flatMap { state.attempts[$0] }
        let tree = attempt?.worktreeID.flatMap { state.worktrees[$0] }
        let candidates = state.candidates.values.filter { $0.taskID == task }
            .map { "\($0.id.uuidString):\($0.version):\($0.state.rawValue)" }.sorted()
        return Key(
            taskVersion: record.version, taskState: record.state, resumeState: record.resumeState, attempt: record.currentAttemptID,
            attemptState: attempt?.state, attemptVersion: attempt?.version, worktree: tree?.id, worktreeState: tree?.state,
            worktreeVersion: tree?.version, sealStatus: tree?.sealStatus, resultOID: tree?.resultOID,
            rejected: tree?.rejectedPaths.keys.sorted() ?? [], candidates: candidates, tip: tip, issue: issue
        )
    }

    /// The task's check: the cached one while `key` is unchanged, else `compute`'s (then kept).
    public func check(_ task: TaskID, key: Key?, compute: @Sendable () async throws -> ResultCheck?) async throws -> ResultCheck? {
        guard let key else { return try await compute() }
        if let entry = entries[task], entry.key == key { return entry.check }
        let check = try await compute()
        entries[task] = (key, check)
        return check
    }

    /// Drops the entries of tasks the state no longer has.
    public func keep(only tasks: Set<TaskID>) {
        entries = entries.filter { tasks.contains($0.key) }
    }

    /// The `resultCheck` lookup for `PendingDecisions.collect`: the chain's check of each task,
    /// cached against `state`, the job's integration tip (a store read) and the chain's issue.
    public nonisolated func lookup(
        state: WorkspaceState, store: Store, chain: CandidateChain?
    ) -> @Sendable (TaskID) async throws -> ResultCheck? {
        lookup(state: state, store: store, chain: chain) { chain, task in try await chain.check(task) }
    }

    /// `lookup` with the call of the chain's check passed in, so tests can count it.
    nonisolated func lookup(
        state: WorkspaceState, store: Store, chain: CandidateChain?,
        chainCheck: @escaping @Sendable (CandidateChain, TaskID) async throws -> ResultCheck?
    ) -> @Sendable (TaskID) async throws -> ResultCheck? {
        { [self] task in
            guard let chain else { return nil }
            var tip: String?
            if let job = state.tasks[task]?.jobID { tip = try await store.integrationTip(job: job) }
            let key = Self.key(task, in: state, tip: tip, issue: await chain.issue(task))
            return try await check(task, key: key) { try await chainCheck(chain, task) }
        }
    }
}
