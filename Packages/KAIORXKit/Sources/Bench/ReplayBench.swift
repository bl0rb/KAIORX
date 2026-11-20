import Domain
import Foundation
import Storage
import Workbench

/// Beta target: replay of the last view without reading every text delta. A finished run with
/// many deltas is reopened twice: (1) the workspace view (`Projector.load`, as at app start) and
/// (2) the monitor timeline of that run (as when it is selected, App/ToolViews.swift `load`).
/// Reports time and how many events each one reads.
public enum ReplayBench {
    public struct Options: Sendable {
        public var deltas: Int
        public var repeats: Int

        public init(deltas: Int, repeats: Int = 5) {
            self.deltas = deltas
            self.repeats = repeats
        }
    }

    public static func run(_ options: Options) async throws -> [BenchResult] {
        let harness = try await RunHarness("replay")
        var workspace: [Duration] = []
        var timeline: [Duration] = []
        var timelineRead = 0
        var seedDuration = Duration.zero
        do {
            let store = harness.store
            let task = try await harness.newTask()
            let attempt = AttemptID()
            try await store.execute(Command(.reserveAttempt(AttemptReservation(
                attemptID: attempt, taskID: task, projectID: harness.project, role: .author, provider: .fake, mode: .automatic,
                model: "bench", specDigest: "bench"
            ))))
            let version = try await store.attempt(attempt)?.version ?? 1
            try await store.execute(Command(.transitionAttempt(id: attempt, to: .starting, expectedVersion: version, errorClass: nil)))
            let seedStart = ContinuousClock.now
            _ = try await store.ingest(.started(sessionID: "bench"), attemptID: attempt)
            for index in 0..<options.deltas {
                _ = try await store.ingest(.messageDelta(itemID: "m\(index / 200)", text: PacedAdapter.text(index)), attemptID: attempt)
            }
            _ = try await store.ingest(.completed(.succeeded), attemptID: attempt)
            seedDuration = ContinuousClock.now - seedStart

            for _ in 0..<options.repeats {
                var start = ContinuousClock.now
                _ = try await Projector(store: store).load()
                workspace.append(ContinuousClock.now - start)

                start = ContinuousClock.now
                var view = Timeline()
                var read = 0
                while true {
                    let page = try await store.attemptEvents(attempt, afterOrdinal: view.lastOrdinal, limit: 500)
                    read += page.count
                    view.append(page)
                    if page.count < 500 { break }
                }
                timeline.append(ContinuousClock.now - start)
                timelineRead = read
            }
        } catch {
            await harness.close()
            throw error
        }
        await harness.close()

        let scenario = "replay-\(options.deltas)"
        let readsAll = timelineRead >= options.deltas
        return [
            BenchResult(scenario: scenario, metric: "seed (one transaction per event)", value: LatencyStats.milliseconds(seedDuration), notes: ["\(options.deltas) deltas"]),
            .p95(scenario, "workspace view (Projector.load)", workspace, below: nil, notes: ["reads rows only, no events"]),
            .p95(scenario, "monitor timeline of the run", timeline, below: nil, notes: ["pages attemptEvents from ordinal 0 with payloads"]),
            BenchResult(
                scenario: scenario, metric: "events the timeline reads", value: Double(timelineRead), unit: "count",
                target: "not every text delta", verdict: readsAll ? .missed : .met,
                notes: readsAll ? ["the timeline has no snapshot or last-N read: it reads every delta of the run"] : []
            ),
        ]
    }
}
