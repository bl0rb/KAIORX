import Domain
import Foundation
import Orchestration
import Providers
import Storage

/// Development CLI for package B until the Xcode app exists. Uses only the fake adapter.
let usage = """
    Usage: kaiorx-dev [--db PATH] COMMAND

      open PATH                      Open a project folder (reopening returns the same project)
      projects                       List projects
      demo PROJECT [success|hang|fail|end]
                                     Create job and task, run the fake adapter. `hang` keeps running
                                     until the process exits; the next start reports it as uncertain.
      runs                           List active (non-terminal) runs
      events [AFTER_SEQ]             Print the event journal from a cursor

    Every command first recovers runs lost by a previous exit.
    Default database: ~/Library/Application Support/KAIORX/kaiorx.sqlite
    """

struct CLIError: Error, CustomStringConvertible {
    let description: String
}

func script(named name: String) throws -> FakeScript {
    switch name {
    case "success": .success(text: "Demo erledigt")
    case "hang": .waitsForCancel
    case "fail": FakeScript(steps: [.emit(.started(sessionID: "fake")), .emit(.completed(.failed(reason: "demo failure")))])
    case "end": FakeScript(steps: [.emit(.started(sessionID: "fake")), .end])
    default: throw CLIError(description: "Unknown script \(name)")
    }
}

func describe(_ run: AttemptRecord) -> String {
    "\(run.id)  \(run.state.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(run.provider.rawValue)/\(run.model)  task \(run.taskID)  #\(run.ordinal)\(run.errorClass.map { "  (\($0))" } ?? "")"
}

let commands: Set<String> = ["open", "projects", "demo", "runs", "events"]

func run(_ arguments: [String]) async throws {
    var args = arguments
    var databasePath: String?
    if args.first == "--db" {
        guard args.count >= 2 else { throw CLIError(description: usage) }
        databasePath = args[1]
        args.removeFirst(2)
    }
    guard let command = args.first, commands.contains(command) else {
        // Help and unknown commands never touch a database.
        if let first = args.first, ["help", "--help", "-h"].contains(first) {
            print(usage)
            return
        }
        throw CLIError(description: usage)
    }
    let rest = Array(args.dropFirst())
    let resolvedPath = try databasePath ?? AppPaths.defaultDatabaseURL().path(percentEncoded: false)

    let scriptName = command == "demo" && rest.count >= 2 ? rest[1] : "success"
    let chosenScript = try script(named: scriptName)
    let store = try Store(path: resolvedPath)
    let coordinator = RunCoordinator(store: store, adapters: [FakeAdapter { _ in chosenScript }])
    let report = try await coordinator.bootstrap()
    for id in report.uncertain { print("recovered: \(id) is uncertain (process lost)") }
    for id in report.cancelledReservations { print("recovered: \(id) cancelled (never started)") }

    switch command {
    case "open":
        guard let path = rest.first else { throw CLIError(description: usage) }
        let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else { throw CLIError(description: "Not a folder: \(path)") }
        let outcome = try await store.execute(Command(.openProject(
            id: ProjectID(), name: url.lastPathComponent, rootLocator: url.path(percentEncoded: false)
        )))
        print(outcome.objectID)

    case "projects":
        for project in try await store.projects() { print("\(project.id)  \(project.name)  \(project.rootLocator)") }

    case "demo":
        guard let reference = rest.first else { throw CLIError(description: usage) }
        let projects = try await store.projects()
        guard let project = projects.first(where: { $0.id.uuidString == reference.lowercased() || $0.rootLocator == reference })
        else { throw CLIError(description: "Unknown project \(reference); use `open` first") }
        let jobID = JobID()
        let taskID = TaskID()
        try await store.execute(Command(.createJob(id: jobID, projectID: project.id, goal: "Demo-Lauf")))
        try await store.execute(Command(.createTask(id: taskID, jobID: jobID, title: "Fake-Agent (\(scriptName))")))
        // A run needs an active job and a ready task (runtime contract).
        try await store.execute(Command(.transitionJob(id: jobID, to: .planned, expectedVersion: 1, reason: nil)))
        try await store.execute(Command(.transitionJob(id: jobID, to: .active, expectedVersion: 2, reason: nil)))
        try await store.execute(Command(.transitionTask(id: taskID, to: .ready, expectedVersion: 1)))
        let result = try await coordinator.start(StartRequest(
            taskID: taskID, projectID: project.id, provider: .fake, modelProfile: "standard",
            model: "fake-model", workingDirectory: project.rootLocator, prompt: "Demo"
        ))
        guard case .started(let id) = result else {
            print("not started: \(result)")
            return
        }
        if scriptName == "hang" {
            // Let the stream reach `running`, then exit without a terminal event.
            for _ in 0..<200 where try await store.attempt(id)?.state != .running {
                try await Task.sleep(for: .milliseconds(5))
            }
            if let attempt = try await store.attempt(id) { print(describe(attempt)) }
            print("exiting while the run is active")
            return
        }
        if let attempt = try await coordinator.waitUntilFinished(id) { print(describe(attempt)) }

    case "runs":
        let runs = try await coordinator.activeRuns()
        if runs.isEmpty { print("no active runs") }
        for run in runs { print(describe(run)) }

    case "events":
        let cursor = rest.first.flatMap(Int64.init) ?? 0
        for event in try await store.events(after: cursor) {
            let payload = event.payload.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            print("\(event.seq)  \(event.kind)  \(event.ordinal.map { "#\($0)" } ?? "-")  \(payload)")
        }

    default:
        throw CLIError(description: usage)
    }
    await store.close()
}

do {
    try await run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
