import Domain
import Foundation
import Orchestration
import Workspace

/// How a status reads and looks: always text plus symbol, never color alone (Plan/macos-und-git.md).
public struct StatusLabel: Sendable, Equatable, Hashable {
    public enum Tone: String, Sendable, Hashable {
        case neutral, active, waiting, success, warning, failure
    }

    public var text: String
    /// SF Symbol name.
    public var symbol: String
    public var tone: Tone

    public init(_ text: String, _ symbol: String, _ tone: Tone) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
    }

    /// What VoiceOver reads: the text, with the tone where the text alone does not carry it.
    public var accessibilityLabel: String { text }
}

/// German labels for every state the UI shows. Each switch is exhaustive, so a new state does not
/// compile until it has a label.
public enum Labels {
    public static func job(_ state: JobState) -> StatusLabel {
        switch state {
        case .draft: StatusLabel("Entwurf", "square.dashed", .neutral)
        case .planned: StatusLabel("Geplant", "list.bullet.rectangle", .neutral)
        case .active: StatusLabel("Aktiv", "play.circle", .active)
        case .done: StatusLabel("Erledigt", "checkmark.circle", .success)
        case .paused: StatusLabel("Pausiert", "pause.circle", .waiting)
        case .cancelled: StatusLabel("Abgebrochen", "xmark.circle", .neutral)
        case .needsAttention: StatusLabel("Braucht Aufmerksamkeit", "exclamationmark.triangle", .warning)
        }
    }

    public static func task(_ state: TaskState) -> StatusLabel {
        switch state {
        case .pending: StatusLabel("Wartet auf Vorgänger", "clock", .waiting)
        case .ready: StatusLabel("Bereit", "circle", .neutral)
        case .running: StatusLabel("Läuft", "play.circle", .active)
        case .resultReady: StatusLabel("Ergebnis liegt vor", "tray.full", .active)
        case .verifying: StatusLabel("Wird geprüft", "checklist", .active)
        case .awaitingMerge: StatusLabel("Wartet auf Freigabe", "hand.raised", .waiting)
        case .integrated: StatusLabel("Integriert", "checkmark.circle", .success)
        case .conflict: StatusLabel("Konflikt", "arrow.triangle.merge", .warning)
        case .blocked: StatusLabel("Angehalten", "pause.circle", .waiting)
        case .needsChanges: StatusLabel("Änderungen nötig", "pencil.circle", .warning)
        case .noResult: StatusLabel("Kein Ergebnis", "minus.circle", .neutral)
        case .failed: StatusLabel("Fehlgeschlagen", "xmark.octagon", .failure)
        case .cancelled: StatusLabel("Abgebrochen", "xmark.circle", .neutral)
        }
    }

    public static func attempt(_ state: AttemptState) -> StatusLabel {
        switch state {
        case .reserved: StatusLabel("Reserviert", "clock", .waiting)
        case .starting: StatusLabel("Startet", "hourglass", .active)
        case .running: StatusLabel("Läuft", "play.circle", .active)
        case .awaitingApproval: StatusLabel("Wartet auf Entscheidung", "hand.raised", .waiting)
        case .cancelling: StatusLabel("Wird abgebrochen", "stop.circle", .waiting)
        case .succeeded: StatusLabel("Erfolgreich", "checkmark.circle", .success)
        case .failed: StatusLabel("Fehlgeschlagen", "xmark.octagon", .failure)
        case .cancelled: StatusLabel("Abgebrochen", "xmark.circle", .neutral)
        case .uncertain: StatusLabel("Ungeklärt", "questionmark.circle", .warning)
        }
    }

    public static func candidate(_ state: CandidateState) -> StatusLabel {
        switch state {
        case .conflicted: StatusLabel("Konflikt", "arrow.triangle.merge", .warning)
        case .built: StatusLabel("Gebaut", "shippingbox", .neutral)
        case .testing: StatusLabel("Tests laufen", "testtube.2", .active)
        case .reviewing: StatusLabel("Im Review", "eye", .active)
        case .accepted: StatusLabel("Angenommen", "checkmark.seal", .success)
        case .publishing: StatusLabel("Wird veröffentlicht", "arrow.up.circle", .active)
        case .published: StatusLabel("Veröffentlicht", "checkmark.circle", .success)
        case .rejected: StatusLabel("Abgelehnt", "xmark.circle", .failure)
        case .superseded: StatusLabel("Ersetzt", "arrow.uturn.backward.circle", .neutral)
        }
    }

    public static func worktree(_ state: WorktreeState) -> StatusLabel {
        switch state {
        case .preparing: StatusLabel("Wird vorbereitet", "hourglass", .active)
        case .ready: StatusLabel("Bereit", "folder", .neutral)
        case .frozen: StatusLabel("Eingefroren", "lock", .neutral)
        case .removing: StatusLabel("Wird entfernt", "trash", .waiting)
        case .removed: StatusLabel("Entfernt", "trash.slash", .neutral)
        case .needsAttention: StatusLabel("Braucht Aufmerksamkeit", "exclamationmark.triangle", .warning)
        }
    }

