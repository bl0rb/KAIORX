import Domain

/// Contract every provider adapter implements (Plan/laufzeitvertrag.md, "Swift-Schnittstellen").
/// Provider wire objects never cross this boundary.
public protocol AgentAdapter: Sendable {
    var provider: ProviderKind { get }

    /// Version and capability probe. Must not consume inference.
    func probe(_ request: ProbeRequest) async throws -> CapabilitySnapshot

    /// Starts one attempt. The handle exists before the provider confirms a turn. Throwing means
    /// the start failed safely before a turn began.
    func start(_ spec: AttemptSpec) async throws -> any RunHandle

    /// Classifies an attempt from a previous app run.
    func reconcile(_ request: ReconcileRequest) async throws -> ReconcileResult
}

/// A running attempt. `events` is ordered and has exactly one consumer (the persistence path).
/// A stream that ends without `.completed` means the outcome is unknown.
public protocol RunHandle: Sendable {
    var attemptID: AttemptID { get }
    var events: AsyncThrowingStream<AgentEvent, any Error> { get }

    /// Orderly interrupt. Early and repeated calls are allowed.
    func cancel(reason: String) async
}

/// Receives every protocol line of a run (`outgoing`: written to the provider), for the owner's
/// acceptance recording. Lines are raw: the receiver must redact before keeping anything.
public typealias ProtocolLineSink = @Sendable (_ outgoing: Bool, _ line: String) -> Void
