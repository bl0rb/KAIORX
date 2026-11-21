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

/// German texts for the errors of the candidate chain, shown in its sheets.
public enum ChainMessages {
    public static func text(_ error: any Error) -> String {
        switch error {
        case ChainError.shownStateChanged, IntegrationError.shownStateChanged:
            "Der Stand hat sich geändert, seit das Blatt ihn gezeigt hat. Entscheide neu."
        case ChainError.busy: "Die Aufgabe wird gerade bearbeitet. Versuche es gleich noch einmal."
        case ChainError.notImplemented: "Die Kandidatenkette ist noch nicht verfügbar."
        case IntegrationError.undeclaredChanges:
            "Das Ergebnis hat Änderungen außerhalb des Schreibbereichs verworfen. Bestätige zuerst, dass ohne sie gebaut wird."
        case IntegrationError.resultNotEmpty: "Das Ergebnis ist weder leer noch im Integrationsstand enthalten."
        case IntegrationError.taskNotInVerification, IntegrationStoreError.taskNotInVerification:
            "Die Aufgabe ist angehalten, beendet oder wieder beim Autor."
        case IntegrationStoreError.openCandidateExists: "Für diese Aufgabe gibt es schon einen offenen Kandidaten."
        case MergeError.unresolved(let paths): "Für diese Dateien fehlt noch eine Entscheidung: \(paths.joined(separator: ", "))"
        case IntegrationError.reviewerNotIndependent: "Der Prüfer muss von einem anderen Anbieter kommen als der Autor."
        case StoreError.activeReviewerExists: "Für diese Aufgabe läuft schon ein Review."
        case PlanningError.accountBlocked: "Das Prüferkonto ist gesperrt."
        case MemoryError.candidateContentPurged: "Die Inhalte des Autors wurden vergessen; dieser Kandidat bekommt kein neues Review."
        default: IntegrationMessages.text(error)
        }
    }
}

/// The user's actions on the candidate chain (ADR 0011). Each guards `services.chain`.
///
/// Skeleton (WP0): the signatures are frozen; the bodies follow with WP3.
extension WorkbenchActions {
    /// The task's result as a sheet would show it, with the driver's current issue.
    public func resultCheck(_ task: TaskID) async throws -> (ShownResult, ChainIssue?) {
        throw ActionError.unavailable("Kandidatenkette")
    }

    /// Builds the shown result without its rejected paths.
    public func confirmUndeclared(_ shown: ShownResult) async throws -> BuildOutcome {
        throw ActionError.unavailable("Kandidatenkette")
    }

    /// Accepts the shown empty or already contained result as done.
    public func acceptEmptyResult(_ shown: ShownResult) async throws {
        throw ActionError.unavailable("Kandidatenkette")
    }

    /// Discards the shown result: grant first, then `needsChanges`; the attempt count restarts.
    public func discardResult(_ shown: ShownResult) async throws {
        throw ActionError.unavailable("Kandidatenkette")
    }

    /// Clears the task's build backoff.
    public func retryBuild(_ task: TaskID) async throws {
        throw ActionError.unavailable("Kandidatenkette")
    }

    public func conflictPreview(_ candidate: CandidateID) async throws -> ConflictPreview {
        throw ActionError.unavailable("Kandidatenkette")
    }

    /// One side of a conflicting path, diffed from the merge base. Read-only.
    public func conflictSideDiff(_ preview: ConflictPreview, path: String, side: ConflictSide) async throws -> FileDiffText {
        throw ActionError.unavailable("Kandidatenkette")
    }

    public func resolveConflicts(_ preview: ConflictPreview, choices: [String: ConflictChoice]) async throws -> CandidateRecord {
        throw ActionError.unavailable("Kandidatenkette")
    }

    public func reviewOptions(_ candidate: CandidateID) async throws -> [ReviewOption] {
        throw ActionError.unavailable("Kandidatenkette")
    }

    public func startReview(_ option: ReviewOption, candidate: CandidateID) async throws -> AttemptID {
        throw ActionError.unavailable("Kandidatenkette")
    }

    /// Records a review the user pasted as reported text.
    public func importReview(_ candidate: CandidateID, text: String) async throws -> ReviewRecord {
        throw ActionError.unavailable("Kandidatenkette")
    }
}
