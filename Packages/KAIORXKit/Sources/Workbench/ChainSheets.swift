import Domain
import Foundation
import Orchestration
import Storage

/// The decision sheets of the candidate chain (ADR 0011). Like every sheet they are built only
/// from typed fields; the approval is never the safe default, and each sheet carries what it
/// showed, so an action on a changed state is refused.
extension DecisionSheet {
    /// The sheet for a task's result, chosen by what the check found: undeclared paths, an
    /// empty or already contained result (also after a rebuild), or else discarding it.
    public static func resultDecision(
        _ shown: ShownResult, task: TaskRecord?, writeArea: ResultWriteArea, issue: ChainIssue?, tip: String? = nil
    ) -> DecisionSheet {
        switch shown.check {
        case .undeclared: undeclaredPaths(shown, task: task, writeArea: writeArea)
        case .empty, .contained, .supersededContained: emptyResult(shown, task: task, tip: tip)
        default: discardResult(shown, task: task, issue: issue)
        }
    }

    /// Building a result whose seal dropped paths: the candidate is built without them.
    public static func undeclaredPaths(_ shown: ShownResult, task: TaskRecord?, writeArea: ResultWriteArea) -> DecisionSheet {
        var scope = [
            "Aufgabe: \(task?.title ?? "–")",
            "Ergebniscommit: \(shown.resultOID ?? "–")",
            Labels.writeArea(writeArea),
        ]
        scope += rejectedLines(shown)
        var blockers = heldBlockers(task)
        if case .undeclared = shown.check {} else { blockers.append("Das Ergebnis hat keine verworfenen Pfade zu bestätigen.") }
        var sheet = DecisionSheet(
            title: "Abweichende Änderungen",
            action: "Kandidat aus dem versiegelten Ergebnis bauen; die verworfenen Pfade bleiben draußen.",
            scope: scope,
            ifRejected: "Es wird kein Kandidat gebaut. Die Aufgabe hält ihren Schreibbereich, bis du entscheidest.",
            approveLabel: "Ohne diese Pfade bauen", rejectLabel: "Nicht bauen", reported: nil, blockers: blockers, shown: nil
        )
        sheet.result = shown
        return sheet
    }

    /// Accepting an empty or already contained result as done (ADR 0005: never automatic).
    public static func emptyResult(_ shown: ShownResult, task: TaskRecord?, tip: String? = nil) -> DecisionSheet {
        var title = "Leeres Ergebnis"
        var state = tip
        var extra: [String] = []
        var ifRejected = "Die Aufgabe bleibt mit ihrem Ergebnis stehen und hält ihren Schreibbereich, bis du entscheidest."
        var blockers = heldBlockers(task)
        switch shown.check {
        case .empty: break
        case .contained(let contained):
            title = "Schon enthalten"
            state = contained
        case .supersededContained(let contained):
            title = "Nach Neubau schon enthalten"
            state = contained
            extra = ["Ergebniscommit: \(shown.resultOID ?? "–")", "Der ersetzte Kandidat wird nicht veröffentlicht."]
            ifRejected = "Die Aufgabe bleibt in der Prüfung stehen und hält ihren Schreibbereich, bis du entscheidest; es wird kein neuer Kandidat gebaut."
        default: blockers.append("Das Ergebnis ist weder leer noch im Integrationsstand enthalten.")
        }
        var sheet = DecisionSheet(
            title: title,
            action: "Die Aufgabe ohne Änderung als erledigt annehmen.",
            scope: ["Aufgabe: \(task?.title ?? "–")"] + extra + [
                state.map { "Integrationsstand: \($0)" } ?? "Integrationsstand: unverändert",
                "Es wird nichts veröffentlicht; dein Checkout und deine Branches bleiben unverändert.",
            ],
            ifRejected: ifRejected,
            approveLabel: "Als erledigt annehmen", rejectLabel: "Nicht annehmen", reported: nil, blockers: blockers, shown: nil
        )
        sheet.result = shown
        return sheet
    }

