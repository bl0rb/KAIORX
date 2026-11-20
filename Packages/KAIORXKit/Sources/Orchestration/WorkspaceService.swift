import Domain
import Foundation
import ProcessHost
import Storage
import Workspace

public struct SealReport: Sendable, Equatable {
    public var worktreeID: WorktreeID
    public var outcome: SealOutcome
    public var status: SealStatus
    /// `refs/kaiorx/results/<attempt>`; `nil` unless committed.
    public var resultRef: String?
}

public struct WorkspaceRecoveryReport: Sendable, Equatable {
    public var applied: [GitOperationID] = []
    public var failed: [GitOperationID] = []
    public var needsAttention: [GitOperationID] = []
    /// Left `prepared`, because the project's repository could not be checked; reason by entry.
    public var skipped: [GitOperationID: String] = [:]
    /// Worktrees the database expects that Git or the disk no longer has.
    public var missingWorktrees: [WorktreeID] = []
    /// KAIORX-locked worktrees Git has that the database does not know (left in place).
    public var orphanedWorktrees: [String] = []

    public var isEmpty: Bool {
        applied.isEmpty && failed.isEmpty && needsAttention.isEmpty && skipped.isEmpty && missingWorktrees.isEmpty
            && orphanedWorktrees.isEmpty
    }
}

public enum WorkspaceServiceError: Error, Equatable, Sendable {
    case projectNotFound(ProjectID)
    case jobNotFound(JobID)
    case worktreeNotFound(WorktreeID)
    case worktreeNotReady(WorktreeID, WorktreeState)
    case invalidCommit(String)
    /// A repository without commits has no base to work from and no stable identity yet.
    case repositoryWithoutCommits(String)
    /// The folder no longer holds the repository first attached (its root commit is gone).
    case repositoryChanged(projectID: ProjectID, recorded: String)
    /// A worktree is sealed once; changes after that need a new attempt.
    case alreadySealed(WorktreeID)
    case outsideWorktreeRoot(String)
}

