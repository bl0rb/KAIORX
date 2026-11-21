import Bench
import Foundation

// Measures the beta targets of Plan/ARCHITEKTURPLAN.md on synthetic data in a temporary folder.
// Never opens the app's database and never starts a real provider CLI.

let usage = """
    kaiorx-bench [--quick | --full] [--only fts,events,replay,control] [--out <folder>] [--build <label>]

      --full    the plan's beta sizes (10,000 and 50,000 chunks, 20 control rounds); several minutes
      --quick   small sizes to check the harness (default)
      --out     write report.md and report.json there (default: print only)
      --build   label for the measured build, e.g. a commit (default: unknown)

    Run a release build for real figures:
      swift run -c release --package-path Packages/KAIORXKit kaiorx-bench --full --out <folder>
    """

var arguments = Array(CommandLine.arguments.dropFirst())
var size = BenchPlan.Size.quick
var scenarios = BenchPlan.scenarios
var output: String?
var build = "unknown"
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--full": size = .full
    case "--quick": size = .quick
    case "--only":
        guard let list = arguments.first else { print(usage); exit(2) }
        arguments.removeFirst()
        scenarios = Set(list.split(separator: ",").map(String.init))
        guard scenarios.isSubset(of: BenchPlan.scenarios), !scenarios.isEmpty else { print(usage); exit(2) }
    case "--out":
        guard let folder = arguments.first else { print(usage); exit(2) }
        arguments.removeFirst()
        output = folder
    case "--build":
        guard let label = arguments.first else { print(usage); exit(2) }
        arguments.removeFirst()
        build = label
    case "-h", "--help": print(usage); exit(0)
    default: print(usage); exit(2)
    }
}

#if DEBUG
FileHandle.standardError.write(Data("Hinweis: Debug-Build. Für echte Werte mit -c release bauen.\n".utf8))
#endif

do {
    let results = try await BenchPlan.run(size, scenarios: scenarios) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    let date = ISO8601DateFormatter().string(from: Date())
    let report = BenchReport(date: date, machine: .current(), build: build + (size == .quick ? " (quick)" : ""), results: results)
    let markdown = report.markdown()
    print(markdown)
    if let output {
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: URL(filePath: output + "/report.md"))
        try report.json().write(to: URL(filePath: output + "/report.json"))
        FileHandle.standardError.write(Data("Bericht: \(output)/report.md\n".utf8))
    }
    exit(results.contains { $0.verdict == .missed } ? 1 : 0)
} catch {
    FileHandle.standardError.write(Data("Fehler: \(error)\n".utf8))
    exit(3)
}