    /// Discarding a result: the task goes back to an author, and the attempt count restarts.
    /// Offered for plan tasks only.
    public static func discardResult(_ shown: ShownResult, task: TaskRecord?, issue: ChainIssue?) -> DecisionSheet {
        var scope = ["Aufgabe: \(task?.title ?? "–")"]
        switch shown.check {
        case .rejectedOnly: scope.append("Nur verworfene Änderungen")
        case .planTaskMissing: scope.append("Die Planaufgabe fehlt in der Planfassung des Laufs.")
        default: if let resultOID = shown.resultOID { scope.append("Ergebniscommit: \(resultOID)") }
        }
        scope += rejectedLines(shown)
        if let issue { scope.append(Labels.chainIssue(issue)) }
        scope += [
            "Ein Grund ist freiwillig; er geht mit der Aufgabe an den nächsten Autor, außer er sieht nach einem Geheimnis aus.",
            "Die Zählung der Versuche beginnt neu.", "Ein neuer Lauf kann Kontingent verbrauchen.",
        ]
        var blockers = heldBlockers(task)
        if let task, task.planKey == nil { blockers.append("Nur Aufgaben aus einem Plan lassen sich neu bearbeiten.") }
        switch shown.check {
        case .notApplicable, .candidate, .supersededContained: blockers.append("Für dieses Ergebnis ist gerade nichts zu entscheiden.")
        default: break
        }
        var sheet = DecisionSheet(
            title: "Ergebnis verwerfen",
            action: "Ergebnis verwerfen und die Aufgabe erneut bearbeiten lassen.",
            scope: scope,
            ifRejected: "Das Ergebnis bleibt stehen; die Aufgabe hält ihren Schreibbereich, bis du entscheidest.",
            approveLabel: "Verwerfen und neu bearbeiten lassen", rejectLabel: "Nicht verwerfen", reported: nil, blockers: blockers, shown: nil
        )
        sheet.result = shown
        return sheet
    }

    /// Resolving a conflicted candidate with one choice per path (no content editing in v1).
    public static func resolveConflicts(
        _ preview: ConflictPreview, candidate: CandidateRecord, task: TaskRecord?, choices: [String: ConflictChoice]
    ) -> DecisionSheet {
        let revert = preview.kind == .revert
        var scope = [
            "Aufgabe: \(task?.title ?? "–")",
            "Zielref: \(candidate.targetRef)",
            "Integrationsstand: \(preview.target)",
            revert ? "Rücknahme: \(preview.result)" : "Ergebnis: \(preview.result)",
        ]
        for row in preview.rows {
            let choice = choices[row.path].map { Labels.conflictChoice($0, revert: revert) } ?? "noch offen"
            scope.append("\(row.path): \(Labels.conflictKind(row.kind)) – \(choice)")
        }
        scope.append("Dein Checkout bleibt unverändert.")
        var blockers = heldBlockers(task)
        let open = preview.shown.paths.filter { choices[$0] == nil }.count
        if open > 0 { blockers.append("Noch ohne Entscheidung: \(open == 1 ? "1 Datei" : "\(open) Dateien")") }
        if candidate.state != .conflicted || candidate.version != preview.shown.version {
            blockers.append("Der Kandidat hat sich geändert, seit die Konflikte gelesen wurden.")
        }
        var sheet = DecisionSheet(
            title: "Konflikt lösen",
            action: "Den Konflikt mit deinen Entscheidungen auflösen und einen Kandidaten bauen.",
            scope: scope,
            ifRejected: "Der Kandidat bleibt im Konflikt; die Aufgabe hält ihren Schreibbereich, bis du entscheidest.",
            approveLabel: "Auflösen und Kandidat bauen", rejectLabel: "Nicht jetzt", reported: nil, blockers: blockers, shown: nil
        )
        sheet.conflicts = preview.shown
        return sheet
    }

