import Domain
import Foundation
import Orchestration
import Storage
import Workspace

/// What the conflict sheet shows for a conflicted candidate (ADR 0011 §2): the paths with their
/// kind and the commits the side diffs are read between.
public struct ConflictPreview: Sendable, Equatable {
    public var shown: ShownConflicts
    public var kind: CandidateKind
    /// The author attempt's worktree base; nil for a revert, which shows only the kind.
    public var mergeBase: String?
    /// The integration state the candidate was built on (first parent).
    public var target: String
    /// The incoming result (or, for a revert, the reverted state).
    public var result: String
    public var rows: [ConflictRow]

    public init(shown: ShownConflicts, kind: CandidateKind, mergeBase: String?, target: String, result: String, rows: [ConflictRow]) {
        self.shown = shown
        self.kind = kind
        self.mergeBase = mergeBase
        self.target = target
        self.result = result
        self.rows = rows
    }
}

public struct ConflictRow: Sendable, Equatable, Identifiable {
    public var path: String
    public var kind: ConflictEntry.Kind

    public var id: String { path }

    public init(path: String, kind: ConflictEntry.Kind) {
        self.path = path
        self.kind = kind
    }
}

/// The user's choice for one conflicting path. No manual content editing in v1 (ADR 0011 §9.4).
public enum ConflictChoice: String, Sendable, CaseIterable {
    /// Keep the integration state's version (`.ours`).
    case target
    /// Take the result's version (`.theirs`).
    case result
    case delete

    public var resolution: ConflictResolution {
        switch self {
        case .target: .ours
        case .result: .theirs
        case .delete: .delete
        }
    }
}

/// Which side of a conflict a side diff shows: `mergeBase..target` or `mergeBase..result`.
public enum ConflictSide: Sendable {
    case target, result
}

/// The write area a result was sealed against: the attempt's plan revision decides, not a later
/// one (ADR 0011 §4).
public enum ResultWriteArea: Sendable, Equatable {
    /// No plan task: the whole project.
    case wholeProject
    case paths([String])
    /// The task has a plan key the attempt's plan revision does not know.
    case planTaskMissing
}

/// German texts for the errors of the candidate chain, shown in its sheets.
public enum ChainMessages {
    public static func text(_ error: any Error) -> String {
        switch error {
        case ChainError.shownStateChanged, IntegrationError.shownStateChanged:
            "Der Stand hat sich geändert, seit das Blatt ihn gezeigt hat. Entscheide neu."
        case ChainError.busy: "Die Aufgabe wird gerade bearbeitet. Versuche es gleich noch einmal."
        case ChainError.notImplemented: "Die Kandidatenkette ist noch nicht verfügbar."
        case IntegrationError.undeclaredChanges:
            "Beim Versiegeln wurden Änderungen außerhalb des Schreibbereichs verworfen. Bestätige zuerst, dass ohne sie gebaut wird."
        case IntegrationError.resultNotEmpty: "Das Ergebnis ist weder leer noch im Integrationsstand enthalten."
        case IntegrationError.resultNotSealed: "Das Ergebnis ist noch nicht versiegelt."
        case IntegrationError.taskNotInVerification, IntegrationStoreError.taskNotInVerification:
            "Die Aufgabe ist angehalten, beendet oder wieder beim Autor."
        case IntegrationError.candidateNotIn(_, let state):
            "Der Kandidat ist im Zustand „\(Labels.candidate(state).text)“; diese Entscheidung passt nicht mehr dazu."
        case IntegrationStoreError.openCandidateExists: "Für diese Aufgabe gibt es schon einen offenen Kandidaten."
        case MergeError.unresolved(let paths): "Für diese Dateien fehlt noch eine Entscheidung: \(paths.joined(separator: ", "))"
        case MergeError.nothingToCommit: "Nach deiner Auflösung bleibt nichts zu integrieren; der Kandidat wurde abgelehnt."
        case IntegrationError.reviewerNotIndependent: "Der Prüfer muss von einem anderen Anbieter kommen als der Autor."
        case IntegrationError.reviewAttemptNotFinished: "Das Review konnte nicht starten oder ist nicht abgeschlossen."
        case PlanningError.noReviewerConsent(let provider): "Für \(Labels.provider(provider)) fehlt die Zustimmung als Prüfer."
        case StoreError.activeReviewerExists: "Für diese Aufgabe läuft schon ein Review."
        case PlanningError.accountBlocked: "Das Prüferkonto ist gesperrt."
        case PlanningError.slotsFull(let global, let provider): Labels.reviewBlocker(.slotsFull(global: global), provider: provider) + "."
        case MemoryError.candidateContentPurged: "Die Inhalte des Autors wurden vergessen; dieser Kandidat bekommt kein neues Review."
        case ChainActionError.notAPlanTask:
            "Nur Aufgaben aus einem Plan lassen sich neu bearbeiten."
        case ChainActionError.nothingToDecide: "Für dieses Ergebnis ist gerade nichts zu entscheiden."
        case ChainActionError.reviewBlocked(let reasons): "Das Review kann nicht starten: \(reasons.joined(separator: "; "))."
        case ChainActionError.emptyReview: "Füge zuerst den Text des Reviews ein."
        case IntegrationError.reviewStartFailed(_, let reason): "Das Review konnte nicht starten: \(reason)"
        default: IntegrationMessages.text(error)
        }
    }
}

