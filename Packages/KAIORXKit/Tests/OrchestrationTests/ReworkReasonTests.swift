import Domain
import Foundation
import Memory
import Synchronization
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workspace

/// The user's reason for rejecting a candidate or discarding a result goes into the next author
/// prompt (ADR 0011, rework reason; revises §9.6): only the user's own reason about the task's
/// last result, never an automatic one, never a forgotten one, never one that looks like a
/// secret. Fake providers only.
@Suite struct ReworkReasonTests {
    /// A task state move as its payload stores it.
    struct Move: Decodable, Equatable {
        var from: String
        var to: String
        var reason: String?
        var actor: String?
        var attemptID: String?
    }

    /// Every author prompt the harness's author double received, in order.
    final class Prompts: Sendable {
        private let all = Mutex<[String]>([])
        func record(_ prompt: String) { all.withLock { $0.append(prompt) } }
        var list: [String] { all.withLock { $0 } }
    }

    func harness(_ prompts: Prompts = Prompts()) async throws -> SchedulerHarness {
        try await SchedulerHarness(script: { spec in
            prompts.record(spec.prompt)
            return .success()
        })
    }

    /// A's sealed result with one file inside its write area.
    func sealedResult(_ h: SchedulerHarness) async throws -> WorktreeRecord {
        try await PlannedIntegrationTests().result(h, "A", "mkdir -p src/A && echo x > src/A/f", writes: ["src/A"])
    }

    func built(_ h: SchedulerHarness, _ tree: WorktreeRecord) async throws -> CandidateRecord {
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { throw ChainError.shownStateChanged }
        return candidate
    }

    func lastMove(_ h: SchedulerHarness, _ task: TaskID) async throws -> Move? {
        let events = try await h.store.events(after: 0, limit: 100_000).filter { $0.taskID == task && $0.kind == .taskStateChanged }
        return try events.last.map { try JSONDecoder().decode(Move.self, from: try #require($0.payload)) }
    }

    /// One scheduler tick after the user's grant; returns the prompt of the attempt it started.
    func reworkTick(_ h: SchedulerHarness, _ prompts: Prompts, grant: Bool = true) async throws -> String {
        let scheduler = h.scheduler()
        let task = try await h.task("A")
        if grant { try await scheduler.grant(task.id, actor: "user") }
        let report = try await scheduler.tick()
        let attempt = try #require(report.reserved.first)
        _ = try await h.coordinator.waitUntilFinished(attempt)
        return try #require(prompts.list.last)
    }

    func move(_ store: Store, _ id: TaskID, to state: TaskState) async throws {
        let version = try #require(try await store.task(id)).version
        try await store.execute(Command(.transitionTask(id: id, to: state, expectedVersion: version)))
    }

    func leaks(_ store: Store, _ marker: String) async throws -> Bool {
        try await store.events(limit: 100_000).contains { $0.payload.map { String(decoding: $0, as: UTF8.self).contains(marker) } ?? false }
    }

    func manifest(_ store: Store, attempt: AttemptID, note: MemoryRevisionRecord) async throws {
        let excerpt = note.body
        _ = try await store.prepareManifest(attempt: attempt, reviewerProvider: nil, baseOID: nil, items: [ManifestItemRecord(
            position: 0, revisionID: note.id, byteFrom: 0, byteTo: excerpt.utf8.count, excerptDigest: Canonical.sha256Hex(Data(excerpt.utf8)),
            tokenEstimate: 2, reason: .lexical, rank: 0
        )])
    }

    @Test func aDiscardStoresTheReasonWithTheMoveInOneTransaction() async throws {
        let h = try await harness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        _ = try await sealedResult(h)
        let task = try await h.task("A")
        let attempt = try #require(task.currentAttemptID)
        let before = try await h.store.events(after: 0, limit: 100_000).count
        await #expect(throws: StoreError.versionConflict(entity: "task", id: task.id.uuidString, expected: task.version - 1, actual: task.version)) {
            try await h.store.discardResult(task: task.id, expectedVersion: task.version - 1, attempt: attempt, reason: "zu breit", actor: "user")
        }
        let other = AttemptID()
        await #expect(throws: StoreError.notFound(entity: "result", id: other.uuidString)) {
            try await h.store.discardResult(task: task.id, expectedVersion: task.version, attempt: other, reason: "zu breit", actor: "user")
        }
        #expect(try await h.store.events(after: 0, limit: 100_000).count == before)
        #expect(try await h.task("A").state == .resultReady)

        try await h.store.discardResult(task: task.id, expectedVersion: task.version, attempt: attempt, reason: "  zu breit\n", actor: "user")
        #expect(try await h.task("A").state == .needsChanges)
        #expect(try await lastMove(h, task.id) == Move(from: "resultReady", to: "needsChanges", reason: "zu breit", actor: "user", attemptID: attempt.uuidString))
        let reason = try #require(try await h.store.reworkReason(task: task.id))
        #expect(reason.source == .discarded && reason.attemptID == attempt && reason.text == "zu breit")

        // A blank reason is no reason; the move is still marked as the user's.
        let blank = try await harness()
        try await blank.activate([planTask("A", writes: ["src/A"])])
        _ = try await sealedResult(blank)
        let other2 = try await blank.task("A")
        let attempt2 = try #require(other2.currentAttemptID)
        try await blank.store.discardResult(task: other2.id, expectedVersion: other2.version, attempt: attempt2, reason: " \n ", actor: "user")
        #expect(try await lastMove(blank, other2.id) == Move(from: "resultReady", to: "needsChanges", reason: nil, actor: "user", attemptID: attempt2.uuidString))
        #expect(try await blank.store.reworkReason(task: other2.id) == nil)
    }

