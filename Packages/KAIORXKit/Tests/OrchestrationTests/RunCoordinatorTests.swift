import Domain
import Foundation
import Synchronization
import Testing
@testable import Orchestration
@testable import Providers
@testable import Storage

final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

final class Recorder: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ value: String) { storage.withLock { $0.append(value) } }
    var values: [String] { storage.withLock { $0 } }
}

/// Latch the test opens explicitly.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var hasWaiter: Bool { !waiters.isEmpty }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Adapter whose start and events the test drives step by step.
final class ControlledAdapter: AgentAdapter {
    let provider: ProviderKind = .fake
    let startGate = Gate()
    private let blockStart: Bool
    private let streams = Mutex<[AttemptID: AsyncThrowingStream<AgentEvent, any Error>.Continuation]>([:])
    private let cancelReasons = Recorder()

    init(blockStart: Bool = false) {
        self.blockStart = blockStart
    }

    var cancels: [String] { cancelReasons.values }

    func probe(_ request: ProbeRequest) async throws -> CapabilitySnapshot {
        try await FakeAdapter().probe(request)
    }

    func start(_ spec: AttemptSpec) async throws -> any RunHandle {
        if blockStart { await startGate.wait() }
        let (stream, continuation) = AsyncThrowingStream<AgentEvent, any Error>.makeStream()
        streams.withLock { $0[spec.attemptID] = continuation }
        let reasons = cancelReasons
        return ControlledHandle(attemptID: spec.attemptID, events: stream) { reasons.append($0) }
    }

    func reconcile(_ request: ReconcileRequest) async throws -> ReconcileResult { .unknown }

    func emit(_ event: AgentEvent, to id: AttemptID) {
        _ = streams.withLock { $0[id]?.yield(event) }
    }
}

struct ControlledHandle: RunHandle {
    let attemptID: AttemptID
    let events: AsyncThrowingStream<AgentEvent, any Error>
    let onCancel: @Sendable (String) -> Void

    func cancel(reason: String) async { onCancel(reason) }
}

struct Harness {
    let path: String
    let store: Store
    let project: ProjectID
    let job: JobID

