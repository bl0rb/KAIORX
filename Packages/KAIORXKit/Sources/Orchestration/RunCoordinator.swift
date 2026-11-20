import Domain
import Providers
import Storage

public struct StartRequest: Sendable, Equatable {
    /// Idempotency key: two windows sending the same request start one attempt.
    public var commandID: CommandID
    public var attemptID: AttemptID
    public var taskID: TaskID
    public var projectID: ProjectID
    public var role: AttemptRole
    public var provider: ProviderKind
    public var modelProfile: String
    public var model: String
    public var effort: String?
    public var workingDirectory: String?
    public var prompt: String

    public init(
        commandID: CommandID = CommandID(), attemptID: AttemptID = AttemptID(), taskID: TaskID,
        projectID: ProjectID, role: AttemptRole = .author, provider: ProviderKind, modelProfile: String,
        model: String, effort: String? = nil, workingDirectory: String? = nil, prompt: String
    ) {
        self.commandID = commandID
        self.attemptID = attemptID
        self.taskID = taskID
        self.projectID = projectID
        self.role = role
        self.provider = provider
        self.modelProfile = modelProfile
        self.model = model
        self.effort = effort
        self.workingDirectory = workingDirectory
        self.prompt = prompt
    }
}

public enum StartResult: Sendable, Equatable {
    case started(AttemptID)
    /// The command had already been applied; nothing new was started.
    case alreadyRequested(AttemptID)
    /// The adapter refused before a turn began; the attempt is `failed`.
    case failedToStart(AttemptID, reason: String)
    /// `cancel` won the race against `start`; no adapter was started.
    case cancelledBeforeStart(AttemptID)
}

public enum CoordinatorError: Error, Equatable, Sendable {
    case attemptNotFound(AttemptID)
    case transitionFailed(AttemptID)
}

