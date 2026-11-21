import Domain
import Orchestration
import Storage
import SwiftUI
import Workbench

/// Action, scope, what a rejection means, and what still blocks the approval of a decision sheet.
struct DecisionSheetContent: View {
    let sheet: DecisionSheet

    var body: some View {
        Text(sheet.title).font(.headline).accessibilityAddTraits(.isHeader)
        GroupBox("Aktion") { Text(sheet.action).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("sheetAction") }
        GroupBox("Geltungsbereich") {
            VStack(alignment: .leading) { ForEach(sheet.scope, id: \.self) { Text($0).textSelection(.enabled) } }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("sheetScope")
        GroupBox("Wenn du ablehnst") { Text(sheet.ifRejected).frame(maxWidth: .infinity, alignment: .leading) }
        if !sheet.blockers.isEmpty {
            GroupBox("Noch offen") {
                VStack(alignment: .leading) { ForEach(sheet.blockers, id: \.self) { Label($0, systemImage: "xmark.circle") } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Noch offen: \(sheet.blockers.joined(separator: " "))")
            .accessibilityIdentifier("blockers")
        }
    }
}

/// The outcome or error of a sheet's action, as text plus symbol and announced to VoiceOver.
struct SheetOutcome: View {
    let text: String
    let failed: Bool

    var body: some View {
        Label(text, systemImage: failed ? "exclamationmark.triangle" : "checkmark.circle")
            .foregroundStyle(failed ? .red : .green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(failed ? "Fehler: \(text)" : text)
            .accessibilityIdentifier(failed ? "sheetError" : "sheetResult")
            .onAppear { Accessibility.announce(text) }
    }
}

/// The safe choice of a sheet (decline, close, „Fertig“): both Return and Escape trigger it, and
/// it is the only button bound to either key, so Return never approves. SwiftUI applies only one
/// `keyboardShortcut` per button, so the visible button takes Return (`defaultAction`) and an
/// invisible twin with the same action takes Escape (`cancelAction`).
struct SafeChoiceButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .keyboardShortcut(.defaultAction)
            .background {
                Button(title, action: action)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
    }
}

/// Delivers a job's integration state into a new branch of the user's repository (ADR 0004 §7):
/// create-only, the name checked as the service checks it, bound to the state the sheet showed.
/// Return is the safe choice (nothing is created).
struct DeliverBranchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let job: JobID
    @State private var name = ""
    @State private var sheet: DecisionSheet?
    @State private var problem: String?
    @State private var working = false
    @State private var created: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let created {
                Text("In neuen Branch liefern").font(.headline).accessibilityAddTraits(.isHeader)
                SheetOutcome(text: "Branch „\(created)“ angelegt. Dein Checkout und deine anderen Branches sind unverändert.", failed: false)
                HStack {
                    Spacer()
                    SafeChoiceButton("Fertig") { dismiss() }
                        .accessibilityIdentifier("deliveryDone")
                }
            } else {
                TextField("Name des neuen Branches", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .accessibilityLabel("Name des neuen Branches")
                    .accessibilityHint("Wörtlicher Branchname; ein belegter Name bekommt ein Suffix.")
                    .accessibilityIdentifier("deliveryName")
                if let sheet { DecisionSheetContent(sheet: sheet) } else if problem == nil { ProgressView() }
                if let problem { SheetOutcome(text: problem, failed: true) }
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    SafeChoiceButton(sheet?.rejectLabel ?? "Nicht liefern") { dismiss() }
                        .accessibilityIdentifier("decisionReject")
                    Button(sheet?.approveLabel ?? "Branch anlegen") { approve() }
                        .disabled(!(sheet?.canApprove ?? false) || sheet?.delivery?.name != name || working)
                        .accessibilityIdentifier("decisionApprove")
                }
            }
        }
        .padding()
        .frame(width: 560)
        .onAppear { if name.isEmpty { name = DeliveryPreview.suggestedName(for: job) } }
        .task(id: name) { await preview() }
    }

    func preview() async {
        guard let actions = model.actions, !name.isEmpty || sheet != nil else { return }
        let wanted = name
        // Typing settles before Git is asked again.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, wanted == name else { return }
        do {
            let preview = try await actions.deliveryPreview(job: job, name: wanted)
            guard !Task.isCancelled, wanted == name else { return }
            sheet = DecisionSheet.deliver(preview, jobTitle: model.state.jobs[job].map(model.goal(of:)) ?? "–")
            problem = nil
        } catch {
            guard !Task.isCancelled else { return }
            sheet = nil
            problem = IntegrationMessages.text(error)
        }
    }

    func approve() {
        guard let actions = model.actions, let sheet else { return }
        working = true
        Task {
            do {
                created = try await actions.deliver(sheet: sheet)
            } catch {
                // The shown state may be outdated (for example a moved integration state): show
                // the current one next to the error, for a new decision.
                let message = IntegrationMessages.text(error)
                await preview()
                problem = message
            }
            working = false
        }
    }
}

/// Reverts a published candidate (ADR 0004 §8): a new candidate in its own task that runs through
/// test, review and approval; the target changes only when that is published. Return is the safe
/// choice (nothing is built).
struct RevertSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let candidate: CandidateID
    @State private var sheet: DecisionSheet?
    @State private var problem: String?
    @State private var working = false
    @State private var outcome: RevertOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let outcome {
                Text("Veröffentlichung zurücknehmen").font(.headline).accessibilityAddTraits(.isHeader)
                SheetOutcome(text: outcome.text, failed: { if case .conflicted = outcome { true } else { false } }())
                HStack {
                    Spacer()
                    if let task = revertTask(outcome) {
                        Button("Revert-Aufgabe zeigen") {
                            model.selectedTask = task
                            dismiss()
                        }
                        .accessibilityIdentifier("showRevertTask")
                    }
                    SafeChoiceButton("Fertig") { dismiss() }
                        .accessibilityIdentifier("revertDone")
                }
            } else {
                if let sheet { DecisionSheetContent(sheet: sheet) } else if problem == nil { ProgressView() }
                if let problem { SheetOutcome(text: problem, failed: true) }
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    SafeChoiceButton(sheet?.rejectLabel ?? "Nicht zurücknehmen") { dismiss() }
                        .accessibilityIdentifier("decisionReject")
                    Button(sheet?.approveLabel ?? "Revert bauen") { approve() }
                        .disabled(!(sheet?.canApprove ?? false) || working)
                        .accessibilityIdentifier("decisionApprove")
                }
            }
        }
        .padding()
        .frame(width: 560)
        .task { await load() }
    }

    func revertTask(_ outcome: RevertOutcome) -> TaskID? {
        switch outcome {
        case .built(let record), .conflicted(let record, _): record.taskID
        case .nothingToRevert: nil
        }
    }

    func load() async {
        guard let actions = model.actions else { return }
        do {
            guard let record = try await model.services?.store.candidate(candidate) else { return }
            let task = record.taskID.flatMap { model.state.tasks[$0] }
            sheet = DecisionSheet.revert(record, task: task, openRevert: try await actions.openRevert(of: candidate))
            problem = nil
        } catch {
            problem = IntegrationMessages.text(error)
        }
    }

    func approve() {
        guard let actions = model.actions, let sheet else { return }
        working = true
        Task {
            do {
                outcome = try await actions.revert(candidate, sheet: sheet)
            } catch {
                await load()
                problem = IntegrationMessages.text(error)
            }
            working = false
        }
    }
}
