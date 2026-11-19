import Domain
import Foundation
import Storage

/// The structured review a reviewer must return (Plan/ARCHITEKTURPLAN.md §4): candidate OID,
/// verdict, and findings with severity, file and line, impact and a checkable suggestion. Free
/// text without a valid location is kept as a comment.
public enum ReviewReport {
    public struct Parsed: Sendable, Equatable {
        public var status: ReviewStatus
        public var summary: String
        public var findings: [FindingDraft]
    }

    /// Instructions appended to the reviewer prompt.
    public static func instructions(candidateOID: String) -> String {
        """
        Answer with exactly one JSON object in a ```json code block (the fences on their own lines):
        {"candidateOID": "\(candidateOID)", "verdict": "approve" | "changes",
         "summary": "<one paragraph>",
         "findings": [{"severity": "blocking" | "major" | "minor", "path": "<file in the diff>", "line": <number>,
                       "impact": "<concrete effect>", "suggestion": "<checkable fix>"}]}
        Use "blocking" only for defects that must not be published. Do not change any files.
        """
    }

    /// Reads the report. Anything that cannot be tied to this candidate is invalid; findings
    /// without a valid location in the changed files become comments, except declared blocking
    /// or major ones, which become major (they need a decision) and keep the review from
    /// approving.
    public static func parse(_ text: String, candidateOID: String, changedPaths: Set<String>) -> Parsed {
        guard let object = jsonObject(in: text) else {
            return Parsed(status: .invalid, summary: "no readable review report", findings: [comment(text)])
        }
        guard object["candidateOID"] as? String == candidateOID else {
            return Parsed(status: .invalid, summary: "review names another commit", findings: [comment(text)])
        }
        let summary = (object["summary"] as? String) ?? ""
        var findings: [FindingDraft] = []
        var declaredBlocking = false
        let entries: [Any]
        switch object["findings"] {
        case nil, is NSNull: entries = []
        case let list as [Any]: entries = list
        default: return Parsed(status: .invalid, summary: "findings are not a list", findings: [comment(text)])
        }
        for item in entries {
            guard let entry = item as? [String: Any] else {
                // Free text in the list is kept as a comment; the other entries still count.
                findings.append(FindingDraft(severity: .comment, path: nil, line: nil, impact: String(describing: item), suggestion: ""))
                continue
            }
            let impact = (entry["impact"] as? String) ?? ""
            let suggestion = (entry["suggestion"] as? String) ?? ""
            let path = entry["path"] as? String
            let line = Self.line(entry["line"])
            let severity = Self.severity(entry["severity"])
            if severity == .blocking { declaredBlocking = true }
            if let severity, severity != .comment, let path, changedPaths.contains(path), let line, line > 0,
               !impact.isEmpty, !suggestion.isEmpty {
                findings.append(FindingDraft(severity: severity, path: path, line: line, impact: impact, suggestion: suggestion))
            } else {
                // Without a valid location in the diff a finding cannot block or be tracked to a
                // line, but a declared blocking or major one still needs the user's decision.
                let serious = severity == .blocking || severity == .major
                findings.append(FindingDraft(
                    severity: serious ? .major : .comment, path: path, line: line,
                    impact: impact.isEmpty ? String(describing: entry) : impact, suggestion: suggestion
                ))
            }
        }
        let verdict = object["verdict"] as? String
        // Judged on what the reviewer declared: a blocking finding anywhere is not an approval.
        let blocking = declaredBlocking
        let status: ReviewStatus = switch verdict {
        case "approve" where !blocking: .approved
        case "approve", "changes": .changesRequested
        default: .invalid
        }
        return Parsed(status: status, summary: summary, findings: findings)
    }

    /// The last ```json block, or the whole text if it is a JSON object. Fences count only as
    /// whole lines, so ``` inside a JSON string does not end the block. Earlier blocks are never
    /// used: a reviewer's later answer replaces its earlier one, and an unreadable or
    /// unterminated last block makes the review invalid.
    static func jsonObject(in text: String) -> [String: Any]? {
        // CRLF and CR answers (Windows-edited imports) read like LF.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var lastBlock: String?
        var current: [String]?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if current == nil, trimmed == "```json" {
                current = []
            } else if current != nil, trimmed == "```" {
                lastBlock = current!.joined(separator: "\n")
                current = nil
            } else {
                current?.append(line)
            }
        }
        // An unterminated last block is the reviewer's last word: unreadable, not an earlier block.
        if current != nil { return nil }
        let candidate = lastBlock ?? text
        guard let data = candidate.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Case-insensitive; a stated but unknown severity ("critical", "high") needs a decision.
    /// A stated severity that is not a known string (a number, a list, "critical") is major.
    static func severity(_ value: Any?) -> FindingSeverity? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else {
            return .major
        }
        return FindingSeverity(rawValue: text) ?? .major
    }

    /// A line is a whole number, not a boolean or a fraction.
    static func line(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double == double.rounded(), abs(double) < 1e9 else { return nil }
        return Int(double)
    }

    static func comment(_ text: String) -> FindingDraft {
        FindingDraft(severity: .comment, path: nil, line: nil, impact: String(text.prefix(2000)), suggestion: "")
    }
}
