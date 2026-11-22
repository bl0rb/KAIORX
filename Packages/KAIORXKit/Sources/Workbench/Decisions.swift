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
    /// A sealed result the driver does not build on its own (ADR 0011): undeclared paths, an
    /// empty or already contained result, only rejected changes, a missing plan task, or a
    /// superseded candidate's result already contained after a rebuild (§10).
    case result(TaskID)
    /// A conflicted candidate whose conflicts wait for the user's resolution.
    case conflicts(CandidateID)
    /// A built candidate waiting for the user to run its tests (ADR 0010: nothing runs them
    /// automatically).
    case tests(CandidateID)
    /// A candidate in review waiting for the user to start or import a review (ADR 0009 §8).
    case review(CandidateID)

    public var id: String {
        switch self {
        case .publish(let id): "publish:\(id.uuidString)"
        case .task(let id, let reason): "task:\(id.uuidString):\(reason.kind.rawValue)"
        case .uncertain(let id): "uncertain:\(id.uuidString)"
        case .findings(let id): "findings:\(id.uuidString)"
        case .result(let id): "result:\(id.uuidString)"
        case .conflicts(let id): "conflicts:\(id.uuidString)"
        case .tests(let id): "tests:\(id.uuidString)"
        case .review(let id): "review:\(id.uuidString)"
        }
    }
}

public enum PendingDecisions {
    static let userKinds: Set<WaitReason.Kind> = [.userDecision, .awaitingUserStart, .consent]

    /// Whether a result check leaves the next step to the user (ADR 0011).
    public static func needsUser(_ check: ResultCheck) -> Bool {
        switch check {
        case .empty, .contained, .supersededContained, .rejectedOnly, .undeclared, .planTaskMissing: true
        case .notApplicable, .awaitingSeal, .buildable, .candidate: false
        }
    }

    /// Whether the driver's issue with a waiting result leaves it to the user: a seal or build
    /// that keeps failing holds the task's write area until the user retries or discards it.
    /// Review and rebuild issues belong to a candidate, not to a result decision.
    public static func needsUser(_ issue: ChainIssue?) -> Bool {
        switch issue {
        case .sealFailed?, .buildFailed?, .planTaskMissing?: true
        case .collectFailed?, .containedAfterRebuild?, nil: false
        }
    }

