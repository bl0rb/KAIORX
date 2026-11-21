import Domain
import Orchestration
import Storage
import SwiftUI
import Workbench
import Workspace

// The candidate chain in the app (ADR 0011): the host-only steps run on their own; these views
// show where a result stands and hold the decisions that stay with the user. Every sheet uses
// `DecisionSheetContent` and `SheetOutcome`; Return and Escape take the safe choice, the approval
// is never the default button.

// MARK: Result box in the task view

/// A task's result before it has a candidate: seal status, write area, dropped paths, and the
/// decisions the driver leaves to the user.
struct ResultBox: View {
    @Environment(AppModel.self) private var model
    let task: TaskRecord
    @State private var shown: ShownResult?
    @State private var issue: ChainIssue?
    @State private var area: ResultWriteArea?
    @State private var loadError: String?

    /// The task waits with its author's result, possibly held.
    static func applies(to task: TaskRecord) -> Bool {
        task.state == .resultReady || (task.state == .blocked && task.resumeState == .resultReady)
    }

    private var held: Bool { task.state == .blocked }

    var body: some View {
        GroupBox("Ergebnis") {
            VStack(alignment: .leading, spacing: 6) {
                let status = shown.map { Labels.result($0.check, issue: issue) } ?? StatusLabel("Wird versiegelt …", "lock.rotation", .active)
                StatusBadge(label: status).accessibilityIdentifier("resultStatus")
                if let area {
                    Text(Labels.writeArea(area)).foregroundStyle(.secondary).accessibilityIdentifier("writeArea")
                }
                if let shown {
                    ForEach(shown.rejected, id: \.self) { path in
                        Label("Verworfen: \(path) – \(reason(path, in: shown.check))", systemImage: "xmark.bin")
                            .font(.callout)
                            .textSelection(.enabled)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Verworfen: \(path), \(reason(path, in: shown.check))")
                            .accessibilityIdentifier("rejectedPath-\(path)")
                    }
                }
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).accessibilityIdentifier("resultError")
                }
                if held {
                    Label("Aufgabe angehalten", systemImage: "pause.circle").foregroundStyle(.orange)
                }
                buttons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("resultBox")
        .task(id: reloadKey) { await load() }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            Spacer()
            if canRetry {
                Button("Erneut versuchen") { retry() }
                    .disabled(held)
                    .help(held ? "Aufgabe angehalten" : "Versucht das Versiegeln oder Bauen gleich noch einmal.")
                    .accessibilityLabel("Erneut versuchen")
                    .accessibilityHint("Der nächste Durchlauf versiegelt oder baut dieses Ergebnis erneut; es startet kein Anbieter.")
                    .accessibilityIdentifier("retryBuild")
            }
            if canDiscard {
                Button("Ergebnis verwerfen …") { model.sheet = .result(task.id, discard: true) }
                    .disabled(held)
                    .help(held ? "Aufgabe angehalten" : "Verwirft das Ergebnis; die Aufgabe wird neu bearbeitet.")
                    .accessibilityLabel("Ergebnis verwerfen")
                    .accessibilityHint("Öffnet die Entscheidung. Die Aufgabe geht zurück an einen Autor, die Zählung der Versuche beginnt neu.")
                    .accessibilityIdentifier("discardResult")
            }
            if needsDecision {
                Button("Ergebnis entscheiden …") { model.sheet = .result(task.id) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(held)
                    .help(held ? "Aufgabe angehalten" : "Öffnet die Entscheidung über dieses Ergebnis (⇧⌘E).")
                    .accessibilityLabel("Ergebnis entscheiden")
                    .accessibilityHint("Zeigt, was mit dem Ergebnis geschieht, bevor du entscheidest.")
                    .accessibilityIdentifier("decideResult")
            }
        }
    }

    /// Reloads when the task, its result worktree, its candidates or the chain moved on.
    private var reloadKey: String {
        let tree = model.state.resultWorktree(of: task.id)
        let candidates = model.state.candidates.values.filter { $0.taskID == task.id }.map { "\($0.id.uuidString):\($0.version)" }.sorted()
        return [
            task.id.uuidString, "\(task.version)", tree.map { "\($0.id.uuidString):\($0.version)" } ?? "-",
            candidates.joined(separator: ","), "\(model.chainRevision)",
        ].joined(separator: "|")
    }

    private var needsDecision: Bool { shown.map { PendingDecisions.needsUser($0.check) } ?? false }

