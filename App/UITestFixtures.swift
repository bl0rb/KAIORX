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
    /// The candidate chain's starting states (`KAIORX_UITEST_SEED`, ADR 0011), each in the opened
    /// fixture repository. Runs before the chain loop starts, so every seal here is the seed's.
    /// - `result`: an unsealed author result with one new file; the chain seals and builds it.
    /// - `undeclared`: a sealed plan-task result whose seal dropped `NOTIZ.md`.
    /// - `empty`: a sealed result of a run that changed nothing.
    /// - `conflicted`: a conflicted candidate on `KONFLIKT.md`.
    /// - `containedAfterRebuild`: an accepted candidate superseded by its own commit; the rebuild
    ///   finds the result already contained (ADR 0011 §10).
    /// Returns the job and task to select, or nil for an unknown seed or a failed step.
    func seedChainForUITests(_ services: AppServices, seed: String) async -> (job: JobID, task: TaskID)? {
        guard let repo = launch.uiTestRepository else { return nil }
        do {
            let project = try await WorkbenchActions(services: services).openProject(at: repo)
            switch seed {
            case "result":
                let seeded = try await UITestSeed.authorResult(
                    services: services, project: project, title: "Neue Datei anlegen", writes: ["src/neu.swift": "let neu = 2\n"]
                )
                return (seeded.job, seeded.task)
            case "undeclared":
                let seeded = try await UITestSeed.undeclared(services: services, project: project, title: "Leerwert dokumentieren")
                return (seeded.job, seeded.task)
            case "empty":
                let seeded = try await UITestSeed.empty(services: services, project: project, title: "Nichts zu tun")
                return (seeded.job, seeded.task)
            case "conflicted":
                let seeded = try await UITestSeed.conflicted(services: services, project: project, title: "Konflikt anlegen")
                return (seeded.job, seeded.task)
            case "containedAfterRebuild":
                let seeded = try await UITestSeed.containedAfterRebuild(services: services, project: project, title: "Schon enthalten nach Neubau")
                return (seeded.job, seeded.task)
            default:
                return nil
            }
        } catch {
            errorMessage = "UI-Test-Vorbereitung fehlgeschlagen: \(error)"
            return nil
        }
    }

    /// `published`: the temporary repository opened as a project, one active job, and one task
    /// whose result was built, tested, reviewed (an imported approving review), approved and
    /// published onto the job's integration ref. Returns the job, or nil if a step failed.
    func seedPublishedJob(_ services: AppServices) async -> JobID? {
        guard let repo = launch.uiTestRepository, let workspace = services.workspace, let integration = services.integration else { return nil }
        let store = services.store
        do {
            let project = try await WorkbenchActions(services: services).openProject(at: repo)
            // Only tests from a confirmed registry profile count for the gate (ADR 0010).
            let proposed = try await store.proposeTestProfile(project: project, TestProfileSpec(name: "test", executable: "/bin/sh", arguments: ["-c", "exit 0"]))
            let profile = try await store.confirmTestProfile(proposed.id, digest: proposed.digest, actor: WorkbenchActor.user)
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
            try await integration.runTests(candidate.id, profile: profile.id)
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
