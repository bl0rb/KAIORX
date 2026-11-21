import Domain
import Foundation
import Orchestration
import ProcessHost
import Providers
import Storage
import Workspace

/// Beta target: with two active runs, Stop and approval stay usable. Two paced runs stream while
/// (1) an accepted candidate is approved and published (IntegrationService, as the decision sheet
/// does) and (2) one run is stopped. Each round prepares its candidate first (author result,
/// build, test, independent review) outside the timing. The plan names no number for this
/// target; the report compares with the 250 ms of the UI target (an assumption).
public enum ControlBench {
    public struct Options: Sendable {
        public var rounds: Int
        public var interval: Duration
        public var target: Double?

        public init(rounds: Int, interval: Duration = .milliseconds(40), target: Double? = 250) {
            self.rounds = rounds
            self.interval = interval
            self.target = target
        }
    }

    public static func run(_ options: Options) async throws -> [BenchResult] {
        let folder = try benchFolder("control")
        defer { removeFolder(folder) }
        let host = ProcessHost()
        let checkout = folder + "/user"
        try FileManager.default.createDirectory(atPath: checkout, withIntermediateDirectories: true)
        let layout = WorkspaceLayout(root: folder + "/data")
        let git = try GitRunner(host: host, home: layout.gitHome)
        func sh(_ script: String, in directory: String) async throws {
            try await shell(script, in: directory, git: git, home: layout.gitHome, host: host)
        }
        try await sh("git init -q -b main && echo start > a.txt && git add -A && git commit -q -m init", in: checkout)

        let store = try Store(path: folder + "/bench.sqlite")
        let project = ProjectID(), job = JobID()
        try await store.execute(Command(.openProject(id: project, name: "Bench", rootLocator: checkout)))
        try await RunHarness.activate(job, project: project, store: store)
        let workspace = WorkspaceService(store: store, git: git, layout: layout)
        _ = try await workspace.openIntegration(job, baseRevision: "main")

        let streams = PacedAdapter(provider: .codex, interval: options.interval, deltas: 100_000)
        let coordinator = RunCoordinator(store: store, adapters: [streams, reviewer()])
        let integration = IntegrationService(store: store, workspace: workspace, git: git, coordinator: coordinator)
        let pump = AppPump(store: store)
        let loop = Task { try await pump.run() }

        func task() async throws -> TaskID {
            let id = TaskID()
            try await store.execute(Command(.createTask(id: id, jobID: job, title: "Aufgabe")))
            try await store.execute(Command(.transitionTask(id: id, to: .ready, expectedVersion: 1)))
            return id
        }
        func stream() async throws -> AttemptID {
            let request = StartRequest(taskID: try await task(), projectID: project, provider: .codex, modelProfile: "standard", model: "bench", prompt: "Schreibe")
            guard case .started(let id) = try await coordinator.start(request) else { throw BenchError.unexpected("stream did not start") }
            return id
        }
        func accepted(_ round: Int) async throws -> CandidateID {
            let author = AttemptID()
            try await store.execute(Command(.reserveAttempt(AttemptReservation(
                attemptID: author, taskID: try await task(), projectID: project, role: .author, provider: .claude, mode: .automatic,
                model: "bench", specDigest: "bench"
            ))))
            guard let tip = try await store.integrationTip(job: job) else { throw BenchError.unexpected("no integration tip") }
            let tree = try await workspace.prepareWorktree(projectID: project, attemptID: author, kind: .author, base: tip)
            try "Runde \(round)\n".write(toFile: workspace.path(of: tree) + "/runde-\(round).txt", atomically: true, encoding: .utf8)
            let version = try await store.attempt(author)?.version ?? 1
            try await store.execute(Command(.transitionAttempt(id: author, to: .starting, expectedVersion: version, errorClass: nil)))
            _ = try await store.ingest(.started(sessionID: "author"), attemptID: author)
            _ = try await store.ingest(.completed(.succeeded), attemptID: author)
            _ = try await workspace.seal(tree.id, allowedPrefixes: nil, message: "Runde \(round)")
            guard case .built(let candidate) = try await integration.buildCandidate(from: tree.id) else { throw BenchError.unexpected("candidate not built") }
            _ = try await integration.runTests(candidate.id, profile: TestProfile(executable: "/bin/sh", arguments: ["-c", "exit 0"]))
            let review = try await integration.startReview(candidate.id, provider: .fake, model: "reviewer", criteria: "Datei vorhanden")
            _ = try await integration.collectReview(candidate.id, attempt: review)
            return candidate.id
        }

        var approve: [Duration] = [], publish: [Duration] = [], click: [Duration] = []
        var stopAck: [Duration] = [], stopShown: [Duration] = [], stopDone: [Duration] = []
        var neverShown = 0
        var running: [AttemptID] = []
        do {
            for round in 0..<options.rounds {
                let candidate = try await accepted(round)
                let first = try await stream()
                running = [first]
                let second = try await stream()
                running.append(second)
                pump.select(first)
                try await Task.sleep(for: .milliseconds(500))  // both runs are streaming

                // One click on the decision sheet: approve, then publish.
                let clicked = ContinuousClock.now
                let approval = try await integration.approve(candidate, actor: "bench")
                let approved = ContinuousClock.now
                try await integration.publish(candidate, approval: approval.id)
                let published = ContinuousClock.now
                approve.append(approved - clicked)
                publish.append(published - approved)
                click.append(published - clicked)

                let start = ContinuousClock.now
                try await coordinator.cancel(first, reason: "bench stop")
                stopAck.append(ContinuousClock.now - start)
                let seq = try await store.latestEventSeq()
                _ = try await coordinator.waitUntilFinished(first)
                stopDone.append(ContinuousClock.now - start)
                for _ in 0..<200 where pump.visible(seq: seq) == nil { try await Task.sleep(for: .milliseconds(5)) }
                if let shown = pump.visible(seq: seq) { stopShown.append(shown - start) } else { neverShown += 1 }

                try await coordinator.cancel(second, reason: "bench end")
                _ = try await coordinator.waitUntilFinished(second)
                running = []
            }
        } catch {
            for id in running { try? await coordinator.cancel(id, reason: "bench error") }
            pump.stop()
            _ = try? await loop.value
            await store.close()
            throw error
        }
        pump.stop()
        _ = try await loop.value
        await store.close()

        let setting = "\(options.rounds) rounds, 2 runs streaming at \(Int(1_000 / LatencyStats.milliseconds(options.interval)))/s each"
        let assumption = "no number in the plan; compared with the 250 ms UI target"
        return [
            .p95("control", "approve + publish (one click on the decision sheet)", click, below: options.target, notes: [setting, assumption]),
            .p95("control", "approve", approve, below: nil, notes: [setting]),
            .p95("control", "publish after approval", publish, below: nil, notes: [setting, "journaled compare-and-swap of the integration ref"]),
            .p95("control", "Stop → acknowledged (cancelling)", stopAck, below: options.target, notes: [setting, assumption]),
            .p95("control", "Stop → shown in the app", stopShown, below: options.target, notes: [setting, assumption]),
            BenchResult(
                scenario: "control", metric: "Stops never shown within 1 s", value: Double(neverShown), unit: "count", target: "0",
                verdict: neverShown == 0 ? .met : .missed, notes: ["left out of the percentiles above"]
            ),
            .p95("control", "Stop → run ended", stopDone, below: nil, notes: [setting, "the adapter ends before its next delta"]),
        ]
    }

    /// An independent reviewer that approves the candidate named in its prompt.
    static func reviewer() -> FakeAdapter {
        FakeAdapter(provider: .fake) { spec in
            let oid = spec.prompt.split(separator: " ").dropFirst(2).first.map(String.init) ?? ""
            let verdict = #"```json\#n{"candidateOID": "\#(oid)", "verdict": "approve", "summary": "ok", "findings": []}\#n```"#
            return FakeScript(steps: [.emit(.started(sessionID: "review")), .emit(.messageFinal(itemID: "r", text: verdict)), .emit(.completed(.succeeded))])
        }
    }
}