    private var canRetry: Bool {
        switch issue {
        case .sealFailed?, .buildFailed?, .collectFailed?: true
        default: false
        }
    }

    /// Discarding is offered for plan tasks only (only the scheduler picks a task up again), and
    /// not for an empty or contained result: that one is accepted instead.
    private var canDiscard: Bool {
        guard task.planKey != nil, let shown else { return false }
        switch shown.check {
        case .rejectedOnly, .undeclared, .planTaskMissing: return true
        case .buildable, .awaitingSeal: return canRetry
        case .notApplicable, .empty, .contained, .candidate: return false
        }
    }

    private func reason(_ path: String, in check: ResultCheck) -> String {
        switch check {
        case .undeclared(_, let rejected), .rejectedOnly(let rejected): rejected[path].map(Labels.rejectReason) ?? "verworfen"
        default: "verworfen"
        }
    }

    private func load() async {
        guard let actions = model.actions else { return }
        do {
            let (shown, issue) = try await actions.resultCheck(task.id)
            self.shown = shown
            self.issue = issue
            area = try? await actions.writeArea(of: task.id)
            loadError = nil
        } catch ActionError.unavailable {
            // No result worktree yet (the run's record is still arriving).
            shown = nil
            issue = nil
        } catch {
            loadError = ChainMessages.text(error)
        }
    }

    private func retry() {
        guard let actions = model.actions else { return }
        let id = task.id
        Task {
            do { try await actions.retryBuild(id) } catch { model.errorMessage = ChainMessages.text(error) }
            await load()
        }
    }
}

// MARK: Result sheet

/// The decision on a result the driver does not build on its own: undeclared paths, an empty or
/// already contained result, or discarding it.
struct ResultSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: TaskID
    @State private var discard: Bool
    @State private var sheet: DecisionSheet?
    @State private var mode: Mode = .discard
    @State private var problem: String?
    @State private var working = false
    @State private var outcome: Outcome?
    @State private var planTask = false

    enum Mode { case build, accept, discard }

    enum Outcome: Equatable {
        case built
        case conflicted(CandidateID, files: Int)
        case alreadyContained
        case accepted
        case discarded

        var text: String {
            switch self {
            case .built: "Kandidat gebaut – als Nächstes Tests ausführen."
            case .conflicted(_, let files): files == 1 ? "Konflikt in 1 Datei." : "Konflikt in \(files) Dateien."
            case .alreadyContained: "Das Ergebnis ist inzwischen im Integrationsstand enthalten; es wurde nichts gebaut."
            case .accepted: "Die Aufgabe ist ohne Änderung als erledigt angenommen."
            case .discarded: "Ergebnis verworfen. Die Aufgabe wird neu bearbeitet; die Zählung der Versuche beginnt neu."
            }
        }
    }

    init(task: TaskID, discard: Bool) {
        self.task = task
        _discard = State(initialValue: discard)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let outcome {
                Text(sheet?.title ?? "Ergebnis entscheiden").font(.headline).accessibilityAddTraits(.isHeader)
                SheetOutcome(text: outcome.text, failed: false)
                HStack {
                    Spacer()
                    if case .conflicted(let candidate, _) = outcome {
                        Button("Konflikt zeigen") { model.sheet = .resolveConflicts(candidate) }
                            .accessibilityHint("Öffnet die Auflösung des Konflikts.")
                            .accessibilityIdentifier("showConflicts")
                    }
                    Button("Fertig") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("resultDone")
                }
            } else {
                if let sheet { DecisionSheetContent(sheet: sheet) } else if problem == nil { ProgressView() }
                if let problem { SheetOutcome(text: problem, failed: true) }
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    if mode == .build, planTask, sheet != nil {
                        Button("Ergebnis verwerfen …") {
                            discard = true
                            Task { await load() }
                        }
                        .disabled(working)
                        .accessibilityHint("Zeigt stattdessen die Entscheidung, das Ergebnis zu verwerfen.")
                        .accessibilityIdentifier("sheetDiscardResult")
                    }
                    Spacer()
                    Button(sheet?.rejectLabel ?? "Nicht jetzt") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("decisionReject")
                    Button(sheet?.approveLabel ?? "Entscheiden") { approve() }
                        .disabled(!(sheet?.canApprove ?? false) || sheet?.result == nil || working)
                        .accessibilityIdentifier("decisionApprove")
                }
            }
        }
        .padding()
        .frame(width: 560)
        .task { await load() }
    }

    func load() async {
        guard let actions = model.actions, let store = model.services?.store else { return }
        do {
            let (shown, issue) = try await actions.resultCheck(task)
            let record = try await store.task(task)
            planTask = record?.planKey != nil
            if discard {
                mode = .discard
                sheet = .discardResult(shown, task: record, issue: issue)
            } else {
                // Nothing waits for the user while the driver can still move the result on.
                guard PendingDecisions.needsUser(shown.check) || issue != nil else { throw ChainActionError.nothingToDecide(task) }
                let area = (try? await actions.writeArea(of: task)) ?? .planTaskMissing
                var tip: String?
                if case .empty = shown.check, let job = record?.jobID { tip = try? await store.integrationTip(job: job) }
                switch shown.check {
                case .undeclared: mode = .build
                case .empty, .contained: mode = .accept
                default: mode = .discard
                }
                sheet = .resultDecision(shown, task: record, writeArea: area, issue: issue, tip: tip)
            }
            problem = nil
        } catch {
            sheet = nil
            problem = ChainMessages.text(error)
        }
    }

    func approve() {
        guard let actions = model.actions, let sheet, sheet.canApprove, let shown = sheet.result else { return }
        let mode = mode
        working = true
        Task {
            do {
                switch mode {
                case .build:
                    switch try await actions.confirmUndeclared(shown) {
                    case .built: outcome = .built
                    case .conflicted(let candidate, let entries): outcome = .conflicted(candidate.id, files: entries.count)
                    case .alreadyContained: outcome = .alreadyContained
                    }
                case .accept:
                    try await actions.acceptEmptyResult(shown)
                    outcome = .accepted
                case .discard:
                    try await actions.discardResult(shown)
                    outcome = .discarded
                }
            } catch {
                // The shown state may be outdated: show the current one next to the error.
                let message = ChainMessages.text(error)
                await load()
                problem = message
            }
            working = false
            await model.refreshDecisions()
        }
    }
}