/// Starts attempts on adapters and is the single consumer of their event streams. Everything an
/// adapter reports goes through `Store`, so the UI reads only persisted state.
///
/// The actor is reentrant at every `await`, so `start`, `cancel` and the event consumers can
/// interleave. Each state change is therefore decided from the state read right before it is
/// written, and retried when another writer got there first.
public actor RunCoordinator {
    private let store: Store
    private let adapters: [ProviderKind: any AgentAdapter]
    private var handles: [AttemptID: any RunHandle] = [:]
    private var consumers: [AttemptID: Task<Void, Never>] = [:]

    public init(store: Store, adapters: [any AgentAdapter]) {
        self.store = store
        var byProvider: [ProviderKind: any AgentAdapter] = [:]
        for adapter in adapters { byProvider[adapter.provider] = adapter }
        self.adapters = byProvider
    }

    /// Call once at app start, before any `start`.
    public func bootstrap() async throws -> RecoveryReport {
        try await store.recoverAfterRestart()
    }

    public func start(_ request: StartRequest) async throws -> StartResult {
        let spec = AttemptSpec(
            attemptID: request.attemptID, taskID: request.taskID, projectID: request.projectID,
            role: request.role, provider: request.provider, runMode: .automatic,
            modelProfile: request.modelProfile, effectiveModel: request.model, effort: request.effort,
            workingDirectory: request.workingDirectory, prompt: request.prompt
        )
        let reservation = AttemptReservation(
            attemptID: request.attemptID, taskID: request.taskID, projectID: request.projectID,
            role: request.role, provider: request.provider, mode: .automatic, model: request.model,
            effort: request.effort, specDigest: try spec.digest()
        )
        let outcome = try await store.execute(Command(id: request.commandID, .reserveAttempt(reservation)))
        let id = request.attemptID
        if outcome.isReplay { return .alreadyRequested(id) }
        return try await launch(id, spec: spec)
    }

    /// Starts an attempt that is already `reserved` (for example by the scheduler's atomic
    /// reservation) on its adapter. A cancel that won the race ends it without a start.
    public func launch(_ id: AttemptID, spec: AttemptSpec) async throws -> StartResult {
        guard let adapter = adapters[spec.provider] else {
            let state = try await transition(id, errorClass: "adapterUnavailable") { $0 == .reserved ? .failed : nil }
            if state == .cancelled { return .cancelledBeforeStart(id) }
            return .failedToStart(id, reason: "No adapter for \(spec.provider.rawValue)")
        }
        let state = try await transition(id) { $0 == .reserved ? .starting : nil }
        guard state == .starting else { return .cancelledBeforeStart(id) }

        let handle: any RunHandle
        do {
            handle = try await adapter.start(spec)
        } catch {
            // Safe failure before a turn; a cancel requested meanwhile ends the same way.
            _ = try await transition(id, errorClass: "startFailed") { $0.allowsTransition(to: .failed) ? .failed : nil }
            return .failedToStart(id, reason: String(describing: error))
        }
        handles[id] = handle
        consumers[id] = Task { await self.consume(id, handle) }

        // `cancel` may have run while `adapter.start` was suspended; it found no handle then.
        if try await store.attempt(id)?.state == .cancelling {
            await handle.cancel(reason: "cancelledDuringStart")
        }
        return .started(id)
    }

    /// Requests an orderly stop. A reserved attempt is cancelled at once; a started one stays
    /// `cancelling` until the adapter confirms. Repeated calls and calls on finished attempts
    /// are allowed and change nothing.
    public func cancel(_ id: AttemptID, reason: String) async throws {
        let state = try await transition(id, errorClass: nil) { current in
            switch current {
            case .reserved: .cancelled
            case .starting, .running, .awaitingApproval: .cancelling
            case .cancelling, .uncertain, .succeeded, .failed, .cancelled: nil
            }
        }
        if state == .cancelling, let handle = handles[id] {
            await handle.cancel(reason: reason)
        }
    }

    /// Waits until the event stream of a started attempt has been fully persisted.
    public func waitUntilFinished(_ id: AttemptID) async throws -> AttemptRecord? {
        if let consumer = consumers[id] { await consumer.value }
        return try await store.attempt(id)
    }

    public func activeRuns() async throws -> [AttemptRecord] {
        try await store.activeAttempts()
    }

    private func consume(_ id: AttemptID, _ handle: any RunHandle) async {
        do {
            for try await event in handle.events {
                do {
                    _ = try await store.ingest(event, attemptID: id)
                } catch {
                    // The event could not be journaled: a transition the contract forbids, or
                    // storage failed. Stop the provider and leave the attempt for review.
                    let errorClass = Self.isProtocolViolation(error) ? "protocolViolation" : "persistenceFailure"
                    await handle.cancel(reason: errorClass)
                    await markUncertain(id, errorClass: errorClass)
                    break
                }
            }
            await markUncertain(id, errorClass: "streamEndedWithoutCompletion")
        } catch {
            await markUncertain(id, errorClass: "streamError")
        }
        handles[id] = nil
        consumers[id] = nil
    }

    private static func isProtocolViolation(_ error: any Error) -> Bool {
        if error is DomainError { return true }
        if case .unexpectedEvent = error as? StoreError { return true }
        return false
    }

    /// Marks a non-terminal attempt `uncertain`; no-op once it is terminal.
    private func markUncertain(_ id: AttemptID, errorClass: String) async {
        _ = try? await transition(id, errorClass: errorClass) { $0.allowsTransition(to: .uncertain) ? .uncertain : nil }
    }

    /// Reads the attempt, asks `decide` for the target state (nil: leave it), writes it with the
    /// version just read and retries if a concurrent writer changed the attempt. Returns the
    /// state the attempt is in afterwards.
    @discardableResult
    private func transition(
        _ id: AttemptID, errorClass: String? = nil, _ decide: (AttemptState) -> AttemptState?
    ) async throws -> AttemptState {
        for _ in 0..<10 {
            guard let attempt = try await store.attempt(id) else { throw CoordinatorError.attemptNotFound(id) }
            guard let target = decide(attempt.state), target != attempt.state else { return attempt.state }
            do {
                try await store.execute(Command(.transitionAttempt(
                    id: id, to: target, expectedVersion: attempt.version, errorClass: errorClass
                )))
                return target
            } catch let error as StoreError where error.isVersionConflict {
                continue
            }
        }
        throw CoordinatorError.transitionFailed(id)
    }
}
