import Domain
import Foundation
import Providers
import Synchronization

/// A provider stand-in that streams text deltas at a fixed rate, like a model writing, and
/// records the instant each event left the provider (the "local receipt" of the beta target).
/// Stop ends the stream with `.completed(.cancelled)` before the next delta.
public final class PacedAdapter: AgentAdapter {
    public let provider: ProviderKind
    let interval: Duration
    let deltas: Int
    private let receipts = Mutex<[AttemptID: [Int: ContinuousClock.Instant]]>([:])

    /// `deltas`: how many text deltas a run writes before it completes on its own.
    public init(provider: ProviderKind = .codex, interval: Duration, deltas: Int) {
        self.provider = provider
        self.interval = interval
        self.deltas = deltas
    }

    public func probe(_ request: ProbeRequest) async throws -> CapabilitySnapshot {
        try await FakeAdapter(provider: provider).probe(request)
    }

    public func reconcile(_ request: ReconcileRequest) async throws -> ReconcileResult { .unknown }

    public func start(_ spec: AttemptSpec) async throws -> any RunHandle {
        let (stream, continuation) = AsyncThrowingStream<AgentEvent, any Error>.makeStream()
        let stop = Mutex(false)
        let attempt = spec.attemptID
        let interval = interval, deltas = deltas
        let producer = Task { [weak self] in
            continuation.yield(.started(sessionID: "bench"))
            var index = 0
            while index < deltas, !stop.withLock({ $0 }) {
                try? await Task.sleep(for: interval)
                if stop.withLock({ $0 }) { break }
                self?.record(attempt, index)
                continuation.yield(.messageDelta(itemID: "m\(index / 200)", text: Self.text(index)))
                index += 1
            }
            continuation.yield(.completed(stop.withLock { $0 } ? .cancelled : .succeeded))
            continuation.finish()
        }
        return PacedHandle(attemptID: attempt, events: stream) {
            stop.withLock { $0 = true }
            _ = producer
        }
    }

    /// The delta text carries its index, so a persisted event maps back to its receipt instant.
    static func text(_ index: Int) -> String { "e\(index) Die Ausgabe des Modells wächst Stück für Stück weiter. " }

    static func index(of event: AgentEvent) -> Int? {
        guard case .messageDelta(_, let text) = event, text.hasPrefix("e"), let space = text.firstIndex(of: " ") else { return nil }
        return Int(text[text.index(after: text.startIndex)..<space])
    }

    private func record(_ attempt: AttemptID, _ index: Int) {
        let now = ContinuousClock.now
        receipts.withLock { $0[attempt, default: [:]][index] = now }
    }

    func receipt(_ attempt: AttemptID, _ index: Int) -> ContinuousClock.Instant? {
        receipts.withLock { $0[attempt]?[index] }
    }
}

struct PacedHandle: RunHandle {
    let attemptID: AttemptID
    let events: AsyncThrowingStream<AgentEvent, any Error>
    let onCancel: @Sendable () -> Void

    func cancel(reason: String) async { onCancel() }
}