// MARK: Conflicts

/// The conflicting paths of a conflicted candidate, with their kinds, in the candidate view.
struct CandidateConflictsView: View {
    @Environment(AppModel.self) private var model
    let candidate: CandidateRecord
    @State private var rows: [ConflictRow] = []

    private var held: Bool { candidate.taskID.flatMap { model.state.tasks[$0] }?.state == .blocked }

    var body: some View {
        GroupBox("Konflikte") {
            VStack(alignment: .leading, spacing: 6) {
                if rows.isEmpty {
                    ForEach(candidate.conflicts.sorted(), id: \.self) { path in
                        Label(path, systemImage: "arrow.triangle.merge").font(.body.monospaced()).accessibilityIdentifier("conflict-\(path)")
                    }
                } else {
                    ForEach(rows) { row in
                        Label("\(row.path) – \(Labels.conflictKind(row.kind))", systemImage: "arrow.triangle.merge")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(row.path): \(Labels.conflictKind(row.kind))")
                            .accessibilityIdentifier("conflict-\(row.path)")
                    }
                }
                HStack {
                    Spacer()
                    Button("Konflikte lösen …") { model.sheet = .resolveConflicts(candidate.id) }
                        .keyboardShortcut("k", modifiers: [.command, .shift])
                        .disabled(held)
                        .help(held ? "Aufgabe angehalten" : "Entscheide je Datei, welche Fassung gilt; danach wird der Kandidat gebaut (⇧⌘K).")
                        .accessibilityLabel("Konflikte lösen")
                        .accessibilityHint("Öffnet die Auflösung. Dein Checkout bleibt unverändert.")
                        .accessibilityIdentifier("resolveConflicts")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conflicts")
        .task(id: "\(candidate.id.uuidString)|\(candidate.version)") {
            rows = (try? await model.actions?.conflictPreview(candidate.id).rows) ?? []
        }
    }
}

/// Resolves a conflicted candidate with one choice per path; no manual content editing in v1.
struct ResolveConflictsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let candidate: CandidateID
    @State private var preview: ConflictPreview?
    @State private var record: CandidateRecord?
    @State private var choices: [String: ConflictChoice] = [:]
    @State private var problem: String?
    @State private var working = false
    @State private var outcome: (text: String, failed: Bool)?

    private var sheet: DecisionSheet? {
        guard let preview, let record else { return nil }
        return .resolveConflicts(preview, candidate: record, task: record.taskID.flatMap { model.state.tasks[$0] }, choices: choices)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let outcome {
                Text("Konflikt lösen").font(.headline).accessibilityAddTraits(.isHeader)
                SheetOutcome(text: outcome.text, failed: outcome.failed)
                HStack {
                    Spacer()
                    Button("Fertig") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("conflictsDone")
                }
            } else {
                if let sheet { DecisionSheetContent(sheet: sheet) } else if problem == nil { ProgressView() }
                if let preview { rows(preview) }
                if let problem { SheetOutcome(text: problem, failed: true) }
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(sheet?.rejectLabel ?? "Nicht jetzt") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("decisionReject")
                    Button(sheet?.approveLabel ?? "Auflösen und Kandidat bauen") { approve() }
                        .disabled(!(sheet?.canApprove ?? false) || working)
                        .accessibilityIdentifier("decisionApprove")
                }
            }
        }
        .padding()
        .frame(width: 620)
        .task { await load() }
    }

