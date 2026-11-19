import Domain

/// Scripted behaviour of one fake attempt. Steps run in order; nothing depends on wall-clock time.
public struct FakeScript: Sendable {
    public enum Step: Sendable {
        case emit(AgentEvent)
        /// Blocks until `cancel` is called, then completes with `.cancelled`.
        case waitForCancel
        /// The stream fails with `FakeAdapterError`.
        case fail(String)
        /// The stream ends without a terminal event.
        case end
    }

    /// If set, `start` throws before any turn begins.
    public var startError: String?
    public var steps: [Step]

    public init(startError: String? = nil, steps: [Step]) {
        self.startError = startError
        self.steps = steps
    }

    public static func success(text: String = "ok") -> FakeScript {
        FakeScript(steps: [
            .emit(.started(sessionID: "fake-session")),
            .emit(.messageDelta(itemID: "m1", text: text)),
            .emit(.messageFinal(itemID: "m1", text: text)),
            .emit(.usage(UsageSample(inputTokens: 10, outputTokens: 5, cachedTokens: 0))),
            .emit(.completed(.succeeded)),
        ])
    }

    public static let waitsForCancel = FakeScript(steps: [
        .emit(.started(sessionID: "fake-session")),
        .waitForCancel,
    ])
}

public struct FakeAdapterError: Error, Equatable, Sendable {
    public let message: String
}

/// Deterministic adapter for local tests and the development shell. Never starts a process.
public final class FakeAdapter: AgentAdapter {
    public let provider: ProviderKind = .fake
    private let script: @Sendable (AttemptSpec) -> FakeScript

    public init(script: @escaping @Sendable (AttemptSpec) -> FakeScript = { _ in .success() }) {
        self.script = script
    }

    public func probe(_ request: ProbeRequest) async throws -> CapabilitySnapshot {
        CapabilitySnapshot(
            provider: .fake, binaryVersion: "fake-1", authState: .signedIn, planMode: "fake",
            runModes: [.automatic], roles: AttemptRole.allCases, supportsStreaming: true,
            supportsUsage: true, supportsApprovals: false, supportsResume: false
        )
    }

    public func start(_ spec: AttemptSpec) async throws -> any RunHandle {
        let script = script(spec)
        if let startError = script.startError { throw FakeAdapterError(message: startError) }
        return FakeRunHandle(attemptID: spec.attemptID, steps: script.steps)
    }

    public func reconcile(_ request: ReconcileRequest) async throws -> ReconcileResult {
        .unknown
    }
}

final class FakeRunHandle: RunHandle {
    let attemptID: AttemptID
    let events: AsyncThrowingStream<AgentEvent, any Error>
    private let gate = CancelGate()

    init(attemptID: AttemptID, steps: [FakeScript.Step]) {
        self.attemptID = attemptID
        let (stream, continuation) = AsyncThrowingStream<AgentEvent, any Error>.makeStream()
        self.events = stream
        let gate = self.gate
        Task {
            for step in steps {
                switch step {
                case .emit(let event):
                    continuation.yield(event)
                case .waitForCancel:
                    await gate.wait()
                    continuation.yield(.completed(.cancelled))
                    continuation.finish()
                    return
                case .fail(let message):
                    continuation.finish(throwing: FakeAdapterError(message: message))
                    return
                case .end:
                    continuation.finish()
                    return
                }
            }
            continuation.finish()
        }
    }

    func cancel(reason: String) async {
        await gate.open()
    }

    /// Test hook: returns once the script waits in `waitForCancel`.
    func waitUntilParked() async {
        while await !gate.hasWaiter { await Task.yield() }
    }
}

/// One-shot latch: `wait` returns once `open` has been called, before or after.
actor CancelGate {
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var hasWaiter: Bool { !waiters.isEmpty }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
