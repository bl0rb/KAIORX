import Domain
import Foundation
import Orchestration
import Storage
import Workspace

/// Why a delivery branch cannot be created with the typed name (ADR 0004 §7).
public enum DeliveryProblem: Sendable, Equatable, Hashable {
    case emptyName
    /// Refused by `git check-ref-format --branch`, or not literal (`@`, `@{…}`, leading `-`).
    case invalidName
    /// The name and every suffix up to `-20` are taken, case- and normalisation-insensitively,
    /// or lie below an existing branch (`a/b` next to `a`).
    case noFreeName
    /// A folder of the name is spelled differently from an existing branch folder (`feature/y`
    /// next to `Feature/x`); on APFS the branch would appear as `Feature/y`.
    case folderCaseConflict(name: String, existing: String)
    /// No candidate of this job is published yet: the branch would only repeat the base.
    case nothingPublished

    public var text: String {
        switch self {
        case .emptyName: "Gib einen Namen für den neuen Branch ein."
        case .invalidName:
            "Kein gültiger Branchname. Erlaubt sind wörtliche Namen ohne Leerzeichen, ohne ~ ^ : ? * [ \\ und „..“, "
                + "nicht „@“, ohne „@{“, nicht mit „-“, „/“ oder „.“ am Anfang und nicht mit „/“, „.“ oder „.lock“ am Ende."
        case .noFreeName:
            "Der Name ist belegt, und auch die Varianten bis „-20“ sind belegt oder liegen unter einem vorhandenen Branch. "
                + "Groß- und Kleinschreibung zählen dabei nicht (APFS). Wähle einen anderen Namen."
        case .folderCaseConflict(let name, let existing):
            "Es gibt schon den Branch-Ordner „\(existing)“. Groß- und Kleinschreibung zählen dabei nicht (APFS): "
                + "Der Branch würde als „\(Self.spelled(name, as: existing))“ angelegt. Schreibe den Ordner wie vorhanden oder wähle einen anderen Namen."
        case .nothingPublished: "In diesem Auftrag ist noch kein Kandidat veröffentlicht."
        }
    }

    /// `name` with its leading folders replaced by the existing spelling `folder`.
    static func spelled(_ name: String, as folder: String) -> String {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        let count = folder.split(separator: "/", omittingEmptySubsequences: false).count
        return ([folder] + parts.dropFirst(count).map(String.init)).joined(separator: "/")
    }
}

/// What the delivery sheet shows for a job and a typed name: the branch the service would create
/// now (after its suffix rule) at which integration state.
public struct DeliveryPreview: Sendable, Equatable {
    public var job: JobID
    public var requestedName: String
    /// The name `createDeliveryBranch` would use now; `nil` when the name is refused.
    public var branchName: String?
    public var integrationRef: String
    public var target: String
    public var publishedCandidates: Int
    public var problems: [DeliveryProblem]

    public init(
        job: JobID, requestedName: String, branchName: String?, integrationRef: String, target: String, publishedCandidates: Int,
        problems: [DeliveryProblem]
    ) {
        self.job = job
        self.requestedName = requestedName
        self.branchName = branchName
        self.integrationRef = integrationRef
        self.target = target
        self.publishedCandidates = publishedCandidates
        self.problems = problems
    }

    /// A suggestion for the name field: below `kaiorx/`, named after the job.
    public static func suggestedName(for job: JobID) -> String {
        "kaiorx/auftrag-\(job.uuidString.prefix(6).lowercased())"
    }
}

/// Exactly what the delivery decision binds to: the job, the typed name and the integration
/// state the sheet showed. A target that moved since refuses (`IntegrationError.targetMoved`).
public struct ShownDelivery: Sendable, Equatable {
    public var job: JobID
    public var name: String
    public var target: String

    public init(job: JobID, name: String, target: String) {
        self.job = job
        self.name = name
        self.target = target
    }
}

/// The result of building a revert (ADR 0004 §8).
public enum RevertOutcome: Sendable, Equatable {
    /// A revert candidate with its own task; it runs through test, review and approval.
    case built(CandidateRecord)
    /// The revert has conflicts; its task waits in `conflict`.
    case conflicted(CandidateRecord, paths: [String])
    /// The published change is no longer part of the integration state.
    case nothingToRevert

