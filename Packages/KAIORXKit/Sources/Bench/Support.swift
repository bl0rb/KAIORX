import Darwin
import Domain
import Foundation
import ProcessHost
import Workspace

/// Latency figures of one metric, in milliseconds.
public struct LatencyStats: Sendable, Codable, Equatable {
    public var count: Int
    public var p50: Double
    public var p95: Double
    public var max: Double

    public init(_ samples: [Duration]) {
        let values = samples.map(Self.milliseconds).sorted()
        count = values.count
        func at(_ quantile: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            // Nearest rank: the smallest value with at least `quantile` of all samples at or below it.
            let rank = Int((quantile * Double(values.count)).rounded(.up))
            return values[Swift.max(0, Swift.min(values.count - 1, rank - 1))]
        }
        p50 = at(0.5)
        p95 = at(0.95)
        max = values.last ?? 0
    }

    public static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}

/// One measured value of a scenario, compared with its beta target where the plan names one.
public struct BenchResult: Sendable, Codable, Equatable {
    public enum Verdict: String, Sendable, Codable { case met, missed, info }

    public var scenario: String
    public var metric: String
    public var stats: LatencyStats?
    /// A single value (count, duration in ms or a yes/no as 1/0) when there is no distribution.
    public var value: Double?
    public var unit: String
    public var target: String?
    public var verdict: Verdict
    public var notes: [String]

    public init(
        scenario: String, metric: String, stats: LatencyStats? = nil, value: Double? = nil, unit: String = "ms", target: String? = nil,
        verdict: Verdict = .info, notes: [String] = []
    ) {
        self.scenario = scenario
        self.metric = metric
        self.stats = stats
        self.value = value
        self.unit = unit
        self.target = target
        self.verdict = verdict
        self.notes = notes
    }

    /// A p95 compared with an upper bound in milliseconds.
    public static func p95(_ scenario: String, _ metric: String, _ samples: [Duration], below limit: Double?, notes: [String] = []) -> BenchResult {
        let stats = LatencyStats(samples)
        let verdict: Verdict = limit.map { stats.count > 0 && stats.p95 < $0 ? .met : .missed } ?? .info
        return BenchResult(scenario: scenario, metric: metric, stats: stats, target: limit.map { "p95 < \(Int($0)) ms" }, verdict: verdict, notes: notes)
    }
}

/// The machine a run was measured on (no user or host names).
public struct BenchMachine: Sendable, Codable, Equatable {
    public var model: String
    public var cpu: String
    public var cores: Int
    public var memoryGB: Int
    public var macOS: String

    public static func current() -> BenchMachine {
        func sysctl(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
            return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
        let info = ProcessInfo.processInfo
        return BenchMachine(
            model: sysctl("hw.model"), cpu: sysctl("machdep.cpu.brand_string"), cores: info.activeProcessorCount,
            memoryGB: Int(info.physicalMemory >> 30), macOS: info.operatingSystemVersionString
        )
    }
}

/// A fresh folder below the system temporary directory, symlinks resolved (`/var` → `/private/var`).
/// The harness never touches the app's real database.
public func benchFolder(_ name: String) throws -> String {
    let url = FileManager.default.temporaryDirectory.appending(path: "kaiorx-bench-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return Confinement.resolved(url.path(percentEncoded: false))
}

/// Removes a bench folder, also the sealed worktrees in it (sealing makes them read-only).
func removeFolder(_ folder: String) {
    if let paths = FileManager.default.enumerator(atPath: folder) {
        for case let path as String in paths {
            var info = stat()
            let full = folder + "/" + path
            if lstat(full, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { chmod(full, info.st_mode | S_IRWXU) }
        }
    }
    chmod(folder, S_IRWXU)
    try? FileManager.default.removeItem(atPath: folder)
}

/// Milliseconds on a monotonic clock since `origin` (for the app's coalescer, which counts in ms).
func milliseconds(since origin: ContinuousClock.Instant) -> Int64 {
    Int64(LatencyStats.milliseconds(ContinuousClock.now - origin))
}

/// Runs a shell script for repository setup through ProcessHost with a hermetic Git environment.
@discardableResult
func shell(_ script: String, in directory: String, git: GitRunner, home: String, host: ProcessHost) async throws -> String {
    let result = try await host.run(LaunchSpec(
        executable: "/bin/sh", arguments: ["-c", script], workingDirectory: directory,
        environment: [
            "PATH": "/usr/bin:/bin:" + URL(filePath: git.executable).deletingLastPathComponent().path(percentEncoded: false),
            "HOME": home, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "Bench", "GIT_AUTHOR_EMAIL": "bench@example.invalid",
            "GIT_COMMITTER_NAME": "Bench", "GIT_COMMITTER_EMAIL": "bench@example.invalid",
        ],
        timeout: .seconds(60)
    ))
    guard result.termination == .exited(0) else { throw BenchError.setup("\(script): \(result.stderr.text)") }
    return result.stdout.text.trimmingCharacters(in: .newlines)
}

public enum BenchError: Error, Equatable {
    case setup(String)
    case unexpected(String)
}
