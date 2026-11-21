import Domain
import Foundation
import Orchestration
import Storage

/// The user who decides in this app. Never taken from model, review or repository text.
public enum WorkbenchActor {
    public static let user = "user"
}

/// Something that waits for the user, derived from the stored state (no event of its own; ADR 0007).
public enum PendingDecision: Sendable, Equatable, Hashable, Identifiable {
    /// An accepted candidate whose only missing condition is the approval.
    case publish(CandidateID)
    /// A task waiting for the user's start, decision or consent.
    case task(TaskID, WaitReason)
    /// An attempt whose process was lost: the user decides after reconciliation.
    case uncertain(AttemptID)
    /// A candidate in review with findings that need a decision.
    case findings(CandidateID)

    public var id: String {
        switch self {
        case .publish(let id): "publish:\(id.uuidString)"
        case .task(let id, let reason): "task:\(id.uuidString):\(reason.kind.rawValue)"
        case .uncertain(let id): "uncertain:\(id.uuidString)"
        case .findings(let id): "findings:\(id.uuidString)"
        }
    }
}

public enum PendingDecisions {
    static let userKinds: Set<WaitReason.Kind> = [.userDecision, .awaitingUserStart, .consent]

    /// Everything in `project` (or every project) that waits for the user, oldest first.
    public static func collect(
        _ state: WorkspaceState, project: ProjectID?, gate: @Sendable (CandidateID) async throws -> [GateItem],
        openFindings: @Sendable (CandidateID) async throws -> Bool
    ) async throws -> [PendingDecision] {
        func inProject(_ job: JobID) -> Bool {
            guard let project else { return true }
            return state.jobs[job]?.projectID == project
        }
        var result: [PendingDecision] = []
        for candidate in state.candidates.values.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) })
        where inProject(candidate.jobID) {
            if candidate.state == .accepted, let task = candidate.taskID.flatMap({ state.tasks[$0] }), task.state == .awaitingMerge,
               try await gate(candidate.id).isEmpty {
                result.append(.publish(candidate.id))
            } else if candidate.state == .reviewing, try await openFindings(candidate.id) {
                result.append(.findings(candidate.id))
            }
        }
        for task in state.tasks.values.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) })
        where inProject(task.jobID) {
            if let reason = task.waitReason.flatMap(WaitReason.init(stored:)), userKinds.contains(reason.kind) {
                result.append(.task(task.id, reason))
            }
        }
        for attempt in state.attempts.values.sorted(by: { ($0.reservedAt, $0.id.uuidString) < ($1.reservedAt, $1.id.uuidString) })
        where attempt.state == .uncertain {
            if let task = state.tasks[attempt.taskID], inProject(task.jobID) { result.append(.uncertain(attempt.id)) }
        }
        return result
    }
}

/// What every decision sheet shows: the concrete action, its scope, and what a rejection means
/// (ARCHITEKTURPLAN §4). Built only from typed fields; text a model or reviewer wrote appears
/// only in `reported`, labelled as reported text. The safe default (Return) is never the approval.
public struct DecisionSheet: Sendable, Equatable {
    public var title: String
    public var action: String
    public var scope: [String]
    public var ifRejected: String
    public var approveLabel: String
    public var rejectLabel: String
    /// Text from providers or reviewers, shown separately as „gemeldeter Text“.
    public var reported: String?
    /// Conditions that still block the approval (empty: it may be given).
    public var blockers: [String]
    /// For a publication: exactly what the approval binds to.
    public var shown: ShownApproval?
    /// For a delivery branch: the job, name and integration state the sheet showed.
    public var delivery: ShownDelivery?

    public var canApprove: Bool { blockers.isEmpty }

    public init(
        title: String, action: String, scope: [String], ifRejected: String, approveLabel: String, rejectLabel: String, reported: String?,
        blockers: [String], shown: ShownApproval?
    ) {
        self.title = title
        self.action = action
        self.scope = scope
        self.ifRejected = ifRejected
        self.approveLabel = approveLabel
        self.rejectLabel = rejectLabel
        self.reported = reported
        self.blockers = blockers
        self.shown = shown
    }

    /// The publication of a candidate onto its integration target.
    public static func publish(_ candidate: CandidateRecord, task: TaskRecord?, gate: [GateItem]) -> DecisionSheet {
        let commit = candidate.candidateOID ?? "–"
        return DecisionSheet(
            title: "Integration veröffentlichen",
            action: "Den geprüften Commit \(Labels.short(commit)) auf das Integrationsziel setzen.",
            scope: [
                "Aufgabe: \(task?.title ?? "–")",
                "Zielref: \(candidate.targetRef)",
                "Geprüfter Commit: \(commit)",
                "Erwarteter bisheriger Stand: \(candidate.previousTargetOID)",
                "Dein Checkout und deine Branches bleiben unverändert.",
            ],
            ifRejected: "Der Kandidat bleibt angenommen, aber unveröffentlicht. Du kannst ihn später freigeben oder ablehnen.",
            approveLabel: "Freigeben und veröffentlichen", rejectLabel: "Nicht jetzt", reported: nil,
            blockers: gate.map(Labels.gate),
            shown: ShownApproval(candidateOID: candidate.candidateOID, expectedOldOID: candidate.previousTargetOID, targetRef: candidate.targetRef)
        )
    }