/// The single Git coordinator: every Git side effect is journaled in the store first, then
/// applied, then completed with its domain effects. `reconcile` resolves journal entries a crash
/// left open, by comparing them with Git.
public actor WorkspaceService {
    public let layout: WorkspaceLayout
    private let store: Store
    private let git: GitRunner
    private var repositories: [ProjectID: RepositoryInfo] = [:]

    public init(store: Store, git: GitRunner, layout: WorkspaceLayout) {
        self.store = store
        self.git = git
        self.layout = layout
    }

    // MARK: Projects and jobs

    /// Inspects the project folder and records or checks its Git identity. The identity is the
    /// root commit recorded at the first attach; the folder must still contain it (switching
    /// branches or adding unrelated histories does not change the identity).
    @discardableResult
    public func attach(_ projectID: ProjectID) async throws -> RepositoryInfo {
        guard let project = try await store.projects().first(where: { $0.id == projectID }) else {
            throw WorkspaceServiceError.projectNotFound(projectID)
        }
        let info = try await git.inspect(project.rootLocator)
        if let recorded = project.gitCommonIdentity {
            let parts = recorded.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == info.objectFormat, try await git.containsCommit(parts[1], in: info) else {
                throw WorkspaceServiceError.repositoryChanged(projectID: projectID, recorded: recorded)
            }
        } else {
            guard let identity = info.identity else { throw WorkspaceServiceError.repositoryWithoutCommits(project.rootLocator) }
            try await store.execute(Command(.attachRepository(
                projectID: projectID, gitCommonIdentity: identity, objectFormat: info.objectFormat
            )))
        }
        repositories[projectID] = info
        return info
    }

    /// Resolves the job's base and creates `refs/kaiorx/integrations/<job>` there (create-only).
    /// Uncommitted user changes are not part of the base.
    public func openIntegration(_ jobID: JobID, baseRevision: String) async throws -> (base: String, ref: String) {
        guard let job = try await store.jobs().first(where: { $0.id == jobID }) else { throw WorkspaceServiceError.jobNotFound(jobID) }
        if let base = job.baseOID, let ref = job.integrationRef { return (base, ref) }
        let repository = try await repository(job.projectID)
        let base = try await git.resolveCommit(baseRevision, in: repository)
        let ref = "refs/kaiorx/integrations/\(jobID.uuidString)"
        let operation = try await store.prepareRefUpdate(projectID: job.projectID, worktreeID: nil, ref: ref, expectedOld: nil, desiredNew: base)
        try await applyRefUpdate(operation, ref: ref, to: base, expectedOld: nil, in: repository,
                                 effects: GitOperationEffects(jobIntegration: (jobID, base, ref)))
        return (base, ref)
    }

    // MARK: Worktrees

    public nonisolated func path(of worktree: WorktreeRecord) -> String {
        layout.worktreePath(token: worktree.pathToken)
    }

    /// Creates a detached, locked worktree at `base` outside the user's checkout. Refuses when
    /// the repository has filters, custom merge drivers or submodules at `base`.
    public func prepareWorktree(
        projectID: ProjectID, attemptID: AttemptID?, kind: WorktreeKind, base: String
    ) async throws -> WorktreeRecord {
        let repository = try await repository(projectID)
        guard repository.isValidOID(base) else { throw WorkspaceServiceError.invalidCommit(base) }
        let blockers = try await git.blockers(at: base, in: repository)
        guard blockers.isEmpty else { throw WorkspaceError.blocked(blockers) }

        let id = WorktreeID()
        let (record, operation) = try await store.registerWorktree(WorktreeRegistration(
            id: id, projectID: projectID, attemptID: attemptID, pathToken: "\(projectID.uuidString)/\(id.uuidString)",
            baseOID: base, kind: kind, ownerNonce: Self.nonce()
        ))
        do {
            try await git.addWorktree(at: path(of: record), base: base, lockReason: record.lockReason, in: repository)
            try await store.completeGitOperation(operation, as: .applied, effects: GitOperationEffects(worktreeState: .ready))
        } catch {
            let registered = (try? await registration(of: record, in: repository)) != nil
            try await store.completeGitOperation(
                operation, as: registered ? .needsAttention : .failed, detail: String(describing: error),
                effects: GitOperationEffects(worktreeState: registered ? .needsAttention : .removed)
            )
            throw error
        }
        return try await worktree(id)
    }

    /// The worktree with its administrative folder, for Git and test runs.
    public func location(of worktree: WorktreeRecord) async throws -> WorktreeLocation {
        try git.locate(worktree: path(of: worktree), in: try await repository(worktree.projectID))
    }

    /// Ends write access, commits the accepted changes on top of the base and pins the commit
    /// under `refs/kaiorx/results/<attempt>`. Empty results and results with only rejected
    /// changes are recorded as such. The worktree stays frozen for review.
    public func seal(_ id: WorktreeID, allowedPrefixes: [String]?, message: String) async throws -> SealReport {
        let record = try await worktree(id)
        guard record.state == .ready else { throw WorkspaceServiceError.worktreeNotReady(id, record.state) }
        guard record.sealStatus == nil else { throw WorkspaceServiceError.alreadySealed(id) }
        let repository = try await repository(record.projectID)
        let location = try git.locate(worktree: path(of: record), in: repository)
        try GitRunner.setWritable(location.path, writable: false)
        do {
            let outcome = try await git.buildResult(of: location, base: record.baseOID, allowedPrefixes: allowedPrefixes, message: message)
            let rejected = Dictionary(uniqueKeysWithValues: outcome.rejected.map { ($0.key.path, $0.value.rawValue) })
            guard let commit = outcome.commit else {
                let status: SealStatus = rejected.isEmpty ? .empty : .rejectedOnly
                try await store.transitionWorktree(id, to: .frozen, savedTree: outcome.tree, seal: (status, rejected))
                return SealReport(worktreeID: id, outcome: outcome, status: status, resultRef: nil)
            }
            let ref = "refs/kaiorx/results/\((record.attemptID?.uuidString ?? id.uuidString))"
            let operation = try await store.prepareRefUpdate(projectID: record.projectID, worktreeID: id, ref: ref, expectedOld: nil, desiredNew: commit)
            try await applyRefUpdate(operation, ref: ref, to: commit, expectedOld: nil, in: repository, effects: GitOperationEffects(
                worktreeState: .frozen, resultOID: commit, savedTree: outcome.tree, seal: (.committed, rejected)
            ))
            return SealReport(worktreeID: id, outcome: outcome, status: .committed, resultRef: ref)
        } catch {
            // Nothing was sealed: the author keeps a writable worktree.
            if try await worktree(id).state == .ready { try? GitRunner.setWritable(location.path, writable: true) }
            throw error
        }
    }

    /// Removes a worktree this host created. Without `force`, changes beyond the sealed result
    /// keep it in place (state `needsAttention`).
    public func remove(_ id: WorktreeID, force: Bool = false) async throws {
        let record = try await worktree(id)
        guard layout.isOwnedWorktreePath(path(of: record)) else { throw WorkspaceServiceError.outsideWorktreeRoot(path(of: record)) }
        let repository = try await repository(record.projectID)
        let operation = try await store.prepareWorktreeRemoval(id, force: force)
        do {
            try await git.removeWorktree(at: path(of: record), lockReason: record.lockReason, savedTree: record.savedTree, force: force, in: repository)
            try await store.completeGitOperation(operation, as: .applied, effects: GitOperationEffects(worktreeState: .removed))
        } catch {
            try await store.completeGitOperation(operation, as: .failed, detail: String(describing: error),
                                                 effects: GitOperationEffects(worktreeState: .needsAttention))
            throw error
        }
    }

    /// Checks out `commit` in a disposable QA worktree, runs the confirmed profile there with the
    /// test-runner confinement and removes the worktree again.
    public func runTests(_ profile: TestProfile, projectID: ProjectID, commit: String, confinement: Bool = true) async throws -> TestReport {
        let record = try await prepareWorktree(projectID: projectID, attemptID: nil, kind: .qa, base: commit)
        let location = try await location(of: record)
        let temporary = try layout.runTemporaryDirectory(record.id.uuidString)
        let rules = confinement
            ? RoleProfile.testRunner(writesWorktree: profile.writesWorktree).confinement(
                worktree: location.path, runTemporaryDirectory: temporary, layout: layout, extraHidden: storeFiles)
            : nil
        let report = await git.runTests(profile, in: location, commit: commit, runTemporaryDirectory: temporary, confinement: rules)
        // A finished run keeps its verdict even if the cleanup fails: the worktree is then left
        // in `needsAttention` for recovery.
        try? await remove(record.id, force: true)
        try? FileManager.default.removeItem(atPath: temporary)
        return report
    }

    /// The database, its side files and its pre-migration backups, hidden from confined
    /// processes even when the database is kept outside `layout.root`.
    public var storeFiles: [String] {
        let url = URL(filePath: store.path)
        let folder = url.deletingLastPathComponent().path(percentEncoded: false)
        let backups = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.hasPrefix(url.lastPathComponent + ".backup-") }
            .map { URL(filePath: folder).appending(path: $0).path(percentEncoded: false) }
        return ["", "-wal", "-shm", ".lock"].map { store.path + $0 } + backups
    }

    // MARK: Recovery

    /// Resolves prepared journal entries after a restart. Run before any new Git operation.
    /// A project whose repository cannot be checked is skipped (its entries stay prepared);
    /// the others are still reconciled.
    public func reconcile() async throws -> WorkspaceRecoveryReport {
        var report = WorkspaceRecoveryReport()
        for operation in try await store.gitOperations(state: .prepared) {
            let outcome: (GitOperationState, String?, GitOperationEffects)
            do {
                let repository = try await repository(operation.projectID)
                outcome = try await reconcile(operation, in: repository)
            } catch {
                report.skipped[operation.id] = String(describing: error)
                continue
            }
            do {
                try await store.completeGitOperation(operation.id, as: outcome.0, detail: outcome.1, effects: outcome.2)
            } catch {
                // One entry whose effects cannot be applied must not block the others.
                report.skipped[operation.id] = "completion failed: \(error)"
                continue
            }
            switch outcome.0 {
            case .applied: report.applied.append(operation.id)
            case .failed: report.failed.append(operation.id)
            case .needsAttention, .prepared: report.needsAttention.append(operation.id)
            }
        }

        // Compare the remaining worktrees with Git and the disk.
        let known = try await store.worktrees()
        for projectID in Set(known.map(\.projectID)) {
            guard let repository = try? await repository(projectID),
                  let registered = try? await git.registeredWorktrees(in: repository) else { continue }
            for record in known where record.projectID == projectID && (record.state == .ready || record.state == .frozen) {
                let path = Confinement.resolved(path(of: record))
                let present = registered.contains { $0.path == path && $0.lockReason == record.lockReason }
                    && FileManager.default.fileExists(atPath: path)
                if !present {
                    try await store.transitionWorktree(record.id, to: .needsAttention)
                    report.missingWorktrees.append(record.id)
                } else if record.state == .ready, record.kind == .author {
                    // A crash between freezing and journaling a seal leaves a ready worktree read-only.
                    try? GitRunner.setWritable(path, writable: true)
                }
            }
            let live = Set(known.filter { $0.state != .removed }.map(\.lockReason))
            for entry in registered where entry.lockReason?.hasPrefix("kaiorx:") == true && layout.isOwnedWorktreePath(entry.path) {
                if let reason = entry.lockReason, !live.contains(reason) { report.orphanedWorktrees.append(entry.path) }
            }
        }
        return report
    }

    private func reconcile(_ operation: GitOperationRecord, in repository: RepositoryInfo) async throws -> (GitOperationState, String?, GitOperationEffects) {
        switch operation.kind {
        case .updateRef:
            return try await reconcileRef(operation, in: repository)

        case .addWorktree:
            let record = try await worktree(try require(operation.worktreeID))
            let path = path(of: record)
            guard try await registration(of: record, in: repository) != nil else {
                return (.failed, "not created", GitOperationEffects(worktreeState: .removed))
            }
            guard FileManager.default.fileExists(atPath: path) else {
                return (.needsAttention, "registered but folder missing", GitOperationEffects(worktreeState: .needsAttention))
            }
            // Git registers the worktree before checking out files: only a complete, clean
            // checkout at the base counts as created.
            let location = try git.locate(worktree: path, in: repository)
            let complete = (try? await git.isClean(location, at: record.baseOID)) ?? false
            return complete
                ? (.applied, "found after restart", GitOperationEffects(worktreeState: .ready))
                : (.needsAttention, "checkout incomplete", GitOperationEffects(worktreeState: .needsAttention))

        case .removeWorktree:
            let record = try await worktree(try require(operation.worktreeID))
            let path = path(of: record)
            if try await registration(of: record, in: repository) == nil, !FileManager.default.fileExists(atPath: path) {
                return (.applied, "gone after restart", GitOperationEffects(worktreeState: .removed))
            }
            guard layout.isOwnedWorktreePath(path) else {
                return (.needsAttention, "outside the worktree folder", GitOperationEffects(worktreeState: .needsAttention))
            }
            do {
                // Finishes a removal that was cut off (with the force decided before the crash),
                // including one an older version left unlocked.
                try await git.removeWorktree(
                    at: path, lockReason: record.lockReason, savedTree: record.savedTree, force: operation.force,
                    acceptUnlocked: true, in: repository
                )
                return (.applied, "removed on recovery", GitOperationEffects(worktreeState: .removed))
            } catch {
                return (.needsAttention, String(describing: error), GitOperationEffects(worktreeState: .needsAttention))
            }
        }
    }

    // MARK: Helpers

    public func worktree(_ id: WorktreeID) async throws -> WorktreeRecord {
        guard let record = try await store.worktree(id) else { throw WorkspaceServiceError.worktreeNotFound(id) }
        return record
    }

    private func repository(_ projectID: ProjectID) async throws -> RepositoryInfo {
        if let cached = repositories[projectID] { return cached }
        return try await attach(projectID)
    }

    private func applyRefUpdate(
        _ operation: GitOperationID, ref: String, to new: String, expectedOld: String?, in repository: RepositoryInfo,
        effects: GitOperationEffects
    ) async throws {
        do {
            try await git.updateRef(ref, to: new, expectedOld: expectedOld, in: repository)
        } catch {
            try await store.completeGitOperation(operation, as: .needsAttention, detail: String(describing: error))
            throw error
        }
        try await store.completeGitOperation(operation, as: .applied, effects: effects)
    }

    private func reconcileRef(_ operation: GitOperationRecord, in repository: RepositoryInfo) async throws -> (GitOperationState, String?, GitOperationEffects) {
        let ref = try require(operation.ref)
        let desired = try require(operation.desiredNew)
        var effects = GitOperationEffects()
        if let worktreeID = operation.worktreeID, try await worktree(worktreeID).state == .ready {
            // The rejection list of a seal interrupted here is not recoverable; the result is.
            effects = GitOperationEffects(
                worktreeState: .frozen, resultOID: desired, savedTree: try await git.tree(of: desired, in: repository),
                seal: (.committed, [:])
            )
        }
        let integrationPrefix = "refs/kaiorx/integrations/"
        let publication = operation.approvalID != nil && ref.hasPrefix(integrationPrefix)
        if publication {
            effects.candidatePublished = operation.candidateID
        } else if ref.hasPrefix(integrationPrefix), let job = JobID(string: String(ref.dropFirst(integrationPrefix.count))) {
            effects.jobIntegration = (job, desired, ref)
        }
        let current = try await git.readRef(ref, in: repository)
        if current == desired { return (.applied, "found after restart", effects) }
        guard current == operation.expectedOld else {
            if publication, let candidate = operation.candidateID {
                // The target moved elsewhere: the candidate cannot be published any more.
                return (.failed, "target moved to \(current ?? "nothing")", GitOperationEffects(candidateReleased: (candidate, .superseded)))
            }
            return (.needsAttention, "ref is at \(current ?? "nothing"), expected \(operation.expectedOld ?? "nothing")", GitOperationEffects())
        }
        // A publication is repeated only while the user's approval still stands (granted and not
        // expired, ADR 0007) and the task still waits for the merge (a hold taken meanwhile stops it).
        let now = await store.now()
        if publication, let approval = operation.approvalID, let record = try await store.approval(approval),
           record.state != .granted || record.isExpired(at: now) {
            let release = operation.candidateID.map { GitOperationEffects(candidateReleased: ($0, .accepted)) } ?? GitOperationEffects()
            return (.failed, "approval no longer valid", release)
        }
        if publication, let candidateID = operation.candidateID, let taskID = try await store.candidate(candidateID)?.taskID,
           let task = try await store.task(taskID), task.state != .awaitingMerge {
            return (.failed, "task \(task.state.rawValue)", GitOperationEffects(candidateReleased: (candidateID, .accepted)))
        }
        // The update never happened: repeat the same compare-and-swap.
        do {
            try await git.updateRef(ref, to: desired, expectedOld: operation.expectedOld, in: repository)
            return (.applied, "repeated on recovery", effects)
        } catch {
            let release = publication ? operation.candidateID.map { GitOperationEffects(candidateReleased: ($0, .accepted)) } : nil
            return (publication ? .failed : .needsAttention, String(describing: error), release ?? GitOperationEffects())
        }
    }

    /// Git's entry for this worktree when it is ours: our lock reason, or (after an interrupted
    /// removal by an older version) unlocked at our own path.
    private func registration(of record: WorktreeRecord, in repository: RepositoryInfo) async throws -> RegisteredWorktree? {
        let path = Confinement.resolved(path(of: record))
        return try await git.registeredWorktrees(in: repository).first {
            $0.path == path && ($0.lockReason == record.lockReason || !$0.isLocked)
        }
    }

    private func require<T>(_ value: T?) throws -> T {
        guard let value else { throw StoreError.corruptRow("incomplete git operation") }
        return value
    }

    private static func nonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}