    private func rows(_ preview: ConflictPreview) -> some View {
        let revert = preview.kind == .revert
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(preview.rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.path).font(.body.monospaced()).textSelection(.enabled)
                            Text(Labels.conflictKind(row.kind)).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        // No preselection: every path needs the user's own choice.
                        Picker("Entscheidung für \(row.path)", selection: choice(for: row.path)) {
                            ForEach(ConflictChoice.allCases, id: \.self) { choice in
                                Text(Labels.conflictChoice(choice, revert: revert)).tag(ConflictChoice?.some(choice))
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("Entscheidung für \(row.path)")
                        .accessibilityIdentifier("conflictResolution-\(row.path)")
                        if preview.mergeBase != nil {
                            ConflictDiffDisclosure(preview: preview, path: row.path)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("conflictRow-\(row.path)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
    }

    private func choice(for path: String) -> Binding<ConflictChoice?> {
        Binding(get: { choices[path] }, set: { choices[path] = $0 })
    }

    func load() async {
        guard let actions = model.actions, let store = model.services?.store else { return }
        do {
            let preview = try await actions.conflictPreview(candidate)
            record = try await store.candidate(candidate)
            // Choices for paths that are no longer shown do not carry over.
            choices = choices.filter { preview.shown.paths.contains($0.key) }
            self.preview = preview
            problem = nil
        } catch {
            preview = nil
            problem = ChainMessages.text(error)
        }
    }

    func approve() {
        guard let actions = model.actions, let preview, sheet?.canApprove == true else { return }
        let choices = choices
        working = true
        Task {
            do {
                _ = try await actions.resolveConflicts(preview, choices: choices)
                outcome = ("Konflikt gelöst – Kandidat gebaut. Als Nächstes Tests ausführen.", false)
            } catch MergeError.nothingToCommit {
                outcome = (ChainMessages.text(MergeError.nothingToCommit), true)
            } catch {
                let message = ChainMessages.text(error)
                await load()
                problem = message
            }
            working = false
            await model.refreshDecisions()
        }
    }
}

/// The two sides of one conflicting path, each diffed from the merge base. Read-only.
struct ConflictDiffDisclosure: View {
    @Environment(AppModel.self) private var model
    let preview: ConflictPreview
    let path: String
    @State private var expanded = false
    @State private var result: [DiffLine] = []
    @State private var target: [DiffLine] = []
    @State private var problem: String?

    var body: some View {
        DisclosureGroup("Änderungen ansehen", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                Text("Was der Lauf geändert hat").font(.caption.bold())
                side(result)
                Text("Was sich im Integrationsstand geändert hat").font(.caption.bold())
                side(target)
            }
        }
        .accessibilityIdentifier("conflictDiff-\(path)")
        .task(id: expanded) { if expanded { await load() } }
    }

    @ViewBuilder private func side(_ lines: [DiffLine]) -> some View {
        if lines.isEmpty {
            Text("Keine Änderung auf dieser Seite").foregroundStyle(.secondary)
        } else {
            DiffLinesView(lines: lines).frame(maxHeight: 200)
        }
    }

    private func load() async {
        guard let actions = model.actions else { return }
        do {
            result = DiffParser.parse(try await actions.conflictSideDiff(preview, path: path, side: .result).text)
            target = DiffParser.parse(try await actions.conflictSideDiff(preview, path: path, side: .target).text)
            problem = nil
        } catch {
            problem = "Diff nicht lesbar: \(ChainMessages.text(error))"
        }
    }
}

// MARK: Review

/// The review of a candidate in review: where it stands, and the user's explicit start or import
/// (ADR 0009 §8: only the user starts a review).
struct CandidateReviewStatusView: View {
    @Environment(AppModel.self) private var model
    let candidate: CandidateRecord

    private var task: TaskRecord? { candidate.taskID.flatMap { model.state.tasks[$0] } }
    private var held: Bool { task?.state == .blocked }
    private var openReviewer: AttemptRecord? { candidate.taskID.flatMap { model.state.openReviewer(of: $0) } }

    var status: StatusLabel {
        if let open = openReviewer { return StatusLabel("Review läuft (\(Labels.provider(open.provider)))", "eye", .active) }
        let reviews = (model.state.reviews[candidate.id] ?? []).filter { $0.candidateOID == candidate.candidateOID }
        let recorded = Set(reviews.compactMap(\.reviewerAttemptID))
        let reviewers = model.state.reviewers(of: candidate)
        if reviewers.contains(where: { $0.state == .succeeded && !recorded.contains($0.id) }) {
            return StatusLabel("Review wird übernommen …", "tray.and.arrow.down", .active)
        }
        if let latest = reviews.max(by: { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }) { return Labels.review(latest.status) }
        if let last = reviewers.last, last.state == .failed || last.state == .cancelled {
            return StatusLabel("Prüfer abgebrochen", "xmark.circle", .warning)
        }
        return StatusLabel("Noch kein Review", "eye.slash", .waiting)
    }

    var body: some View {
        GroupBox("Review") {
            VStack(alignment: .leading, spacing: 6) {
                StatusBadge(label: status).accessibilityIdentifier("reviewStatus")
                if candidate.state == .reviewing {
                    HStack {
                        Spacer()
                        Button("Review einfügen …") { model.sheet = .importReview(candidate.id) }
                            .disabled(held)
                            .help(held ? "Aufgabe angehalten" : "Übernimmt ein außerhalb von KAIORX erstelltes Review als gemeldeten Text.")
                            .accessibilityLabel("Review einfügen")
                            .accessibilityHint("Öffnet ein Feld für den Text eines Reviews, das du anderswo erstellt hast.")
                            .accessibilityIdentifier("importReview")
                        Button(retryLabel) { model.sheet = .startReview(candidate.id) }
                            .keyboardShortcut("r", modifiers: [.command, .option])
                            .disabled(held || openReviewer != nil)
                            .help(startHelp)
                            .accessibilityLabel(retryLabel.replacingOccurrences(of: " …", with: ""))
                            .accessibilityHint("Zeigt Prüfer, Modell und was übertragen wird, bevor du startest. Ein Review verbraucht Kontingent.")
                            .accessibilityIdentifier("startReview")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private var retryLabel: String {
        status.text == "Prüfer abgebrochen" ? "Review erneut starten …" : "Review starten …"
    }

    private var startHelp: String {
        if held { return "Aufgabe angehalten" }
        if openReviewer != nil { return "Für diese Aufgabe läuft schon ein Review." }
        return "Startet ein Review bei einem anderen Anbieter als dem Autor (⌥⌘R)."
    }
}

/// The explicit start of a review: one option per provider, each with its blockers. The gate's
/// verdict is shown for information only and never blocks.
struct StartReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let candidate: CandidateID
    @State private var options: [ReviewOption] = []
    @State private var selected: String?
    @State private var record: CandidateRecord?
    @State private var problem: String?
    @State private var working = false
    @State private var started: String?

    private var option: ReviewOption? { options.first { $0.id == selected } }

    private var sheet: DecisionSheet? {
        guard let record else { return nil }
        return .startReview(option, candidate: record, task: record.taskID.flatMap { model.state.tasks[$0] })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let started {
                Text("Review starten").font(.headline).accessibilityAddTraits(.isHeader)
                SheetOutcome(text: started, failed: false)
                HStack {
                    Spacer()
                    Button("Fertig") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("reviewDone")
                }
            } else {
                if !options.isEmpty {
                    GroupBox("Prüfer") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(options) { option in optionRow(option) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Prüfer")
                }
                if let sheet { DecisionSheetContent(sheet: sheet) } else if problem == nil { ProgressView() }
                if let problem { SheetOutcome(text: problem, failed: true) }
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(sheet?.rejectLabel ?? "Nicht jetzt") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("decisionReject")
                    Button(sheet?.approveLabel ?? "Review starten") { approve() }
                        .disabled(!(sheet?.canApprove ?? false) || sheet?.review == nil || working)
                        .accessibilityIdentifier("decisionApprove")
                }
            }
        }
        .padding()
        .frame(width: 580)
        .task { await load() }
    }

    private func optionRow(_ option: ReviewOption) -> some View {
        let chosen = option.id == selected
        let name = "\(Labels.provider(option.provider)) · \(option.model.isEmpty ? "kein Prüfermodell" : option.model)"
        let blocker = option.blockers.first.map { Labels.reviewBlocker($0, provider: option.provider) }
        return Button { selected = option.id } label: {
            HStack {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                Text(name)
                if let blocker { Text("– \(blocker)").foregroundStyle(.secondary) }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(blocker.map { "\(name), \($0)" } ?? name)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("reviewOption-\(option.provider.rawValue)")
    }

    func load() async {
        guard let actions = model.actions, let store = model.services?.store else { return }
        do {
            record = try await store.candidate(candidate)
            options = try await actions.reviewOptions(candidate)
            if option == nil {
                // The first option nothing blocks, else one only the shared state blocks.
                selected = (options.first { $0.blockers.isEmpty }
                    ?? options.first { !$0.blockers.contains(.sameProviderAsAuthor) } ?? options.first)?.id
            }
            problem = nil
        } catch {
            problem = ChainMessages.text(error)
        }
    }

    func approve() {
        guard let actions = model.actions, let option, sheet?.canApprove == true else { return }
        working = true
        Task {
            do {
                _ = try await actions.startReview(option, candidate: candidate)
                started = "Review bei \(Labels.provider(option.provider)) gestartet. Das Ergebnis wird übernommen, sobald der Prüfer fertig ist."
            } catch {
                let message = ChainMessages.text(error)
                await load()
                problem = message
            }
            working = false
            await model.refreshDecisions()
        }
    }
}

/// Imports a review the user ran elsewhere. The pasted text is reported text, never KAIORX's own;
/// for a sensitive task this is the only way to its review.
struct ImportReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let candidate: CandidateID
    @State private var text = ""
    @State private var record: CandidateRecord?
    @State private var problem: String?
    @State private var working = false
    @State private var imported: ReviewRecord?

    private var sheet: DecisionSheet? {
        guard let record else { return nil }
        return .importReview(record, task: record.taskID.flatMap { model.state.tasks[$0] }, text: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imported {
                Text("Review einfügen").font(.headline).accessibilityAddTraits(.isHeader)
                SheetOutcome(text: "Review übernommen: \(Labels.review(imported.status).text).", failed: imported.status == .invalid)
                HStack {
                    Spacer()
                    Button("Fertig") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("importDone")
                }
            } else {
                if let sheet { DecisionSheetContent(sheet: sheet) } else if problem == nil { ProgressView() }
                GroupBox("Gemeldeter Text (nicht von KAIORX)") {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                        .accessibilityLabel("Gemeldeter Text des Reviews")
                        .accessibilityHint("Füge das Review ein; es zählt nur, wenn es genau diesen Commit nennt.")
                        .accessibilityIdentifier("importReviewText")
                }
                if let problem { SheetOutcome(text: problem, failed: true) }
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(sheet?.rejectLabel ?? "Nicht übernehmen") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("decisionReject")
                    Button(sheet?.approveLabel ?? "Review übernehmen") { approve() }
                        .disabled(!(sheet?.canApprove ?? false) || working)
                        .accessibilityIdentifier("decisionApprove")
                }
            }
        }
        .padding()
        .frame(width: 580)
        .task { await load() }
    }

    func load() async {
        do {
            record = try await model.services?.store.candidate(candidate)
            problem = nil
        } catch {
            problem = ChainMessages.text(error)
        }
    }

    func approve() {
        guard let actions = model.actions, sheet?.canApprove == true else { return }
        let text = text
        working = true
        Task {
            do {
                imported = try await actions.importReview(candidate, text: text)
            } catch {
                let message = ChainMessages.text(error)
                await load()
                problem = message
            }
            working = false
            await model.refreshDecisions()
        }
    }
}
