import Domain
import Foundation
import Orchestration

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
        case .awaitingUserStart: StatusLabel("Wartet auf deinen Start", "play.circle", .waiting)
        case .userDecision: StatusLabel("Wartet auf deine Entscheidung", "hand.raised", .waiting)
        case .retryLater: StatusLabel("Neuer Versuch später", "arrow.clockwise", .waiting)
        case .capability: StatusLabel("Fähigkeit nicht freigegeben", "lock", .warning)
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
