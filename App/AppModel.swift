import AppKit
import Domain
import Foundation
import Observation
import Orchestration
import ProcessHost
import Providers
import Storage
import Workbench
import Workspace

/// The app's state on the main actor: what the windows show, refreshed by a projection pump
/// that runs off the main actor and publishes at most every 100 ms (critical changes at once).
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case starting
        case recovery(StartupIssue, [BackupInfo])
        case ready
    }

    var phase: Phase = .starting
    var state = WorkspaceState()
    var onboarding: [OnboardingItem] = []
    var pending: [PendingDecision] = []
    var selectedProject: ProjectID?
    var selectedJob: JobID?
    var selectedTask: TaskID?
    var monitorFilter = MonitorFilter()
    var errorMessage: String?
    var sheet: ActiveSheet?
    var pendingTerminalRequests: [TerminalRequest] = []
    var restartNeeded = false
    /// Counts test profile changes (ADR 0010); views showing profiles reload on a new value.
    var testProfileRevision = 0
    /// Counts passes of the candidate chain that changed something (ADR 0011); views showing a
    /// result or a review reload on a new value.
    var chainRevision = 0
    /// What the candidate chain's last pass with a change did (volatile, not projected).
    var chainReport = ChainReport()

    enum ActiveSheet: Identifiable, Equatable {
        case trustProject(String)
        case newJob(ProjectID)
        case decision(PendingDecision)
        case reject(CandidateID)
        case testProfiles(ProjectID)
        case deliver(JobID)
        case revert(CandidateID)
        /// The decision on a task's result; `discard` opens it as „Ergebnis verwerfen“.
        case result(TaskID, discard: Bool = false)
        case resolveConflicts(CandidateID)
        case startReview(CandidateID)
        case importReview(CandidateID)

        var id: String {
            switch self {
            case .trustProject(let path): "trust:\(path)"
            case .newJob(let id): "job:\(id.uuidString)"
            case .decision(let decision): "decision:\(decision.id)"
            case .reject(let id): "reject:\(id.uuidString)"
            case .testProfiles(let id): "testProfiles:\(id.uuidString)"
            case .deliver(let id): "deliver:\(id.uuidString)"
            case .revert(let id): "revert:\(id.uuidString)"
            case .result(let id, let discard): "result:\(id.uuidString)\(discard ? ":discard" : "")"
            case .resolveConflicts(let id): "conflicts:\(id.uuidString)"
            case .startReview(let id): "review:\(id.uuidString)"
            case .importReview(let id): "import:\(id.uuidString)"
            }
        }
    }

    private(set) var services: AppServices?
    var actions: WorkbenchActions? { services.map(WorkbenchActions.init) }
    private var pump: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var chainLoop: Task<Void, Never>?
    private var coalescer = Coalescer(interval: 100)
    private var batcher = AnnouncementBatcher()
    private var latest: WorkspaceState?
    let launch = LaunchMode.current

    // MARK: Start

    func start() async {
        guard phase == .starting, services == nil else { return }
        let configuration: AppConfiguration
        do { configuration = try launch.configuration() } catch {
            phase = .recovery(.storeFailed(String(describing: error)), [])
            return
        }
        switch await AppBootstrap.start(configuration) {
        case .recovery(let issue, let backups):
            phase = .recovery(issue, backups)
        case .ready(let services):
            self.services = services
            if launch.isUITest { await seedForUITests(services.store) }
            var seeded = launch.seed == "candidate" ? await seedCandidateForUITests(services) : nil
            var fixtureJob: JobID?
            #if DEBUG
            if launch.isUITest, launch.fixture == "published" { fixtureJob = await seedPublishedJob(services) }
            if launch.isUITest, seeded == nil, let seed = launch.seed { seeded = await seedChainForUITests(services, seed: seed) }
            #endif
            let projector = Projector(store: services.store)
            if let loaded = try? await projector.load() { state = loaded }
            selectedProject = state.projects.values.sorted { $0.createdAt < $1.createdAt }.first?.id
            if let seeded {
                selectedJob = seeded.job
                selectedTask = seeded.task
            } else if let fixtureJob {
                selectedJob = fixtureJob
            }
            phase = .ready
            startPump(projector)
            startTicker()
            // After the seeds: a seeded result is sealed by the seed, never by a racing pass.
            startChainLoop()
            await refreshDecisions()
            Task { await self.probe() }
        }
    }

    /// UI tests: a temporary Git repository to open, and model profiles for the two fake
    /// providers (consent still comes from the sheet).
    private func seedForUITests(_ store: Store) async {
        if let repo = launch.uiTestRepository, !FileManager.default.fileExists(atPath: repo + "/.git"), let git = GitRunner.locate() {
            try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
            let script = "\(git) init -q -b main && printf 'Hallo\\n' > README.md && mkdir -p src && printf 'let a = 1\\n' > src/a.swift && \(git) add -A && \(git) commit -qm start"
            _ = try? await services?.agents.run(LaunchSpec(
                executable: "/bin/sh", arguments: ["-c", script], workingDirectory: repo,
                environment: ["PATH": "/usr/bin:/bin", "HOME": repo, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                              "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "t@example.invalid", "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "t@example.invalid"],
                timeout: .seconds(30)
            ))
        }
        for tier in CapabilityTier.allCases {
            try? await store.registerModelProfile(ModelProfile(provider: .fake, role: .author, tier: tier, model: "fake-\(tier.rawValue)", typicalTokens: 1_000, verifiedAt: 1))
        }
        try? await store.registerModelProfile(ModelProfile(provider: .codex, role: .reviewer, tier: .fast, model: "fake-reviewer", typicalTokens: 500, verifiedAt: 1))
    }

    /// UI tests with `KAIORX_UITEST_SEED=candidate`: the fixture repository opened and a built
    /// candidate in it (no provider run), so the test reaches the candidate review directly.
    private func seedCandidateForUITests(_ services: AppServices) async -> (job: JobID, task: TaskID)? {
        guard let repo = launch.uiTestRepository else { return nil }
        let actions = WorkbenchActions(services: services)
        guard let project = try? await actions.openProject(at: repo),
              let seeded = try? await UITestSeed.builtCandidate(services: services, project: project, title: "Leerwert prüfen") else { return nil }
        return (seeded.job, seeded.task)
    }

    /// Local probes only (`--version`, sandbox check); never a login or a model call.
    func probe() async {
        guard let services else { return }
        let scratch = URL(filePath: services.configuration.workspaceRoot).appending(path: "probe")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let results = launch.isUITest
            ? ProbeResults(gitPath: GitRunner.locate())
            : await Onboarding.probe(host: services.agents, scratch: scratch, projects: state.projects.count)
        // A fresh sandbox check is the automatic gate's latest probe result too (ADR 0009).
        if let gate = services.configuration.gate as? AutomationGate, let confinement = results.confinement {
            await gate.record(confinement: confinement)
        }
        var adjusted = results
        adjusted.projects = state.projects.count
        let support = (try? AppPaths.supportFolder()) ?? ""
        onboarding = Onboarding.checklist(adjusted, configDirectories: [.claude: support + "/claude-config", .codex: support + "/codex-home"])
    }

    private func startPump(_ projector: Projector) {
        pump = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                if let delta = try? await projector.step() {
                    await self?.receive(delta)
                } else {
                    await self?.idle()
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func now() -> Int64 { services?.configuration.clock() ?? Int64(Date().timeIntervalSince1970 * 1000) }

    private func receive(_ delta: ProjectionDelta) async {
        latest = delta.state
        if coalescer.change(at: now(), critical: delta.critical, visible: true) { await publish() }
        // Spoken also while output streams, at most once per batch interval.
        if let text = batcher.flush(at: now()) { Accessibility.announce(text) }
    }

    private func idle() async {
        if coalescer.tick(at: now(), visible: true) { await publish() }
        if let text = batcher.flush(at: now()) { Accessibility.announce(text) }
    }

    private func publish() async {
        guard let latest else { return }
        batcher.add(Announcements.changes(from: state, to: latest))
        state = latest
        await refreshDecisions()
        if onboarding.contains(where: { $0.id == "project" && $0.status != .ok }) && !state.projects.isEmpty { await probe() }
    }

    /// The scheduler works on its own; the user's explicit decisions still go through actions.
    private func startTicker() {
        guard let scheduler = services?.scheduler else { return }
        ticker = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                _ = try? await scheduler.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The candidate chain's host-only steps (seal, build, rebuild, collect, clean up; ADR 0011)
    /// run in their own loop, so a long merge never delays a scheduler tick.
    private func startChainLoop() {
        guard let chain = services?.chain else { return }
        chainLoop = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let report = await chain.step()
                await self?.receive(report)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func receive(_ report: ChainReport) async {
        guard report != ChainReport() else { return }
        chainReport = report
        chainRevision += 1
        await refreshDecisions()
    }

    private var decisionGeneration = 0

    /// Rebuilds the pending decisions from the current state; a refresh that finishes after a
    /// newer one started is dropped, so an older state never overwrites a newer list.
    func refreshDecisions() async {
        guard let services else { return }
        decisionGeneration += 1
        let generation = decisionGeneration
        let integration = services.integration
        let chain = services.chain
        let collected = (try? await PendingDecisions.collect(
            state, project: nil,
            gate: { id in try await integration?.gateItems(id) ?? [.noCommit] },
            openFindings: { id in
                let findings = try await services.store.findings(candidate: id)
                return findings.contains { $0.severity.needsDecision && $0.disposition == .open }
            },
            resultCheck: { id in try await chain?.check(id) }
        )) ?? []
        if generation == decisionGeneration { pending = collected }
    }

    /// At most a few terminal requests wait; repeats are dropped, so a program cannot flood the window.
    func queueTerminalRequest(_ request: TerminalRequest) {
        guard !pendingTerminalRequests.contains(request), pendingTerminalRequests.count < 3 else { return }
        if case .copyToClipboard(let text) = request, text.utf8.count > 1 << 20 { return }
        pendingTerminalRequests.append(request)
    }

    func shutdown() async {
        pump?.cancel()
        ticker?.cancel()
        chainLoop?.cancel()
        if let services { await AppBootstrap.shutdown(services) }
    }

    // MARK: Intents

    func perform(_ work: @escaping (WorkbenchActions) async throws -> Void) {
        guard let actions else { return }
        Task {
            do { try await work(actions) } catch { self.errorMessage = Self.describe(error) }
            await self.refreshDecisions()
        }
    }

    /// Opens the sheet (or the place) where a pending decision is taken.
    func open(_ decision: PendingDecision) {
        switch decision {
        case .publish, .task, .uncertain, .findings: sheet = .decision(decision)
        case .result(let task):
            show(task: task)
            sheet = .result(task)
        case .conflicts(let candidate):
            show(task: state.candidates[candidate]?.taskID)
            sheet = .resolveConflicts(candidate)
        case .review(let candidate):
            show(task: state.candidates[candidate]?.taskID)
            sheet = .startReview(candidate)
        case .tests(let candidate):
            // No sheet: „Tests ausführen“ in the candidate view runs the confirmed profile (ADR 0010).
            show(task: state.candidates[candidate]?.taskID)
        }
    }

    /// Selects a task and its job, so the detail view shows it.
    func show(task: TaskID?) {
        guard let task, let record = state.tasks[task] else { return }
        if selectedJob != record.jobID { selectedJob = record.jobID }
        selectedTask = task
    }

    func requestOpenProject() {
        if let path = launch.uiTestRepository {
            sheet = .trustProject(path)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Öffnen"
        panel.message = "Wähle ein eigenes Git-Repository."
        if panel.runModal() == .OK, let url = panel.url { sheet = .trustProject(url.path(percentEncoded: false)) }
    }

    func openTrusted(_ path: String) {
        perform { actions in
            let id = try await actions.openProject(at: path)
            await MainActor.run { self.selectedProject = id }
        }
    }

    func stageRestore(_ backup: BackupInfo) {
        guard let path = (try? launch.configuration())?.databasePath else { return }
        do {
            try AppBootstrap.stageRestore(backup, database: path)
            restartNeeded = true
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case IntegrationError.shownStateChanged: "Der Kandidat hat sich geändert. Bitte neu entscheiden."
        case IntegrationStoreError.approvalExpired: "Die Freigabe ist abgelaufen. Bitte neu freigeben."
        case IntegrationError.reasonRequired: "Bitte gib eine Begründung an."
        case IntegrationError.targetMoved: "Das Integrationsziel hat sich bewegt; der Kandidat ist ersetzt."
        case ActionError.notARepository: "Der Ordner ist kein unterstütztes Git-Repository."
        case ActionError.notAFolder: "Der Ordner existiert nicht."
        case RestoreError.predatesForget: "Diese Sicherung ist älter als eine Löschung und wird nicht wiederhergestellt."
        case let error as TestProfileError: Labels.testProfileError(error)
        case TestProfileStoreError.digestChanged: "Das Testprofil hat sich geändert. Bitte die neue Fassung prüfen und bestätigen."
        case TestProfileStoreError.invalid(let issues): issues.map(Labels.testProfileIssue).joined(separator: " ")
        // The candidate chain's texts; they fall back to the integration texts, then to the raw error.
        default: ChainMessages.text(error)
        }
    }

    // MARK: Lookups for views

    var projects: [ProjectRecord] { state.projects.values.sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) } }

    func jobs(of project: ProjectID) -> [JobRecord] { state.jobs(of: project) }

    func goal(of job: JobRecord) -> String { "Auftrag \(job.id.uuidString.prefix(6))" }

    func candidate(for task: TaskID) -> CandidateRecord? {
        state.candidates.values.filter { $0.taskID == task }.max { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    func project(of task: TaskRecord) -> ProjectRecord? { state.jobs[task.jobID].flatMap { state.projects[$0.projectID] } }
}

/// How the app was launched: normally, or for UI tests with a temporary database, a temporary
/// Git repository and the fake adapter (never the real CLIs).
struct LaunchMode: Sendable {
    let isUITest: Bool
    let uiTestFolder: String?
    let fakeScript: String
    /// What a UI test starts with besides the fixture repository (`candidate`: a built candidate).
    var seed: String? = nil
    /// A prepared state for one UI test (`KAIORX_UITEST_FIXTURE`), for example `published`.
    var fixture: String? = nil

    static let current: LaunchMode = {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        let requested = arguments.contains("-KAIORXUITest")
        #else
        // Release builds never switch to the test configuration.
        let requested = false
        #endif
        guard requested else { return LaunchMode(isUITest: false, uiTestFolder: nil, fakeScript: "success") }
        let folder = environment["KAIORX_UITEST_FOLDER"] ?? NSTemporaryDirectory() + "kaiorx-uitest-\(UUID().uuidString)"
        return LaunchMode(
            isUITest: true, uiTestFolder: folder, fakeScript: environment["KAIORX_UITEST_SCRIPT"] ?? "success", seed: environment["KAIORX_UITEST_SEED"],
            fixture: environment["KAIORX_UITEST_FIXTURE"]
        )
    }()

    var uiTestRepository: String? { uiTestFolder.map { $0 + "/repo" } }

    func configuration() throws -> AppConfiguration {
        if let folder = uiTestFolder {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let script = fakeScript
            return AppConfiguration(
                databasePath: folder + "/kaiorx.sqlite", workspaceRoot: folder + "/workspace",
                // Author and reviewer must differ: the fake provider writes, a second fake reviews.
                adapters: { _ in [
                    FakeAdapter(provider: .fake) { spec in UITestScripts.author(script, spec: spec) },
                    FakeAdapter(provider: .codex) { spec in UITestScripts.reviewer(spec) },
                ] },
                gate: UITestGate()
            )
        }
        // The build's channel (Info.plist, per build configuration; unknown means distributed)
        // decides whether any real provider may run without the user's start (ADR 0009).
        return try AppConfiguration.standard(adapters: { host in RealAdapters.make(host: host) }, channel: .current())
    }
}

/// The fake providers' behaviour in UI tests. Nothing here starts a process.
enum UITestScripts {
    /// `hang` waits for a cancel; `writes` leaves `src/neu.swift` in the author's worktree, so the
    /// candidate chain has a change to seal and build; anything else succeeds without a change.
    static func author(_ script: String, spec: AttemptSpec) -> FakeScript {
        switch script {
        case "hang": return .waitsForCancel
        case "writes":
            if let directory = spec.workingDirectory {
                let file = URL(filePath: directory).appending(path: "src/neu.swift")
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "let neu = 2\n".write(to: file, atomically: true, encoding: .utf8)
            }
            return .success()
        default: return .success()
        }
    }

    /// The independent reviewer approves the candidate its prompt names
    /// („Review candidate <oid> …“); any other run just succeeds.
    static func reviewer(_ spec: AttemptSpec) -> FakeScript {
        let words = spec.prompt.split(separator: " ", maxSplits: 3)
        guard words.count >= 3, words[0] == "Review", words[1] == "candidate" else { return .success() }
        let oid = String(words[2])
        let verdict = #"```json\#n{"candidateOID": "\#(oid)", "verdict": "approve", "summary": "ok", "findings": []}\#n```"#
        return FakeScript(steps: [
            .emit(.started(sessionID: "uitest-review")), .emit(.messageFinal(itemID: "r", text: verdict)), .emit(.completed(.succeeded)),
        ])
    }
}

/// UI tests may run the fake provider automatically.
struct UITestGate: CapabilityGate {
    func allowsAutomatic(_ provider: ProviderKind) async -> Bool { provider == .fake || provider == .codex }
    func accessRestored(_ provider: ProviderKind, account: AccountID) async -> Bool { true }
}

/// The real adapters for CLIs that are installed, each under the product confinement
/// (`ProviderAdapters`). Automatic runs pass the `AutomationGate` first: channel, live-verified
/// installed build, effective confinement and a subscription verdict (ADR 0003, ADR 0009).
enum RealAdapters {
    static func make(host: ProcessHost) -> [any AgentAdapter] {
        guard let support = try? AppPaths.supportFolder() else { return [] }
        return ProviderAdapters.make(host: host, support: support) { Onboarding.locate($0) }
    }
}
