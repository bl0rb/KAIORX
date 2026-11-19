import Domain
import Foundation

/// Command line and environment of the automatic Claude Code profile
/// (Plan/anbieter.md, "Automatisches Startprofil"), checked against `claude --help` of the
/// versions in the compatibility matrix.
public enum ClaudeCommand {
    public static let readTools = ["Read", "Grep", "Glob"]
    public static let writeTools = ["Edit", "Write"]

    public static func arguments(for spec: AttemptSpec) throws -> [String] {
        guard spec.runMode == .automatic else { throw ProviderError.unsupportedMode(spec.runMode) }
        var arguments = [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            // No command-running tools, no user/project settings, file tools confined to the cwd.
            "--restricted", "--safe-mode", "--strict-mcp-config", "--disable-slash-commands",
            // Nothing is asked interactively: what the rules below do not allow is denied.
            "--permission-mode", "manual", "--permission-prompts", "none",
            "--no-session-persistence",
            "--model", spec.effectiveModel,
        ]
        if let effort = spec.effort { arguments += ["--effort", effort] }
        switch spec.role {
        case .reviewer:
            arguments += ["--tools", readTools.joined(separator: ",")]
        case .author:
            arguments += ["--tools", (readTools + writeTools).joined(separator: ",")]
            arguments += ["--allowedTools", try writeRules(for: spec.writablePaths).joined(separator: ",")]
        }
        return arguments
    }

    /// `Edit`/`Write` rules limited to the writable paths, relative to the working directory.
    static func writeRules(for paths: [String]?) throws -> [String] {
        let patterns: [String] = try (paths ?? [""]).map { path in
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.contains(","), !trimmed.contains(")"), !trimmed.split(separator: "/").contains("..") else {
                throw ProviderError.protocolViolation("unsupported writable path \(path)")
            }
            return trimmed.isEmpty ? "./**" : "./\(trimmed)/**"
        }
        return patterns.flatMap { pattern in writeTools.map { "\($0)(\(pattern))" } }
    }

    /// Only what the CLI needs. Provider overrides, API keys, gateways and key helpers are never
    /// passed, so the run cannot fall back from the subscription to another billing source.
    public static func environment(configDirectory: String, temporaryDirectory: String, home: String) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home, "TMPDIR": temporaryDirectory, "LANG": "en_US.UTF-8",
            "CLAUDE_CONFIG_DIR": configDirectory,
        ]
    }
}

/// Turns Claude Code `stream-json` lines into provider-neutral events. Unknown event types are
/// passed on as diagnostics; malformed lines are protocol violations.
public struct ClaudeStreamParser: Sendable {
    private var currentMessageID: String?
    private var textCounters: [String: Int] = [:]
    private var usageSeen: Set<String> = []
    public private(set) var sessionStarted = false
    public private(set) var completed = false

    public init() {}

    public mutating func parse(_ line: String, cancelRequested: Bool = false) throws -> [AgentEvent] {
        let value: JSONValue
        do { value = try JSONValue.parse(line) } catch { throw ProviderError.protocolViolation("invalid JSON line") }
        guard let type = value["type"]?.string else { throw ProviderError.protocolViolation("line without type") }
        if completed { return [.diagnostic(message: "claude: \(type) after result")] }

        switch type {
        case "system":
            if value["subtype"]?.string == "init" {
                sessionStarted = true
                return [.started(sessionID: value["session_id"]?.string)]
            }
            return [.diagnostic(message: "claude system \(value["subtype"]?.string ?? "?")")]

        case "stream_event":
            guard let event = value["event"] else { return [] }
            switch event["type"]?.string {
            case "message_start":
                currentMessageID = event["message"]?["id"]?.string
                return []
            case "content_block_delta":
                guard event["delta"]?["type"]?.string == "text_delta", let text = event["delta"]?["text"]?.string else { return [] }
                return [.messageDelta(itemID: "delta:\(currentMessageID ?? "?"):\(event["index"]?.int ?? 0)", text: text)]
            default:
                return []
            }

        case "assistant":
            guard let message = value["message"], let id = message["id"]?.string else {
                throw ProviderError.protocolViolation("assistant message without id")
            }
            var events: [AgentEvent] = []
            for block in message["content"]?.array ?? [] {
                switch block["type"]?.string {
                case "text":
                    let counter = textCounters[id, default: 0]
                    textCounters[id] = counter + 1
                    events.append(.messageFinal(itemID: "\(id):text\(counter)", text: block["text"]?.string ?? ""))
                case "tool_use":
                    events.append(.toolStarted(itemID: block["id"]?.string ?? "\(id):tool", toolClass: block["name"]?.string ?? "unknown"))
                default:
                    break
                }
            }
            // Usage is reported per message and repeated on every line of the same message.
            if let usage = message["usage"], usageSeen.insert(id).inserted {
                events.append(.usage(Self.usage(usage, cumulative: false)))
            }
            return events

        case "user":
            return (value["message"]?["content"]?.array ?? []).compactMap { block in
                guard block["type"]?.string == "tool_result", let id = block["tool_use_id"]?.string else { return nil }
                return .toolEnded(itemID: id, status: block["is_error"]?.bool == true ? "error" : "ok")
            }

        case "result":
            completed = true
            var events: [AgentEvent] = []
            for denial in value["permission_denials"]?.array ?? [] {
                let input = denial["tool_input"]
                let path = input?["file_path"]?.string ?? input?["path"]?.string ?? input?["notebook_path"]?.string
                events.append(.diagnostic(message: "claude permission denied: \(denial["tool_name"]?.string ?? "?")" + (path.map { " \($0)" } ?? "")))
            }
            if let usage = value["usage"] { events.append(.usage(Self.usage(usage, cumulative: true))) }
            let success = value["subtype"]?.string == "success" && value["is_error"]?.bool != true
            if success {
                events.append(.completed(.succeeded))
            } else if cancelRequested {
                events.append(.completed(.cancelled))
            } else {
                let reason = [value["subtype"]?.string, value["result"]?.string.map { String($0.prefix(200)) }]
                    .compactMap { $0 }.joined(separator: ": ")
                events.append(.completed(.failed(reason: reason.isEmpty ? "error" : reason)))
            }
            return events

        default:
            return [.diagnostic(message: "claude event \(type)")]
        }
    }

    static func usage(_ value: JSONValue, cumulative: Bool) -> UsageSample {
        UsageSample(
            inputTokens: value["input_tokens"]?.int, outputTokens: value["output_tokens"]?.int,
            cachedTokens: value["cache_read_input_tokens"]?.int, cumulative: cumulative
        )
    }
}
