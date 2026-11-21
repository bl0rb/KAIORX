import Domain
import Orchestration
import Storage
import SwiftUI
import Workbench
import Workspace

/// Status as text plus symbol (never color alone).
struct StatusBadge: View {
    let label: StatusLabel

    var body: some View {
        Label(label.text, systemImage: label.symbol)
            .foregroundStyle(color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label.accessibilityLabel)
    }

    var color: Color {
        switch label.tone {
        case .neutral: .secondary
        case .active: .blue
        case .waiting: .orange
        case .success: .green
        case .warning: .yellow
        case .failure: .red
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .starting:
                ProgressView("KAIORX startet …").accessibilityIdentifier("starting")
            case .recovery(let issue, let backups):
                RecoveryView(issue: issue, backups: backups)
            case .ready:
                MainView()
            }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .trustProject(let path): TrustProjectSheet(path: path)
            case .newJob(let project): NewJobSheet(project: project)
            case .decision(let decision): DecisionView(decision: decision)
            case .reject(let candidate): RejectSheet(candidate: candidate)
            case .testProfiles(let project): TestProfilesSheet(project: project)
            case .deliver(let job): DeliverBranchSheet(job: job)
            case .revert(let candidate): RevertSheet(candidate: candidate)
            case .result(let task, let discard): ResultSheet(task: task, discard: discard)
            case .resolveConflicts(let candidate): ResolveConflictsSheet(candidate: candidate)
            case .startReview(let candidate): StartReviewSheet(candidate: candidate)
            case .importReview(let candidate): ImportReviewSheet(candidate: candidate)
            }
        }
        .alert("Hinweis", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } content: {
            if let job = model.selectedJob {
                TaskListView(job: job)
            } else if model.projects.isEmpty {
                OnboardingView()
            } else {
                ContentUnavailableView("Kein Auftrag gewählt", systemImage: "list.bullet", description: Text("Wähle links einen Auftrag oder lege einen neuen an (⇧⌘N)."))
            }
        } detail: {
            if let task = model.selectedTask, let record = model.state.tasks[task] {
                TaskDetailView(task: record)
            } else {
                ContentUnavailableView("Keine Aufgabe gewählt", systemImage: "square.dashed")
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.requestOpenProject() } label: { Label("Projekt öffnen", systemImage: "folder.badge.plus") }
                    .accessibilityIdentifier("openProject")
                Button { if let project = model.selectedProject { model.sheet = .newJob(project) } } label: { Label("Neuer Auftrag", systemImage: "plus") }
                    .disabled(model.selectedProject == nil)
                    .accessibilityIdentifier("newJob")
                Button { if let project = model.selectedProject { model.sheet = .testProfiles(project) } } label: {
                    Label("Testprofile", systemImage: "checkmark.shield")
                }
                .disabled(model.selectedProject == nil)
                .accessibilityIdentifier("testProfiles")
                Menu {
                    if model.pending.isEmpty { Text("Nichts wartet auf dich") }
                    ForEach(model.pending) { decision in
                        Button(model.title(of: decision)) { model.open(decision) }
                    }
                } label: {
                    Label("Entscheidungen (\(model.pending.count))", systemImage: model.pending.isEmpty ? "hand.raised" : "hand.raised.fill")
                }
                .accessibilityIdentifier("decisions")
                Button { openWindow(id: "monitor") } label: { Label("Monitor", systemImage: "waveform.path.ecg") }
                Button { openWindow(id: "editor") } label: { Label("Editor", systemImage: "doc.text") }
                Button { openWindow(id: "terminal") } label: { Label("Terminal", systemImage: "terminal") }
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedJob) {
            ForEach(model.projects) { project in
                Section {
                    let jobs = model.jobs(of: project.id)
                    if jobs.isEmpty { Text("Noch kein Auftrag").foregroundStyle(.secondary) }
                    ForEach(jobs) { job in
                        HStack {
                            Text(model.goal(of: job))
                            Spacer()
                            StatusBadge(label: Labels.job(job.state)).labelStyle(.iconOnly)
                        }
                        .tag(job.id)
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text(project.name).accessibilityAddTraits(.isHeader)
                }
            }
        }
        .onChange(of: model.selectedJob) { _, job in
            if let job, let project = model.state.jobs[job]?.projectID { model.selectedProject = project }
            // A task chosen together with its job (`AppModel.show(task:)`) stays selected.
            if let task = model.selectedTask, let job, model.state.tasks[task]?.jobID == job { return }
            model.selectedTask = nil
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .accessibilityIdentifier("sidebar")
    }
}

