import Domain
import Foundation
import Orchestration
import Providers
import Storage

/// A temporary store with a project and an active job; tasks are plain (not plan-managed), so the
/// run coordinator can start them directly, as an explicit user start does.
struct RunHarness {
    let folder: String
    let store: Store
    let project = ProjectID()
    let job = JobID()

    init(_ name: String) async throws {
        folder = try benchFolder(name)
        store = try Store(path: folder + "/bench.sqlite")
        try await store.execute(Command(.openProject(id: project, name: "Bench", rootLocator: folder)))
        try await Self.activate(job, project: project, store: store)
    }

    static func activate(_ job: JobID, project: ProjectID, store: Store) async throws {
        try await store.execute(Command(.createJob(id: job, projectID: project, goal: "Messung")))
        try await store.execute(Command(.transitionJob(id: job, to: .planned, expectedVersion: 1, reason: nil)))
        try await store.execute(Command(.transitionJob(id: job, to: .active, expectedVersion: 2, reason: nil)))
    }

    func newTask() async throws -> TaskID {
        let task = TaskID()
        try await store.execute(Command(.createTask(id: task, jobID: job, title: "Lauf")))
        try await store.execute(Command(.transitionTask(id: task, to: .ready, expectedVersion: 1)))
        return task
    }

    func start(_ coordinator: RunCoordinator, provider: ProviderKind) async throws -> AttemptID {
        let request = StartRequest(
            taskID: try await newTask(), projectID: project, provider: provider, modelProfile: "standard", model: "bench", prompt: "Schreibe"
        )
        guard case .started(let id) = try await coordinator.start(request) else { throw BenchError.unexpected("run did not start") }
        return id
    }

    func close() async {
        await store.close()
        removeFolder(folder)
    }
}

/// Beta target: UI events within 250 ms of local receipt (p95), with two active runs. Two paced
/// runs stream deltas through the run coordinator into the store; the app's update loop
/// (`AppPump`) shows them. Measured from the instant a delta left the provider to the instant
/// (1) the workspace state the app published covers it and (2) the monitor timeline of the
/// selected run holds it.
public enum EventLatencyBench {
    public struct Options: Sendable {
        public var deltasPerRun: Int
        public var interval: Duration
        public var target: Double?

        public init(deltasPerRun: Int, interval: Duration = .milliseconds(40), target: Double? = 250) {
            self.deltasPerRun = deltasPerRun
            self.interval = interval
            self.target = target
        }
    }

    public static func run(_ options: Options) async throws -> [BenchResult] {
        let harness = try await RunHarness("events")
        let adapter = PacedAdapter(provider: .codex, interval: options.interval, deltas: options.deltasPerRun)
        let coordinator = RunCoordinator(store: harness.store, adapters: [adapter])
        let pump = AppPump(store: harness.store)
        let loop = Task { try await pump.run() }
        var started: [AttemptID] = []
        do {
            let first = try await harness.start(coordinator, provider: .codex)
            started.append(first)
            started.append(try await harness.start(coordinator, provider: .codex))
            pump.select(first)
            for id in started { _ = try await coordinator.waitUntilFinished(id) }
            // Let the loop publish the tail: until a published cursor covers the last event.
            let last = try await harness.store.latestEventSeq()
            for _ in 0..<100 where pump.visible(seq: last) == nil { try await Task.sleep(for: .milliseconds(20)) }
            pump.stop()
            _ = try await loop.value

            var projection: [Duration] = []
            var timeline: [Duration] = []
            var missing = 0, missingTimeline = 0, matched = 0
            for attempt in started {
                var after = 0
                while true {
                    let page = try await harness.store.attemptEvents(attempt, afterOrdinal: after, limit: 500)
                    for event in page {
                        guard let payload = event.payload, let decoded = try? JSONDecoder().decode(AgentEvent.self, from: payload),
                              let index = PacedAdapter.index(of: decoded), let sent = adapter.receipt(attempt, index) else { continue }
                        matched += 1
                        guard let shown = pump.visible(seq: event.seq) else { missing += 1; continue }
                        projection.append(shown - sent)
                        guard attempt == first else { continue }
                        if let ordinal = event.ordinal, let listed = pump.inTimeline(attempt, ordinal: ordinal) {
                            timeline.append(listed - sent)
                        } else {
                            missingTimeline += 1
                        }
                    }
                    after = page.last?.ordinal ?? after
                    if page.count < 500 { break }
                }
            }
            await harness.close()
            let expected = 2 * options.deltasPerRun
            return results(options, projection: projection, timeline: timeline, missing: missing + (expected - matched), missingTimeline: missingTimeline)
        } catch {
            pump.stop()
            _ = try? await loop.value
            for id in started { try? await coordinator.cancel(id, reason: "bench error") }
            await harness.close()
            throw error
        }
    }

    static func results(_ options: Options, projection: [Duration], timeline: [Duration], missing: Int, missingTimeline: Int) -> [BenchResult] {
        let rate = Int(1_000 / LatencyStats.milliseconds(options.interval))
        let setting = "2 runs × \(options.deltasPerRun) deltas at \(rate)/s each; app loop: step, coalescer 100 ms, 50 ms pause"
        return [
            .p95("events", "delta → app state published", projection, below: options.target, notes: [setting]),
            .p95("events", "delta → monitor timeline (selected run)", timeline, below: options.target, notes: [setting, "includes the timeline's attemptEvents read"]),
            BenchResult(scenario: "events", metric: "deltas never shown", value: Double(missing), unit: "count", target: "0", verdict: missing == 0 ? .met : .missed),
            BenchResult(
                scenario: "events", metric: "deltas never in the timeline", value: Double(missingTimeline), unit: "count", target: "0",
                verdict: missingTimeline == 0 ? .met : .missed, notes: ["deltas of the selected run the monitor never listed"]
            ),
        ]
    }
}
