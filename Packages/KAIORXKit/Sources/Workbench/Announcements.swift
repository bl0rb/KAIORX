import Domain
import Foundation

/// VoiceOver hears state changes bundled (Plan/macos-und-git.md): which attempts changed into a
/// state worth saying, collected and spoken at most once per interval as one sentence.
public enum Announcements {
    static let spoken: Set<AttemptState> = [.running, .awaitingApproval, .cancelling, .succeeded, .failed, .cancelled, .uncertain]

    /// Sentences for attempts whose state changed between two projections, and for the steps of
    /// the candidate chain (ADR 0011): a result sealed, a candidate built or conflicted, a review
    /// arrived.
    public static func changes(from old: WorkspaceState, to new: WorkspaceState) -> [String] {
        let attempts = new.attempts.values.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { attempt -> String? in
            // A new attempt counts too when it is first seen in a state worth saying (reserved and
            // failed within one projection step).
            guard spoken.contains(attempt.state), old.attempts[attempt.id]?.state != attempt.state else { return nil }
            let task = new.tasks[attempt.taskID]?.title ?? "Aufgabe"
            return "\(task): \(Labels.attempt(attempt.state).text)"
        }
        return attempts + chainChanges(from: old, to: new)
    }

    static func chainChanges(from old: WorkspaceState, to new: WorkspaceState) -> [String] {
        func title(_ task: TaskID?) -> String { task.flatMap { new.tasks[$0]?.title } ?? "Aufgabe" }
        var sentences: [String] = []
        for tree in new.worktrees.values.sorted(by: { $0.id.uuidString < $1.id.uuidString })
        where tree.kind == .author && tree.sealStatus != nil && old.worktrees[tree.id]?.sealStatus == nil {
            sentences.append("\(title(tree.attemptID.flatMap { new.attempts[$0]?.taskID })): Ergebnis versiegelt")
        }
        for candidate in new.candidates.values.sorted(by: { $0.id.uuidString < $1.id.uuidString })
        where old.candidates[candidate.id]?.state != candidate.state {
            switch candidate.state {
            case .built: sentences.append("\(title(candidate.taskID)): Kandidat gebaut")
            case .conflicted: sentences.append("\(title(candidate.taskID)): Kandidat hat Konflikte")
            default: break
            }
        }
        for (candidateID, reviews) in new.reviews.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let known = Set((old.reviews[candidateID] ?? []).map(\.id))
            if reviews.contains(where: { !known.contains($0.id) }) {
                sentences.append("\(title(new.candidates[candidateID]?.taskID)): Review eingegangen")
            }
        }
        return sentences
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
