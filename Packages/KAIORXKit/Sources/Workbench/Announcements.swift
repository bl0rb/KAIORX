import Domain
import Foundation

/// VoiceOver hears state changes bundled (Plan/macos-und-git.md): which attempts changed into a
/// state worth saying, collected and spoken at most once per interval as one sentence.
public enum Announcements {
    static let spoken: Set<AttemptState> = [.running, .awaitingApproval, .cancelling, .succeeded, .failed, .cancelled, .uncertain]

    /// Sentences for attempts whose state changed between two projections.
    public static func changes(from old: WorkspaceState, to new: WorkspaceState) -> [String] {
        new.attempts.values.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { attempt in
            // A new attempt counts too when it is first seen in a state worth saying (reserved and
            // failed within one projection step).
            guard spoken.contains(attempt.state), old.attempts[attempt.id]?.state != attempt.state else { return nil }
            let task = new.tasks[attempt.taskID]?.title ?? "Aufgabe"
            return "\(task): \(Labels.attempt(attempt.state).text)"
        }
    }
}

/// Collects sentences and releases them as one announcement per interval.
public struct AnnouncementBatcher: Sendable {
    public let interval: Int64
    private var pending: [String] = []
    private var lastSpoken: Int64?

    public init(interval: Int64 = 1_500) {
        self.interval = interval
    }

    public mutating func add(_ sentences: [String]) {
        for sentence in sentences where !pending.contains(sentence) { pending.append(sentence) }
    }

    /// The announcement to speak now, if any.
    public mutating func flush(at now: Int64) -> String? {
        guard !pending.isEmpty, lastSpoken.map({ now - $0 >= interval }) ?? true else { return nil }
        defer {
            pending = []
            lastSpoken = now
        }
        return pending.count <= 3 ? pending.joined(separator: ". ") : "\(pending.count) Läufe haben ihren Zustand geändert"
    }
}
