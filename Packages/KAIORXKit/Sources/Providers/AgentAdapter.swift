import Domain
import Foundation

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
/// Receives a provider process's standard error line by line (owner's acceptance only).
public typealias DiagnosticLineSink = @Sendable (_ line: String) -> Void

/// Splits standard error into lines for a `DiagnosticLineSink`. A line longer than 4 KiB keeps
/// only its start, cut back to a word or path boundary and marked with `…`: a private value is
/// never split across two recorded pieces (the recording is redacted line by line).
struct DiagnosticLines {
    static let limit = 4096
    let sink: DiagnosticLineSink?
    private var pending = Data()
    /// The rest of an overlong line is being dropped until its line break.
    private var skipping = false

    init(sink: DiagnosticLineSink?) {
        self.sink = sink
    }

    mutating func append(_ data: Data) {
        guard let sink else { return }
        pending.append(data)
        while let end = pending.firstIndex(of: 0x0A) {
            if !skipping { sink(Self.line(pending[pending.startIndex..<end])) }
            skipping = false
            pending = Data(pending[pending.index(after: end)...])
        }
        if pending.count > Self.limit {
            if !skipping { sink(Self.line(pending)) }
            skipping = true
            pending = Data()
        }
    }

    /// Hands over an unterminated last line; later calls do nothing.
    mutating func finish() {
        guard let sink, !pending.isEmpty else { return }
        if !skipping { sink(Self.line(pending)) }
        pending = Data()
    }

    static func line(_ bytes: Data) -> String {
        guard bytes.count > limit else { return String(decoding: bytes, as: UTF8.self) }
        let head = bytes.prefix(limit)
        // Back to the last space, tab, quote or slash, so the cut never lands inside a name.
        let boundaries: Set<UInt8> = [0x20, 0x09, 0x22, 0x27, 0x2F]
        let cut = head.lastIndex { boundaries.contains($0) }.map { head[head.startIndex...$0] } ?? Data()
        return String(decoding: cut, as: UTF8.self) + "…"
    }
}
