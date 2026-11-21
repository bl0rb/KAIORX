import Domain
import Foundation
import Orchestration
import Storage

/// Fixtures for UI tests (`-KAIORXUITest`, temporary database and repository) and the Workbench
/// tests. Never used by the normal app: it records an author result without any provider run.
public enum UITestSeed {
    /// A job with one task whose recorded author result (a new file) is built into a candidate
    /// on the job's integration target. Returns the job, the task and the built candidate.
    public static func builtCandidate(
        services: AppServices, project: ProjectID, title: String, baseRevision: String = "HEAD"
    ) async throws -> (job: JobID, task: TaskID, candidate: CandidateRecord) {
        guard let workspace = services.workspace, let integration = services.integration else { throw ActionError.unavailable("Git") }
        let store = services.store
        let job = JobID(), task = TaskID(), attempt = AttemptID()
        try await store.execute(Command(.createJob(id: job, projectID: project, goal: title)))
        try await store.execute(Command(.transitionJob(id: job, to: .planned, expectedVersion: 1, reason: nil)))
        try await store.execute(Command(.transitionJob(id: job, to: .active, expectedVersion: 2, reason: nil)))
        _ = try await workspace.openIntegration(job, baseRevision: baseRevision)
        try await store.execute(Command(.createTask(id: task, jobID: job, title: title)))
        try await store.execute(Command(.transitionTask(id: task, to: .ready, expectedVersion: 1)))
        try await store.execute(Command(.reserveAttempt(AttemptReservation(
            attemptID: attempt, taskID: task, projectID: project, role: .author, provider: .fake, mode: .automatic, model: "fake-seed",
            specDigest: "uitest-seed"
        ))))
        guard let tip = try await store.integrationTip(job: job) else { throw ActionError.unknown("integration") }
        let tree = try await workspace.prepareWorktree(projectID: project, attemptID: attempt, kind: .author, base: tip)
        try "Leerwert: nil\n".write(toFile: workspace.path(of: tree) + "/LEERWERT.md", atomically: true, encoding: .utf8)
        guard let version = try await store.attempt(attempt)?.version else { throw ActionError.unknown("attempt") }
        try await store.execute(Command(.transitionAttempt(id: attempt, to: .starting, expectedVersion: version, errorClass: nil)))
        _ = try await store.ingest(.started(sessionID: "uitest-seed"), attemptID: attempt)
        _ = try await store.ingest(.completed(.succeeded), attemptID: attempt)
        _ = try await workspace.seal(tree.id, allowedPrefixes: nil, message: title)
        guard case .built(let candidate) = try await integration.buildCandidate(from: tree.id) else { throw ActionError.unknown("candidate") }
        return (job, task, candidate)
    }
}
