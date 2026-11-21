import Domain
import Foundation
import Storage
import Workbench

/// Beta target: replay of the last view without reading every text delta. A finished run with
/// many deltas is reopened: (1) the workspace view (`Projector.load`, as at app start), (2) the
/// monitor's last view of that run (as when it is selected, App/ToolViews.swift `load` through
/// `TimelinePaging.open`) and, for comparison, (3) its full history from ordinal 0. Reports time
/// and how many events each one reads.
public enum ReplayBench {
    public struct Options: Sendable {
        public var deltas: Int
        public var repeats: Int
        /// The app's opening limits; tests scale them down with the run.
        public var limits: TimelinePaging.Limits

        public init(deltas: Int, repeats: Int = 5, limits: TimelinePaging.Limits = .app) {
            self.deltas = deltas
            self.repeats = repeats
            self.limits = limits
        }
    }

    public static func run(_ options: Options) async throws -> [BenchResult] {
        let harness = try await RunHarness("replay")
        var workspace: [Duration] = []
        var lastView: [Duration] = []
        var fullHistory: [Duration] = []
        var lastViewRead = 0
        var runEvents = 0
        var differingRows = 0
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

                // The app's path on selection: only the newest pages.
                start = ContinuousClock.now
                let opened = try await TimelinePaging.open(attempt, store: store, limits: options.limits)
                lastView.append(ContinuousClock.now - start)
                lastViewRead = opened.eventsRead

                // For comparison: the whole history from ordinal 0, as before 0.4.
                start = ContinuousClock.now
                var view = Timeline()
                var read = 0
                while true {
                    let page = try await store.attemptEvents(attempt, afterOrdinal: view.lastOrdinal, limit: options.limits.pageSize)
                    read += page.count
                    view.append(page)
                    if page.count < options.limits.pageSize { break }
                }
                fullHistory.append(ContinuousClock.now - start)
                runEvents = read
                // The last view shows the end of the full history; only its first row may lack
                // the start of a message.
                let shown = opened.timeline.rows.dropFirst().map { "\($0.kind) \($0.text)" }
                differingRows = zip(shown, view.rows.suffix(shown.count).map { "\($0.kind) \($0.text)" }).filter { $0 != $1 }.count
            }
        } catch {
            await harness.close()
            throw error
        }
        await harness.close()

        let scenario = "replay-\(options.deltas)"
        // Met when the last view reads at most a fifth of the run (and never all of it).
        let met = lastViewRead < runEvents && lastViewRead * 5 <= runEvents
        let limits = options.limits
        return [
            BenchResult(scenario: scenario, metric: "seed (one transaction per event)", value: LatencyStats.milliseconds(seedDuration), notes: ["\(options.deltas) deltas"]),
            .p95(scenario, "workspace view (Projector.load)", workspace, below: nil, notes: ["reads rows only, no events"]),
            .p95(scenario, "monitor: last view on selection", lastView, below: nil, notes: [
                "TimelinePaging.open: newest pages via latestAttemptEvents until \(limits.openRows) rows or \(limits.openEvents) events, pages of \(limits.pageSize)",
            ]),
            BenchResult(
                scenario: scenario, metric: "events the last view reads", value: Double(lastViewRead), unit: "count",
                target: "≤ 20 % of the run's events", verdict: met ? .met : .missed, notes: ["the run has \(runEvents) events"]
            ),
            BenchResult(
                scenario: scenario, metric: "last-view rows unlike the full history", value: Double(differingRows), unit: "count",
                target: "0", verdict: differingRows == 0 ? .met : .missed
            ),
            .p95(scenario, "monitor: full history (comparison)", fullHistory, below: nil, notes: ["pages attemptEvents from ordinal 0 with payloads"]),
            BenchResult(scenario: scenario, metric: "events a full history load reads", value: Double(runEvents), unit: "count"),
        ]
    }
}