    /// Why a ready task is not started, as a sentence.
    public static func wait(_ reason: WaitReason) -> StatusLabel {
        switch reason.kind {
        case .slot: StatusLabel("Wartet auf einen freien Platz", "clock", .waiting)
        case .writeArea: StatusLabel("Wartet auf einen freien Schreibbereich", "square.on.square.dashed", .waiting)
        case .consent: StatusLabel("Wartet auf deine Zustimmung", "hand.raised", .waiting)
        case .quota: StatusLabel("Wartet auf das Nutzungslimit", "gauge.with.dots.needle.67percent", .waiting)
        case .budget: StatusLabel("Budget erschöpft", "creditcard", .waiting)
        case .profileMissing: StatusLabel("Kein passendes Modellprofil", "questionmark.circle", .warning)
        case .noIndependentReviewer: StatusLabel("Kein unabhängiger Reviewer verfügbar", "person.2.slash", .warning)
        case .predecessorEnded: StatusLabel("Ein Vorgänger endete ohne Ergebnis", "arrow.uturn.left.circle", .warning)
        case .predecessorReverted: StatusLabel("Ein Vorgänger wurde zurückgenommen", "arrow.uturn.backward.circle", .warning)
        case .awaitingUserStart:
            if let detail = reason.detail, let parsed = AutomationBlock.parse(detail), let why = automation(parsed.1, provider: parsed.0) {
                StatusLabel("Wartet auf deinen Start: \(why)", "play.circle", .waiting)
            } else {
                StatusLabel("Wartet auf deinen Start", "play.circle", .waiting)
            }
        case .userDecision:
            if reason.detail == "rework" {
                StatusLabel("Wartet auf deine Freigabe zur Nacharbeit", "hand.raised", .waiting)
            } else {
                StatusLabel("Wartet auf deine Entscheidung", "hand.raised", .waiting)
            }
        case .retryLater: StatusLabel("Neuer Versuch später", "arrow.clockwise", .waiting)
        case .capability: StatusLabel("Fähigkeit nicht freigegeben", "lock", .warning)
        }
    }

    /// Why a provider does not start automatically (ADR 0009); nil when there is nothing more
    /// to say than "waits for your start".
    public static func automation(_ block: AutomationBlock, provider: ProviderKind) -> String? {
        let name = self.provider(provider)
        switch block {
        case .notPermitted: return nil
        case .channel: return "\(name) startet in dieser Ausgabe von KAIORX nie automatisch (keine Anbieterfreigabe)"
        case .notInstalled: return "\(name) ist nicht installiert"
        case .identityUnknown: return "Das installierte \(name)-Programm ließ sich nicht prüfen"
        case .versionNotListed(let version), .versionNotLiveVerified(let version):
            return "Die installierte Version \(name) \(version) ist nicht live abgenommen"
        case .buildNotVerified(let version): return "Dieser Build von \(name) \(version) ist nicht live abgenommen"
        case .confinementIneffective: return "Der Schreibschutz für Agenten wirkt nicht"
        case .notSubscribed(let kind):
            switch kind {
            case "signedOut": return "\(name) ist in KAIORX nicht angemeldet"
            case "otherBilling": return "\(name) rechnet nicht nur über das Abo ab"
            default: return "Das \(name)-Abo ist nicht bestätigt"
            }
        }
    }

    /// The stored wait reason, or nil if it cannot be read.
    public static func wait(stored: String?) -> StatusLabel? {
        stored.flatMap(WaitReason.init(stored:)).map(wait)
    }

    public static func provider(_ provider: ProviderKind) -> String {
        switch provider {
        case .claude: "Claude"
        case .codex: "Codex"
        case .fake: "Testanbieter"
        }
    }

    public static func role(_ role: AttemptRole) -> String {
        switch role {
        case .author: "Autor"
        case .reviewer: "Reviewer"
        }
    }

    /// One missing gate condition as a checklist line.
    public static func gate(_ item: GateItem) -> String {
        switch item {
        case .noCommit: "Kein Kandidatencommit"
        case .noPassingTest(let commit): "Kein grüner Test für \(short(commit))"
        case .noIndependentReview(let commit): "Kein zustimmendes unabhängiges Review für \(short(commit))"
        case .noTestProfileForSensitiveTask: "Sicherheitskritische Aufgabe ohne Testprofil"
        case .noHumanReviewForSensitiveTask: "Sicherheitskritische Aufgabe ohne zustimmendes menschliches Review"
        case .blockingFindings: "Blockierende Befunde"
        case .undecidedFindings: "Offene Befunde ohne Entscheidung"
        case .testProfileNotConfirmed(let name): "Testprofil „\(name)“ ist nicht bestätigt"
        case .noConfirmedTestProfile: "Kein bestätigtes Testprofil im Projekt"
        }
    }

