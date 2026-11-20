import Foundation
import Memory

/// Turns raw protocol lines into fixtures that can be committed (Plan/anbieter.md: auth fixtures
/// are redacted). Fails closed: after replacing identifiers and secrets, a deny scan looks for
/// every literal the kit knows to be private (user name, home, host, canaries); one hit and
/// nothing is written.
public struct FixtureRedactor: Sendable {
    /// Literal values that must never appear in a fixture (never written themselves).
    public var denylist: [String]
    /// Replaced by a stable placeholder wherever they appear (home, worktree, temp folders).
    public var paths: [(String, String)]

    public init(denylist: [String], paths: [(String, String)]) {
        self.denylist = denylist.filter { $0.count >= 3 }
        self.paths = paths.sorted { $0.0.count > $1.0.count }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// A private value survived; the fixture is not written. Only the kind is named.
        case privateValueRemains(String)
    }

    /// Keys whose string values identify a person, account, session or machine.
    static let identifyingKeys = ["id", "uuid", "session", "thread", "turn", "item", "account", "org", "organization", "email", "user",
                                  "token", "workspace", "request", "message_id", "messageid", "parent", "cwd", "path", "label"]

    static let patterns: [(String, String)] = [
        (#"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, "<jwt>"),
        (#"\bsk-[A-Za-z0-9_\-]{12,}"#, "<secret>"),
        (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, "<uuid>"),
        (#"\b[0-9a-fA-F]{32,}\b"#, "<hex>"),
    ]

    /// One redacted line, or a failure if a private value remains.
    public func redact(_ line: String, placeholders: inout [String: String]) throws -> String {
        // Recorded lines carry a direction prefix ("> " sent, "< " received); the JSON follows it.
        var prefix = ""
        var text = line
        if line.hasPrefix("> ") || line.hasPrefix("< ") {
            prefix = String(line.prefix(2))
            text = String(line.dropFirst(2))
        }
        for (path, placeholder) in paths where !path.isEmpty {
            text = text.replacingOccurrences(of: path, with: placeholder)
        }
        if let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            let cleaned = Self.walk(json, key: nil, placeholders: &placeholders)
            if let out = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) {
                text = String(decoding: out, as: UTF8.self)
            }
        }
        for (pattern, replacement) in Self.patterns {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        let secrets = SecretScanner.ranges(text)
        if !secrets.isEmpty { throw Failure.privateValueRemains("secret:\(secrets[0].kind)") }
        if denylist.contains(where: { Self.containsToken($0, in: text) }) { throw Failure.privateValueRemains("denylist") }
        return prefix + text
    }

    /// A denylisted literal as a whole token (a short user name like `kai` must not match `kaiorx`).
    static func containsToken(_ literal: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: literal)
        return text.range(of: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Replaces string values under identifying keys (or anywhere inside an identifying object,
    /// such as `organization.name`) with stable placeholders (`<session-1>`).
    static func walk(_ value: Any, key: String?, placeholders: inout [String: String], inside: Bool = false) -> Any {
        switch value {
        case let object as [String: Any]:
            let identifyingObject = inside || key.map(identifying) == true
            var result: [String: Any] = [:]
            for (k, v) in object { result[k] = walk(v, key: k, placeholders: &placeholders, inside: identifyingObject) }
            return result
        case let array as [Any]:
            return array.map { walk($0, key: key, placeholders: &placeholders, inside: inside) }
        case let string as String:
            guard let key, !vocabulary(key), inside || identifying(key), !string.isEmpty else { return string }
            if let existing = placeholders[string] { return existing }
            let kind = key.lowercased().replacingOccurrences(of: "_", with: "")
            let placeholder = "<\(kind)-\(placeholders.count + 1)>"
            placeholders[string] = placeholder
            return placeholder
        default:
            return value
        }
    }

    /// Protocol vocabulary (event types, roles, plans, tool names): kept even inside an
    /// identifying object.
    static func vocabulary(_ key: String) -> Bool {
        ["type", "subtype", "role", "method", "status", "model", "kind", "stop_reason", "tool_name", "toolname", "plantype", "plan_type",
         "subscriptiontype", "subscription_type", "authmethod", "auth_method"].contains(key.lowercased())
    }

    static func identifying(_ key: String) -> Bool {
        let lower = key.lowercased()
        if vocabulary(key) || lower == "name" { return false }
        // Display names of people, accounts, organisations and workspaces.
        if lower.hasSuffix("name") || lower.hasSuffix("_name") { return true }
        return identifyingKeys.contains { lower == $0 || lower.hasSuffix($0) || lower.hasSuffix($0 + "id") || lower.hasSuffix("_" + $0) }
    }

    /// Redacts all lines; any failure means no fixture at all.
    public func redact(lines: [String]) throws -> [String] {
        var placeholders: [String: String] = [:]
        return try lines.map { try redact($0, placeholders: &placeholders) }
    }
}