    /// Rejecting a candidate needs a reason; its task goes back for changes.
    public static func rejectCandidate(_ candidate: CandidateRecord, task: TaskRecord?) -> DecisionSheet {
        DecisionSheet(
            title: "Kandidat ablehnen",
            action: "Den Kandidaten \(Labels.short(candidate.candidateOID ?? "–")) ablehnen.",
            scope: ["Aufgabe: \(task?.title ?? "–")", "Freigaben dieses Kandidaten werden widerrufen."],
            ifRejected: "Wenn du nicht ablehnst, bleibt der Kandidat im aktuellen Zustand.",
            approveLabel: "Ablehnen", rejectLabel: "Abbrechen", reported: nil, blockers: [], shown: nil
        )
    }

    /// The explicit start of a task that waits for the user.
    public static func start(_ task: TaskRecord, provider: ProviderKind?, writePaths: [String]) -> DecisionSheet {
        DecisionSheet(
            title: "Aufgabe starten",
            action: "Die Aufgabe „\(task.title)“ jetzt starten.",
            scope: [
                "Anbieter: \(provider.map(Labels.provider) ?? "nach Plan")",
                writePaths.isEmpty ? "Schreibbereich: keiner" : "Schreibbereich: \(writePaths.joined(separator: ", "))",
                "Der Lauf erhält nur freigegebene Inhalte dieses Projekts.",
            ],
            ifRejected: "Die Aufgabe wartet weiter auf deinen Start; nichts wird übertragen.",
            approveLabel: "Starten", rejectLabel: "Nicht starten", reported: nil, blockers: [], shown: nil
        )
    }

    /// More attempts for a task that stopped for the user's decision.
    public static func moreAttempts(_ task: TaskRecord, reason: WaitReason) -> DecisionSheet {
        DecisionSheet(
            title: "Weitere Versuche erlauben",
            action: "Für „\(task.title)“ weitere Versuche erlauben; die Zählung beginnt neu.",
            scope: [
                "Grund des Halts: \(reason.detail.map(Self.stopReason) ?? "Entscheidung nötig")",
                "Jeder Versuch kann beim Anbieter Kontingent und Budget verbrauchen.",
            ],
            ifRejected: "Die Aufgabe bleibt angehalten, bis du entscheidest.",
            approveLabel: "Weitere Versuche erlauben", rejectLabel: "Angehalten lassen", reported: nil, blockers: [], shown: nil
        )
    }

    static func stopReason(_ detail: String) -> String {
        switch detail {
        case "attemptLimit": "Versuchsgrenze erreicht"
        case "topTierReached": "Höchste Modellstufe erreicht"
        default: "Wiederholte Startfehler"
        }
    }

    /// A consent for automatic runs, one draft per provider (author and reviewer providers both
    /// need one: the reviewer sees the author's diff). Every provider is named in the scope.
    public static func consent(_ drafts: [ConsentDraft]) -> DecisionSheet {
        let names = drafts.map { Labels.provider($0.provider) }.joined(separator: " und ")
        let scopeKind = drafts.first?.jobID == nil ? "Projekts" : "Auftrags"
        var scope = drafts.map { draft in
            "\(Labels.provider(draft.provider)): Rollen \(draft.roles.map(Labels.role).joined(separator: ", ")); "
                + (draft.writeRoots == [""] ? "Schreibbereich: das ganze Projekt, je Aufgabe nur ihre Pfade" : "Schreibbereiche: \(draft.writeRoots.joined(separator: ", "))")
        }
        if let limit = drafts.first?.unconfirmedAttemptLimit { scope.append("Ohne gemeldetes Kontingent höchstens \(limit) Läufe je Anbieter") }
        scope.append(drafts.first?.expiresAt == nil ? "Gültig bis zum Widerruf" : "Gültig bis zum gesetzten Ablauf")
        scope.append("Jeder Lauf überträgt freigegebene Inhalte an \(names).")
        return DecisionSheet(
            title: "Zustimmung für automatische Läufe",
            action: "\(names) dürfen Aufgaben dieses \(scopeKind) automatisch bearbeiten und prüfen.",
            scope: scope,
            ifRejected: "Ohne Zustimmung startet nichts automatisch; Aufgaben warten mit „Wartet auf deine Zustimmung“.",
            approveLabel: "Zustimmen", rejectLabel: "Nicht zustimmen", reported: nil, blockers: drafts.isEmpty ? ["Kein Anbieter verfügbar"] : [], shown: nil
        )
    }

    /// An uncertain attempt: the process was lost, a provider may already have used quota.
    public static func uncertain(_ attempt: AttemptRecord, task: TaskRecord?) -> DecisionSheet {
        DecisionSheet(
            title: "Ungeklärter Lauf",
            action: "Den ungeklärten Lauf von \(Labels.provider(attempt.provider)) als abgebrochen abschließen.",
            scope: [
                "Aufgabe: \(task?.title ?? "–")",
                "Modell: \(attempt.model)",
                "Ein neuer Versuch kann beim Anbieter erneut Kontingent verbrauchen.",
            ],
            ifRejected: "Der Lauf bleibt ungeklärt und hält seinen Platz und seinen Arbeitsstand gesperrt.",
            approveLabel: "Als abgebrochen abschließen", rejectLabel: "Offen lassen", reported: nil, blockers: [], shown: nil
        )
    }
}
