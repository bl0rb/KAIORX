import CryptoKit
import Foundation

/// Event type of the internal event log v1. An open set: unknown kinds read from storage are kept,
/// not rejected.
public struct EventKind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let projectOpened: EventKind = "project.opened"
    public static let jobCreated: EventKind = "job.created"
    public static let jobStateChanged: EventKind = "job.stateChanged"
    public static let taskCreated: EventKind = "task.created"
    public static let taskStateChanged: EventKind = "task.stateChanged"
    public static let attemptReserved: EventKind = "attempt.reserved"
    public static let attemptStateChanged: EventKind = "attempt.stateChanged"
    public static let attemptStarted: EventKind = "attempt.started"
    public static let attemptCompleted: EventKind = "attempt.completed"
    public static let messageDelta: EventKind = "message.delta"
    public static let messageFinal: EventKind = "message.final"
    public static let toolStarted: EventKind = "tool.started"
    public static let toolEnded: EventKind = "tool.ended"
    public static let usageObserved: EventKind = "usage.observed"
    public static let providerDiagnostic: EventKind = "provider.diagnostic"
    public static let recoveryRequired: EventKind = "recovery.required"
    public static let planProposed: EventKind = "plan.proposed"
    public static let planAccepted: EventKind = "plan.accepted"
    public static let taskReady: EventKind = "task.ready"
    public static let taskBlocked: EventKind = "task.blocked"
    public static let policyDecided: EventKind = "policy.decided"
    public static let quotaBlocked: EventKind = "quota.blocked"
    public static let quotaReleased: EventKind = "quota.released"
    public static let quotaObserved: EventKind = "quota.observed"
    public static let memoryDispatched: EventKind = "memory.dispatched"
    public static let memoryRevoked: EventKind = "memory.revoked"
    public static let contentPurged: EventKind = "content.purged"
}

public enum Canonical {
    /// Deterministic JSON (sorted keys) for digests and payloads.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
