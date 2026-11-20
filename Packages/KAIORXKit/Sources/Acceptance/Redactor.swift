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

    /// What a denylisted value is (for example "Benutzername"), named when a fixture is discarded.
    public var labels: [String: String]

    /// Each path is also replaced in its dashed form (every character except ASCII letters and
    /// digits as `-`), as Claude Code names its project folders.
    public init(denylist: [String], paths: [(String, String)], labels: [String: String] = [:]) {
        self.denylist = denylist.filter { $0.count >= 3 }
        self.labels = labels
        let dashed = paths.compactMap { path, placeholder -> (String, String)? in
            let form = String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            return form == path || path.isEmpty ? nil : (form, placeholder)
        }
        self.paths = (paths + dashed).sorted { $0.0.count > $1.0.count }
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
        if let first = secrets.first {
            throw Failure.privateValueRemains("secret:\(first.kind)" + location(in: text) { !SecretScanner.ranges($0).isEmpty })
        }
        if let hit = denylist.first(where: { Self.containsToken($0, in: text) }) {
            throw Failure.privateValueRemains((labels[hit] ?? "denylist") + location(in: text) { Self.containsToken(hit, in: $0) })
        }
        return prefix + text
    }

    /// Where in a JSON line a check hits: the event type and the key path of the first string
    /// (or key) it hits, as `", assistant: message.content[].text"`. Only keys that look like
    /// protocol vocabulary and pass every check are named; others become `?`. Never the value.
    func location(in text: String, hits: (String) -> Bool) -> String {
        guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return "" }
        func safe(_ key: String) -> Bool {
            key.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,40}$"#, options: .regularExpression) != nil && !hits(key)
                && !denylist.contains { Self.containsToken($0, in: key) }
        }
        func search(_ value: Any, _ path: [String]) -> [String]? {
            switch value {
            case let object as [String: Any]:
                for key in object.keys.sorted() {
                    let name = safe(key) ? key : "?"
                    if hits(key) { return path + [name] }
                    if let found = search(object[key]!, path + [name]) { return found }
                }
                return nil
            case let array as [Any]:
                for element in array { if let found = search(element, path.isEmpty ? ["[]"] : path.dropLast() + [path.last! + "[]"]) { return found } }
                return nil
            case let string as String:
                return hits(string) ? path : nil
            default:
                return nil
            }
        }
        guard let path = search(json, []) else { return "" }
        let type = ((json as? [String: Any])?["type"] as? String).flatMap { $0.range(of: #"^[a-z_]{1,30}$"#, options: .regularExpression) != nil ? $0 : nil }
        return ", " + (type.map { "\($0): " } ?? "") + path.joined(separator: ".")
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
            let identifyingObject = inside || key.map(identityObject) == true
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

    /// Objects that describe a person, account or organisation: everything inside is replaced.
    /// (Protocol objects such as `item` or `thread` keep their content; only their identifiers go.)
    static func identityObject(_ key: String) -> Bool {
        let lower = key.lowercased()
        return ["account", "organization", "organisation", "org", "user", "profile", "workspace", "owner", "member"].contains { lower == $0 || lower.hasSuffix($0) }
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
        return try lines.enumerated().map { index, line in
            do { return try redact(line, placeholders: &placeholders) } catch Failure.privateValueRemains(let what) {
                // "Benutzername, assistant: …" → "Benutzername in Zeile 2, assistant: …"
                let parts = what.split(separator: ",", maxSplits: 1)
                throw Failure.privateValueRemains("\(parts[0]) in Zeile \(index + 1)" + (parts.count > 1 ? ",\(parts[1])" : ""))
            }
        }
    }
}
