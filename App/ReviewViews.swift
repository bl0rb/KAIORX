import Domain
import Orchestration
import Storage
import SwiftUI
import Workbench
import Workspace

/// A decision sheet: action, scope, what a rejection means. Return triggers the safe choice.
struct DecisionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let decision: PendingDecision
    @State private var sheet: DecisionSheet?
    /// Exactly the consents the sheet shows; approving grants these and nothing else.
    @State private var consentDrafts: [ConsentDraft] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let sheet {
                Text(sheet.title).font(.headline).accessibilityAddTraits(.isHeader)
                GroupBox("Aktion") { Text(sheet.action).frame(maxWidth: .infinity, alignment: .leading) }
                GroupBox("Geltungsbereich") {
                    VStack(alignment: .leading) { ForEach(sheet.scope, id: \.self) { Text($0).textSelection(.enabled) } }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Wenn du ablehnst") { Text(sheet.ifRejected).frame(maxWidth: .infinity, alignment: .leading) }
                if let reported = sheet.reported {
                    GroupBox("Gemeldeter Text (nicht von KAIORX)") { Text(reported).font(.body.monospaced()) }
                }
                if !sheet.blockers.isEmpty {
                    GroupBox("Noch offen") {
                        VStack(alignment: .leading) { ForEach(sheet.blockers, id: \.self) { Label($0, systemImage: "xmark.circle") } }
                    }
                    .accessibilityIdentifier("blockers")
                }
                HStack {
                    Spacer()
                    SafeChoiceButton(sheet.rejectLabel) { dismiss() }
                        .accessibilityIdentifier("decisionReject")
                    Button(sheet.approveLabel) { approve(sheet) }
                        .disabled(!sheet.canApprove)
                        .accessibilityIdentifier("decisionApprove")
                }
            } else {
                ProgressView()
            }
        }
        .padding()
        .frame(width: 520)
        .task { await load() }
        .onChange(of: model.state) { _, _ in
            // A new candidate commit invalidates the sheet (runtime contract: new candidate, new decision).
            if case .publish(let id) = decision, let shown = sheet?.shown, model.state.candidates[id]?.candidateOID != shown.candidateOID {
                model.errorMessage = "Neuer Kandidat – neue Entscheidung nötig."
                dismiss()
            }
        }
    }

    func load() async {
        guard let services = model.services else { return }
        switch decision {
        case .publish(let id):
            guard let candidate = model.state.candidates[id] else { return }
            let gate = (try? await services.integration?.gateItems(id)) ?? [.noCommit]
            sheet = DecisionSheet.publish(candidate, task: candidate.taskID.flatMap { model.state.tasks[$0] }, gate: gate)
        case .task(let id, let reason):
            guard let task = model.state.tasks[id], let project = model.project(of: task) else { return }
            if reason.kind == .consent {
                consentDrafts = model.consentProviders.map { WorkbenchActions.consentDraft(project: project.id, provider: $0) }
                sheet = DecisionSheet.consent(consentDrafts)
            } else if reason.kind == .userDecision {
                sheet = DecisionSheet.moreAttempts(task, reason: reason)
            } else {
                let planned = try? await services.store.plannedTask(id)
                sheet = DecisionSheet.start(task, provider: nil, writePaths: planned?.writePaths ?? [])
            }
        case .uncertain(let id):
            guard let attempt = model.state.attempts[id] else { return }
            sheet = DecisionSheet.uncertain(attempt, task: model.state.tasks[attempt.taskID])
        case .findings(let id):
            guard let candidate = model.state.candidates[id] else { return }
            sheet = DecisionSheet(
                title: "Befunde entscheiden", action: "Offene Befunde dieses Kandidaten in der Review-Ansicht entscheiden.",
                scope: ["Kandidat \(Labels.short(candidate.candidateOID ?? "–"))"], ifRejected: "Der Kandidat bleibt im Review.",
                approveLabel: "Zur Review-Ansicht", rejectLabel: "Später", reported: nil, blockers: [], shown: nil
            )
        case .result, .conflicts, .tests, .review:
            // These have their own sheets (`AppModel.open`); a stale route closes and reopens there.
            dismiss()
            model.open(decision)
        }
    }

    func approve(_ sheet: DecisionSheet) {
        let decision = decision
        let providers = consentDrafts.map(\.provider)
        let state = model.state
        model.perform { actions in
            switch decision {
            case .publish(let id): try await actions.approveAndPublish(id, sheet: sheet)
            case .task(let id, let reason):
                if reason.kind == .consent, let task = state.tasks[id], let project = state.jobs[task.jobID]?.projectID {
                    for provider in providers { try await actions.grantConsent(project: project, provider: provider) }
                } else if reason.kind == .userDecision {
                    try await actions.allowMoreAttempts(id)
                } else {
                    try await actions.start(id)
                }
            case .uncertain(let id): try await actions.closeUncertain(id)
            case .findings(let id):
                await MainActor.run { model.selectedTask = state.candidates[id]?.taskID }
            case .result, .conflicts, .tests, .review:
                break
            }
        }
        dismiss()
    }
}

