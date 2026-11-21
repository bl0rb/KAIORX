import Domain
import Foundation
import Storage

/// Milliseconds since 1970; injected so tests run in virtual time.
public typealias WorkbenchClock = @Sendable () -> Int64

/// The rows a window shows, re-read from the store. Events are only invalidation signals: the
/// projector maps each event to the rows it can have changed and reads those rows again, so a
/// replay from any cursor ends in the same state (ADR 0007).
public struct WorkspaceState: Sendable, Equatable {
    public var projects: [ProjectID: ProjectRecord] = [:]
    public var jobs: [JobID: JobRecord] = [:]
    public var tasks: [TaskID: TaskRecord] = [:]
    public var attempts: [AttemptID: AttemptRecord] = [:]
    public var candidates: [CandidateID: CandidateRecord] = [:]
    /// Author and reviewer worktrees (seal status, rejected paths, the commit a reviewer reads);
    /// test and integration worktrees are not shown.
    public var worktrees: [WorktreeID: WorktreeRecord] = [:]
    /// Reviews per candidate, oldest first.
    public var reviews: [CandidateID: [ReviewRecord]] = [:]
    /// Time of the latest event of an attempt (provider output included), for "last activity".
    public var lastActivity: [AttemptID: Int64] = [:]
    /// The replay cursor: everything up to this `seq` is reflected.
    public var cursor: Int64 = 0

    public init() {}

