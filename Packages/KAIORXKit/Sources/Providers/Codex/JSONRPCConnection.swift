import Foundation
import ProcessHost

/// Bidirectional JSON-RPC over a child's stdin/stdout, one JSON object per line. The Codex App
/// Server omits the `jsonrpc` field on the wire. Requests from the server are answered by the
/// handler; notifications go to the notification handler in arrival order.
actor JSONRPCConnection {
    typealias NotificationHandler = @Sendable (_ method: String, _ params: JSONValue) async -> Void
    /// Returns the `result`, or throws `JSONRPCConnection.Refusal` to answer with an error.
    typealias RequestHandler = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue

    struct Refusal: Error, Sendable {
        var code: Int64
        var message: String
        static func unsupported(_ method: String) -> Refusal { Refusal(code: -32601, message: "\(method) is not supported by KAIORX") }
    }

    struct RemoteError: Error, Equatable, Sendable {
        var method: String
        var code: Int64
        var message: String
    }

    private let process: ManagedProcess
    private var nextID: Int64 = 1
    private var pending: [Int64: (method: String, continuation: CheckedContinuation<JSONValue, any Error>)] = [:]
    private var failure: (any Error)?
    private var notificationHandler: NotificationHandler?
    private var requestHandler: RequestHandler?
    /// Copies of every line sent and received, for contract tests.
    private(set) var transcript: [(outgoing: Bool, line: JSONValue)] = []
    let recordsTranscript: Bool
    /// Outgoing messages in the order they were issued; one drain task writes them.
    private var outbox: [JSONValue] = []
    private var draining = false
    /// Requests that gave up waiting; their late responses are ignored.
    private var timedOut: Set<Int64> = []

    init(process: ManagedProcess, recordsTranscript: Bool = false) {
        self.process = process
        self.recordsTranscript = recordsTranscript
    }

    func setHandlers(notifications: @escaping NotificationHandler, requests: @escaping RequestHandler) {
        notificationHandler = notifications
        requestHandler = requests
    }

    struct Timeout: Error, Equatable, Sendable {
        var method: String
    }

    /// Sends a request and waits for its response, at most `timeout` (then `Timeout`; a late
    /// response is ignored).
    func request(_ method: String, _ params: JSONValue, timeout: Duration? = nil) async throws -> JSONValue {
        if let failure { throw failure }
        let id = nextID
        nextID += 1
        let message: JSONValue = ["id": .int(id), "method": .string(method), "params": params]
        return try await withCheckedThrowingContinuation { continuation in
            // Registered before the write, so the response always finds it.
            pending[id] = (method, continuation)
            enqueue(message)
            if let timeout {
                Task {
                    try? await Task.sleep(for: timeout)
                    self.expire(id)
                }
            }
        }
    }

    private func expire(_ id: Int64) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        timedOut.insert(id)
        entry.continuation.resume(throwing: Timeout(method: entry.method))
    }

    func notify(_ method: String, _ params: JSONValue? = nil) {
        var message: [String: JSONValue] = ["method": .string(method)]
        if let params { message["params"] = params }
        enqueue(.object(message))
    }

    /// Feeds one received line. Throws on a frame that is not valid JSON-RPC.
    func receive(_ line: String) async throws {
        let message: JSONValue
        do { message = try JSONValue.parse(line) } catch { throw ProviderError.protocolViolation("invalid JSON-RPC frame") }
        if recordsTranscript { transcript.append((false, message)) }
        let method = message["method"]?.string
        let id = message["id"]
        switch (method, id) {
        case (nil, .some(let id)):
            if case .int(let number) = id, timedOut.remove(number) != nil { return }
            guard case .int(let number) = id, let entry = pending.removeValue(forKey: number) else {
                throw ProviderError.protocolViolation("response to unknown request \(id)")
            }
            if let error = message["error"] {
                entry.continuation.resume(throwing: RemoteError(
                    method: entry.method, code: Int64(error["code"]?.int ?? 0), message: error["message"]?.string ?? ""
                ))
            } else if let result = message["result"] {
                entry.continuation.resume(returning: result)
            } else {
                throw ProviderError.protocolViolation("response without result or error")
            }
        case (.some(let method), .some(let id)):
            let params = message["params"] ?? .null
            let handler = requestHandler
            // Answered in order, but without blocking the reader.
            let response: JSONValue
            do {
                guard let handler else { throw Refusal.unsupported(method) }
                response = ["id": id, "result": try await handler(method, params)]
            } catch let refusal as Refusal {
                response = ["id": id, "error": ["code": .int(refusal.code), "message": .string(refusal.message)]]
            } catch {
                response = ["id": id, "error": ["code": -32603, "message": .string(String(describing: error))]]
            }
            enqueue(response)
        case (.some(let method), nil):
            await notificationHandler?(method, message["params"] ?? .null)
        case (nil, nil):
            throw ProviderError.protocolViolation("frame without method or id")
        }
    }

    /// Fails every open request (process ended or the protocol broke).
    func close(with error: any Error) {
        failure = error
        // The handlers capture the run handle; dropping them ends that reference cycle.
        notificationHandler = nil
        requestHandler = nil
        for (_, entry) in pending { entry.continuation.resume(throwing: error) }
        pending.removeAll()
    }

    private func enqueue(_ message: JSONValue) {
        if recordsTranscript { transcript.append((true, message)) }
        outbox.append(message)
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !outbox.isEmpty {
            let message = outbox.removeFirst()
            do {
                try await process.send(try message.line())
            } catch {
                close(with: error)
            }
        }
        draining = false
    }
}
