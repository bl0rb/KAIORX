import Domain
import Orchestration
import Storage
import SwiftUI
import Workbench

/// The project's test profiles (ADR 0010): add or change one, confirm exactly the shown command,
/// remove. Confirming happens on a decision page inside the sheet; Return never confirms.
struct TestProfilesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: ProjectID
    @State private var profiles: [TestProfileRecord] = []
    @State private var form = TestProfileForm()
    @State private var formErrors: [String] = []
    @State private var confirming: TestProfileRecord?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let confirming {
                TestProfileConfirmation(profile: confirming) { approved in
                    if approved { confirm(confirming) }
                    self.confirming = nil
                }
            } else {
                list
                Divider()
                editor
                HStack {
                    Spacer()
                    Button("Schließen") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("closeTestProfiles")
                }
            }
        }
        .padding()
        .frame(width: 620)
        .task(id: model.testProfileRevision) { await reload() }
    }

    private var projectName: String { model.state.projects[project]?.name ?? "Projekt" }

    @ViewBuilder private var list: some View {
        Text("Testprofile für \(projectName)").font(.headline).accessibilityAddTraits(.isHeader)
        Text("Nur bestätigte Profile laufen. Jede Änderung braucht eine neue Bestätigung.").foregroundStyle(.secondary)
        if profiles.isEmpty {
            Text("Noch kein Testprofil").foregroundStyle(.secondary).accessibilityIdentifier("noTestProfiles")
        }
        ForEach(profiles) { profile in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.spec.name).bold()
                    Text(Labels.commandLine(profile.spec)).font(.body.monospaced()).textSelection(.enabled)
                    Text("Arbeitsordner \(profile.spec.workingDirectory) · Zeitlimit \(profile.spec.timeoutSeconds) s"
                        + (profile.spec.writesWorktree ? " · schreibt in den Worktree" : ""))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                StatusBadge(label: Labels.testProfile(profile)).accessibilityIdentifier("testProfileStatus-\(profile.spec.name)")
                if !profile.isConfirmed {
                    Button("Bestätigen …") { confirming = profile }
                        .accessibilityLabel("\(profile.spec.name) bestätigen …")
                        .accessibilityIdentifier("confirmTestProfile-\(profile.spec.name)")
                        .accessibilityHint("Zeigt den vollständigen Befehl vor der Bestätigung")
                }
                Button("Bearbeiten") {
                    form = TestProfileForm(profile.spec)
                    nameFocused = true
                }
                .accessibilityLabel("\(profile.spec.name) bearbeiten")
                Button("Entfernen", role: .destructive) { remove(profile) }
                    .accessibilityLabel("\(profile.spec.name) entfernen")
                    .accessibilityIdentifier("removeTestProfile-\(profile.spec.name)")
            }
            .padding(6)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder private var editor: some View {
        Text("Profil hinzufügen oder ändern").font(.subheadline.bold()).accessibilityAddTraits(.isHeader)
        Grid(alignment: .leading, verticalSpacing: 6) {
            GridRow {
                Text("Name")
                TextField("Name", text: $form.name, prompt: Text("zum Beispiel Unit-Tests"))
                    .focused($nameFocused)
                    .accessibilityIdentifier("profileName")
            }
            GridRow {
                Text("Programm")
                TextField("Programm", text: $form.executable, prompt: Text("absoluter Pfad, zum Beispiel /usr/bin/make"))
                    .font(.body.monospaced())
                    .accessibilityIdentifier("profileExecutable")
            }
            GridRow(alignment: .top) {
                Text("Argumente")
                VStack(alignment: .leading, spacing: 2) {
                    TextEditor(text: $form.arguments)
                        .font(.body.monospaced())
                        .frame(height: 54)
                        .border(.quaternary)
                        .accessibilityLabel("Argumente, eins pro Zeile")
                        .accessibilityIdentifier("profileArguments")
                    Text("Eins pro Zeile; nichts wird von einer Shell zerlegt.").font(.caption).foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("Arbeitsordner")
                TextField("Arbeitsordner", text: $form.workingDirectory, prompt: Text("relativ zum Worktree"))
                    .accessibilityIdentifier("profileWorkingDirectory")
            }
            GridRow {
                Text("Zeitlimit (s)")
                TextField("Zeitlimit in Sekunden", text: $form.timeoutSeconds).frame(width: 100)
                    .accessibilityIdentifier("profileTimeout")
            }
            GridRow(alignment: .top) {
                Text("Testeingaben")
                TextEditor(text: $form.testInputPrefixes)
                    .font(.body.monospaced())
                    .frame(height: 36)
                    .border(.quaternary)
                    .accessibilityLabel("Pfade der Testeingaben, einer pro Zeile")
                    .accessibilityIdentifier("profilePrefixes")
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Toggle("Darf in den Worktree schreiben (Build-Ausgaben)", isOn: $form.writesWorktree)
                    .accessibilityIdentifier("profileWritesWorktree")
            }
        }
        if !formErrors.isEmpty {
            VStack(alignment: .leading) { ForEach(formErrors, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") } }
                .foregroundStyle(.red)
                .accessibilityIdentifier("profileErrors")
        }
        HStack {
            Spacer()
            Button("Vorschlagen") { propose() }
                .accessibilityIdentifier("proposeTestProfile")
                .accessibilityHint("Speichert das Profil unbestätigt")
        }
    }

    private func reload() async {
        profiles = (try? await model.actions?.testProfiles(project: project)) ?? []
        // A sheet open on a profile that changed meanwhile shows the stored state again.
        if let shown = confirming, profiles.first(where: { $0.id == shown.id })?.digest != shown.digest {
            confirming = nil
            model.errorMessage = "Das Testprofil hat sich geändert. Bitte die neue Fassung prüfen."
        }
    }

    private func propose() {
        switch form.spec() {
        case .failure(let error):
            formErrors = error.messages
        case .success(let spec):
            formErrors = []
            let project = project
            model.performProfileChange { try await $0.proposeTestProfile(project: project, spec) }
            form = TestProfileForm()
        }
    }

    private func confirm(_ profile: TestProfileRecord) {
        let id = profile.id, digest = profile.digest
        model.performProfileChange(announcing: "Testprofil \(profile.spec.name) bestätigt") { try await $0.confirmTestProfile(id, digest: digest) }
    }

    private func remove(_ profile: TestProfileRecord) {
        let id = profile.id
        model.performProfileChange { try await $0.removeTestProfile(id) }
    }
}

/// The decision page for one profile, built from `DecisionSheet.confirmTestProfile`.
struct TestProfileConfirmation: View {
    let profile: TestProfileRecord
    let decide: (Bool) -> Void

    var body: some View {
        let sheet = DecisionSheet.confirmTestProfile(profile)
        VStack(alignment: .leading, spacing: 12) {
            Text(sheet.title).font(.headline).accessibilityAddTraits(.isHeader)
            GroupBox("Aktion") { Text(sheet.action).frame(maxWidth: .infinity, alignment: .leading) }
            GroupBox("Geltungsbereich") {
                VStack(alignment: .leading) {
                    ForEach(sheet.scope, id: \.self) { Text($0).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("testProfileScope")
            GroupBox("Wenn du ablehnst") { Text(sheet.ifRejected).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Spacer()
                SafeChoiceButton(sheet.rejectLabel) { decide(false) }
                    .accessibilityIdentifier("decisionReject")
                Button(sheet.approveLabel) { decide(true) }
                    .accessibilityIdentifier("decisionApprove")
            }
        }
    }
}

/// Tests of a candidate: the latest results for its commit, and „Tests ausführen“ with the
/// profile the gate counts (the plan task's named one, else the confirmed one) while the
/// candidate is built, or again once its test was withdrawn by a profile change.
struct CandidateTestsView: View {
    @Environment(AppModel.self) private var model
    let candidate: CandidateRecord
    @State private var results: [TestResultRecord] = []
    @State private var profiles: [TestProfileRecord] = []
    @State private var plannedName: String?
    @State private var testWithdrawn = false
    @State private var chosen: TestProfileID?
    @State private var running = false

    var body: some View {
        GroupBox("Tests") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(results.suffix(3).reversed()) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        StatusBadge(label: Labels.testStatus(result.status))
                        Text("Profil: \(profileName(result.profileDigest))").foregroundStyle(.secondary)
                        if result.status != .passed { Text(result.summary).font(.callout.monospaced()).textSelection(.enabled).lineLimit(4) }
                        if !result.changedTestInputs.isEmpty {
                            Text("Geänderte Testeingaben: \(result.changedTestInputs.joined(separator: ", "))").foregroundStyle(.orange)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("testResult")
                }
                if results.isEmpty { Text("Noch kein Testlauf für diesen Commit").foregroundStyle(.secondary) }
                if candidate.state == .testing || running {
                    ProgressView("Tests laufen …").controlSize(.small).accessibilityIdentifier("testsRunning")
                } else if candidate.state == .built || (testWithdrawn && [.reviewing, .accepted].contains(candidate.state)) {
                    runControls
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(candidate.id.uuidString)|\(candidate.version)|\(model.testProfileRevision)") { await load() }
    }

    /// The same resolution as the gate: a named profile is the only one offered.
    private var choice: TestRunChoice { TestRunChoice.resolve(plannedName: plannedName, profiles: profiles) }

    @ViewBuilder private var runControls: some View {
        let choice = choice
        HStack {
            switch choice {
            case .choose(let confirmed):
                Picker("Profil", selection: $chosen) {
                    Text("Bitte wählen").tag(TestProfileID?.none)
                    ForEach(confirmed) { Text($0.spec.name).tag(TestProfileID?.some($0.id)) }
                }
                .frame(maxWidth: 260)
                .accessibilityIdentifier("testProfilePicker")
            case .run(let profile, let planned):
                Text(planned ? "Profil der Aufgabe: \(profile.spec.name)" : "Profil: \(profile.spec.name)").foregroundStyle(.secondary)
                Text(Labels.commandLine(profile.spec)).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
            case .plannedMissing, .plannedNotConfirmed, .noneConfirmed:
                Label(choice.reason ?? "", systemImage: "exclamationmark.shield").foregroundStyle(.orange)
                    .accessibilityIdentifier("testProfileBlocked")
                Button("Testprofile …") { model.sheet = .testProfiles(candidate.projectID) }
                    .accessibilityIdentifier("openTestProfiles")
            }
            Spacer()
            Button("Tests ausführen") { run(choice) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(Self.profileToRun(choice, chosen: chosen) == nil)
                .accessibilityIdentifier("runTests")
                .accessibilityHint("Führt das bestätigte Testprofil auf genau diesem Kandidatencommit aus")
        }
    }

    private static func profileToRun(_ choice: TestRunChoice, chosen: TestProfileID?) -> TestProfileID? {
        if case .choose(let confirmed) = choice { return confirmed.first { $0.id == chosen }?.id }
        return choice.profile?.id
    }

    private func profileName(_ digest: String) -> String {
        if let profile = profiles.first(where: { $0.digest == digest }) {
            return profile.isConfirmed ? profile.spec.name : "\(profile.spec.name) (nicht bestätigt)"
        }
        return "nicht mehr im Register – zählt nicht"
    }

    private func load() async {
        guard let services = model.services else { return }
        let commit = candidate.candidateOID
        results = ((try? await services.store.testResults(candidate: candidate.id)) ?? []).filter { $0.candidateOID == commit }
        profiles = (try? await services.store.testProfiles(project: candidate.projectID)) ?? []
        plannedName = if let task = candidate.taskID { (try? await services.store.plannedTask(task))??.testProfile } else { nil }
        let gate = (try? await services.integration?.gateItems(candidate.id)) ?? []
        testWithdrawn = commit.map { gate.contains(.noPassingTest($0)) } ?? false
        if let chosen, Self.profileToRun(choice, chosen: chosen) == nil { self.chosen = nil }
    }

    private func run(_ choice: TestRunChoice) {
        guard let actions = model.actions, let profile = Self.profileToRun(choice, chosen: chosen) else { return }
        let id = candidate.id
        running = true
        Task {
            do {
                let result = try await actions.runTests(id, profile: profile)
                Accessibility.announce(Labels.testStatus(result.status).text)
            } catch {
                model.errorMessage = AppModel.describe(error)
            }
            running = false
            await load()
            await model.refreshDecisions()
        }
    }
}

extension AppModel {
    /// A registry change; views that show profiles reload afterwards, also after a refusal.
    func performProfileChange(announcing announcement: String? = nil, _ work: @escaping (WorkbenchActions) async throws -> Void) {
        guard let actions else { return }
        Task {
            do {
                try await work(actions)
                if let announcement { Accessibility.announce(announcement) }
            } catch {
                errorMessage = Self.describe(error)
            }
            testProfileRevision += 1
            await refreshDecisions()
        }
    }
}