    public func tasks(of job: JobID) -> [TaskRecord] {
        tasks.values.filter { $0.jobID == job }.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    public func attempts(of task: TaskID) -> [AttemptRecord] {
        attempts.values.filter { $0.taskID == task }.sorted { ($0.role.rawValue, $0.ordinal) < ($1.role.rawValue, $1.ordinal) }
    }

    public func candidates(of job: JobID) -> [CandidateRecord] {
        candidates.values.filter { $0.jobID == job }.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    public func jobs(of project: ProjectID) -> [JobRecord] {
        jobs.values.filter { $0.projectID == project }.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// Open attempts (not terminal), uncertain ones included: they are shown as open.
    public var openAttempts: [AttemptRecord] {
        attempts.values.filter { !$0.state.isTerminal }.sorted { ($0.reservedAt, $0.id.uuidString) < ($1.reservedAt, $1.id.uuidString) }
    }

    /// Which worktrees the projection keeps: those of authors and reviewers, removed ones
    /// included (a reviewer's worktree still tells which commit it read).
    static func shows(_ worktree: WorktreeRecord) -> Bool { worktree.kind == .author || worktree.kind == .reviewer }

    /// The worktree holding the task's current author result.
    public func resultWorktree(of task: TaskID) -> WorktreeRecord? {
        guard let attempt = tasks[task]?.currentAttemptID.flatMap({ attempts[$0] }), attempt.role == .author,
              let tree = attempt.worktreeID else { return nil }
        return worktrees[tree]
    }

    /// The reviewer attempts that read exactly this candidate's commit, oldest first.
    public func reviewers(of candidate: CandidateRecord) -> [AttemptRecord] {
        guard let task = candidate.taskID, let commit = candidate.candidateOID else { return [] }
        return attempts(of: task).filter { attempt in
            attempt.role == .reviewer && attempt.worktreeID.flatMap { worktrees[$0] }?.baseOID == commit
        }
    }

    /// The task's open reviewer attempt (uncertain included: it still holds the review).
    public func openReviewer(of task: TaskID) -> AttemptRecord? {
        attempts(of: task).first { $0.role == .reviewer && !$0.state.isTerminal }
    }

    /// The candidate a task has open (not published, rejected or superseded), if any.
    public func openCandidate(of task: TaskID) -> CandidateRecord? {
        candidates.values.filter { $0.taskID == task && ![.published, .rejected, .superseded].contains($0.state) }
            .max { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// A candidate in review that waits for the user to start one: no readable review of its
    /// commit, no open reviewer, and no finished reviewer the driver has yet to collect. With
    /// `collectFailed` (the driver gave up collecting a finished reviewer, `ChainIssue.collectFailed`)
    /// that reviewer no longer counts as on its way, so a new start is offered.
    public func needsReview(_ candidate: CandidateRecord, collectFailed: Bool = false) -> Bool {
        guard candidate.state == .reviewing, let commit = candidate.candidateOID, let taskID = candidate.taskID,
              tasks[taskID]?.state == .verifying else { return false }
        let ofCommit = (reviews[candidate.id] ?? []).filter { $0.candidateOID == commit }
        if ofCommit.contains(where: { $0.status != .invalid }) { return false }
        if openReviewer(of: taskID) != nil { return false }
        if collectFailed { return true }
        return !uncollectedReviewer(of: candidate)
    }

    /// Whether a reviewer of exactly this commit succeeded but its review is not recorded yet.
    func uncollectedReviewer(of candidate: CandidateRecord) -> Bool {
        let recorded = Set((reviews[candidate.id] ?? []).filter { $0.candidateOID == candidate.candidateOID }.compactMap(\.reviewerAttemptID))
        return reviewers(of: candidate).contains { $0.state == .succeeded && !recorded.contains($0.id) }
    }

    /// Where the review of a candidate stands. `issue` is the driver's issue with its task: a
    /// refused collect is shown instead of „Review wird übernommen …“, which would never end.
    /// Without the chain nothing is collected, so that status is never shown either.
    public func reviewStatus(of candidate: CandidateRecord, issue: ChainIssue?, chainAvailable: Bool) -> StatusLabel {
        if let task = candidate.taskID, let open = openReviewer(of: task) {
            return StatusLabel("Review läuft (\(Labels.provider(open.provider)))", "eye", .active)
        }
        let reviews = (reviews[candidate.id] ?? []).filter { $0.candidateOID == candidate.candidateOID }
        let latest = reviews.max { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }
        if uncollectedReviewer(of: candidate) {
            if let latest, PendingDecisions.collectFailed(issue) || !chainAvailable { return Labels.review(latest.status) }
            if PendingDecisions.collectFailed(issue) { return Self.reviewNotCollected }
            if !chainAvailable { return StatusLabel("Kandidatenkette nicht verfügbar – das Review wird nicht übernommen", "exclamationmark.octagon", .failure) }
            return StatusLabel("Review wird übernommen …", "tray.and.arrow.down", .active)
        }
        if let latest { return Labels.review(latest.status) }
        if let last = reviewers(of: candidate).last, last.state == .failed || last.state == .cancelled { return Self.reviewerStopped }
        return StatusLabel("Noch kein Review", "eye.slash", .waiting)
    }

    public static let reviewNotCollected = StatusLabel("Review nicht übernommen – starte ein neues Review", "exclamationmark.triangle", .failure)
    public static let reviewerStopped = StatusLabel("Prüfer abgebrochen", "xmark.circle", .warning)
}

/// What one projection step changed.
public struct ProjectionDelta: Sendable, Equatable {
    public var state: WorkspaceState
    /// An approval, a terminal attempt state or a recovery need: published without coalescing.
    public var critical: Bool
    public var events: Int
}

/// Reads event headers after the cursor (no payloads, a page at a time) and re-reads the rows
/// they name. Runs off the main actor.
public actor Projector {
    private let store: Store
    private var state = WorkspaceState()
    private let pageSize: Int
    static let criticalKinds: Set<EventKind> = [.approvalResolved, .attemptCompleted, .recoveryRequired, .candidateStateChanged, .policyDecided]
    static let activityKinds: Set<EventKind> = [.messageDelta, .messageFinal, .toolStarted, .toolEnded, .usageObserved, .providerDiagnostic]

    public init(store: Store, pageSize: Int = 500) {
        self.store = store
        self.pageSize = pageSize
    }

    /// The first full read: every row, cursor at the newest event.
    public func load() async throws -> WorkspaceState {
        var fresh = WorkspaceState()
        // The cursor first: rows read afterwards are at least as new, later events re-read them.
        let cursor = try await store.latestEventSeq()
        for project in try await store.projects() { fresh.projects[project.id] = project }
        for job in try await store.jobs() {
            fresh.jobs[job.id] = job
            for candidate in try await store.candidates(jobID: job.id) {
                fresh.candidates[candidate.id] = candidate
                fresh.reviews[candidate.id] = try await store.reviews(candidate: candidate.id)
            }
        }
        for task in try await store.tasks() { fresh.tasks[task.id] = task }
        for attempt in try await store.attempts() { fresh.attempts[attempt.id] = attempt }
        for worktree in try await store.worktrees() where WorkspaceState.shows(worktree) { fresh.worktrees[worktree.id] = worktree }
        fresh.cursor = cursor
        state = fresh
        return fresh
    }

    /// One step: at most `maxPages` pages of events; nil when nothing new arrived.
    public func step(maxPages: Int = 4) async throws -> ProjectionDelta? {
        var events: [EventRecord] = []
        for _ in 0..<maxPages {
            let page = try await store.eventHeaders(after: events.last?.seq ?? state.cursor, limit: pageSize)
            events += page
            if page.count < pageSize { break }
        }
        guard let last = events.last else { return nil }
        var taskIDs = Set<TaskID>(), attemptIDs = Set<AttemptID>(), projectIDs = Set<ProjectID>()
        var critical = false
        for event in events {
            if Self.criticalKinds.contains(event.kind) || event.kind == .attemptStateChanged { critical = true }
            if let attempt = event.attemptID {
                state.lastActivity[attempt] = max(state.lastActivity[attempt] ?? 0, event.at)
                // Provider output changes no row: only the activity time.
                if Self.activityKinds.contains(event.kind) { continue }
                attemptIDs.insert(attempt)
            }
            if let task = event.taskID { taskIDs.insert(task) }
            if event.taskID == nil && event.attemptID == nil { projectIDs.insert(event.projectID) }
        }
        for id in attemptIDs {
            if let attempt = try await store.attempt(id) {
                state.attempts[id] = attempt
                taskIDs.insert(attempt.taskID)
            }
        }
        var jobIDs = Set<JobID>()
        for id in taskIDs {
            if let task = try await store.task(id) {
                state.tasks[id] = task
                jobIDs.insert(task.jobID)
                for attempt in try await store.attempts(taskID: id) {
                    state.attempts[attempt.id] = attempt
                    // A reviewer worktree is linked to its attempt without an event of its own.
                    if let tree = attempt.worktreeID, let worktree = try await store.worktree(tree), WorkspaceState.shows(worktree) {
                        state.worktrees[tree] = worktree
                    }
                }
            }
        }
        if !projectIDs.isEmpty {
            for project in try await store.projects() { state.projects[project.id] = project }
            for project in projectIDs {
                // Worktree events (prepare, seal, removal) carry neither task nor attempt.
                for worktree in try await store.worktrees(projectID: project) where WorkspaceState.shows(worktree) {
                    state.worktrees[worktree.id] = worktree
                }
                for job in try await store.jobs(projectID: project) {
                    state.jobs[job.id] = job
                    jobIDs.insert(job.id)
                }
            }
        }
        for job in jobIDs {
            if let record = try await store.jobs().first(where: { $0.id == job }) { state.jobs[job] = record }
            for candidate in try await store.candidates(jobID: job) {
                state.candidates[candidate.id] = candidate
                state.reviews[candidate.id] = try await store.reviews(candidate: candidate.id)
            }
            // Tasks created without an event of their own (plan acceptance) appear with the job.
            for task in try await store.tasks(jobID: job) where state.tasks[task.id] != task { state.tasks[task.id] = task }
        }
        state.cursor = last.seq
        return ProjectionDelta(state: state, critical: critical, events: events.count)
    }
}

/// Decides when a visible area publishes: at most once per interval, critical changes at once,
/// hidden areas only remember that they are dirty (Plan/macos-und-git.md: bundle updates per
/// visible area).
public struct Coalescer: Sendable {
    public var interval: Int64
    private var lastPublished: Int64?
    private(set) public var dirty = false

    public init(interval: Int64 = 100) {
        self.interval = interval
    }

    /// Records a change; returns true when it should be published now.
    public mutating func change(at now: Int64, critical: Bool, visible: Bool) -> Bool {
        dirty = true
        guard visible else { return false }
        if critical || lastPublished.map({ now - $0 >= interval }) ?? true { return publish(at: now) }
        return false
    }

    /// A timer tick or the area becoming visible: publishes what is pending once the interval passed.
    public mutating func tick(at now: Int64, visible: Bool) -> Bool {
        guard dirty, visible, lastPublished.map({ now - $0 >= interval }) ?? true else { return false }
        return publish(at: now)
    }

    private mutating func publish(at now: Int64) -> Bool {
        lastPublished = now
        dirty = false
        return true
    }
}