    public var text: String {
        switch self {
        case .built:
            "Der Revert-Kandidat ist gebaut. Er läuft als eigene Aufgabe durch Test, Review und Freigabe; "
                + "veröffentlicht wird er erst nach deiner Freigabe."
        case .conflicted(_, let paths):
            "Der Revert hat Konflikte in \(paths.count == 1 ? "einer Datei" : "\(paths.count) Dateien"): "
                + "\(paths.joined(separator: ", ")). Die Revert-Aufgabe steht in „Konflikt“; ohne Auflösung kannst du den Revert ablehnen."
        case .nothingToRevert:
            "Nichts zurückzunehmen: Die Änderung ist im aktuellen Integrationsstand nicht mehr enthalten. Es wurde kein Kandidat angelegt."
        }
    }
}

extension DecisionSheet {
    /// A new branch in the user's repository at the job's integration state (create-only).
    public static func deliver(_ preview: DeliveryPreview, jobTitle: String) -> DecisionSheet {
        let name = preview.branchName ?? preview.requestedName
        var scope = ["Auftrag: \(jobTitle)", "Neuer Branch: refs/heads/\(name)"]
        if let branch = preview.branchName, branch != preview.requestedName {
            scope.append(
                "„\(preview.requestedName)“ ist schon belegt (Groß- und Kleinschreibung zählen auf APFS nicht); angelegt wird „\(branch)“."
            )
        }
        scope += [
            "Integrationsref: \(preview.integrationRef)",
            "Integrationsstand: \(preview.target)",
            "Veröffentlichte Kandidaten: \(preview.publishedCandidates)",
            "Vorhandene Branches, dein Checkout und dein Index bleiben unverändert; nichts wird gepusht.",
        ]
        var sheet = DecisionSheet(
            title: "In neuen Branch liefern",
            action: "Den Branch „\(name)“ in deinem Repository neu anlegen, auf dem Integrationsstand \(Labels.short(preview.target)).",
            scope: scope,
            ifRejected: "Es wird kein Branch angelegt. Der Integrationsstand bleibt unter \(preview.integrationRef) erhalten; du kannst später liefern.",
            approveLabel: "Branch anlegen", rejectLabel: "Nicht liefern", reported: nil,
            blockers: preview.problems.map(\.text), shown: nil
        )
        sheet.delivery = ShownDelivery(job: preview.job, name: preview.requestedName, target: preview.target)
        return sheet
    }

    /// Reverting a published candidate: a new candidate on the current integration state, in its
    /// own task, through the same chain (ADR 0004 §8).
    public static func revert(_ candidate: CandidateRecord, task: TaskRecord?, openRevert: CandidateRecord?) -> DecisionSheet {
        let commit = candidate.candidateOID ?? "–"
        var blockers: [String] = []
        if candidate.state != .published { blockers.append("Nur veröffentlichte Kandidaten lassen sich zurücknehmen.") }
        if let openRevert {
            blockers.append("Für diese Veröffentlichung gibt es schon einen offenen Revert (Kandidat \(Labels.short(openRevert.candidateOID ?? openRevert.id.uuidString))).")
        }
        return DecisionSheet(
            title: "Veröffentlichung zurücknehmen",
            action: "Einen Revert-Kandidaten bauen, der den veröffentlichten Commit \(Labels.short(commit)) auf dem aktuellen Integrationsstand zurücknimmt.",
            scope: [
                "Aufgabe: \(task?.title ?? "–")",
                "Zielref: \(candidate.targetRef)",
                "Zurückgenommener Commit: \(commit)",
                "Der Revert läuft als eigene Aufgabe durch Test, Review und Freigabe; das Ziel ändert sich erst nach deiner Freigabe.",
                "Gelieferte Branches, dein Checkout und deine Branches bleiben unverändert.",
            ],
            ifRejected: "Es wird nichts gebaut; die Veröffentlichung bleibt bestehen.",
            approveLabel: "Revert bauen", rejectLabel: "Nicht zurücknehmen", reported: nil, blockers: blockers, shown: nil
        )
    }
}

