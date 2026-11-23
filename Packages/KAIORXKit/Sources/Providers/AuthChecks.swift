import Foundation

/// Whether a run would use a subscription plan and nothing else (Plan/anbieter.md §3: a run that
/// is not provably subscription-only starts no automatic job).
public enum SubscriptionVerdict: Sendable, Equatable {
    /// Signed in with a plan, no other billing source seen.
    case subscription(plan: String?)
    /// Not signed in.
    case signedOut
    /// Another billing source (API key, cloud provider, gateway) is active or possible.
    case otherBilling(String)
    /// The output could not be judged; the owner decides with the redacted output in front of them.
    case unclear(String)

    public var allowsRun: Bool { if case .subscription = self { true } else { false } }
}

/// `claude auth status --json`. The field names are not published; this judges conservatively:
/// a recognised API-key or cloud source is other billing, a missing login is signed out, a plan
/// is only accepted when named. The fixtures of the owner's run pin the real fields (ADR 0008).
public struct ClaudeAuthStatus: Sendable, Equatable {
    public var output: String
    public var exitCode: Int32

    public init(output: String, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }

    public var json: JSONValue? { try? JSONValue.parse(output.trimmingCharacters(in: .whitespacesAndNewlines)) }

    public var verdict: SubscriptionVerdict {
        guard let json, case .object(let root) = json else {
            return exitCode == 0 ? .unclear("keine JSON-Ausgabe") : .signedOut
        }
        let flat = Self.flatten(root)
        func value(_ keys: [String]) -> JSONValue? {
            flat.first { key, _ in keys.contains { key.lowercased().hasSuffix($0) } }?.value
        }
        if let loggedIn = value(["loggedin", "logged_in", "authenticated"]), loggedIn == .bool(false) { return .signedOut }
        // Any API key indication (a source string, a flag, a number, a list), or a cloud/gateway
        // provider, means another billing path.
        for (key, entry) in flat {
            let lower = key.lowercased()
            let text = entry.string?.lowercased() ?? ""
            if lower.contains("apikey") || lower.contains("api_key") {
                switch entry {
                case .null, .bool(false): break
                case .string: if !text.isEmpty, text != "none" { return .otherBilling(key) }
                case .array(let items): if !items.isEmpty { return .otherBilling(key) }
                case .int(let number): if number != 0 { return .otherBilling(key) }
                default: return .otherBilling(key)
                }
            }
            if ["bedrock", "vertex", "foundry", "gateway"].contains(where: { text.contains($0) || lower.contains($0) && entry == .bool(true) }) {
                return .otherBilling(key)
            }
        }
        let method = value(["authmethod", "auth_method", "authtype", "auth_type", "method"])?.string?.lowercased()
        if let method, method.contains("api") || method.contains("key") { return .otherBilling("authMethod") }
        // A failed status command is never a confirmation, whatever it printed.
        guard exitCode == 0 else { return .unclear("Statusbefehl endete mit \(exitCode)") }
        let plan = value(["subscriptiontype", "subscription_type", "plan", "plantype", "plan_type", "subscription"])?.string
        if let plan, !plan.isEmpty { return .subscription(plan: plan) }
        if method?.contains("oauth") == true || method?.contains("claude.ai") == true || method?.contains("subscription") == true {
            return .unclear("Anmeldung ohne erkennbaren Plan")
        }
        return .unclear("kein Plan erkennbar")
    }

    /// `a.b.c` keys of every leaf.
    static func flatten(_ object: [String: JSONValue], prefix: String = "") -> [(key: String, value: JSONValue)] {
        object.sorted { $0.key < $1.key }.flatMap { key, value -> [(key: String, value: JSONValue)] in
            let full = prefix.isEmpty ? key : prefix + "." + key
            if case .object(let inner) = value { return flatten(inner, prefix: full) }
            if case .array(let items) = value {
                // Objects in lists are searched too; the list itself stays visible as a value.
                return [(full, value)] + items.enumerated().flatMap { index, item -> [(key: String, value: JSONValue)] in
                    if case .object(let inner) = item { return flatten(inner, prefix: "\(full).\(index)") }
                    return []
                }
            }
            return [(full, value)]
        }
    }
}

/// `account/read` and `account/rateLimits/read` of the Codex app server (schema of 0.170.0).
public struct CodexAccountReport: Sendable, Equatable {
    public var account: JSONValue
    public var rateLimits: JSONValue?

    public init(account: JSONValue, rateLimits: JSONValue?) {
        self.account = account
        self.rateLimits = rateLimits
    }

    /// Paid ChatGPT plans billed as a subscription (schema 0.170.0). Usage-based, automation and
    /// unknown plans are not accepted: the owner sees them as unclear.
    static let plans: Set<String> = ["go", "plus", "pro", "prolite", "promax", "team", "business", "edu"]

    public var verdict: SubscriptionVerdict {
        guard let account = account["account"], account != .null else { return .signedOut }
        let type = account["type"]?.string ?? ""
        guard type == "chatgpt" else { return .otherBilling("account.type=\(type)") }
        guard let plan = account["planType"]?.string else { return .unclear("ChatGPT ohne Plan") }
        guard Self.plans.contains(plan.lowercased()) else { return .unclear("Plan \(plan)") }
        return .subscription(plan: plan)
    }
}
