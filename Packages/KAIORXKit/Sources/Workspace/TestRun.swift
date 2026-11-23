import Foundation
import ProcessHost

/// A test command the user confirmed for the project. Only such profiles run.
public struct TestProfile: Sendable, Equatable, Codable {
    public var executable: String
    public var arguments: [String]
    /// Relative to the worktree; must not leave it.
    public var workingDirectory: String
    public var timeoutSeconds: Int
    public var environment: [String: String]
    /// Tests that build into the worktree need write access there; otherwise only the run's
    /// temporary folder is writable.
    public var writesWorktree: Bool
    public var outputLimit: Int
    /// Paths (prefixes) whose changes count as changed test inputs: tests, fixtures, build and
    /// CI scripts. Part of the confirmed profile and its digest.
    public var testInputPrefixes: [String]

    public init(
        executable: String, arguments: [String] = [], workingDirectory: String = ".", timeoutSeconds: Int = 600,
        environment: [String: String] = [:], writesWorktree: Bool = false, outputLimit: Int = 4 << 20,
        testInputPrefixes: [String] = []
    ) {
        self.testInputPrefixes = testInputPrefixes
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.environment = environment
        self.writesWorktree = writesWorktree
        self.outputLimit = outputLimit
    }

    /// Changed paths that are test inputs: under a declared prefix, a file the profile names in
    /// its arguments or working directory, or a Git hook location.
    public func testInputs(in changed: [String]) -> [String] {
        let named = Set((arguments + [workingDirectory]).map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 })
        return changed.filter { path in
            named.contains(path)
                || (testInputPrefixes + [".githooks", ".husky", ".github/workflows"]).contains { prefix in
                    let trimmed = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
                    return path == trimmed || path.hasPrefix(trimmed + "/")
                }
        }
    }
}

/// Infrastructure errors, stopped runs, red tests and changed inputs are different results.
public enum TestOutcome: Sendable, Equatable {
    case passed
    case failed(exitCode: Int32)
    case crashed(signal: Int32)
    case timedOut
    /// The run changed versioned files; its result does not count.
    case inputsModified([String])
    case infrastructureError(String)
}

public struct TestReport: Sendable, Equatable {
    public var commit: String
    public var outcome: TestOutcome
    public var process: ProcessResult?
    /// New untracked files the run left in the worktree.
    public var untrackedOutputs: [String]

    public init(commit: String, outcome: TestOutcome, process: ProcessResult?, untrackedOutputs: [String]) {
        self.commit = commit
        self.outcome = outcome
        self.process = process
        self.untrackedOutputs = untrackedOutputs
    }
}

extension GitRunner {
    /// Runs a confirmed test profile in a worktree that must be clean at `commit`.
    public func runTests(
        _ profile: TestProfile, in worktree: WorktreeLocation, commit: String, runTemporaryDirectory: String,
        confinement: Confinement?
    ) async -> TestReport {
        func infrastructure(_ message: String) -> TestReport {
            TestReport(commit: commit, outcome: .infrastructureError(message), process: nil, untrackedOutputs: [])
        }
        let relative = profile.workingDirectory
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
            return infrastructure("working directory leaves the worktree: \(relative)")
        }
        guard profile.executable.hasPrefix("/") else { return infrastructure("executable is not absolute") }
        // Checked here: under the sandbox wrapper a missing program would look like a red test.
        guard FileManager.default.isExecutableFile(atPath: profile.executable) else {
            return infrastructure("executable not found: \(profile.executable)")
        }
        do {
            guard try await isClean(worktree, at: commit) else { return infrastructure("worktree is not clean at \(commit)") }
        } catch {
            return infrastructure("cannot check the worktree: \(error)")
        }

        let directory = relative == "." ? worktree.path : worktree.path + "/" + relative
        let environment = Environment.minimal(temporaryDirectory: runTemporaryDirectory)
            .merging(profile.environment.filter { $0.key != "PATH" && $0.key != "TMPDIR" }) { _, new in new }
        let result: ProcessResult
        do {
            result = try await host.run(LaunchSpec(
                executable: profile.executable, arguments: profile.arguments, workingDirectory: directory,
                environment: environment, outputLimit: profile.outputLimit,
                timeout: .seconds(profile.timeoutSeconds), confinement: confinement
            ))
        } catch {
            return infrastructure("cannot start: \(error)")
        }

        let changes: [ChangeEntry]
        do {
            changes = try await inventory(of: worktree)
        } catch {
            return TestReport(commit: commit, outcome: .infrastructureError("cannot inspect after the run: \(error)"), process: result, untrackedOutputs: [])
        }
        let modified = changes.filter { $0.kind != .untracked }.map(\.path)
        let untracked = changes.filter { $0.kind == .untracked }.map(\.path)
        let outcome: TestOutcome
        if !modified.isEmpty {
            outcome = .inputsModified(modified)
        } else if result.timedOut {
            outcome = .timedOut
        } else {
            switch result.termination {
            case .exited(0): outcome = .passed
            case .exited(let code): outcome = .failed(exitCode: code)
            case .signaled(let signal): outcome = .crashed(signal: signal)
            }
        }
        return TestReport(commit: commit, outcome: outcome, process: result, untrackedOutputs: untracked)
    }
}