/// German texts for the errors of delivery and revert, shown in their sheets.
public enum IntegrationMessages {
    public static func text(_ error: any Error) -> String {
        switch error {
        case MergeError.invalidBranchName: DeliveryProblem.invalidName.text
        case MergeError.noFreeBranchName: DeliveryProblem.noFreeName.text
        case MergeError.branchFolderCaseConflict(let name, let existing): DeliveryProblem.folderCaseConflict(name: name, existing: existing).text
        case IntegrationError.targetMoved:
            "Der Integrationsstand hat sich geändert, seit das Blatt ihn gezeigt hat. Prüfe den neuen Stand und entscheide neu."
        case IntegrationError.jobWithoutIntegration: "Dieser Auftrag hat keinen Integrationsstand."
        case IntegrationError.candidateNotIn(_, let state): "Der Kandidat ist nicht veröffentlicht (Zustand: \(Labels.candidate(state).text))."
        case IntegrationStoreError.openRevertExists: "Für diese Veröffentlichung gibt es schon einen offenen Revert."
        case IntegrationStoreError.rejectedBefore:
            "Ein Revert auf diesem Integrationsstand ist schon an Belegen gescheitert; er wird nicht neu gebaut."
        case MergeError.unsupportedConflict(let paths):
            "Der Revert hat Konflikte, die KAIORX nicht zur Auflösung anbietet (\(paths.joined(separator: ", "))). Er wurde abgebrochen."
        case ActionError.unavailable(let what): "Nicht verfügbar: \(what)."
        default: String(describing: error)
        }
    }
}

extension WorkbenchActions {
    /// What a delivery with `name` would do now. Reads only: the integration ref, the branch
    /// names, and the service's own name check and suffix rule.
    public func deliveryPreview(job: JobID, name: String) async throws -> DeliveryPreview {
        guard let git = services.git, let workspace = services.workspace else { throw ActionError.unavailable("Git") }
        guard let record = try await store.jobs().first(where: { $0.id == job }), let ref = record.integrationRef else {
            throw IntegrationError.jobWithoutIntegration(job)
        }
        let repository = try await workspace.attach(record.projectID)
        guard let target = try await git.readRef(ref, in: repository) else { throw IntegrationError.jobWithoutIntegration(job) }
        let published = try await store.candidates(jobID: job).filter { $0.state == .published }.count
        var problems: [DeliveryProblem] = []
        var branch: String?
        if name.isEmpty {
            problems.append(.emptyName)
        } else {
            do {
                try await git.checkBranchName(name, in: repository)
                branch = GitRunner.freeBranchNames(for: name, existing: try await git.branchNames(in: repository)).first
                if branch == nil { problems.append(.noFreeName) }
            } catch MergeError.invalidBranchName {
                problems.append(.invalidName)
            } catch MergeError.branchFolderCaseConflict(let name, let existing) {
                problems.append(.folderCaseConflict(name: name, existing: existing))
            }
        }
        if published == 0 { problems.append(.nothingPublished) }
        return DeliveryPreview(
            job: job, requestedName: name, branchName: branch, integrationRef: ref, target: target, publishedCandidates: published, problems: problems
        )
    }

    /// Creates the branch the sheet showed, at exactly the integration state it showed; returns
    /// the name used (it differs from the preview only if a branch appeared in between).
    @discardableResult
    public func deliver(sheet: DecisionSheet) async throws -> String {
        guard let integration = services.integration else { throw ActionError.unavailable("Integration") }
        guard sheet.canApprove, let shown = sheet.delivery else { throw ActionError.unavailable("Lieferung") }
        return try await integration.createDeliveryBranch(job: shown.job, name: shown.name, expectedTarget: shown.target)
    }

    /// The open (not published, rejected or superseded) revert of a published candidate, if any.
    public func openRevert(of candidate: CandidateID) async throws -> CandidateRecord? {
        guard let original = try await store.candidate(candidate) else { return nil }
        return try await store.candidates(jobID: original.jobID).first {
            $0.revertsCandidateID == candidate && ![.published, .rejected, .superseded].contains($0.state)
        }
    }

    /// Builds the revert the sheet offered.
    public func revert(_ candidate: CandidateID, sheet: DecisionSheet) async throws -> RevertOutcome {
        guard let integration = services.integration else { throw ActionError.unavailable("Integration") }
        guard sheet.canApprove else { throw ActionError.unavailable("Revert") }
        switch try await integration.buildRevert(of: candidate) {
        case .built(let record): return .built(record)
        case .conflicted(let record, let entries): return .conflicted(record, paths: entries.map(\.path))
        case .alreadyContained: return .nothingToRevert
        }
    }
}
