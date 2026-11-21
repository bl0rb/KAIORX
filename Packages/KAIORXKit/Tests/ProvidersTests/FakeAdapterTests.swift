import Domain
import Testing
@testable import Providers

func spec() -> AttemptSpec {
    AttemptSpec(
        attemptID: AttemptID(), taskID: TaskID(), projectID: ProjectID(), role: .author, provider: .fake,
        runMode: .automatic, modelProfile: "standard", effectiveModel: "fake", prompt: "p"
    )
}

func collect(_ handle: any RunHandle) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in handle.events { events.append(event) }
    return events
}

@Suite struct FakeAdapterTests {
    @Test func successScriptEmitsInOrder() async throws {
        let handle = try await FakeAdapter().start(spec())
        let events = try await collect(handle)
        #expect(events.map(\.kind) == [.attemptStarted, .messageDelta, .messageFinal, .usageObserved, .attemptCompleted])
        #expect(events.last == .completed(.succeeded))
    }

    /// The script is parked in `waitForCancel` (its `started` was consumed and nothing else
    /// arrives) before `cancel` resumes the waiter.
    @Test func cancelResumesAParkedWaiter() async throws {
        let handle = try await FakeAdapter { _ in .waitsForCancel }.start(spec())
        var iterator = handle.events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(sessionID: "fake-session"))
        await (handle as! FakeRunHandle).waitUntilParked()
        await handle.cancel(reason: "test")
        #expect(try await iterator.next() == .completed(.cancelled))
        #expect(try await iterator.next() == nil)
    }

    /// Order between `cancel` and reaching `waitForCancel` is up to the scheduler; both end the run.
    @Test func cancelRightAfterStartEndsTheRun() async throws {
        let handle = try await FakeAdapter { _ in FakeScript(steps: [.emit(.started(sessionID: nil)), .waitForCancel]) }
            .start(spec())
        await handle.cancel(reason: "early")
        await handle.cancel(reason: "repeated")
        #expect(try await collect(handle) == [.started(sessionID: nil), .completed(.cancelled)])
    }

    @Test func gateOpenedBeforeWaitDoesNotBlock() async {
        let gate = CancelGate()
        await gate.open()
        await gate.wait()
        #expect(await gate.isOpen)
        #expect(await !gate.hasWaiter)
    }

    @Test func gateOpenResumesAParkedWaiter() async {
        let gate = CancelGate()
        let waiter = Task { await gate.wait() }
        while await !gate.hasWaiter { await Task.yield() }
        await gate.open()
        await waiter.value
        #expect(await !gate.hasWaiter)
    }

    @Test func startErrorThrowsBeforeAnyTurn() async {
        let adapter = FakeAdapter { _ in FakeScript(startError: "no binary", steps: []) }
        await #expect(throws: FakeAdapterError(message: "no binary")) { _ = try await adapter.start(spec()) }
    }

    @Test func failingStreamThrows() async throws {
        let handle = try await FakeAdapter { _ in FakeScript(steps: [.emit(.started(sessionID: nil)), .fail("broken frame")]) }
            .start(spec())
        await #expect(throws: FakeAdapterError(message: "broken frame")) { _ = try await collect(handle) }
    }

    @Test func endWithoutCompletion() async throws {
        let handle = try await FakeAdapter { _ in FakeScript(steps: [.emit(.started(sessionID: nil)), .end]) }.start(spec())
        #expect(try await collect(handle) == [.started(sessionID: nil)])
    }

    @Test func probeAndReconcileNeedNoRun() async throws {
        let snapshot = try await FakeAdapter().probe(ProbeRequest(profile: "default", mode: .automatic))
        #expect(snapshot.provider == .fake)
        #expect(snapshot.authState == .signedIn)
        #expect(try await FakeAdapter().reconcile(ReconcileRequest(attemptID: AttemptID(), lastKnownState: .running, sessionHandle: nil)) == .unknown)
    }
}