    /// Everything in `project` (or every project) that waits for the user, oldest first.
    /// `resultCheck` is the candidate chain's check of a task's result (nil: not known, no
    /// result decision); `chainIssue` is the driver's current issue with a task. A lookup that
    /// fails for one candidate or task only drops that entry, never the rest of the list.
    public static func collect(
        _ state: WorkspaceState, project: ProjectID?, gate: @Sendable (CandidateID) async throws -> [GateItem],
        openFindings: @Sendable (CandidateID) async throws -> Bool,
        resultCheck: @Sendable (TaskID) async throws -> ResultCheck? = { _ in nil },
        chainIssue: @Sendable (TaskID) async -> ChainIssue? = { _ in nil }
    ) async throws -> [PendingDecision] {
        func inProject(_ job: JobID) -> Bool {
            guard let project else { return true }
            return state.jobs[job]?.projectID == project
        }
        var result: [PendingDecision] = []
        for candidate in state.candidates.values.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) })
        where inProject(candidate.jobID) {
            let task = candidate.taskID.flatMap { state.tasks[$0] }
            if candidate.state == .accepted, task?.state == .awaitingMerge, (try? await gate(candidate.id))?.isEmpty == true {
                result.append(.publish(candidate.id))
            } else if candidate.state == .reviewing, (try? await openFindings(candidate.id)) == true {
                result.append(.findings(candidate.id))
            } else if candidate.state == .conflicted, task?.state == .conflict {
                result.append(.conflicts(candidate.id))
            } else if candidate.state == .built, task?.state == .verifying {
                result.append(.tests(candidate.id))
            } else if candidate.state == .reviewing, let task,
                      state.needsReview(candidate, collectFailed: Self.collectFailed(await chainIssue(task.id))) {
                result.append(.review(candidate.id))
            }
        }
        for task in state.tasks.values.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) })
        where inProject(task.jobID) {
            if let reason = task.waitReason.flatMap(WaitReason.init(stored:)), userKinds.contains(reason.kind) {
                result.append(.task(task.id, reason))
            }
            // A held task is not offered: its result decisions need `resultReady`, or past it a
            // superseded result the integration state already contains (ADR 0011 §10).
            let past = task.state == .verifying || task.state == .awaitingMerge
            guard task.state == .resultReady || past, state.openCandidate(of: task.id) == nil else { continue }
            // A check that fails (for example a moved checkout) leaves only this task out.
            let check = (try? await resultCheck(task.id)) ?? nil
            if past {
                // A driver issue of a task past its result (a failed rebuild) is no result decision.
                if case .supersededContained? = check { result.append(.result(task.id)) }
                continue
            }
            let issue = await chainIssue(task.id)
            if check.map(needsUser) == true || needsUser(issue) {
                result.append(.result(task.id))
            }
        }
        for attempt in state.attempts.values.sorted(by: { ($0.reservedAt, $0.id.uuidString) < ($1.reservedAt, $1.id.uuidString) })
        where attempt.state == .uncertain {
            if let task = state.tasks[attempt.taskID], inProject(task.jobID) { result.append(.uncertain(attempt.id)) }
        }
        return result
    }

    static func collectFailed(_ issue: ChainIssue?) -> Bool {
        if case .collectFailed? = issue { return true }
        return false
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
    /// For a result decision: the task version, worktree and check the sheet showed.
    public var result: ShownResult?
    /// For a conflict resolution: the candidate version and paths the sheet showed.
    public var conflicts: ShownConflicts?
    /// For a review start: the option (provider, model, commit, version) the sheet showed.
    public var review: ReviewOption?

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
            scope: [
                "Aufgabe: \(task?.title ?? "–")", "Freigaben dieses Kandidaten werden widerrufen.",
                rejectionReasonLine(candidate.kind),
            ],
            ifRejected: "Wenn du nicht ablehnst, bleibt der Kandidat im aktuellen Zustand.",
            approveLabel: "Ablehnen", rejectLabel: "Abbrechen", reported: nil, blockers: [], shown: nil
        )
    }

    /// What happens to a rejection reason: a revert task ends with its candidate, so no author
    /// gets it; a reason that looks like a secret is withheld from the next author.
    public static func rejectionReasonLine(_ kind: CandidateKind) -> String {
        switch kind {
        case .revert: "Die Rücknahme endet mit der Ablehnung; die Begründung bleibt nur im Verlauf."
        case .implementation: "Die Begründung geht an den nächsten Autor dieser Aufgabe, außer sie sieht nach einem Geheimnis aus."
        }
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
    /// A task waiting for rework after a rejection gets its own sheet (`rework`), with the user's
    /// reason the next author gets (`Store.reworkReason`).
    public static func moreAttempts(_ task: TaskRecord, reason: WaitReason, rework reworkReason: ReworkReason? = nil) -> DecisionSheet {
        if reason.detail == "rework" { return rework(task, reason: reworkReason) }
        return DecisionSheet(
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

    /// A task back in `needsChanges` without a counted failure (its candidate was rejected, or
    /// nothing was left to integrate): it returns to an author only with the user's grant
    /// (ADR 0011 §6). The approval is the same grant as „Weitere Versuche erlauben“. `reason` is
    /// the user's own reason the next author gets, if any.
    public static func rework(_ task: TaskRecord, reason: ReworkReason? = nil) -> DecisionSheet {
        DecisionSheet(
            title: "Nacharbeit erlauben",
            action: "„\(task.title)“ erneut von einem Autor bearbeiten lassen; die Zählung der Versuche beginnt neu.",
            scope: [
                "Grund des Halts: \(stopReason("rework"))",
                reworkLine(reason),
                "Jeder Versuch kann beim Anbieter Kontingent und Budget verbrauchen.",
            ],
            ifRejected: "Die Aufgabe bleibt bei „Änderungen nötig“ stehen; es startet kein neuer Lauf.",
            approveLabel: "Nacharbeit erlauben", rejectLabel: "Nicht jetzt", reported: nil, blockers: [], shown: nil
        )
    }

    /// What the next author gets of the user's reason.
    static func reworkLine(_ reason: ReworkReason?) -> String {
        guard let reason else { return "Es liegt kein Grund von dir vor; der Autor bekommt die Aufgabe wie beim ersten Lauf." }
        if ReworkPrompt.isWithheld(reason) { return "Dein Grund sieht nach einem Geheimnis aus und geht nicht an den Autor." }
        let text = reason.text.count > 200 ? String(reason.text.prefix(200)) + " […]" : reason.text
        return "Dein Grund geht an den nächsten Autor: „\(text)“"
    }

    static func stopReason(_ detail: String) -> String {
        switch detail {
        case "attemptLimit": "Versuchsgrenze erreicht"
        case "topTierReached": "Höchste Modellstufe erreicht"
        case "startRetries": "Wiederholte Startfehler"
        case "rework": "Kandidat abgelehnt oder nichts mehr zu integrieren – die Nacharbeit braucht deine Freigabe"
        default: "Entscheidung nötig"
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