    @Test func theReworkReasonIsTheUsersAndBelongsToTheLastResult() async throws {
        let h = try await harness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let tree = try await sealedResult(h)
        let task = try await h.task("A").id
        let first = try #require(tree.attemptID)
        // The user rejects while holding the task: it stays held, the reason is recorded.
        let c1 = try await built(h, tree)
        try await move(h.store, task, to: .blocked)
        try await h.integration.rejectCandidate(c1.id, reason: "erster Grund")
        let held = try #require(try await h.store.reworkReason(task: task))
        #expect(held == ReworkReason(source: .rejected(c1.id), attemptID: first, text: "erster Grund", at: held.at))
        try await move(h.store, task, to: .verifying)
        // A rebuilt candidate of the same result, rejected later: the newest reason wins.
        let c2 = try await built(h, tree)
        try await h.integration.rejectCandidate(c2.id, reason: "zweiter Grund")
        let newest = try #require(try await h.store.reworkReason(task: task))
        #expect(newest.source == .rejected(c2.id) && newest.text == "zweiter Grund" && newest.attemptID == first)

        // A newer result without a reason of the user: nothing stale is handed on.
        try await h.scheduler().grant(task, actor: "user")
        let second = try await sealedResult(h)
        #expect(second.attemptID != first)
        #expect(try await h.store.reworkReason(task: task) == nil)
        // Closing its candidate by sending the task back (no user reason) adds none.
        let c3 = try await built(h, second)
        let verifying = try #require(try await h.store.task(task))
        try await h.store.execute(Command(.transitionTask(id: task, to: .needsChanges, expectedVersion: verifying.version)))
        #expect(try await h.store.candidate(c3.id)?.state == .rejected)
        #expect(try await h.store.reworkReason(task: task) == nil)
    }

