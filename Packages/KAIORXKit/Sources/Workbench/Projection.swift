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
            for candidate in try await store.candidates(jobID: job.id) { fresh.candidates[candidate.id] = candidate }
        }
        for task in try await store.tasks() { fresh.tasks[task.id] = task }
        for attempt in try await store.attempts() { fresh.attempts[attempt.id] = attempt }
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
                for attempt in try await store.attempts(taskID: id) { state.attempts[attempt.id] = attempt }
            }
        }
        if !projectIDs.isEmpty {
            for project in try await store.projects() { state.projects[project.id] = project }
            for project in projectIDs {
                for job in try await store.jobs(projectID: project) {
                    state.jobs[job.id] = job
                    jobIDs.insert(job.id)
                }
            }
        }
        for job in jobIDs {
            if let record = try await store.jobs().first(where: { $0.id == job }) { state.jobs[job] = record }
            for candidate in try await store.candidates(jobID: job) { state.candidates[candidate.id] = candidate }
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
