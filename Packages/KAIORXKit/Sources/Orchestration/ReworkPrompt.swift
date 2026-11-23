import Domain
import Foundation
import Memory
import Storage

/// The user's reason for sending a task's last result back, as the next author prompt carries it
/// (ADR 0011, rework reason). The reason is the user's own guidance, so it is not marked as
/// untrusted like memory or diffs; the fence only keeps a multi-line reason from looking like
/// further prompt sections. A forgotten reason and one that looks like a secret (ADR 0006 §2)
/// never reach a prompt.
public enum ReworkPrompt {
    /// The most characters of the reason a prompt carries.
    public static let limit = 2_000

    /// Whether the reason stays out of the prompt: forgotten, or matching a secret pattern.
    public static func isWithheld(_ reason: ReworkReason) -> Bool {
        reason.text == Store.purgedText || !SecretScanner.ranges(reason.text).isEmpty
    }

    /// The prompt lines for the reason; empty when it is withheld.
    public static func lines(_ reason: ReworkReason?) -> [String] {
        guard let reason, !isWithheld(reason) else { return [] }
        let text = bounded(reason.text)
        let fence = String(repeating: "`", count: max(3, IntegrationService.longestBacktickRun(text) + 1))
        let header = switch reason.source {
        case .rejected: "The user rejected the candidate built from the last result of this task. Their reason, between the fences:"
        case .discarded: "The user discarded the last result of this task. Their reason, between the fences:"
        }
        return [
            header, fence, text, fence,
            "You start again from the current integration state; the earlier result is not in your working directory. Take the reason into account.",
        ]
    }

    /// The text cut to `limit` characters, marked when cut.
    static func bounded(_ text: String) -> String {
        text.count > limit ? String(text.prefix(limit)) + " […]" : text
    }
}