struct TaskListView: View {
    @Environment(AppModel.self) private var model
    let job: JobID

    var body: some View {
        @Bindable var model = model
        let tasks = model.state.tasks(of: job)
        let published = model.state.candidates.values.filter { $0.jobID == job && $0.state == .published }.count
        VStack(spacing: 0) {
            HStack {
                Text(published == 0 ? "Noch nichts veröffentlicht" : "Veröffentlichte Kandidaten: \(published)")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("publishedCount")
                Spacer()
                Button { model.sheet = .deliver(job) } label: { Label("In Branch liefern …", systemImage: "arrow.triangle.branch") }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(model.state.jobs[job]?.integrationRef == nil)
                    .help("Legt einen neuen Branch auf dem Integrationsstand dieses Auftrags an (⇧⌘B).")
                    .accessibilityLabel("In Branch liefern")
                    .accessibilityHint("Legt einen neuen Branch auf dem Integrationsstand dieses Auftrags an. Vorhandene Branches und dein Checkout bleiben unverändert.")
                    .accessibilityIdentifier("deliverJob")
            }
            .padding(.horizontal)
            .padding(.top, 8)
            Table(tasks, selection: $model.selectedTask) {
                TableColumn("Aufgabe") { task in Text(task.title) }
                TableColumn("Status") { task in StatusBadge(label: Labels.task(task.state)) }
                TableColumn("Wartet auf") { task in
                    if let wait = Labels.wait(stored: task.waitReason) { Label(wait.text, systemImage: wait.symbol).foregroundStyle(.secondary) } else { Text("–") }
                }
            }
            .accessibilityIdentifier("tasks")
        }
        .navigationTitle("Aufgaben")
    }
}

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    let task: TaskRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(task.title).font(.title2).accessibilityAddTraits(.isHeader)
                    Spacer()
                    StatusBadge(label: Labels.task(task.state)).accessibilityIdentifier("taskStatus")
                }
                if let wait = Labels.wait(stored: task.waitReason) {
                    Label(wait.text, systemImage: wait.symbol).foregroundStyle(.orange).accessibilityIdentifier("waitReason")
                }
                if let reason = task.waitReason.flatMap(WaitReason.init(stored:)), [.awaitingUserStart, .consent, .userDecision].contains(reason.kind) {
                    Button(reason.kind == .consent ? "Zustimmung erteilen …" : "Entscheiden …") { model.sheet = .decision(.task(task.id, reason)) }
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                        .accessibilityIdentifier("decideTask")
                }
                ForEach(model.state.attempts(of: task.id).filter { $0.state == .uncertain }) { attempt in
                    Button("Ungeklärten Lauf entscheiden …") { model.sheet = .decision(.uncertain(attempt.id)) }
                }
                GroupBox("Läufe") {
                    let attempts = model.state.attempts(of: task.id)
                    if attempts.isEmpty { Text("Noch kein Lauf").foregroundStyle(.secondary) }
                    ForEach(attempts) { attempt in
                        HStack {
                            Text("\(Labels.role(attempt.role)) · \(Labels.provider(attempt.provider)) · \(attempt.model)")
                            Spacer()
                            StatusBadge(label: Labels.attempt(attempt.state)).accessibilityIdentifier("attemptStatus")
                            if [.reserved, .starting, .running, .awaitingApproval].contains(attempt.state) {
                                Button("Abbrechen") { model.perform { try await $0.cancel(attempt.id) } }
                                    .accessibilityIdentifier("cancelAttempt")
                            }
                        }
                    }
                }
                if ResultBox.applies(to: task), model.state.openCandidate(of: task.id) == nil {
                    ResultBox(task: task)
                }
                if let candidate = model.candidate(for: task.id) {
                    CandidateReviewView(candidate: candidate)
                }
            }
            .padding()
        }
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Willkommen bei KAIORX").font(.title).accessibilityAddTraits(.isHeader)
            Text("KAIORX arbeitet nur in eigenen, vertrauenswürdigen Git-Repositories. Dein Checkout bleibt unverändert.")
            ForEach(model.onboarding) { item in
                HStack(alignment: .top) {
                    StatusBadge(label: item.label).labelStyle(.iconOnly).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).bold()
                        Text(item.detail).foregroundStyle(.secondary)
                        if let remedy = item.remedy { Text(remedy) }
                        if let command = item.command {
                            Button("Befehl kopieren: \(command)") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("onboarding-\(item.id)")
            }
            Button("Projekt öffnen …") { model.requestOpenProject() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboardingOpenProject")
        }
        .padding()
        .frame(maxWidth: 560, alignment: .leading)
    }
}