    @Test func forgettingRemovesTheDiscardReason() async throws {
        let marker = "wombatGeheim"
        let h = try await harness()
        try await h.store.setMemoryPolicy(project: h.project, allowGlobal: false, providers: [.claude, .fake])
        let note = try await h.store.addMemory(MemoryDraft(scope: .project, projectID: h.project, title: "Wissen", body: "Wissen", sources: [.user(at: 1)]))
        try await h.activate([planTask("A", writes: ["src/A"])])
        _ = try await sealedResult(h)
        let task = try await h.task("A")
        let attempt = try #require(task.currentAttemptID)
        try await manifest(h.store, attempt: attempt, note: note)
        try await h.store.discardResult(task: task.id, expectedVersion: task.version, attempt: attempt, reason: "Bitte \(marker) beachten", actor: "user")
        #expect(try await h.store.reworkReason(task: task.id)?.text.contains(marker) == true)
        #expect(try await leaks(h.store, marker))
        _ = try await h.store.forgetMemory([note.entryID])
        #expect(try await h.store.reworkReason(task: task.id) == nil)
        #expect(try await !leaks(h.store, marker))
        let path = await h.store.path
        await h.store.close()
        for suffix in ["", "-wal"] {
            let data = FileManager.default.contents(atPath: path + suffix) ?? Data()
            #expect(data.range(of: Data(marker.utf8)) == nil, "\(suffix)")
        }

        // A reason given after the forget about the forgotten attempt is not stored.
        let later = try await harness()
        try await later.store.setMemoryPolicy(project: later.project, allowGlobal: false, providers: [.claude, .fake])
        let laterNote = try await later.store.addMemory(MemoryDraft(scope: .project, projectID: later.project, title: "Wissen", body: "Wissen", sources: [.user(at: 1)]))
        try await later.activate([planTask("A", writes: ["src/A"])])
        _ = try await sealedResult(later)
        let laterTask = try await later.task("A")
        let laterAttempt = try #require(laterTask.currentAttemptID)
        try await manifest(later.store, attempt: laterAttempt, note: laterNote)
        _ = try await later.store.forgetMemory([laterNote.entryID])
        let current = try #require(try await later.store.task(laterTask.id))
        try await later.store.discardResult(task: current.id, expectedVersion: current.version, attempt: laterAttempt, reason: "Bitte \(marker)", actor: "user")
        #expect(try await lastMove(later, current.id)?.reason == Store.purgedText)
        #expect(try await later.store.reworkReason(task: current.id) == nil)
        #expect(try await !leaks(later.store, marker))
    }

    @Test func theReworkPromptCarriesTheUsersRejectionReason() async throws {
        let prompts = Prompts()
        let h = try await harness(prompts)
        try await h.activate([planTask("A", writes: ["src/A"])])
        let candidate = try await built(h, try await sealedResult(h))
        try await h.integration.rejectCandidate(candidate.id, reason: "Bitte den vorhandenen Parser nutzen")
        // Without a counted failure the task waits for the user's grant (ADR 0011 §6).
        #expect(try await h.scheduler().tick().reserved.isEmpty)
        let prompt = try await reworkTick(h, prompts)
        #expect(prompts.list.count == 2)
        #expect(!prompts.list[0].contains("The user"))
        #expect(prompt.contains("The user rejected the candidate built from the last result of this task. Their reason, between the fences:\n```\nBitte den vorhandenen Parser nutzen\n```"))
        #expect(prompt.contains("You start again from the current integration state; the earlier result is not in your working directory. Take the reason into account."))
    }

    @Test func theReworkPromptCarriesTheDiscardReason() async throws {
        let prompts = Prompts()
        let h = try await harness(prompts)
        try await h.activate([planTask("A", writes: ["src/A"])])
        let tree = try await sealedResult(h)
        let chain = CandidateChain(
            store: h.store, workspace: h.service, integration: h.integration, git: h.git, coordinator: h.coordinator, limits: h.limits, gate: nil
        )
        let task = try await h.task("A")
        let shown = ShownResult(
            task: task.id, taskVersion: task.version, worktree: tree.id, resultOID: tree.resultOID, rejected: [], check: try await chain.check(task.id)
        )
        guard case .buildable = shown.check else { Issue.record("\(shown.check)"); return }
        try await chain.discard(shown, reason: "zu breit", actor: "user")
        // The grant came with the discard: the next tick starts the author.
        let prompt = try await reworkTick(h, prompts, grant: false)
        #expect(prompt.contains("The user discarded the last result of this task. Their reason, between the fences:\n```\nzu breit\n```"))
        // The grant's evidence never holds the reason (a forget does not purge decisions).
        #expect(try await h.store.decisions(task: task.id).allSatisfy { !$0.evidence.values.contains { $0.contains("zu breit") } })
    }

    @Test func anAutomaticRejectionAddsNoUserReason() async throws {
        let prompts = Prompts()
        let h = try await harness(prompts)
        try await h.activate([planTask("A", writes: ["src/A"])])
        let candidate = try await built(h, try await sealedResult(h))
        let red = try await h.store.confirmedTestProfile(project: h.project, arguments: ["-c", "echo kaputt >&2; exit 1"])
        try await h.integration.runTests(candidate.id, profile: red)
        #expect(try await h.store.candidate(candidate.id)?.state == .rejected)
        #expect(try await h.store.reworkReason(task: try await h.task("A").id) == nil)
        let prompt = try await reworkTick(h, prompts, grant: false)
        #expect(prompt.contains("Report of the last failed check:\nTest: "))
        #expect(!prompt.contains("The user"))
    }

