import Foundation

/// All results of one harness run, with the machine they were measured on.
public struct BenchReport: Sendable, Codable, Equatable {
    public var date: String
    public var machine: BenchMachine
    public var build: String
    /// `release` for figures that count; a debug build is far slower.
    public var configuration: String
    public var results: [BenchResult]

    public init(date: String, machine: BenchMachine, build: String, configuration: String = BenchReport.configuration, results: [BenchResult]) {
        self.date = date
        self.machine = machine
        self.build = build
        self.configuration = configuration
        self.results = results
    }

    public static var configuration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public func markdown() -> String {
        func number(_ value: Double) -> String { value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value) }
        var lines = [
            "# KAIORX performance (\(date))", "",
            "- Machine: \(machine.model), \(machine.cpu), \(machine.cores) cores, \(machine.memoryGB) GB, \(machine.macOS)",
            "- Build: \(build), \(configuration)" + (configuration == "release" ? "" : " (not comparable: measure a release build)"), "",
            "| Scenario | Metric | n | p50 | p95 | max | Value | Target | Result |",
            "|---|---|---|---|---|---|---|---|---|",
        ]
        for result in results {
            let stats = result.stats
            let value = result.value.map { result.unit == "ms" ? number($0) + " ms" : number($0) + " " + result.unit } ?? ""
            let verdict = switch result.verdict { case .met: "met"; case .missed: "**missed**"; case .info: "–" }
            lines.append("| \(result.scenario) | \(result.metric) | \(stats.map { "\($0.count)" } ?? "") | \(stats.map { number($0.p50) } ?? "") | \(stats.map { number($0.p95) } ?? "") | \(stats.map { number($0.max) } ?? "") | \(value) | \(result.target ?? "") | \(verdict) |")
        }
        let notes = results.flatMap { result in result.notes.map { "- \(result.scenario), \(result.metric): \($0)" } }
        if !notes.isEmpty { lines += ["", "Notes:", ""] + notes }
        lines += [
            "", "Times in milliseconds on a monotonic clock. Not covered: memory pressure, a cold OS file cache, "
                + "time to the first model token (provider-dependent), SwiftUI rendering after a state is published.",
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The scenarios and sizes of a run.
public enum BenchPlan {
    public enum Size: String, Sendable { case quick, full }

    /// `full` is the plan's beta measurement; `quick` checks the harness in seconds.
    public static func run(_ size: Size, scenarios: Set<String>, log: @Sendable (String) -> Void = { _ in }) async throws -> [BenchResult] {
        var results: [BenchResult] = []
        let full = size == .full
        if scenarios.contains("fts") {
            for chunks in full ? [10_000, 50_000] : [500] {
                log("FTS mit \(chunks) Chunks …")
                results += try await FTSBench.run(.init(chunks: chunks, coldQueries: full ? 20 : 3, target: chunks <= 10_000 ? 200 : nil))
            }
        }
        if scenarios.contains("events") {
            log("UI-Ereignisse mit zwei Läufen …")
            results += try await EventLatencyBench.run(.init(deltasPerRun: full ? 750 : 40))
        }
        if scenarios.contains("replay") {
            for deltas in full ? [10_000, 50_000] : [600] {
                log("Replay mit \(deltas) Deltas …")
                results += try await ReplayBench.run(.init(deltas: deltas, repeats: full ? 5 : 2))
            }
        }
        if scenarios.contains("control") {
            log("Stop und Freigabe unter Last …")
            results += try await ControlBench.run(.init(rounds: full ? 20 : 2))
        }
        return results
    }

    public static let scenarios: Set<String> = ["fts", "events", "replay", "control"]
}
