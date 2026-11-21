#if DEBUG
import Domain
import Foundation
import Orchestration
import Storage
import Workbench
import Workspace

/// Prepared states for UI tests (`-KAIORXUITest` only, never in Release builds). They go through
/// the real services on the temporary database and repository; no provider runs.
extension AppModel {
    /// `published`: the temporary repository opened as a project, one active job, and one task
    /// whose result was built, tested, reviewed (an imported approving review), approved and
    /// published onto the job's integration ref. Returns the job, or nil if a step failed.
    func seedPublishedJob(_ services: AppServices) async -> JobID? {
        guard let repo = launch.uiTestRepository, let workspace = services.workspace, let integration = services.integration else { return nil }
        let store = services.store
        do {
            let project = try await WorkbenchActions(services: services).openProject(at: repo)
            let job = JobID(), task = TaskID(), attempt = AttemptID()
            try await store.execute(Command(.createJob(id: job, projectID: project, goal: "Begrüßung liefern")))
            try await store.execute(Command(.transitionJob(id: job, to: .planned, expectedVersion: 1, reason: nil)))
            try await store.execute(Command(.transitionJob(id: job, to: .active, expectedVersion: 2, reason: nil)))
            _ = try await workspace.openIntegration(job, baseRevision: "main")
            try await store.execute(Command(.createTask(id: task, jobID: job, title: "Begrüßung ergänzen")))
            try await store.execute(Command(.transitionTask(id: task, to: .ready, expectedVersion: 1)))
            try await store.execute(Command(.reserveAttempt(AttemptReservation(
                attemptID: attempt, taskID: task, projectID: project, role: .author, provider: .fake, mode: .automatic, model: "fake-fast",
                specDigest: "uitest"
            ))))
            guard let tip = try await store.integrationTip(job: job) else { return nil }
            let tree = try await workspace.prepareWorktree(projectID: project, attemptID: attempt, kind: .author, base: tip)
            try "Willkommen\n".write(toFile: workspace.path(of: tree) + "/WELCOME.md", atomically: true, encoding: .utf8)
            guard let version = try await store.attempt(attempt)?.version else { return nil }
            try await store.execute(Command(.transitionAttempt(id: attempt, to: .starting, expectedVersion: version, errorClass: nil)))
            _ = try await store.ingest(.started(sessionID: "uitest"), attemptID: attempt)
            _ = try await store.ingest(.completed(.succeeded), attemptID: attempt)
            _ = try await workspace.seal(tree.id, allowedPrefixes: nil, message: "Begrüßung")
            guard case .built(let candidate) = try await integration.buildCandidate(from: tree.id), let commit = candidate.candidateOID else { return nil }
            try await integration.runTests(candidate.id, profile: TestProfile(executable: "/bin/sh", arguments: ["-c", "exit 0"]))
            _ = try await integration.importReview(
                candidate.id, text: #"{"candidateOID": "\#(commit)", "verdict": "approve", "summary": "ok", "findings": []}"#
            )
            let approval = try await integration.approve(candidate.id, actor: WorkbenchActor.user)
            try await integration.publish(candidate.id, approval: approval.id)
            return job
        } catch {
            errorMessage = "UI-Test-Vorbereitung fehlgeschlagen: \(error)"
            return nil
        }
    }
}
#endif