/// Why a chain action refuses before it reaches the driver or a service.
public enum ChainActionError: Error, Sendable, Equatable {
    /// Discarding is offered only for plan tasks: only the scheduler picks a task up again.
    case notAPlanTask(TaskID)
    /// The shown result is not one a decision applies to (no result, or already a candidate).
    case nothingToDecide(TaskID)
    /// The option the sheet showed still has blockers (German texts).
    case reviewBlocked([String])
    case emptyReview
}

/// The user's actions on the candidate chain (ADR 0011). Each guards `services.chain`, so none
/// runs before the Git journal was repaired.
extension WorkbenchActions {
    func requireChain() throws -> CandidateChain {
        guard let chain = services.chain else { throw ActionError.unavailable("Kandidatenkette") }
        return chain
    }

    /// The task's current author attempt, if any.
    func currentAuthorAttempt(of task: TaskRecord) async throws -> AttemptRecord? {
        guard let id = task.currentAttemptID, let attempt = try await store.attempt(id), attempt.role == .author else { return nil }
        return attempt
    }

    func requireTask(_ id: TaskID) async throws -> TaskRecord {
        guard let task = try await store.task(id) else { throw StoreError.notFound(entity: "task", id: id.uuidString) }
        return task
    }

    /// The task's result as a sheet would show it, with the driver's current issue.
    public func resultCheck(_ task: TaskID) async throws -> (ShownResult, ChainIssue?) {
        let chain = try requireChain()
        let check = try await chain.check(task)
        let record = try await requireTask(task)
        guard let treeID = try await currentAuthorAttempt(of: record)?.worktreeID, let tree = try await store.worktree(treeID) else {
            throw ActionError.unavailable("Ergebnis")
        }
        let shown = ShownResult(
            task: task, taskVersion: record.version, worktree: tree.id, resultOID: tree.resultOID, rejected: tree.rejectedPaths.keys.sorted(),
            check: check
        )
        return (shown, await chain.issue(task))
    }

    /// The write area the task's current result was sealed against, from the attempt's plan
    /// revision (the same value the sandbox and the prompt got).
    public func writeArea(of task: TaskID) async throws -> ResultWriteArea {
        let record = try await requireTask(task)
        guard let key = record.planKey else { return .wholeProject }
        guard let planID = try await currentAuthorAttempt(of: record)?.planID, let planned = try? await store.validatedPlan(planID).task(key) else {
            return .planTaskMissing
        }
        // As the plan declares it (the start sheet shows the same), not the normalized prefixes.
        guard planned.writeArea != .wholeProject, let paths = planned.draft.writePaths else { return .wholeProject }
        return .paths(paths.sorted())
    }

    /// Builds the shown result without its rejected paths.
    public func confirmUndeclared(_ shown: ShownResult) async throws -> BuildOutcome {
        try await requireChain().buildConfirmed(shown)
    }

    /// Accepts the shown empty or already contained result (also after a rebuild) as done.
    public func acceptEmptyResult(_ shown: ShownResult) async throws {
        try await requireChain().acceptEmpty(shown)
    }

    /// Discards the shown result: the grant and `needsChanges` in one transaction, so the
    /// attempt count restarts (ADR 0011 §7); nothing is voided any more. Runs through the chain
    /// under the task's lock (`CandidateChain.discard`), which checks the shown state again.
    /// Offered for plan tasks only (the scheduler only takes plan tasks). The optional `reason`
    /// goes to the next author unless it looks like a secret (`ReworkPrompt`).
    public func discardResult(_ shown: ShownResult, reason: String? = nil) async throws {
        let chain = try requireChain()
        // Only the scheduler picks the task up again.
        guard services.scheduler != nil else { throw ActionError.unavailable("Scheduler") }
        switch shown.check {
        case .notApplicable, .candidate, .supersededContained: throw ChainActionError.nothingToDecide(shown.task)
        default: break
        }
        let task = try await requireTask(shown.task)
        guard task.planKey != nil else { throw ChainActionError.notAPlanTask(task.id) }
        try await chain.discard(shown, reason: reason, actor: WorkbenchActor.user)
    }