    @Test func aBlockingFindingRejectionStillShowsTheReportOnceAndTheUsersReason() async throws {
        let prompts = Prompts()
        let h = try await harness(prompts)
        try await h.activate([planTask("A", writes: ["src/A"])])
        let candidate = try await built(h, try await sealedResult(h))
        let green = try await h.store.confirmedTestProfile(project: h.project, arguments: ["-c", "exit 0"])
        try await h.integration.runTests(candidate.id, profile: green)
        let oid = try #require(candidate.candidateOID)
        // Recorded without an evaluation: the user rejects before the gate would.
        _ = try await h.store.recordReview(
            candidate: candidate.id, oid: oid, reviewerAttemptID: nil, origin: .userImported, reviewerProvider: nil, status: .changesRequested,
            summary: "nein", findings: [FindingDraft(severity: .blocking, path: "src/A/f", line: 1, impact: "Leerwert fehlt", suggestion: "nil prüfen")]
        )
        try await h.integration.rejectCandidate(candidate.id, reason: "Bitte nil prüfen")
        // A counted failure: the repair starts without a grant.
        let prompt = try await reworkTick(h, prompts, grant: false)
        #expect(prompt.components(separatedBy: "Blocking finding src/A/f:1: Leerwert fehlt – nil prüfen").count == 2)
        #expect(prompt.contains("```\nBitte nil prüfen\n```"))
    }

    @Test func aSecretLookingReasonIsWithheld() async throws {
        let prompts = Prompts()
        let h = try await harness(prompts)
        try await h.activate([planTask("A", writes: ["src/A"])])
        let candidate = try await built(h, try await sealedResult(h))
        try await h.integration.rejectCandidate(candidate.id, reason: "api_key = abcdefgh1234")
        let reason = try #require(try await h.store.reworkReason(task: try await h.task("A").id))
        #expect(ReworkPrompt.isWithheld(reason) && ReworkPrompt.lines(reason).isEmpty)
        let prompt = try await reworkTick(h, prompts)
        #expect(!prompt.contains("abcdefgh1234") && !prompt.contains("The user"))
    }

    @Test func theReasonIsFencedAndBounded() {
        let attempt = AttemptID()
        let fenced = ReworkPrompt.lines(ReworkReason(source: .discarded, attemptID: attempt, text: "so:\n````swift\nlet a = 1\n````", at: 1))
        #expect(fenced[1] == "`````" && fenced[3] == "`````")
        let long = ReworkPrompt.lines(ReworkReason(source: .rejected(CandidateID()), attemptID: attempt, text: String(repeating: "x", count: 3_000), at: 1))
        #expect(long[2] == String(repeating: "x", count: 2_000) + " […]")
        #expect(long[1] == "```")
        #expect(ReworkPrompt.lines(nil).isEmpty)
        #expect(ReworkPrompt.lines(ReworkReason(source: .discarded, attemptID: attempt, text: Store.purgedText, at: 1)).isEmpty)
    }

    @Test func aForgottenReasonNeverReachesAPrompt() async throws {
        let marker = "okapiGeheim"
        let prompts = Prompts()
        let h = try await harness(prompts)
        try await h.store.setMemoryPolicy(project: h.project, allowGlobal: false, providers: [.claude, .fake])
        let note = try await h.store.addMemory(MemoryDraft(scope: .project, projectID: h.project, title: "Wissen", body: "Wissen", sources: [.user(at: 1)]))
        try await h.activate([planTask("A", writes: ["src/A"])])
        let tree = try await sealedResult(h)
        let candidate = try await built(h, tree)
        try await manifest(h.store, attempt: try #require(tree.attemptID), note: note)
        try await h.integration.rejectCandidate(candidate.id, reason: "Bitte \(marker) beachten")
        #expect(try await leaks(h.store, marker))
        _ = try await h.store.forgetMemory([note.entryID])
        #expect(try await h.store.reworkReason(task: try await h.task("A").id) == nil)
        _ = try await reworkTick(h, prompts)
        #expect(prompts.list.allSatisfy { !$0.contains(marker) })
        #expect(try await !leaks(h.store, marker))
    }
}