struct TrustProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projekt als vertrauenswürdig öffnen?").font(.headline)
            Text(path).font(.body.monospaced()).textSelection(.enabled)
            Text("Tests und Werkzeuge dieses Repositories laufen mit deinen Rechten. Öffne nur eigene Projekte, deren Testskripten du vertraust.")
            Text("Wenn du ablehnst, wird nichts geöffnet.").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Nicht öffnen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .keyboardShortcut(.defaultAction)
                Button("Vertrauen und öffnen") {
                    model.openTrusted(path)
                    dismiss()
                }
                .accessibilityIdentifier("trustOpen")
            }
        }
        .padding()
        .frame(width: 480)
    }
}

struct NewJobSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: ProjectID
    @State private var goal = ""
    @State private var tasks: [EditableTask] = [EditableTask()]
    @State private var budget = 200_000

    struct EditableTask: Identifiable {
        let id = UUID()
        var title = ""
        var criteria = ""
        var writes = ""
    }

    var body: some View {
        Form {
            TextField("Ziel des Auftrags", text: $goal).accessibilityIdentifier("jobGoal")
            ForEach($tasks) { $task in
                Section("Aufgabe") {
                    TextField("Titel", text: $task.title).accessibilityIdentifier("taskTitle")
                    TextField("Akzeptanzkriterium", text: $task.criteria)
                    TextField("Schreibbereich (Pfade, durch Komma getrennt)", text: $task.writes)
                }
            }
            Button("Aufgabe hinzufügen") { tasks.append(EditableTask()) }
            TextField("Tokenbudget je Anbieter", value: $budget, format: .number)
                .accessibilityIdentifier("jobBudget")
            Text("Gilt für \(model.consentProviders.map(Labels.provider).joined(separator: " und ")) in diesem Auftrag.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Anlegen") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(goal.trimmingCharacters(in: .whitespaces).isEmpty || tasks.allSatisfy { $0.title.isEmpty })
                    .accessibilityIdentifier("createJob")
            }
        }
        .padding()
        .frame(width: 520)
    }

    func create() {
        let drafts = tasks.filter { !$0.title.isEmpty }.enumerated().map { index, task in
            PlanTaskDraft(
                key: "t\(index + 1)", title: task.title, goal: goal, criteria: task.criteria.isEmpty ? [task.title] : [task.criteria],
                writePaths: task.writes.isEmpty ? nil : task.writes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            )
        }
        let goal = goal
        let budget = (model.consentProviders, max(1, budget))
        model.perform { actions in
            let job = try await actions.createJob(project: project, goal: goal, tasks: drafts, budget: budget)
            await MainActor.run { model.selectedJob = job }
        }
        dismiss()
    }
}

