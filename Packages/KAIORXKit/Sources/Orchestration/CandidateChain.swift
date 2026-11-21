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
/// The actor is reentrant at every `await`. `inFlight` is the per-task lock: it is checked and
/// taken before the first `await` of every step and user call, so the driver and the user never
/// work on one task at the same time. `buildLocks` allows one merge per repository at a time
/// (Plan/macos-und-git.md). Backoff and refused collects live in memory only.
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
    /// Reviewer attempts whose collection failed for good; retried only after a restart.
    private var given: Set<AttemptID> = []

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
                // Never fall back to the whole project.
                standing[task.id] = .planTaskMissing
                report.issues[task.id] = .planTaskMissing
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
                let issue = ChainIssue.sealFailed(Self.describe(error))
                await fail(task.id, issue)
                report.issues[task.id] = issue
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
                        // not retried until a restart.
                        given.insert(reviewer.id)
                        if case IntegrationStoreError.reviewAttemptNotUsable = error { continue }
                        let issue = ChainIssue.collectFailed(Self.describe(error))
                        standing[taskID] = issue
                        report.issues[taskID] = issue
                    }
                }
            }
        }
    }

    /// (e) Removes the worktrees of failed or cancelled reviewers; a new review can be started.
    private func cleanupPass(_ report: inout ChainReport) async {
        guard let trees = try? await store.worktrees() else { return }
        for tree in trees where tree.kind == .reviewer && tree.state != .removed {
            guard let attemptID = tree.attemptID, let attempt = try? await store.attempt(attemptID),
                  attempt.state == .failed || attempt.state == .cancelled else { continue }
            do {
                try await workspace.remove(tree.id, force: true)
                report.removedReviewerTrees.append(tree.id)
            } catch {
                // Left in `needsAttention`; recovery or the user takes over.
            }
        }
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
                if rebuild {
                    await fail(taskID, .containedAfterRebuild)
                    report.issues[taskID] = .containedAfterRebuild
                }
            }
        } catch IntegrationError.taskNotInVerification, IntegrationStoreError.openCandidateExists {
            // Lost a race with the user or another step: retried on the next pass.
        } catch IntegrationStoreError.taskCannotFollow {
            // The task could not take the candidate after the merge (held meanwhile): retried
            // quietly, but not on every pass, so a lasting refusal never loops merges.
            await fail(taskID, nil)
        } catch {
            let issue = ChainIssue.buildFailed(Self.describe(error))
            await fail(taskID, issue)
            report.issues[taskID] = issue
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

    /// The task's current issue (for example a build failure in backoff), if any.
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

    /// Clears the task's build backoff, so the next pass tries again.
    public func retryBuild(_ task: TaskID) {
        backoff[task] = nil
        if let issue = standing[task], issue != .planTaskMissing { standing[task] = nil }
    }

    /// The conflicting paths of a conflicted candidate, read in its integration worktree.
    public func conflictDetails(_ id: CandidateID) async throws -> [ConflictEntry] {
        let candidate = try await candidate(id)
        guard candidate.state == .conflicted, let treeID = candidate.worktreeID else {
            throw IntegrationError.candidateNotIn(id, candidate.state)
        }
        return try await git.conflicts(at: try await workspace.location(of: try await workspace.worktree(treeID)))
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
    /// Slots are a pre-check, not a reservation (ADR 0011 §8). The automation gate's verdict is
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
        let active = try await store.activeAttempts().filter(Self.holdsSlot)
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
            if active.count >= limits.global {
                blockers.append(.slotsFull(global: true))
            } else if let account, active.filter({ $0.accountID == account }).count >= limits.perAccount {
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
        return try await integration.startReview(id, provider: shown.provider, model: shown.model, criteria: shown.criteria)
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
        where attempt.role == .reviewer && attempt.state == .succeeded && !recorded.contains(attempt.id) && !given.contains(attempt.id) {
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

    /// Records a failure with a retry after 5 s × 2ⁿ, at most 5 min.
    private func fail(_ task: TaskID, _ issue: ChainIssue?) async {
        let count = (backoff[task]?.count ?? 0) + 1
        let delay = min(Self.backoffBase << Int64(min(count - 1, 16)), Self.backoffCap)
        backoff[task] = Backoff(count: count, until: await store.now() + delay, issue: issue)
    }

    private func clearIssue(_ task: TaskID) {
        backoff[task] = nil
        standing[task] = nil
    }

    /// Drops backoff and issues of tasks that ended or went back to an author.
    private func forgetSettledTasks() async {
        let known = Set(backoff.keys).union(standing.keys)
        for id in known {
            guard let task = try? await store.task(id) else {
                clearIssue(id)
                continue
            }
            let backToAuthor: Set<TaskState> = [.pending, .ready, .running, .needsChanges]
            if task.state.isTerminal || backToAuthor.contains(task.state) { clearIssue(id) }
        }
    }

    /// Mirrors the store's slot count: active attempts, and `uncertain` ones whose process may
    /// still run (not lost on a restart).
    static func holdsSlot(_ attempt: AttemptRecord) -> Bool {
        switch attempt.state {
        case .reserved, .starting, .running, .awaitingApproval, .cancelling: true
        case .uncertain: attempt.errorClass != "processLostOnRestart"
        case .succeeded, .failed, .cancelled: false
        }
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
        case .noModelProfile, .slotsFull, .adapterMissing: ChainError.shownStateChanged
        }
    }

    static func describe(_ error: any Error) -> String { String(describing: error) }
}
