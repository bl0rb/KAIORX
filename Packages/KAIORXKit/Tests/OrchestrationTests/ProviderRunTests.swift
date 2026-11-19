import Domain
import Foundation
import ProcessHost
import ProviderFixtures
import Testing
@testable import Orchestration
@testable import Providers
@testable import Storage
@testable import Workspace

/// Package D (offline): one Claude and one Codex run in separate, confined worktrees at the
/// same time through the coordinator, each sealed into its own result. The provider programs
/// are fixtures; live subscription runs are package A.
@Suite struct ProviderRunTests {
    @Test func claudeAndCodexRunInParallelAndYieldTwoResults() async throws {
        let harness = try await ServiceHarness()
        let root = URL(filePath: harness.storePath).deletingLastPathComponent().path(percentEncoded: false)
        let host = ProcessHost()
        let layout = harness.layout
        let claudeState = root + "/claude-config"
        let codexState = root + "/codex-home"
        func confinement(_ state: String, files: [String], keychain: Bool) -> @Sendable (AttemptSpec, String) -> Confinement? {
            { spec, temporary in
                RoleProfile.agentCLI(stateDirectory: state, writesWorktree: spec.role == .author, protectedStateFiles: files, needsKeychain: keychain).confinement(
                    worktree: spec.workingDirectory!, runTemporaryDirectory: temporary, layout: layout
                )
            }
        }
        let claude = ClaudeCodeAdapter(
            configuration: ClaudeCodeConfiguration(
                executable: try FixturePrograms.makeExecutable(FixturePrograms.claude([
                    .emit(["type": "system", "subtype": "init", "session_id": "s-claude"]),
                    .timestamped(seconds: 0.4),
                    .writeFile("claude.txt", "von claude\n"),
                    .emit(["type": "result", "subtype": "success", "is_error": false]),
                ]), in: root, name: "claude"),
                configDirectory: claudeState, temporaryRoot: layout.runsRoot, home: root, policy: .fixtureTesting,
                confinement: confinement(claudeState, files: RoleProfile.claudeStateFiles, keychain: true), stopGrace: .seconds(1)
            ),
            host: host
        )
        let codex = CodexAppServerAdapter(
            configuration: CodexConfiguration(
                executable: try FixturePrograms.makeExecutable(FixturePrograms.codex(.success, pauseSeconds: 0.4), in: root, name: "codex"),
                codexHome: codexState, temporaryRoot: layout.runsRoot, home: root, policy: .fixtureTesting,
                confinement: confinement(codexState, files: RoleProfile.codexStateFiles, keychain: false), stopGrace: .seconds(1)
            ),
            host: host
        )
        let coordinator = RunCoordinator(store: harness.store, adapters: [claude, codex])

        let base = try await harness.head()
        let second = TaskID()
        try await harness.store.execute(Command(.createTask(id: second, jobID: harness.job, title: "Codex")))
        try await harness.store.execute(Command(.transitionTask(id: second, to: .ready, expectedVersion: 1)))
        let claudeTree = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: base)
        let codexTree = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: base)

        func request(_ task: TaskID, _ provider: ProviderKind, _ tree: WorktreeRecord) -> StartRequest {
            StartRequest(
                taskID: task, projectID: harness.project, provider: provider, modelProfile: "standard",
                model: provider == .claude ? "claude-sonnet-5-5" : "gpt-6", workingDirectory: harness.service.path(of: tree),
                prompt: "Lege eine Datei an"
            )
        }
        async let startClaude = coordinator.start(request(harness.task, .claude, claudeTree))
        async let startCodex = coordinator.start(request(second, .codex, codexTree))
        let (claudeStart, codexStart) = try await (startClaude, startCodex)
        guard case .started(let claudeAttempt) = claudeStart, case .started(let codexAttempt) = codexStart else {
            Issue.record("not started: \(claudeStart) / \(codexStart)")
            return
        }
        #expect(try await coordinator.waitUntilFinished(claudeAttempt)?.state == .succeeded)
        #expect(try await coordinator.waitUntilFinished(codexAttempt)?.state == .succeeded)
        #expect(try await harness.store.attempt(codexAttempt)?.sessionHandle == "thr-1")

        // The two turns overlapped in time.
        func interval(_ attempt: AttemptID) throws -> (Double, Double) {
            let times = try String(contentsOfFile: layout.runsRoot + "/\(attempt.uuidString)/times", encoding: .utf8)
                .split(separator: "\n").compactMap { Double($0) }
            return (times.first ?? 0, times.last ?? 0)
        }
        let (a, b) = (try interval(claudeAttempt), try interval(codexAttempt))
        #expect(a.0 < b.1 && b.0 < a.1, "runs did not overlap: \(a) \(b)")

        // Two separate diffs, each sealed under its own result ref.
        let claudeResult = try await harness.service.seal(claudeTree.id, allowedPrefixes: nil, message: "claude")
        let codexResult = try await harness.service.seal(codexTree.id, allowedPrefixes: nil, message: "codex")
        #expect(claudeResult.outcome.accepted.map(\.path) == ["claude.txt"])
        #expect(codexResult.outcome.accepted.map(\.path) == ["codex.txt"])
        #expect(claudeResult.outcome.commit != codexResult.outcome.commit)
        #expect(try await harness.sh("git ls-tree --name-only \(try #require(codexResult.outcome.commit)) codex.txt claude.txt") == "codex.txt")
    }
}