    /// The explicit start of a review with the chosen option. The gate's verdict is shown for
    /// information only and never blocks (ADR 0009 §8).
    public static func startReview(_ option: ReviewOption?, candidate: CandidateRecord, task: TaskRecord?) -> DecisionSheet {
        guard let option else {
            return DecisionSheet(
                title: "Review starten",
                action: "Ein Review des Kandidaten \(Labels.short(candidate.candidateOID ?? "–")) starten.",
                scope: ["Aufgabe: \(task?.title ?? "–")", "Geprüfter Commit: \(candidate.candidateOID ?? "–")"],
                ifRejected: "Es startet kein Review; der Kandidat wartet weiter auf ein Review.",
                approveLabel: "Review starten", rejectLabel: "Nicht jetzt", reported: nil,
                blockers: ["Kein Prüfer von einem anderen Anbieter verfügbar"], shown: nil
            )
        }
        let reviewer = Labels.provider(option.provider)
        var scope = [
            "Aufgabe: \(task?.title ?? "–")",
            "Geprüfter Commit: \(option.candidateOID)",
            "Prüfer: \(reviewer) · \(option.model)",
            "Autor: \(candidate.authorProvider.map(Labels.provider) ?? "–") – der Prüfer kommt von einem anderen Anbieter",
            "Kriterien: \(option.criteria)",
            "Diff und Testbelege gehen an \(reviewer).",
            "Der Prüfer arbeitet schreibgeschützt in einem eigenen Worktree.",
            "Ein Review verbraucht Kontingent beim Prüferkonto.",
        ]
        if let note = option.automationNote { scope.append("Automatik (nur zur Information): \(note)") }
        var blockers = option.blockers.map { Labels.reviewBlocker($0, provider: option.provider) }
        if candidate.candidateOID != option.candidateOID || candidate.version != option.candidateVersion {
            blockers.append("Der Kandidat hat sich geändert, seit die Prüfer gelesen wurden.")
        }
        var sheet = DecisionSheet(
            title: "Review starten",
            action: "Ein Review des Kandidaten \(Labels.short(option.candidateOID)) bei \(reviewer) mit \(option.model) starten.",
            scope: scope,
            ifRejected: "Es startet kein Review; der Kandidat wartet weiter auf ein Review.",
            approveLabel: "Review starten", rejectLabel: "Nicht jetzt", reported: nil, blockers: blockers, shown: nil
        )
        sheet.review = option
        return sheet
    }

    /// Importing a review the user ran elsewhere; the pasted text is shown as reported text.
    /// For a sensitive task this is the only way to its human review.
    public static func importReview(_ candidate: CandidateRecord, task: TaskRecord?, text: String) -> DecisionSheet {
        let commit = candidate.candidateOID ?? "–"
        var blockers: [String] = []
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blockers.append("Füge den Text des Reviews ein.") }
        if candidate.state != .reviewing && candidate.state != .accepted { blockers.append("Der Kandidat wartet nicht auf ein Review.") }
        return DecisionSheet(
            title: "Review einfügen",
            action: "Ein außerhalb von KAIORX erstelltes Review für den Kandidaten \(Labels.short(commit)) übernehmen.",
            scope: [
                "Aufgabe: \(task?.title ?? "–")",
                "Geprüfter Commit: \(commit)",
                "Das Review wird als von dir eingefügt gespeichert und so angezeigt.",
                "Es zählt nur, wenn es genau diesen Commit nennt; sonst gilt es als unlesbar.",
            ],
            ifRejected: "Es wird nichts gespeichert; der Kandidat wartet weiter auf ein Review.",
            approveLabel: "Review übernehmen", rejectLabel: "Nicht übernehmen", reported: text, blockers: blockers, shown: nil
        )
    }

    /// One line per dropped path, with its reason.
    static func rejectedLines(_ shown: ShownResult) -> [String] {
        let reasons: [String: String] = switch shown.check {
        case .undeclared(_, let rejected), .rejectedOnly(let rejected): rejected
        default: [:]
        }
        return shown.rejected.sorted().map { Labels.rejectedLine($0, reason: reasons[$0]) }
    }

    /// A held task decides nothing until it is released.
    static func heldBlockers(_ task: TaskRecord?) -> [String] {
        task?.state == .blocked ? ["Aufgabe angehalten"] : []
    }
}