    /// A project with an active job.
    init() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "kaiorx-orch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appending(path: "test.sqlite").path(percentEncoded: false)
        store = try Store(path: path)
        project = ProjectID()
        job = JobID()
        try await store.execute(Command(.openProject(id: project, name: "P", rootLocator: directory.path(percentEncoded: false))))
        try await store.execute(Command(.createJob(id: job, projectID: project, goal: "Ziel")))
        try await store.execute(Command(.transitionJob(id: job, to: .planned, expectedVersion: 1, reason: nil)))
        try await store.execute(Command(.transitionJob(id: job, to: .active, expectedVersion: 2, reason: nil)))
    }

    /// A task that is `ready` for an author.
    func newTask() async throws -> TaskID {
        let task = TaskID()
        try await store.execute(Command(.createTask(id: task, jobID: job, title: "T")))
        try await store.execute(Command(.transitionTask(id: task, to: .ready, expectedVersion: 1)))
        return task
    }

    func request(_ task: TaskID, commandID: CommandID = CommandID(), attemptID: AttemptID = AttemptID()) -> StartRequest {
        StartRequest(
            commandID: commandID, attemptID: attemptID, taskID: task, projectID: project, provider: .fake,
            modelProfile: "standard", model: "fake-model", prompt: "Mach etwas"
        )
    }

    func waitForState(_ id: AttemptID, _ state: AttemptState, in other: Store? = nil) async throws {
        for _ in 0..<2_000 {
            if try await (other ?? store).attempt(id)?.state == state { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("attempt \(id) never reached \(state)")
    }
}

func waitUntil(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<2_000 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("condition not reached")
}

func startedID(_ result: StartResult) throws -> AttemptID {
    guard case .started(let id) = result else {
        Issue.record("expected .started, got \(result)")
        throw CoordinatorError.attemptNotFound(AttemptID())
    }
    return id
}

@Suite struct RunCoordinatorTests {
    @Test func successfulRunIsJournaledEndToEnd() async throws {
        let harness = try await Harness()
        let coordinator = RunCoordinator(store: harness.store, adapters: [FakeAdapter()])
        let task = try await harness.newTask()
        let id = try startedID(try await coordinator.start(harness.request(task)))
        let attempt = try #require(try await coordinator.waitUntilFinished(id))
        #expect(attempt.state == .succeeded)
        #expect(attempt.sessionHandle == "fake-session")
        #expect(try await coordinator.activeRuns().isEmpty)
        #expect(try await harness.store.task(task)?.state == .resultReady)

        let kinds = try await harness.store.events().filter { $0.attemptID == id }.map(\.kind)
        #expect(kinds == [
            .attemptReserved, .attemptStateChanged, .attemptStarted, .messageDelta, .messageFinal,
            .usageObserved, .attemptCompleted,
        ])
    }

    @Test func sameStartFromTwoWindowsStartsOnce() async throws {
        let harness = try await Harness()
        let starts = Counter()
        let coordinator = RunCoordinator(store: harness.store, adapters: [FakeAdapter { _ in starts.increment(); return .success() }])
        let request = harness.request(try await harness.newTask())
        async let first = coordinator.start(request)
        async let second = coordinator.start(request)
        let results = try await [first, second]
        #expect(results.contains(.started(request.attemptID)))
        #expect(results.contains(.alreadyRequested(request.attemptID)))
        _ = try await coordinator.waitUntilFinished(request.attemptID)
        #expect(starts.count == 1)
    }

    @Test func sameStartAfterARestartIsNotRepeated() async throws {
        let harness = try await Harness()
        let starts = Counter()
        let script: @Sendable (AttemptSpec) -> FakeScript = { _ in starts.increment(); return .waitsForCancel }
        let coordinator = RunCoordinator(store: harness.store, adapters: [FakeAdapter(script: script)])
        let request = harness.request(try await harness.newTask())
        _ = try startedID(try await coordinator.start(request))
        try await harness.waitForState(request.attemptID, .running)
        await harness.store.close()

        let reopened = try Store(path: harness.path)
        let restarted = RunCoordinator(store: reopened, adapters: [FakeAdapter(script: script)])
        _ = try await restarted.bootstrap()
        #expect(try await restarted.start(request) == .alreadyRequested(request.attemptID))
        #expect(starts.count == 1)
        #expect(try await reopened.attempt(request.attemptID)?.state == .uncertain)
    }

    @Test func secondAuthorForTheSameTaskIsRefused() async throws {
        let harness = try await Harness()
        let coordinator = RunCoordinator(store: harness.store, adapters: [FakeAdapter { _ in .waitsForCancel }])
        let task = try await harness.newTask()
        let id = try startedID(try await coordinator.start(harness.request(task)))
        await #expect(throws: StoreError.activeAuthorExists(taskID: task, attemptID: id)) {
            _ = try await coordinator.start(harness.request(task))
        }
        try await coordinator.cancel(id, reason: "cleanup")
        _ = try await coordinator.waitUntilFinished(id)
    }

    @Test func requestForAnotherProjectIsRefused() async throws {
        let harness = try await Harness()
        let coordinator = RunCoordinator(store: harness.store, adapters: [FakeAdapter()])
        let task = try await harness.newTask()
        var request = harness.request(task)
        request.projectID = ProjectID()
        await #expect(throws: StoreError.projectMismatch(taskID: task, expected: request.projectID)) {
            _ = try await coordinator.start(request)
        }
    }

    @Test func cancelStopsARunningAttemptAndFreesTheTask() async throws {
        let harness = try await Harness()
        let coordinator = RunCoordinator(store: harness.store, adapters: [FakeAdapter { _ in .waitsForCancel }])
        let task = try await harness.newTask()
        let id = try startedID(try await coordinator.start(harness.request(task)))
        try await harness.waitForState(id, .running)
        try await coordinator.cancel(id, reason: "user")
        try await coordinator.cancel(id, reason: "repeated")
        #expect(try await coordinator.waitUntilFinished(id)?.state == .cancelled)
        #expect(try await harness.store.task(task)?.state == .ready)
        // Cancelling a finished attempt changes nothing.
        try await coordinator.cancel(id, reason: "late")
        #expect(try await harness.store.attempt(id)?.state == .cancelled)
    }

    @Test func cancelDuringAdapterStartKeepsTheSessionAndStopsTheRun() async throws {
        let harness = try await Harness()
        let adapter = ControlledAdapter(blockStart: true)
        let coordinator = RunCoordinator(store: harness.store, adapters: [adapter])
        let request = harness.request(try await harness.newTask())
        let starting = Task { try await coordinator.start(request) }
        try await waitUntil { await adapter.startGate.hasWaiter }
        #expect(try await harness.store.attempt(request.attemptID)?.state == .starting)

        try await coordinator.cancel(request.attemptID, reason: "user")
        #expect(try await harness.store.attempt(request.attemptID)?.state == .cancelling)
        #expect(adapter.cancels.isEmpty)

        await adapter.startGate.open()
        #expect(try await starting.value == .started(request.attemptID))
        #expect(adapter.cancels == ["cancelledDuringStart"])

        adapter.emit(.started(sessionID: "s-42"), to: request.attemptID)
        adapter.emit(.completed(.cancelled), to: request.attemptID)
        try await harness.waitForState(request.attemptID, .cancelled)
        let attempt = try #require(try await harness.store.attempt(request.attemptID))
        #expect(attempt.sessionHandle == "s-42")
    }

    @Test func cancelBeforeStartCancelsTheReservation() async throws {
        let harness = try await Harness()
        let task = try await harness.newTask()
        let id = AttemptID()
        try await harness.store.execute(Command(.reserveAttempt(AttemptReservation(
            attemptID: id, taskID: task, projectID: harness.project, role: .author, provider: .fake,
            mode: .automatic, model: "m", specDigest: "d"
        ))))
        let coordinator = RunCoordinator(store: harness.store, adapters: [FakeAdapter()])
        try await coordinator.cancel(id, reason: "user")
        #expect(try await harness.store.attempt(id)?.state == .cancelled)
        #expect(try await harness.store.task(task)?.state == .ready)
    }

    @Test func streamEndWithoutCompletionIsUncertain() async throws {
        let harness = try await Harness()
        let adapter = FakeAdapter { _ in FakeScript(steps: [.emit(.started(sessionID: nil)), .end]) }
        let coordinator = RunCoordinator(store: harness.store, adapters: [adapter])
        let task = try await harness.newTask()
        let id = try startedID(try await coordinator.start(harness.request(task)))
        let attempt = try #require(try await coordinator.waitUntilFinished(id))
        #expect(attempt.state == .uncertain)
        #expect(attempt.errorClass == "streamEndedWithoutCompletion")
        // An uncertain author keeps the task locked.
        #expect(try await harness.store.task(task)?.state == .running)
    }

    @Test func brokenStreamIsUncertain() async throws {
        let harness = try await Harness()
        let adapter = FakeAdapter { _ in FakeScript(steps: [.emit(.started(sessionID: nil)), .fail("invalid frame")]) }
        let coordinator = RunCoordinator(store: harness.store, adapters: [adapter])
        let id = try startedID(try await coordinator.start(harness.request(try await harness.newTask())))
        #expect(try await coordinator.waitUntilFinished(id)?.errorClass == "streamError")
        #expect(try await harness.store.attempt(id)?.state == .uncertain)
    }

    @Test func journalFailureStopsTheProvider() async throws {
        let harness = try await Harness()
        let adapter = ControlledAdapter()
        let coordinator = RunCoordinator(store: harness.store, adapters: [adapter])
        let id = try startedID(try await coordinator.start(harness.request(try await harness.newTask())))
        adapter.emit(.started(sessionID: nil), to: id)
        try await harness.waitForState(id, .running)

        await harness.store.close()
        adapter.emit(.messageDelta(itemID: "m", text: "lost"), to: id)
        try await waitUntil { adapter.cancels == ["persistenceFailure"] }
    }

    @Test func startFailureFailsTheAttemptAndFreesTheTask() async throws {
        let harness = try await Harness()
        let failing = Mutex(true)
        let adapter = FakeAdapter { _ in
            failing.withLock { $0 } ? FakeScript(startError: "binary missing", steps: []) : .success()
        }
        let coordinator = RunCoordinator(store: harness.store, adapters: [adapter])
        let task = try await harness.newTask()
        let result = try await coordinator.start(harness.request(task))
        guard case .failedToStart(let first, _) = result else { Issue.record("got \(result)"); return }
        let attempt = try #require(try await harness.store.attempt(first))
        #expect(attempt.state == .failed)
        #expect(attempt.errorClass == "startFailed")
        #expect(try await harness.store.task(task)?.state == .ready)

        failing.withLock { $0 = false }
        let second = try startedID(try await coordinator.start(harness.request(task)))
        #expect(second != first)
        #expect(try await harness.store.attempt(second)?.ordinal == 2)
        #expect(try await harness.store.task(task)?.currentAttemptID == second)
        #expect(try await coordinator.waitUntilFinished(second)?.state == .succeeded)
    }

    @Test func missingAdapterFailsCleanly() async throws {
        let harness = try await Harness()
        let coordinator = RunCoordinator(store: harness.store, adapters: [])
        let result = try await coordinator.start(harness.request(try await harness.newTask()))
        guard case .failedToStart(let id, _) = result else { Issue.record("got \(result)"); return }
        #expect(try await harness.store.attempt(id)?.errorClass == "adapterUnavailable")
    }

    @Test func twoRunsOverlapAndAreListedAsActive() async throws {
        let harness = try await Harness()
        let coordinator = RunCoordinator(store: harness.store, adapters: [FakeAdapter { _ in .waitsForCancel }])
        let a = try startedID(try await coordinator.start(harness.request(try await harness.newTask())))
        let b = try startedID(try await coordinator.start(harness.request(try await harness.newTask())))
        try await harness.waitForState(a, .running)
        try await harness.waitForState(b, .running)
        let active = try await coordinator.activeRuns()
        #expect(Set(active.map(\.id)) == [a, b])
        #expect(active.allSatisfy { $0.state == .running })

        try await coordinator.cancel(a, reason: "done")
        try await coordinator.cancel(b, reason: "done")
        #expect(try await coordinator.waitUntilFinished(a)?.state == .cancelled)
        #expect(try await coordinator.waitUntilFinished(b)?.state == .cancelled)
        #expect(try await coordinator.activeRuns().isEmpty)
    }

    @Test func restartTurnsALostRunIntoUncertain() async throws {
        let harness = try await Harness()
        let coordinator = RunCoordinator(store: harness.store, adapters: [FakeAdapter { _ in .waitsForCancel }])
        let id = try startedID(try await coordinator.start(harness.request(try await harness.newTask())))
        try await harness.waitForState(id, .running)
        // Simulated crash: the database goes away without a terminal event.
        await harness.store.close()

        let reopened = try Store(path: harness.path)
        let restarted = RunCoordinator(store: reopened, adapters: [FakeAdapter()])
        let report = try await restarted.bootstrap()
        #expect(report.uncertain == [id])
        #expect(try await reopened.attempt(id)?.state == .uncertain)
        #expect(try await restarted.activeRuns().map(\.id) == [id])
        // No handle survives the restart; cancelling does not pretend to stop anything.
        try await restarted.cancel(id, reason: "user")
        #expect(try await reopened.attempt(id)?.state == .uncertain)
    }

    @Test func providerReportedCancellationIsAccepted() async throws {
        let harness = try await Harness()
        let adapter = FakeAdapter { _ in FakeScript(steps: [.emit(.started(sessionID: nil)), .emit(.completed(.cancelled))]) }
        let coordinator = RunCoordinator(store: harness.store, adapters: [adapter])
        let id = try startedID(try await coordinator.start(harness.request(try await harness.newTask())))
        #expect(try await coordinator.waitUntilFinished(id)?.state == .cancelled)
    }
}
