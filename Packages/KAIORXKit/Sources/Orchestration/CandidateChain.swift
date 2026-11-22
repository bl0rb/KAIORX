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
/// moved, collect finished reviews and remove the worktrees of reviewers no review comes from any
/// more. It never starts a provider and runs no project code; tests and review starts stay with
/// the user.
///
/// The actor is reentrant at every `await`. `inFlight` is the per-task lock: it is checked and
/// taken before the first `await` of every step and user call, so the driver and the user never
/// work on one task at the same time. `buildLocks` allows one merge per repository at a time
/// (Plan/macos-und-git.md). Backoff, refused collects and refused removals live in memory only.
/// A pass reports an issue only when it is new for the task, so an unchanged issue never makes
/// the app refresh; `issue(_:)` returns the current one in every task state.
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

    struct Backoff {
        var count: Int
        var until: Int64
        /// nil: a quiet retry (a lost race), nothing to show.
        var issue: ChainIssue?
    }

    /// Tasks a step or a user call is working on right now.
    private var inFlight: Set<TaskID> = []
    /// Projects with a merge running right now.
    private var buildLocks: Set<ProjectID> = []
    /// Failed builds, seals and rebuilds, retried after `until` (store clock).
    private var backoff: [TaskID: Backoff] = [:]
    /// Issues without a retry (a missing plan task): shown until the task moves on.
    private var standing: [TaskID: ChainIssue] = [:]
    /// Reviewer attempts whose collection failed, per task; retried after `retryBuild` or a restart.
    private var given: [TaskID: Set<AttemptID>] = [:]
    /// Reviewer worktrees whose removal Git refused; left to recovery or the user until a restart.
    private var refusedRemovals: Set<WorktreeID> = []

    static let backoffBase: Int64 = 5_000
    static let backoffCap: Int64 = 300_000
    private static let openCandidateStates: Set<CandidateState> = [.conflicted, .built, .testing, .reviewing, .accepted, .publishing]

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

    // MARK: Driver

    /// One pass over all tasks: seal, build, rebuild, collect, clean up. Never throws; problems
    /// end up in `ChainReport.issues`.
    public func step() async -> ChainReport {
        var report = ChainReport()
        await forgetSettledTasks()
        await sealPass(&report)
        await buildPass(&report)
        await rebuildPass(&report)
        await collectPass(&report)
        await cleanupPass(&report)
        return report
    }

    /// (a) Seals every finished author result whose stream has ended. A held task is sealed too:
    /// sealing only removes write access and does not move the task.
    private func sealPass(_ report: inout ChainReport) async {
        guard let tasks = try? await store.tasks() else { return }
        for task in tasks where Self.waitsWithResult(task) {
            guard case let (attempt, tree)? = try? await authorResult(task), tree.state == .ready, tree.sealStatus == nil else { continue }
            guard !inBackoff(task.id, now: await store.now()) else { continue }
            guard await !isStreaming(attempt.id) else { continue }
            guard claim(task.id) else { continue }
            defer { release(task.id) }
            let area = await writeArea(task, attempt: attempt)
            guard case .known(let prefixes) = area else {
                // Never fall back to the whole project. The check repeats on every pass (a read
                // error clears by itself), but the issue is reported only when it is new.
                let previous = issue(task.id)
                backoff[task.id] = nil
                standing[task.id] = .planTaskMissing
                raise(.planTaskMissing, for: task.id, since: previous, in: &report)
                continue
            }
            do {
                // Read again under the lock: another pass may have sealed meanwhile.
                let current = try await workspace.worktree(tree.id)
                guard current.state == .ready, current.sealStatus == nil else { continue }
                _ = try await workspace.seal(tree.id, allowedPrefixes: prefixes, message: "\(task.title)\n\nAttempt \(attempt.id)")
                report.sealed.append(tree.id)
                clearIssue(task.id)
            } catch {
                await fail(task.id, .sealFailed(Self.describe(error)), report: &report)
            }
        }
    }

    /// (b) Builds every sealed result that is clean: committed, no rejected path (for any task),
    /// not already contained, no open candidate, and the task takes a candidate.
    private func buildPass(_ report: inout ChainReport) async {
        guard let tasks = try? await store.tasks() else { return }
        for task in tasks where task.state == .resultReady && Store.acceptsCandidate(task) {
            guard !inBackoff(task.id, now: await store.now()) else { continue }
            guard case .buildable = (try? await check(task.id)) ?? .notApplicable else { continue }
            guard case let (_, tree)? = try? await authorResult(task) else { continue }
            guard claim(task.id) else { continue }
            defer { release(task.id) }
            // Classified again under the lock: the result may have moved on meanwhile.
            guard case .buildable = (try? await check(task.id)) ?? .notApplicable else { continue }
            await build(task.id, project: tree.projectID, from: tree.id, accepting: false, rebuild: false, report: &report)
        }
    }

    /// (c) Rebuilds a task whose newest candidate was superseded because the integration target
    /// moved, from the same author result. A candidate from that result existed before, so its
    /// rejected paths (if any) were already confirmed.
    private func rebuildPass(_ report: inout ChainReport) async {
        guard let jobs = try? await store.jobs() else { return }
        for job in jobs {
            guard let candidates = try? await store.candidates(jobID: job.id), !candidates.isEmpty,
                  let tip = try? await store.integrationTip(job: job.id) else { continue }
            let byTask = Dictionary(grouping: candidates.filter { $0.taskID != nil }, by: { $0.taskID! })
            for (taskID, own) in byTask {
                guard !own.contains(where: { Self.openCandidateStates.contains($0.state) }) else { continue }
                guard let task = try? await store.task(taskID), Store.acceptsCandidate(task), let current = task.currentAttemptID else { continue }
                // Superseded candidates of the task's current result; one built on the tip already
                // means the move it reacted to is not new.
                let superseded = own.filter { $0.state == .superseded && $0.kind == .implementation && $0.authorAttemptID == current }
                guard !superseded.isEmpty, !superseded.contains(where: { $0.previousTargetOID == tip }) else { continue }
                // Nothing newer may have ended the chain for this result (published, rejected).
                if own.contains(where: { $0.authorAttemptID == current && ($0.state == .published || $0.state == .rejected) }) { continue }
                guard !inBackoff(taskID, now: await store.now()) else { continue }
                guard let attempt = try? await store.attempt(current), let treeID = attempt.worktreeID else { continue }
                guard claim(taskID) else { continue }
                defer { release(taskID) }
                await build(taskID, project: job.projectID, from: treeID, accepting: true, rebuild: true, report: &report)
            }
        }
    }

    /// (d) Collects every finished reviewer of a reviewing (or accepted) candidate: succeeded, its
    /// worktree prepared at exactly the candidate's commit, not recorded yet, stream ended.
    private func collectPass(_ report: inout ChainReport) async {
        guard let jobs = try? await store.jobs() else { return }
        for job in jobs {
            guard let candidates = try? await store.candidates(jobID: job.id) else { continue }
            for candidate in candidates where candidate.state == .reviewing || candidate.state == .accepted {
                guard let taskID = candidate.taskID, let task = try? await store.task(taskID), Store.acceptsCandidate(task) else { continue }
                guard let reviewers = try? await uncollectedReviewers(of: candidate) else { continue }
                for reviewer in reviewers {
                    guard await !isStreaming(reviewer.id) else { continue }
                    guard claim(taskID) else { break }
                    defer { release(taskID) }
                    do {
                        let review = try await integration.collectReview(candidate.id, attempt: reviewer.id)
                        report.collected.append(review.id)
                        if case .collectFailed? = standing[taskID] { standing[taskID] = nil }
                    } catch IntegrationError.taskNotInVerification, IntegrationStoreError.taskNotInVerification {
                        // The user holds the task: collected once it is released.
                    } catch {
                        // The store refused it (already recorded, not usable) or reading failed:
                        // not retried until `retryBuild` or a restart. The issue stays visible in
                        // every task state until it is resolved (`forgetSettledTasks`).
                        given[taskID, default: []].insert(reviewer.id)
                        if case IntegrationStoreError.reviewAttemptNotUsable = error { continue }
                        let previous = issue(taskID)
                        let issue = ChainIssue.collectFailed(Self.describe(error))
                        standing[taskID] = issue
                        raise(issue, for: taskID, since: previous, in: &report)
                    }
                }
            }
        }
    }

    /// (e) Removes the read-only worktrees of reviewers no review comes from any more, once their
    /// stream ended: failed or cancelled ones (a new review can be started), and succeeded ones
    /// whose commit no reviewing or accepted candidate of their task has any more (it was
    /// rejected, superseded or published before the review was collected). Only trees in `ready`
    /// or `frozen`: a tree in `needsAttention`, or one whose removal Git refused in this session,
    /// stays for recovery or the user, so a lasting refusal never loops.
    private func cleanupPass(_ report: inout ChainReport) async {
        guard let trees = try? await store.worktrees() else { return }
        for tree in trees where tree.kind == .reviewer && Self.removableStates.contains(tree.state) && !refusedRemovals.contains(tree.id) {
            guard let attempt = await finishedReviewer(of: tree) else { continue }
            guard claim(attempt.taskID) else { continue }
            defer { release(attempt.taskID) }
            // Read again under the lock: a collect or another pass may have moved it meanwhile.
            guard let current = try? await store.worktree(tree.id), Self.removableStates.contains(current.state),
                  await finishedReviewer(of: current) != nil else { continue }
            do {
                try await workspace.remove(tree.id, force: true)
                report.removedReviewerTrees.append(tree.id)
            } catch {
                refusedRemovals.insert(tree.id)
            }
        }
    }

    private static let removableStates: Set<WorktreeState> = [.ready, .frozen]

    /// The attempt of a reviewer worktree no review needs any more, with its stream ended; nil
    /// while the reviewer runs or streams, or while a candidate still waits for its review.
    private func finishedReviewer(of tree: WorktreeRecord) async -> AttemptRecord? {
        guard let id = tree.attemptID, let attempt = try? await store.attempt(id), attempt.role == .reviewer else { return nil }
        switch attempt.state {
        case .failed, .cancelled:
            break
        case .succeeded:
            guard let task = try? await store.task(attempt.taskID), let candidates = try? await store.candidates(jobID: task.jobID) else { return nil }
            let collectable = candidates.contains {
                $0.taskID == attempt.taskID && ($0.state == .reviewing || $0.state == .accepted) && $0.candidateOID != nil
                    && $0.candidateOID == tree.baseOID
            }
            if collectable { return nil }
        default:
            return nil
        }
        // The store can show the end before the process exited: never remove under a live reviewer.
        guard await !isStreaming(id) else { return nil }
        return attempt
    }

    /// Merges and classifies the outcome (ADR 0011, build outcomes). The caller holds the task.
    private func build(
        _ taskID: TaskID, project: ProjectID, from tree: WorktreeID, accepting: Bool, rebuild: Bool, report: inout ChainReport
    ) async {
        guard buildLocks.insert(project).inserted else { return }
        defer { buildLocks.remove(project) }
        do {
            switch try await integration.buildCandidate(from: tree, acceptingRejectedPaths: accepting) {
            case .built(let candidate):
                report.built.append(candidate.id)
                clearIssue(taskID)
            case .conflicted(let candidate, _):
                report.conflicted.append(candidate.id)
                clearIssue(taskID)
            case .alreadyContained:
                // The tip moved meanwhile: the next `check` says `.contained`. A rebuild cannot
                // be accepted as empty (`acceptEmptyResult` needs `resultReady`): a known limit.
                if rebuild { await fail(taskID, .containedAfterRebuild, report: &report) }
            }
        } catch IntegrationError.taskNotInVerification, IntegrationStoreError.openCandidateExists {
            // Lost a race with the user or another step: retried on the next pass.
        } catch IntegrationStoreError.taskCannotFollow {
            // The task could not take the candidate after the merge (held meanwhile): retried
            // quietly, but not on every pass, so a lasting refusal never loops merges.
            await fail(taskID, nil, report: &report)
        } catch {
            await fail(taskID, .buildFailed(Self.describe(error)), report: &report)
        }
    }

    // MARK: Reading

    /// Where the task's result stands. Read-only; also used by the UI.
    public func check(_ taskID: TaskID) async throws -> ResultCheck {
        guard let task = try await store.task(taskID) else { throw StoreError.notFound(entity: "task", id: taskID.uuidString) }
        if let open = try await openCandidate(of: task) { return .candidate(open.id) }
        guard Self.waitsWithResult(task), case let (attempt, tree)? = try await authorResult(task) else { return .notApplicable }
        guard let status = tree.sealStatus else {
            if case .missing = await writeArea(task, attempt: attempt) { return .planTaskMissing }
            return .awaitingSeal
        }
        switch status {
        case .empty:
            return .empty
        case .rejectedOnly:
            return .rejectedOnly(rejected: tree.rejectedPaths)
        case .committed:
            guard let result = tree.resultOID else { return .awaitingSeal }
            if let tip = try await store.integrationTip(job: task.jobID),
               try await git.isAncestor(result, of: tip, in: try await workspace.attach(tree.projectID)) {
                return .contained(tip: tip)
            }
            if !tree.rejectedPaths.isEmpty { return .undeclared(resultOID: result, rejected: tree.rejectedPaths) }
            return .buildable(resultOID: result)
        }
    }

    /// The task's current issue (for example a build failure in backoff, or a refused collect of
    /// a task in verification), in any task state; nil once it is resolved.
    public func issue(_ task: TaskID) -> ChainIssue? {
        backoff[task]?.issue ?? standing[task]
    }

    // MARK: User decisions

    /// Builds the result the sheet showed, accepting its rejected paths.
    public func buildConfirmed(_ shown: ShownResult) async throws -> BuildOutcome {
        guard claim(shown.task) else { throw ChainError.busy(shown.task) }
        defer { release(shown.task) }
        let tree = try await requireShown(shown)
        switch shown.check {
        case .undeclared, .buildable: break
        default: throw ChainError.shownStateChanged
        }
        guard buildLocks.insert(tree.projectID).inserted else { throw ChainError.busy(shown.task) }
        defer { buildLocks.remove(tree.projectID) }
        let outcome = try await integration.buildCandidate(from: tree.id, acceptingRejectedPaths: true)
        clearIssue(shown.task)
        return outcome
    }

    /// Accepts the empty or already contained result the sheet showed as done.
    public func acceptEmpty(_ shown: ShownResult) async throws {
        guard claim(shown.task) else { throw ChainError.busy(shown.task) }
        defer { release(shown.task) }
        _ = try await requireShown(shown)
        switch shown.check {
        case .empty, .contained: break
        default: throw ChainError.shownStateChanged
        }
        try await integration.acceptEmptyResult(shown.task)
        clearIssue(shown.task)
    }

    /// Clears the task's backoff and its refused collects, so the next pass tries again.
    public func retryBuild(_ task: TaskID) {
        backoff[task] = nil
        given[task] = nil
        if let issue = standing[task], issue != .planTaskMissing { standing[task] = nil }
    }

    /// The conflicting paths of a conflicted candidate: the paths the candidate recorded, each
    /// with its kind as its integration worktree shows it. A resolution decides every recorded
    /// path. After an interrupted resolution Git lists fewer paths (some already staged) or none
    /// (the commit was made, but the candidate did not move on); `resolveConflicts` then starts
    /// the merge over or reuses that commit, so a path Git no longer lists is still shown, with
    /// its kind read from the three sides. Read-only.
    public func conflictDetails(_ id: CandidateID) async throws -> [ConflictEntry] {
        let candidate = try await candidate(id)
        guard candidate.state == .conflicted, let treeID = candidate.worktreeID else {
            throw IntegrationError.candidateNotIn(id, candidate.state)
        }
        let live = try await git.conflicts(at: try await workspace.location(of: try await workspace.worktree(treeID)))
        var entries: [ConflictEntry] = []
        for path in candidate.conflicts {
            if let entry = live.first(where: { $0.path == path }) {
                entries.append(entry)
            } else {
                entries.append(try Self.conflictEntry(path, kind: try await recordedKind(path, of: candidate)))
            }
        }
        return entries
    }

    /// The kind of a recorded conflict Git no longer lists, from which of the three sides (base,
    /// integration state, incoming) have the path, as Git's index stages would show it.
    private func recordedKind(_ path: String, of candidate: CandidateRecord) async throws -> ConflictEntry.Kind {
        var base: String?
        var incoming: String?
        switch candidate.kind {
        case .implementation:
            if let attempt = candidate.authorAttemptID, let tree = try await store.attempt(attempt)?.worktreeID {
                base = try await store.worktree(tree)?.baseOID
            }
            incoming = candidate.resultOID
        case .revert:
            // A revert applies the reverted merge backwards: its base is the merge, the incoming
            // side the state before it.
            if let reverted = candidate.revertsCandidateID, let original = try await store.candidate(reverted) {
                base = original.candidateOID
                incoming = original.previousTargetOID
            }
        }
        guard let base, let incoming else { return .bothModified }
        let repository = try await workspace.attach(candidate.projectID)
        func has(_ commit: String) async throws -> Bool { try await git.treeEntry(path, in: commit, repository: repository) != nil }
        return switch (try await has(base), try await has(candidate.previousTargetOID), try await has(incoming)) {
        case (false, true, true): .bothAdded
        case (true, false, true): .deletedByUs
        case (true, true, false): .deletedByThem
        case (false, false, true): .addedByThem
        case (false, true, false): .addedByUs
        default: .bothModified
        }
    }

    /// `ConflictEntry` has no public initializer outside `Workspace`; it is `Codable`.
    private static func conflictEntry(_ path: String, kind: ConflictEntry.Kind) throws -> ConflictEntry {
        try JSONDecoder().decode(ConflictEntry.self, from: JSONEncoder().encode(["path": path, "kind": kind.rawValue]))
    }

    /// Discards the result the sheet showed (ADR 0011 §7) under the task's lock, so no build of
    /// the driver runs meanwhile: checks that the task is still exactly where the sheet saw it,
    /// then grants and moves it to `needsChanges` in one store transaction
    /// (`Store.discardResult`); on any failure nothing is recorded.
    public func discard(_ shown: ShownResult, actor: String) async throws {
        try await discard(shown, actor: actor, afterCheck: {})
    }

    /// `afterCheck` runs under the lock between the shown-state check and the store transaction
    /// (test seam).
    func discard(_ shown: ShownResult, actor: String, afterCheck: @Sendable () async -> Void) async throws {
        guard claim(shown.task) else { throw ChainError.busy(shown.task) }
        defer { release(shown.task) }
        switch shown.check {
        case .notApplicable, .candidate: throw ChainError.shownStateChanged
        default: break
        }
        _ = try await requireShown(shown)
        guard let task = try await store.task(shown.task), task.state == .resultReady else { throw ChainError.shownStateChanged }
        await afterCheck()
        do {
            try await store.discardResult(task: task.id, expectedVersion: shown.taskVersion, actor: actor)
        } catch let error as StoreError where error.isVersionConflict {
            throw ChainError.shownStateChanged
        } catch is DomainError {
            throw ChainError.shownStateChanged
        }
        clearIssue(task.id)
    }

    /// Resolves the conflicts the sheet showed with the user's choices.
    public func resolveConflicts(_ shown: ShownConflicts, _ resolutions: [String: ConflictResolution]) async throws -> CandidateRecord {
        let first = try await candidate(shown.candidate)
        guard let taskID = first.taskID else { throw IntegrationError.candidateWithoutTask(shown.candidate) }
        guard claim(taskID) else { throw ChainError.busy(taskID) }
        defer { release(taskID) }
        let current = try await candidate(shown.candidate)
        guard current.state == .conflicted, current.version == shown.version, Set(current.conflicts) == Set(shown.paths) else {
            throw ChainError.shownStateChanged
        }
        return try await integration.resolveConflicts(current.id, resolutions)
    }

    // MARK: Review

    /// The providers a review of the candidate could run with, each with its blockers. The
    /// author's own provider is listed with `sameProviderAsAuthor`, so the sheet can say why.
    /// Slots are shown as a pre-check; the store checks them again in the reservation transaction
    /// (ADR 0011 §8). The automation gate's verdict is
    /// shown as `automationNote` (an `AutomationBlock.detail(for:)` code) and never blocks
    /// (ADR 0009 §8).
    public func reviewOptions(_ id: CandidateID) async throws -> [ReviewOption] {
        let candidate = try await candidate(id)
        guard let taskID = candidate.taskID, let task = try await store.task(taskID) else {
            throw IntegrationError.candidateWithoutTask(id)
        }
        let criteria = try await reviewCriteria(taskID)
        var common: [ReviewBlocker] = []
        if candidate.state != .reviewing || candidate.candidateOID == nil || !Store.acceptsCandidate(task) {
            common.append(.candidateNotReviewing)
        }
        // Mirrors the store's reservation: one open (or uncertain) reviewer per task.
        if let open = try await store.attempts(taskID: taskID).first(where: { $0.role == .reviewer && !$0.state.isTerminal }) {
            common.append(.reviewerOpen(open.id))
        }
        let planned = try await store.plannedTask(taskID) != nil
        let now = await store.now()
        let consents = try await store.consents(project: candidate.projectID)
        let profiles = try await store.modelProfiles()
        let blocked = Set(try await store.openBlocks().map(\.accountID))
        let activeGlobal = try await store.activeAttemptCount(account: nil)
        let available = await coordinator.providers

        var options: [ReviewOption] = []
        for provider in available.sorted(by: { $0.rawValue < $1.rawValue }) {
            // The provider's own reason first: a start of it reports that one.
            var blockers: [ReviewBlocker] = provider == candidate.authorProvider ? [.sameProviderAsAuthor] : []
            blockers += common
            // A plan task's review runs under a reviewer consent of that provider (ADR 0005 §7).
            var consent: ConsentRecord?
            if planned {
                consent = ReviewerChoice.consent(consents: consents, provider: provider, job: candidate.jobID, now: now)
                if consent == nil { blockers.append(.noReviewerConsent) }
            }
            let profile = ReviewerChoice.profile(profiles, provider: provider)
            if profile == nil { blockers.append(.noModelProfile) }
            let account = consent?.draft.accountID
            if let account, blocked.contains(account) { blockers.append(.accountBlocked) }
            if activeGlobal >= limits.global {
                blockers.append(.slotsFull(global: true))
            } else if let account, try await store.activeAttemptCount(account: account) >= limits.perAccount {
                blockers.append(.slotsFull(global: false))
            }
            var note: String?
            if let gate, case .blocked(let block) = await gate.automaticVerdict(provider) { note = block.detail(for: provider) }
            options.append(ReviewOption(
                provider: provider, model: profile?.model ?? "", modelProfileID: profile?.id, accountID: account, consentID: consent?.id,
                criteria: criteria, candidateOID: candidate.candidateOID ?? "", candidateVersion: candidate.version,
                blockers: blockers, automationNote: note
            ))
        }
        return options
    }

    /// Starts the review the sheet showed, after checking that the option is unchanged. An
    /// explicit start: the automation gate is not asked (ADR 0009 §8).
    public func startReview(_ shown: ReviewOption, candidate id: CandidateID) async throws -> AttemptID {
        let first = try await candidate(id)
        guard let taskID = first.taskID else { throw IntegrationError.candidateWithoutTask(id) }
        guard claim(taskID) else { throw ChainError.busy(taskID) }
        defer { release(taskID) }
        guard var current = try await reviewOptions(id).first(where: { $0.id == shown.id }) else { throw ChainError.shownStateChanged }
        // The gate's note is information only; a change there does not void the decision.
        current.automationNote = shown.automationNote
        guard current == shown else { throw ChainError.shownStateChanged }
        if let blocker = current.blockers.first {
            throw Self.error(for: blocker, option: current, candidate: first)
        }
        return try await integration.startReview(id, provider: shown.provider, model: shown.model, criteria: shown.criteria, limits: limits)
    }

    /// The acceptance criteria text a review of the task gets: the criteria of the plan revision
    /// the author worked with, the revert instruction for a revert, else the task's title.
    public func reviewCriteria(_ taskID: TaskID) async throws -> String {
        guard let task = try await store.task(taskID) else { throw StoreError.notFound(entity: "task", id: taskID.uuidString) }
        let candidates = try await store.candidates(jobID: task.jobID).filter { $0.taskID == taskID }
        if let revert = candidates.last(where: { $0.kind == .revert }) {
            var oid = "?"
            if let reverted = revert.revertsCandidateID, let original = try await store.candidate(reverted) {
                oid = original.candidateOID ?? oid
            }
            return "Nimmt die Veröffentlichung \(oid) zurück. Prüfe, dass nur diese Änderung zurückgenommen wird, und nenne abhängige spätere Änderungen."
        }
        if task.planKey != nil {
            let author = candidates.last(where: { Self.openCandidateStates.contains($0.state) })?.authorAttemptID
                ?? task.currentAttemptID
            if let author, let attempt = try await store.attempt(author), case .found(let draft) = await plannedDraft(task, attempt: attempt) {
                let lines = draft.criteria.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { "- \($0)" }
                if !lines.isEmpty { return lines.joined(separator: "\n") }
            }
        }
        return "Aufgabe: \(task.title)"
    }

    // MARK: Helpers

    /// The task waits with its author's result: `resultReady`, or held resuming to it.
    static func waitsWithResult(_ task: TaskRecord) -> Bool {
        task.state == .resultReady || (task.state == .blocked && task.resumeState == .resultReady)
    }

    /// The current author attempt (succeeded) and its result worktree.
    private func authorResult(_ task: TaskRecord) async throws -> (AttemptRecord, WorktreeRecord)? {
        guard let id = task.currentAttemptID, let attempt = try await store.attempt(id), attempt.role == .author,
              attempt.state == .succeeded, let treeID = attempt.worktreeID, let tree = try await store.worktree(treeID) else { return nil }
        return (attempt, tree)
    }

    private func openCandidate(of task: TaskRecord) async throws -> CandidateRecord? {
        try await store.candidates(jobID: task.jobID).last { $0.taskID == task.id && Self.openCandidateStates.contains($0.state) }
    }

    enum PlannedDraft {
        case notPlanned
        case found(PlanTaskDraft)
        case missing
    }

    /// The plan task as the attempt's own plan revision has it: what the author was given, not a
    /// later revision.
    private func plannedDraft(_ task: TaskRecord, attempt: AttemptRecord) async -> PlannedDraft {
        guard let key = task.planKey else { return .notPlanned }
        guard let planID = attempt.planID, let plan = try? await store.validatedPlan(planID), let planned = plan.task(key) else {
            return .missing
        }
        return .found(planned.draft)
    }

    enum WriteArea {
        /// Allowed prefixes; nil is the whole project.
        case known([String]?)
        case missing
    }

    private func writeArea(_ task: TaskRecord, attempt: AttemptRecord) async -> WriteArea {
        switch await plannedDraft(task, attempt: attempt) {
        case .notPlanned: .known(nil)
        case .found(let draft): .known(draft.writePaths)
        case .missing: .missing
        }
    }

    /// Reviewers of the candidate's task that finished, were prepared at exactly its commit and
    /// have no review yet. The store's `recordReview` is the hard backstop.
    private func uncollectedReviewers(of candidate: CandidateRecord) async throws -> [AttemptRecord] {
        guard let taskID = candidate.taskID, let oid = candidate.candidateOID else { return [] }
        let recorded = Set(try await store.reviews(candidate: candidate.id).compactMap(\.reviewerAttemptID))
        var result: [AttemptRecord] = []
        for attempt in try await store.attempts(taskID: taskID)
        where attempt.role == .reviewer && attempt.state == .succeeded && !recorded.contains(attempt.id) && given[taskID]?.contains(attempt.id) != true {
            guard let treeID = attempt.worktreeID, let tree = try await store.worktree(treeID), tree.baseOID == oid else { continue }
            result.append(attempt)
        }
        return result
    }

    /// Checks that the task's result is still what the sheet showed; returns its worktree.
    private func requireShown(_ shown: ShownResult) async throws -> WorktreeRecord {
        guard let task = try await store.task(shown.task), task.version == shown.taskVersion,
              case let (_, tree)? = try await authorResult(task), tree.id == shown.worktree, tree.resultOID == shown.resultOID,
              tree.rejectedPaths.keys.sorted() == shown.rejected.sorted() else { throw ChainError.shownStateChanged }
        guard try await check(shown.task) == shown.check else { throw ChainError.shownStateChanged }
        return tree
    }

    private func candidate(_ id: CandidateID) async throws -> CandidateRecord {
        guard let candidate = try await store.candidate(id) else { throw StoreError.notFound(entity: "candidate", id: id.uuidString) }
        return candidate
    }

    private func isStreaming(_ id: AttemptID) async -> Bool {
        if let streaming { return await streaming(id) }
        return await coordinator.isStreaming(id)
    }

    /// Takes the task's lock; false when a step or a user call already holds it.
    private func claim(_ task: TaskID) -> Bool { inFlight.insert(task).inserted }
    private func release(_ task: TaskID) { inFlight.remove(task) }

    private func inBackoff(_ task: TaskID, now: Int64) -> Bool {
        guard let entry = backoff[task] else { return false }
        return entry.until > now
    }

    /// Records a failure with a retry after 5 s × 2ⁿ, at most 5 min; reports the issue if it is new.
    private func fail(_ task: TaskID, _ issue: ChainIssue?, report: inout ChainReport) async {
        let previous = self.issue(task)
        let count = (backoff[task]?.count ?? 0) + 1
        let delay = min(Self.backoffBase << Int64(min(count - 1, 16)), Self.backoffCap)
        backoff[task] = Backoff(count: count, until: await store.now() + delay, issue: issue)
        if let issue { raise(issue, for: task, since: previous, in: &report) }
    }

    /// Puts the issue into the pass's report only when it differs from the one the task showed
    /// before: a report is a change, and the app refreshes on every non-empty one.
    private func raise(_ issue: ChainIssue, for task: TaskID, since previous: ChainIssue?, in report: inout ChainReport) {
        if issue != previous { report.issues[task] = issue }
    }

    private func clearIssue(_ task: TaskID) {
        backoff[task] = nil
        standing[task] = nil
    }

    /// Drops backoff, issues and refused collects of tasks that ended or went back to an author,
    /// and issues that are resolved while the task stays: a refused collect once no candidate
    /// waits for that reviewer any more, a seal or build issue once the task has an open
    /// candidate (built by the user, or a conflict that was resolved).
    private func forgetSettledTasks() async {
        let known = Set(backoff.keys).union(standing.keys).union(given.keys)
        for id in known {
            guard let task = try? await store.task(id) else {
                clearIssue(id)
                given[id] = nil
                continue
            }
            let backToAuthor: Set<TaskState> = [.pending, .ready, .running, .needsChanges]
            if task.state.isTerminal || backToAuthor.contains(task.state) {
                clearIssue(id)
                given[id] = nil
                continue
            }
            if case .collectFailed? = standing[id], let waiting = try? await refusedReviewerWaits(task), !waiting { standing[id] = nil }
            if backoff[id] != nil, let _ = try? await openCandidate(of: task) { backoff[id] = nil }
        }
    }

    /// Whether a reviewer whose collect was refused still belongs to a reviewing or accepted
    /// candidate of the task: prepared at its commit, no review of it recorded.
    private func refusedReviewerWaits(_ task: TaskRecord) async throws -> Bool {
        guard let refused = given[task.id], !refused.isEmpty else { return false }
        for candidate in try await store.candidates(jobID: task.jobID)
        where candidate.taskID == task.id && (candidate.state == .reviewing || candidate.state == .accepted) {
            guard let oid = candidate.candidateOID else { continue }
            let recorded = Set(try await store.reviews(candidate: candidate.id).compactMap(\.reviewerAttemptID))
            for id in refused where !recorded.contains(id) {
                guard let treeID = try await store.attempt(id)?.worktreeID, let tree = try await store.worktree(treeID) else { continue }
                if tree.baseOID == oid { return true }
            }
        }
        return false
    }

    /// The error a blocked start reports; the sheet should not have offered it.
    static func error(for blocker: ReviewBlocker, option: ReviewOption, candidate: CandidateRecord) -> any Error {
        switch blocker {
        case .sameProviderAsAuthor: IntegrationError.reviewerNotIndependent(option.provider)
        case .noReviewerConsent: PlanningError.noReviewerConsent(option.provider)
        case .accountBlocked: option.accountID.map { PlanningError.accountBlocked($0) } ?? ChainError.shownStateChanged
        case .reviewerOpen(let attempt): candidate.taskID.map { StoreError.activeReviewerExists(taskID: $0, attemptID: attempt) } ?? ChainError.shownStateChanged
        case .contentPurged: candidate.taskID.map { MemoryError.candidateContentPurged($0) } ?? ChainError.shownStateChanged
        case .candidateNotReviewing: IntegrationError.candidateNotIn(candidate.id, candidate.state)
        case .slotsFull(let global): PlanningError.slotsFull(global: global, provider: option.provider)
        case .noModelProfile, .adapterMissing: ChainError.shownStateChanged
        }
    }

    static func describe(_ error: any Error) -> String { String(describing: error) }
}