    // MARK: Candidate chain (ADR 0011)

    /// How far sealing a result got; nil: not sealed yet.
    public static func seal(_ status: SealStatus?) -> StatusLabel {
        switch status {
        case nil: StatusLabel("Nicht versiegelt", "lock.open", .waiting)
        case .committed: StatusLabel("Versiegelt", "lock", .success)
        case .empty: StatusLabel("Leer: der Lauf hat nichts geändert", "tray", .neutral)
        case .rejectedOnly: StatusLabel("Nur verworfene Änderungen", "xmark.bin", .warning)
        }
    }

    /// Why sealing dropped a path, from the stored `RejectionReason` raw value (or
    /// `recoveredUnknown`, set by recovery); an unknown value is shown as it is.
    public static func rejectReason(_ raw: String) -> String {
        switch raw {
        case RejectionReason.outsideAllowedPaths.rawValue: "außerhalb des Schreibbereichs"
        case RejectionReason.symlink.rawValue: "symbolischer Link"
        case RejectionReason.gitMetadata.rawValue: "Git-Verwaltungsdatei"
        case RejectionReason.submodule.rawValue: "Submodul"
        case RejectionReason.unmerged.rawValue: "ungelöster Konflikt"
        case RejectionReason.recoveredUnknown.rawValue: "nach Neustart ermittelt"
        default: raw
        }
    }

    /// One dropped path with its reason, as the result box and the decision sheet show it.
    /// Recovery's `RejectionReason.unknownPathsMarker` is not a path: it says the dropped paths
    /// could not be determined after a restart, so the result needs the user's confirmation.
    public static func rejectedLine(_ path: String, reason raw: String?) -> String {
        if path == RejectionReason.unknownPathsMarker, raw == RejectionReason.recoveredUnknown.rawValue {
            return "Verworfene Pfade nicht ermittelbar (nach Neustart) – prüfe das Ergebnis, bevor du baust"
        }
        return "Verworfen: \(path) – \(raw.map(rejectReason) ?? "verworfen")"
    }

    /// Whether the dropped paths are recovery's single unknown-paths marker.
    static func onlyUnknownPaths(_ rejected: [String: String]) -> Bool {
        rejected == [RejectionReason.unknownPathsMarker: RejectionReason.recoveredUnknown.rawValue]
    }

    public static func conflictKind(_ kind: ConflictEntry.Kind) -> String {
        switch kind {
        case .bothModified: "Beide geändert"
        case .bothAdded: "Beide neu angelegt"
        case .deletedByUs: "Im Integrationsstand gelöscht, im Ergebnis geändert"
        case .deletedByThem: "Im Ergebnis gelöscht, im Integrationsstand geändert"
        case .addedByUs: "Nur im Integrationsstand angelegt"
        case .addedByThem: "Nur im Ergebnis angelegt"
        }
    }

    /// The user's choice for a conflicting path; for a revert the incoming side is the reversal.
    public static func conflictChoice(_ choice: ConflictChoice, revert: Bool) -> String {
        switch choice {
        case .target: "Integrationsstand behalten"
        case .result: revert ? "Rücknahme übernehmen" : "Ergebnis übernehmen"
        case .delete: "Datei löschen"
        }
    }

    public static func review(_ status: ReviewStatus) -> StatusLabel {
        switch status {
        case .approved: StatusLabel("Zugestimmt", "checkmark.seal", .success)
        case .changesRequested: StatusLabel("Änderungen verlangt", "exclamationmark.bubble", .warning)
        case .invalid: StatusLabel("Unlesbar", "questionmark.square.dashed", .warning)
        }
    }

    /// Why the driver could not move a task on, as a sentence.
    public static func chainIssue(_ issue: ChainIssue) -> String {
        switch issue {
        case .sealFailed(let detail): "Versiegeln fehlgeschlagen: \(detail)"
        case .buildFailed(let detail): "Bauen fehlgeschlagen: \(detail)"
        case .collectFailed(let detail): "Review konnte nicht übernommen werden: \(detail)"
        case .planTaskMissing: "Die Planaufgabe fehlt in der Planfassung des Laufs; das Ergebnis wird nicht versiegelt."
        case .containedAfterRebuild:
            "Nach dem Neubau ist das Ergebnis schon im Integrationsstand enthalten; es wird kein neuer Kandidat gebaut. Du kannst die Aufgabe als erledigt annehmen."
        }
    }

    /// The driver's issue as a status line.
    public static func chainIssueStatus(_ issue: ChainIssue) -> StatusLabel {
        StatusLabel(chainIssue(issue), "exclamationmark.triangle", .failure)
    }

