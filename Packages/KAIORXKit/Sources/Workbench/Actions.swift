import Domain
import Foundation
import Orchestration
import Storage
import Workspace

public enum ActionError: Error, Equatable, Sendable {
    case notAFolder(String)
    case notARepository(String)
    case unavailable(String)
    case unknown(String)
}

/// What the user can do in the app, as plain async calls on the services (no UI). Every decision
/// carries `WorkbenchActor.user`; nothing here comes from model or repository text.
public struct WorkbenchActions: Sendable {
    public let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    var store: Store { services.store }

    /// Opens a folder the user confirmed as trusted (own repository, own test scripts; ADR 0007).
    /// Attaching reads the repository identity and refuses unsupported setups.
    @discardableResult
    public func openProject(at folder: String) async throws -> ProjectID {
        let url = URL(filePath: folder, directoryHint: .isDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ActionError.notAFolder(folder)
        }
        // The repository is checked before anything is stored: a failed check leaves no project.
        guard let git = services.git, let workspace = services.workspace else { throw ActionError.unavailable("Git") }
        let path = url.path(percentEncoded: false)
        do { _ = try await git.inspect(path) } catch { throw ActionError.notARepository(String(describing: error)) }
        if let existing = try await store.projects().first(where: { $0.rootLocator == path }) {
            do { _ = try await workspace.attach(existing.id) } catch { throw ActionError.notARepository(String(describing: error)) }
            return existing.id
        }
        let id = ProjectID()
        try await store.execute(Command(.openProject(id: id, name: url.lastPathComponent, rootLocator: path)))
        do { _ = try await workspace.attach(id) } catch { throw ActionError.notARepository(String(describing: error)) }
        return id
    }

    /// A new job with its plan: the tasks are proposed and accepted as revision 1, the job
    /// becomes active and gets its private integration ref at `baseRevision`. `budget` is the
    /// token budget the user set for each provider's local account in this job.
    @discardableResult
    public func createJob(
        project: ProjectID, goal: String, tasks: [PlanTaskDraft], baseRevision: String = "HEAD", budget: (providers: [ProviderKind], tokens: Int)? = nil
    ) async throws -> JobID {
        guard let workspace = services.workspace else { throw ActionError.unavailable("Git") }
        let job = JobID()
        try await store.execute(Command(.createJob(id: job, projectID: project, goal: goal)))
        let (plan, _) = try await store.proposePlan(job: job, draft: PlanDraft(tasks: tasks), createdBy: .user, expectedCurrent: nil)
        try await store.acceptPlan(plan.id, expectedCurrent: nil)
        guard let record = try await store.jobs().first(where: { $0.id == job }) else { throw ActionError.unknown("job") }
        try await store.execute(Command(.transitionJob(id: job, to: .active, expectedVersion: record.version, reason: nil)))
        _ = try await workspace.openIntegration(job, baseRevision: baseRevision)
        if let budget {
            for provider in budget.providers {
                let account = try await store.registerAccount(provider: provider, identity: "local")
                try await store.createBudget(account: account, job: job, tokenLimit: budget.tokens)
            }
        }
        return job
    }

    /// The user's consent for one provider in a project: the local account (created once),
    /// author and reviewer roles, the whole project as write area (each task still writes only
    /// its declared paths).
    @discardableResult
    public func grantConsent(project: ProjectID, provider: ProviderKind, job: JobID? = nil) async throws -> ConsentRecord {
        let account = try await store.registerAccount(provider: provider, identity: "local")
        var draft = Self.consentDraft(project: project, provider: provider)
        draft.accountID = account
        draft.jobID = job
        return try await store.grantConsent(draft)
    }

    /// Runs a consent allows while the provider reports no quota (ADR 0005: unknown quota).
    public static let unconfirmedRunLimit = 3

    /// The draft the consent sheet shows before the user decides; `grantConsent` grants exactly this.
    public static func consentDraft(project: ProjectID, provider: ProviderKind) -> ConsentDraft {
        ConsentDraft(
            projectID: project, provider: provider, accountID: AccountID(), mode: .automatic, roles: [.author, .reviewer], writeRoots: [""],
            unconfirmedAttemptLimit: unconfirmedRunLimit
        )
    }

    /// The user allows further attempts for a task that stopped for their decision (attempt
    /// limit, top tier, repeated start failures): the counting restarts from here.
    public func allowMoreAttempts(_ task: TaskID) async throws {
        guard let scheduler = services.scheduler else { throw ActionError.unavailable("Scheduler") }
        try await scheduler.grant(task, actor: WorkbenchActor.user)
    }

    /// The explicit start of a task by the user.
    public func start(_ task: TaskID) async throws {
        guard let scheduler = services.scheduler else { throw ActionError.unavailable("Scheduler") }
        _ = try await scheduler.start(task, actor: WorkbenchActor.user)
    }

    public func cancel(_ attempt: AttemptID) async throws {
        try await services.coordinator.cancel(attempt, reason: "user")
    }

    /// Approve exactly what the sheet showed (limited to `ttl` ms), then publish.
    public func approveAndPublish(_ candidate: CandidateID, sheet: DecisionSheet, ttl: Int64 = 15 * 60 * 1000) async throws {
        guard let integration = services.integration else { throw ActionError.unavailable("Integration") }
        guard sheet.canApprove, let shown = sheet.shown else { throw ActionError.unavailable("Freigabe") }
        let approval = try await integration.approve(candidate, actor: WorkbenchActor.user, shown: shown, ttl: ttl)
        try await integration.publish(candidate, approval: approval.id)
    }

    public func reject(_ candidate: CandidateID, reason: String) async throws {
        guard let integration = services.integration else { throw ActionError.unavailable("Integration") }
        try await integration.rejectCandidate(candidate, reason: reason, actor: WorkbenchActor.user)
    }

    public func decideFinding(_ finding: FindingID, accept: Bool, reason: String) async throws {
        guard let integration = services.integration else { throw ActionError.unavailable("Integration") }
        try await integration.decideFinding(finding, accept ? .accepted : .rejected, reason: reason)
    }

    /// Closes an uncertain attempt as cancelled after the user saw that a new try may use quota
    /// again (runtime contract: accept possible double use).
    public func closeUncertain(_ attempt: AttemptID) async throws {
        guard let record = try await store.attempt(attempt), record.state == .uncertain else { return }
        try await store.execute(Command(.transitionAttempt(id: attempt, to: .cancelled, expectedVersion: record.version, errorClass: "closedByUser")))
    }

    /// Files changed by a candidate against its first parent, and one file's diff.
    public func changes(of candidate: CandidateRecord) async throws -> [DiffFile] {
        guard let git = services.git, let workspace = services.workspace, let commit = candidate.candidateOID else { return [] }
        return try await git.fileChanges(from: candidate.previousTargetOID, to: commit, in: try await workspace.attach(candidate.projectID))
    }

    public func diff(of candidate: CandidateRecord, file: DiffFile) async throws -> FileDiffText {
        guard let git = services.git, let workspace = services.workspace, let commit = candidate.candidateOID else {
            return FileDiffText(text: "", truncated: false)
        }
        return try await git.fileDiff(from: candidate.previousTargetOID, to: commit, file: file, in: try await workspace.attach(candidate.projectID))
    }
}