    /// Clears the task's build backoff, so the driver tries again on its next pass.
    public func retryBuild(_ task: TaskID) async throws {
        let chain = try requireChain()
        await chain.retryBuild(task)
    }

    /// Forgets the review collects the driver refused for the task, so its next pass collects
    /// the finished reviewers again. Starts no provider.
    public func retryCollect(_ task: TaskID) async throws {
        let chain = try requireChain()
        await chain.retryCollect(task)
    }

    /// The conflicting paths of a conflicted candidate with their kinds, and the commits the
    /// side diffs read between. Read-only.
    public func conflictPreview(_ candidate: CandidateID) async throws -> ConflictPreview {
        let chain = try requireChain()
        guard let record = try await store.candidate(candidate) else { throw StoreError.notFound(entity: "candidate", id: candidate.uuidString) }
        guard record.state == .conflicted else { throw IntegrationError.candidateNotIn(candidate, record.state) }
        let entries = try await chain.conflictDetails(candidate)
        var mergeBase: String?
        var incoming = record.resultOID ?? ""
        switch record.kind {
        case .implementation:
            if let attemptID = record.authorAttemptID, let tree = try await store.attempt(attemptID)?.worktreeID {
                mergeBase = try await store.worktree(tree)?.baseOID
            }
        case .revert:
            // The incoming side of a revert is the state before the reverted merge; no side diffs.
            if let reverted = record.revertsCandidateID, let original = try await store.candidate(reverted) {
                incoming = original.previousTargetOID
            }
        }
        let rows = entries.map { ConflictRow(path: $0.path, kind: $0.kind) }.sorted { $0.path < $1.path }
        return ConflictPreview(
            shown: ShownConflicts(candidate: candidate, version: record.version, paths: rows.map(\.path)), kind: record.kind,
            mergeBase: mergeBase, target: record.previousTargetOID, result: incoming, rows: rows
        )
    }

    /// One side of a conflicting path, diffed from the merge base: what the run changed
    /// (`result`) or what changed in the integration state since (`target`). Read-only; empty
    /// for a revert (no merge base) or a path that side did not touch.
    public func conflictSideDiff(_ preview: ConflictPreview, path: String, side: ConflictSide) async throws -> FileDiffText {
        _ = try requireChain()
        guard let git = services.git, let workspace = services.workspace else { throw ActionError.unavailable("Git") }
        let empty = FileDiffText(text: "", truncated: false)
        guard let base = preview.mergeBase, preview.rows.contains(where: { $0.path == path }),
              let record = try await store.candidate(preview.shown.candidate) else { return empty }
        let repository = try await workspace.attach(record.projectID)
        let commit = side == .target ? preview.target : preview.result
        let files = try await git.fileChanges(from: base, to: commit, in: repository)
        guard let file = files.first(where: { $0.newPath == path || $0.oldPath == path }) else { return empty }
        return try await git.fileDiff(from: base, to: commit, file: file, in: repository)
    }

    /// Resolves the conflicts the sheet showed with the user's choices; every shown path needs one.
    public func resolveConflicts(_ preview: ConflictPreview, choices: [String: ConflictChoice]) async throws -> CandidateRecord {
        let chain = try requireChain()
        let missing = preview.shown.paths.filter { choices[$0] == nil }
        guard missing.isEmpty else { throw MergeError.unresolved(missing) }
        var resolutions: [String: ConflictResolution] = [:]
        for path in preview.shown.paths { resolutions[path] = choices[path]?.resolution }
        return try await chain.resolveConflicts(preview.shown, resolutions)
    }

    /// The providers a review of the candidate could run with, each with its blockers.
    public func reviewOptions(_ candidate: CandidateID) async throws -> [ReviewOption] {
        try await requireChain().reviewOptions(candidate)
    }

    /// Starts the review the sheet showed. An explicit start does not ask the automation gate
    /// (ADR 0009 §8); the chain refuses if the option changed since it was shown.
    public func startReview(_ option: ReviewOption, candidate: CandidateID) async throws -> AttemptID {
        let chain = try requireChain()
        guard option.blockers.isEmpty else {
            throw ChainActionError.reviewBlocked(option.blockers.map { Labels.reviewBlocker($0, provider: option.provider) })
        }
        return try await chain.startReview(option, candidate: candidate)
    }

    /// Records a review the user pasted as reported text, marked as imported.
    public func importReview(_ candidate: CandidateID, text: String) async throws -> ReviewRecord {
        _ = try requireChain()
        guard let integration = services.integration else { throw ActionError.unavailable("Integration") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChainActionError.emptyReview }
        return try await integration.importReview(candidate, text: text)
    }
}