struct RejectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let candidate: CandidateID
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kandidat ablehnen").font(.headline)
            Text("Die Aufgabe geht zurück zur Überarbeitung; Freigaben dieses Kandidaten werden widerrufen.")
            TextField("Begründung", text: $reason, axis: .vertical).lineLimit(3...6).accessibilityIdentifier("rejectReason")
            HStack {
                Spacer()
                SafeChoiceButton("Abbrechen") { dismiss() }
                Button("Ablehnen", role: .destructive) {
                    let reason = reason
                    model.perform { try await $0.reject(candidate, reason: reason) }
                    dismiss()
                }
                .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("rejectConfirm")
            }
        }
        .padding()
        .frame(width: 460)
    }
}

/// Candidate review: files against the first parent, the selected file's diff, tests, reviewer,
/// findings and what still blocks the approval.
struct CandidateReviewView: View {
    @Environment(AppModel.self) private var model
    let candidate: CandidateRecord
    @State private var files: [DiffFileRow] = []
    @State private var selected: DiffFileRow.ID?
    @State private var lines: [DiffLine] = []
    @State private var truncated = false
    @State private var gate: [GateItem] = []
    @State private var findings: [FindingRecord] = []
    @State private var loadError: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Kandidat \(Labels.short(candidate.candidateOID ?? "–"))").font(.headline)
                    Spacer()
                    StatusBadge(label: Labels.candidate(candidate.state)).accessibilityIdentifier("candidateStatus")
                }
                Text("Ziel \(candidate.targetRef) · gegen \(Labels.short(candidate.previousTargetOID))").foregroundStyle(.secondary)
                if !gate.isEmpty {
                    VStack(alignment: .leading) { ForEach(gate, id: \.self) { Label(Labels.gate($0), systemImage: "xmark.circle") } }
                        .accessibilityIdentifier("gate")
                }
                List(files, selection: $selected) { row in
                    HStack {
                        StatusBadge(label: row.label).labelStyle(.iconOnly)
                        Text(row.displayPath).font(.body.monospaced())
                        Spacer()
                        Text(row.counts).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(row.label.text): \(row.displayPath), \(row.counts)")
                }
                .frame(minHeight: 120, maxHeight: 200)
                .accessibilityIdentifier("diffFiles")
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).accessibilityIdentifier("diffError")
                }
                if truncated {
                    Label("Diff gekürzt: Die Datei ist größer als die Anzeigegrenze.", systemImage: "scissors").foregroundStyle(.orange)
                }
                DiffLinesView(lines: lines)
                if candidate.state == .conflicted {
                    CandidateConflictsView(candidate: candidate)
                }
                CandidateTestsView(candidate: candidate)
                if candidate.state == .reviewing || candidate.state == .accepted {
                    CandidateReviewStatusView(candidate: candidate)
                }
                ForEach(findings, id: \.id) { finding in
                    FindingRow(finding: finding)
                }
                HStack {
                    Spacer()
                    if candidate.state == .published {
                        Button { model.sheet = .revert(candidate.id) } label: { Label("Zurücknehmen …", systemImage: "arrow.uturn.backward") }
                            .keyboardShortcut("r", modifiers: [.command, .shift])
                            .help("Baut einen Revert-Kandidaten, der diese Veröffentlichung zurücknimmt (⇧⌘R).")
                            .accessibilityLabel("Veröffentlichung zurücknehmen")
                            .accessibilityHint("Baut einen Revert-Kandidaten als eigene Aufgabe; das Ziel ändert sich erst nach deiner Freigabe.")
                            .accessibilityIdentifier("revertCandidate")
                    }
                    if candidate.state != .published, candidate.state != .rejected, candidate.state != .superseded, candidate.state != .publishing {
                        Button("Ablehnen …") { model.sheet = .reject(candidate.id) }.accessibilityIdentifier("rejectCandidate")
                    }
                    if candidate.state == .accepted {
                        // Without a readable change list nothing is approved blind.
                        Button("Freigeben …") { model.sheet = .decision(.publish(candidate.id)) }
                            .disabled(loadError != nil)
                            .accessibilityIdentifier("approveCandidate")
                    }
                }
            }
        }
        .task(id: "\(candidate.id.uuidString)|\(candidate.version)") { await load() }
        .task(id: selected) { await loadDiff() }
    }

    func load() async {
        guard let actions = model.actions else { return }
        do {
            files = try await actions.changes(of: candidate).map(DiffFileRow.init)
            loadError = nil
        } catch {
            files = []
            loadError = "Die Änderungen konnten nicht gelesen werden: \(error)"
        }
        gate = (try? await model.services?.integration?.gateItems(candidate.id)) ?? []
        findings = (try? await model.services?.store.findings(candidate: candidate.id)) ?? []
        if selected == nil { selected = files.first?.id }
    }

    func loadDiff() async {
        guard let actions = model.actions, let row = files.first(where: { $0.id == selected }) else { lines = []; return }
        if row.file.isBinary || row.file.isSubmodule {
            lines = [DiffLine(id: 0, kind: .fileHeader, text: row.file.isBinary ? "Binärdatei – keine Textanzeige" : "Submodul")]
            truncated = false
            return
        }
        let wanted = selected
        do {
            let diff = try await actions.diff(of: candidate, file: row.file)
            // A slower load for an earlier selection never replaces the current one.
            guard !Task.isCancelled, wanted == selected else { return }
            lines = DiffParser.parse(diff.text)
            truncated = diff.truncated
        } catch {
            guard !Task.isCancelled, wanted == selected else { return }
            lines = [DiffLine(id: 0, kind: .fileHeader, text: "Diff nicht lesbar: \(error)")]
            truncated = false
            loadError = "Mindestens ein Diff konnte nicht gelesen werden."
        }
    }
}