    /// Without the candidate chain (the Git journal could not be repaired at start) nothing is
    /// sealed, built or collected.
    public static let chainUnavailable = StatusLabel("Kandidatenkette nicht verfügbar – Git-Arbeit angehalten", "exclamationmark.octagon", .failure)

    /// The status line of a task's result box: the shown result with the driver's issue, an
    /// issue alone, or „Wird versiegelt …“ while no result is readable yet. Never an active
    /// status when the chain is not running.
    public static func resultStatus(_ shown: ShownResult?, issue: ChainIssue?, chainAvailable: Bool) -> StatusLabel {
        guard chainAvailable else { return chainUnavailable }
        if let shown { return result(shown.check, issue: issue) }
        if let issue { return chainIssueStatus(issue) }
        return StatusLabel("Wird versiegelt …", "lock.rotation", .active)
    }

    /// The status line of a task's result, with the driver's current issue first.
    public static func result(_ check: ResultCheck, issue: ChainIssue?) -> StatusLabel {
        if let issue { return chainIssueStatus(issue) }
        switch check {
        case .notApplicable: return StatusLabel("Kein Ergebnis", "minus.circle", .neutral)
        case .awaitingSeal: return StatusLabel("Wird versiegelt …", "lock.rotation", .active)
        case .planTaskMissing: return StatusLabel("Planaufgabe fehlt", "exclamationmark.triangle", .warning)
        case .empty: return StatusLabel("Leer: der Lauf hat nichts geändert", "tray", .waiting)
        case .contained: return StatusLabel("Schon im Integrationsstand enthalten", "checkmark.circle", .waiting)
        case .supersededContained: return StatusLabel("Nach Neubau schon im Integrationsstand enthalten", "checkmark.circle", .waiting)
        case .rejectedOnly: return StatusLabel("Nur verworfene Änderungen", "xmark.bin", .warning)
        case .undeclared(_, let rejected) where onlyUnknownPaths(rejected):
            return StatusLabel("Verworfene Pfade unbekannt – Bestätigung nötig", "exclamationmark.shield", .waiting)
        case .undeclared(_, let rejected):
            return StatusLabel(rejected.count == 1 ? "1 Pfad verworfen" : "\(rejected.count) Pfade verworfen", "exclamationmark.shield", .waiting)
        case .buildable(let commit): return StatusLabel("Versiegelt: Commit \(short(commit)) – Kandidat wird gebaut …", "hammer", .active)
        case .candidate: return StatusLabel("Kandidat gebaut", "shippingbox", .success)
        }
    }

    /// The write area a result was sealed against.
    public static func writeArea(_ area: ResultWriteArea) -> String {
        switch area {
        case .wholeProject: "Schreibbereich: ganzes Projekt"
        case .paths(let paths): "Schreibbereich: \(paths.joined(separator: ", "))"
        case .planTaskMissing: "Schreibbereich: unbekannt, die Planaufgabe fehlt"
        }
    }

    /// Why a review cannot start with `provider` right now.
    public static func reviewBlocker(_ blocker: ReviewBlocker, provider: ProviderKind) -> String {
        let name = self.provider(provider)
        switch blocker {
        case .noReviewerConsent: return "Für \(name) fehlt die Zustimmung als Prüfer"
        case .noModelProfile: return "Für \(name) gibt es kein passendes Prüfermodell"
        case .accountBlocked: return "Das Prüferkonto bei \(name) ist gesperrt"
        case .slotsFull(let global): return global ? "Alle Plätze sind belegt" : "Alle Plätze des Prüferkontos bei \(name) sind belegt"
        case .reviewerOpen: return "Für diese Aufgabe läuft schon ein Review"
        case .contentPurged: return "Die Inhalte des Autors wurden vergessen; dieser Kandidat bekommt kein neues Review"
        case .adapterMissing: return "\(name) ist in KAIORX nicht verfügbar"
        case .candidateNotReviewing: return "Der Kandidat wartet nicht auf ein Review"
        case .sameProviderAsAuthor: return "Der Prüfer muss von einem anderen Anbieter kommen als der Autor"
        }
    }

    /// The first twelve characters of an object ID, for display; the full ID stays available.
    public static func short(_ oid: String) -> String { String(oid.prefix(12)) }

    /// A duration in milliseconds as `1 h 05 min`, `3 min 12 s` or `45 s`.
    public static func duration(_ ms: Int64) -> String {
        let seconds = max(0, ms / 1000)
        if seconds >= 3600 { return "\(seconds / 3600) h \(String(format: "%02d", (seconds % 3600) / 60)) min" }
        if seconds >= 60 { return "\(seconds / 60) min \(String(format: "%02d", seconds % 60)) s" }
        return "\(seconds) s"
    }
}