struct RecoveryView: View {
    @Environment(AppModel.self) private var model
    let issue: StartupIssue
    let backups: [BackupInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("KAIORX kann die Daten nicht öffnen", systemImage: "exclamationmark.triangle").font(.title2)
            Text(text)
            if model.restartNeeded {
                Text("Die Wiederherstellung ist vorgemerkt. Starte KAIORX neu.").bold()
            }
            if !backups.isEmpty {
                Text("Sicherungen").font(.headline)
                ForEach(backups) { backup in
                    HStack {
                        Text("Schema \(backup.version) · \(Date(timeIntervalSince1970: Double(backup.time) / 1000).formatted())")
                        Spacer()
                        Button("Wiederherstellen …") { model.stageRestore(backup) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Beenden") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(maxWidth: 560)
        .accessibilityIdentifier("recovery")
    }

    var text: String {
        switch issue {
        case .databaseNewerThanApp(let db, let app): "Die Datenbank stammt von einer neueren KAIORX-Version (Schema \(db), diese App kennt \(app)). Installiere die neuere Version oder stelle eine Sicherung wieder her."
        case .checksumMismatch(let version): "Die Datenbank passt nicht zu dieser App (Migration \(version) unterscheidet sich)."
        case .databaseInUse: "Die Datenbank wird gerade von einem anderen KAIORX-Prozess benutzt."
        case .restoreFailed(let reason): "Die Wiederherstellung ist fehlgeschlagen: \(reason)"
        case .storeFailed(let reason): "Die Datenbank konnte nicht geöffnet werden: \(reason)"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Sicherungen") {
                let backups = (try? model.launch.configuration()).map { BackupRestore.backups(of: $0.databasePath) } ?? []
                if backups.isEmpty { Text("Keine Sicherungen vorhanden.").foregroundStyle(.secondary) }
                ForEach(backups) { backup in
                    HStack {
                        Text("Schema \(backup.version) · \(Date(timeIntervalSince1970: Double(backup.time) / 1000).formatted())")
                        Spacer()
                        Button("Beim nächsten Start wiederherstellen") { model.stageRestore(backup) }
                    }
                }
                if model.restartNeeded { Text("Vorgemerkt: Beende KAIORX und starte neu.").bold() }
            }
        }
        .padding()
        .frame(width: 520)
    }
}

extension AppModel {
    func title(of decision: PendingDecision) -> String {
        switch decision {
        case .publish(let id): "Veröffentlichen: \(state.candidates[id].flatMap { $0.taskID }.flatMap { state.tasks[$0]?.title } ?? "Kandidat")"
        case .task(let id, let reason): "\(state.tasks[id]?.title ?? "Aufgabe"): \(Labels.wait(reason).text)"
        case .uncertain(let id): "Ungeklärter Lauf: \(state.attempts[id].flatMap { state.tasks[$0.taskID]?.title } ?? "")"
        case .findings(let id): "Befunde entscheiden: \(taskTitle(of: id))"
        case .result(let id): "Ergebnis entscheiden: \(state.tasks[id]?.title ?? "")"
        case .conflicts(let id): "Konflikt lösen: \(taskTitle(of: id))"
        case .tests(let id): "Tests ausführen: \(taskTitle(of: id))"
        case .review(let id): "Review starten: \(taskTitle(of: id))"
        }
    }

    /// The title of a candidate's task, or empty.
    func taskTitle(of candidate: CandidateID) -> String {
        state.candidates[candidate].flatMap { $0.taskID }.flatMap { state.tasks[$0]?.title } ?? ""
    }

    var selectedCancellable: AttemptID? {
        guard let task = selectedTask else { return nil }
        return state.attempts(of: task).first { [.reserved, .starting, .running, .awaitingApproval].contains($0.state) }?.id
    }

    func cancelSelected() {
        guard let attempt = selectedCancellable else { return }
        perform { try await $0.cancel(attempt) }
    }
}