struct DiffLinesView: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(spacing: 6) {
                        Text(line.oldLine.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
                        Text(line.newLine.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
                        Image(systemName: line.symbol.isEmpty ? "circle.fill" : line.symbol).opacity(line.symbol.isEmpty ? 0 : 1).frame(width: 14)
                        Text(verbatim: line.text).font(.body.monospaced()).fixedSize()
                    }
                    .padding(.horizontal, 4)
                    .background(background(line.kind))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(line.accessibilityLabel)
                }
            }
        }
        .frame(minHeight: 200)
        .accessibilityIdentifier("diffLines")
    }

    func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.12)
        case .removed: .red.opacity(0.12)
        case .hunk: .blue.opacity(0.08)
        default: .clear
        }
    }
}

struct FindingRow: View {
    @Environment(AppModel.self) private var model
    let finding: FindingRecord
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(finding.severity.rawValue) · \(finding.path ?? "?"):\(finding.line.map(String.init) ?? "?")", systemImage: "exclamationmark.bubble")
            Text("Gemeldet: \(finding.impact)").font(.callout)
            Text("Vorschlag: \(finding.suggestion)").font(.callout).foregroundStyle(.secondary)
            if finding.disposition == .open, finding.severity.needsDecision {
                HStack {
                    TextField("Begründung", text: $reason)
                    Button("Annehmen") { decide(true) }.disabled(reason.isEmpty || finding.severity == .blocking)
                    Button("Zurückweisen") { decide(false) }.disabled(reason.isEmpty)
                }
            } else {
                Text("Entschieden: \(finding.disposition.rawValue)").foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    func decide(_ accept: Bool) {
        let reason = reason
        let id = finding.id
        model.perform { try await $0.decideFinding(id, accept: accept, reason: reason) }
    }
}

extension AppModel {
    /// Providers the user may consent to: those with an adapter in this app.
    var consentProviders: [ProviderKind] {
        launch.isUITest ? [.fake, .codex] : [.claude, .codex].filter { Onboarding.locate($0) != nil }
    }
}
