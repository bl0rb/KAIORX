import Domain
import Foundation
import ProcessHost
import ProviderFixtures
import Testing
@testable import Providers

func workspace() throws -> String {
    let url = FileManager.default.temporaryDirectory.appending(path: "kaiorx-adapter-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url.appending(path: "work"), withIntermediateDirectories: true)
    return Confinement.resolved(url.path(percentEncoded: false))
}

func attempt(_ role: AttemptRole = .author, provider: ProviderKind, in root: String, writable: [String]? = nil, prompt: String = "Ändere etwas") -> AttemptSpec {
    AttemptSpec(
        attemptID: AttemptID(), taskID: TaskID(), projectID: ProjectID(), role: role, provider: provider, runMode: .automatic,
        modelProfile: "standard", effectiveModel: provider == .claude ? "claude-sonnet-5-5" : "gpt-6", effort: nil,
        workingDirectory: root + "/work", writablePaths: writable, prompt: prompt
    )
}

/// Collects a run's events; fails the test instead of hanging.
func drain(_ handle: any RunHandle, timeout: Duration = .seconds(20)) async throws -> [AgentEvent] {
    try await withThrowingTaskGroup(of: [AgentEvent].self) { group in
        group.addTask {
            var events: [AgentEvent] = []
            for try await event in handle.events { events.append(event) }
            return events
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw CancellationError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

func received(_ root: String, _ spec: AttemptSpec) throws -> JSONValue {
    try JSONValue.parse(String(contentsOfFile: root + "/runs/\(spec.attemptID.uuidString)/received.json", encoding: .utf8))
}

// MARK: Shared pieces

@Suite struct LineFramerTests {
    @Test func linesSplitAcrossReadsAndUTF8() throws {
        var framer = LineFramer()
        let bytes = Array("{\"a\":\"ü\"}\r\n\n{\"b\":1}\n{\"c\"".utf8)
        // Split inside the two-byte "ü".
        let cut = bytes.firstIndex(of: 0xC3)! + 1
        #expect(try framer.append(Data(bytes[..<cut])) == [])
        #expect(try framer.append(Data(bytes[cut...])) == [#"{"a":"ü"}"#, #"{"b":1}"#])
        #expect(framer.remainder == Data(#"{"c""#.utf8))
    }

    @Test func oversizedAndInvalidLinesAreErrors() {
        var small = LineFramer(maxLineBytes: 8)
        #expect(throws: LineFramer.FramingError.lineTooLong(limit: 8)) { _ = try small.append(Data("0123456789".utf8)) }
        var framer = LineFramer()
        #expect(throws: LineFramer.FramingError.invalidUTF8) { _ = try framer.append(Data([0xFF, 0x0A])) }
    }
}

@Suite struct CompatibilityTests {
    @Test func versionsAreParsedFromBothCLIs() {
        #expect(BinaryIdentity.parseVersion("2.1.328 (Claude Code)\n") == "2.1.328")
        #expect(BinaryIdentity.parseVersion("codex-cli 0.170.0\n") == "0.170.0")
    }

    @Test func automaticRunsWaitForLiveVerification() throws {
        let claude = BinaryIdentity(path: "/x", resolvedPath: "/x", sha256: "", version: "2.1.328")
        #expect(throws: ProviderError.notLiveVerified(provider: .claude, version: "2.1.328")) { try AdapterPolicy().check(.claude, identity: claude) }
        var unknown = claude
        unknown.version = "9.9.9"
        #expect(throws: ProviderError.versionNotInMatrix(provider: .claude, version: "9.9.9")) { try AdapterPolicy().check(.claude, identity: unknown) }
        try AdapterPolicy.fixtureTesting.check(.claude, identity: unknown)
        #expect(CompatibilityMatrix.entries.allSatisfy { $0.status == .offlineVerified })
    }
}

// MARK: Claude Code

@Suite struct ClaudeCommandTests {
    @Test func authorProfileMatchesThePlan() throws {
        let spec = attempt(.author, provider: .claude, in: "/w", writable: ["src", "docs/"])
        let arguments = try ClaudeCommand.arguments(for: spec)
        #expect(arguments == [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--restricted", "--safe-mode", "--strict-mcp-config", "--disable-slash-commands",
            "--permission-mode", "manual", "--permission-prompts", "none", "--no-session-persistence",
            "--model", "claude-sonnet-5-5", "--tools", "Read,Grep,Glob,Edit,Write",
            "--allowedTools", "Edit(./src/**),Write(./src/**),Edit(./docs/**),Write(./docs/**)",
        ])
        #expect(try ClaudeCommand.writeRules(for: nil) == ["Edit(./**)", "Write(./**)"])
    }

    @Test func reviewerOnlyReads() throws {
        let arguments = try ClaudeCommand.arguments(for: attempt(.reviewer, provider: .claude, in: "/w"))
        #expect(arguments.suffix(2) == ["--tools", "Read,Grep,Glob"])
        #expect(!arguments.contains("--allowedTools"))
    }

    @Test func unsafeWritablePathsAndManualModeAreRefused() {
        #expect(throws: ProviderError.self) { _ = try ClaudeCommand.writeRules(for: ["../outside"]) }
        #expect(throws: ProviderError.self) { _ = try ClaudeCommand.writeRules(for: ["a,Bash"]) }
        var manual = attempt(provider: .claude, in: "/w")
        manual.runMode = .manual
        #expect(throws: ProviderError.unsupportedMode(.manual)) { _ = try ClaudeCommand.arguments(for: manual) }
    }
}

@Suite struct ClaudeParserTests {
    @Test func fullStreamMapsToNeutralEvents() throws {
        var parser = ClaudeStreamParser()
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"s-1","model":"m","tools":["Read"]}"#,
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hal"}}}"#,
            #"{"type":"assistant","message":{"id":"msg_1","content":[{"type":"text","text":"Hallo"}],"usage":{"input_tokens":10,"output_tokens":3,"cache_read_input_tokens":4}}}"#,
            #"{"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use","id":"tu_1","name":"Edit","input":{}}],"usage":{"input_tokens":10,"output_tokens":3}}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","is_error":false}]}}"#,
            #"{"type":"rate_limit_event","info":{}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":20,"output_tokens":6},"permission_denials":[{"tool_name":"Bash"},{"tool_name":"Write","tool_input":{"file_path":"secrets/x"}}]}"#,
            #"{"type":"system","subtype":"late"}"#,
        ]
        let events = try lines.flatMap { try parser.parse($0) }
        #expect(events == [
            .started(sessionID: "s-1"),
            .messageDelta(itemID: "delta:msg_1:0", text: "Hal"),
            .messageFinal(itemID: "msg_1:text0", text: "Hallo"),
            .usage(UsageSample(inputTokens: 10, outputTokens: 3, cachedTokens: 4)),
            .toolStarted(itemID: "tu_1", toolClass: "Edit"),
            .toolEnded(itemID: "tu_1", status: "ok"),
            .diagnostic(message: "claude event rate_limit_event"),
            .diagnostic(message: "claude permission denied: Bash"),
            .diagnostic(message: "claude permission denied: Write secrets/x"),
            .usage(UsageSample(inputTokens: 20, outputTokens: 6, cumulative: true)),
            .completed(.succeeded),
            .diagnostic(message: "claude: system after result"),
        ])
    }

    @Test func failureAndCancellationResults() throws {
        var failed = ClaudeStreamParser()
        #expect(try failed.parse(#"{"type":"result","subtype":"error_max_turns","is_error":true,"result":"too long"}"#).last
            == .completed(.failed(reason: "error_max_turns: too long")))
        var cancelled = ClaudeStreamParser()
        #expect(try cancelled.parse(#"{"type":"result","subtype":"error_during_execution","is_error":true}"#, cancelRequested: true).last
            == .completed(.cancelled))
    }

    @Test func malformedLinesAreProtocolViolations() {
        var parser = ClaudeStreamParser()
        #expect(throws: ProviderError.self) { _ = try parser.parse("not json") }
        #expect(throws: ProviderError.self) { _ = try parser.parse(#"{"no":"type"}"#) }
        #expect(throws: ProviderError.self) { _ = try parser.parse(#"{"type":"assistant","message":{}}"#) }
    }
}

@Suite struct ClaudeAdapterTests {
    func adapter(_ steps: [FixturePrograms.ClaudeStep], root: String, policy: AdapterPolicy = .fixtureTesting) throws -> ClaudeCodeAdapter {
        let executable = try FixturePrograms.makeExecutable(FixturePrograms.claude(steps), in: root, name: "claude")
        return ClaudeCodeAdapter(
            configuration: ClaudeCodeConfiguration(
                executable: executable, configDirectory: root + "/claude-config", temporaryRoot: root + "/runs",
                home: root, policy: policy, stopGrace: .milliseconds(500)
            ),
            host: ProcessHost()
        )
    }

    static let initLine: JSONValue = ["type": "system", "subtype": "init", "session_id": "s-fixture"]

    @Test func successfulRunEditsAndReportsOnce() async throws {
        let root = try workspace()
        setenv("ANTHROPIC_API_KEY", "must-not-leak", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }
        let adapter = try adapter([
            .emit(Self.initLine),
            .emit(["type": "assistant", "message": ["id": "m1", "content": [["type": "tool_use", "id": "t1", "name": "Write", "input": [:]]], "usage": ["input_tokens": 5, "output_tokens": 1]]]),
            .writeFile("claude.txt", "von claude\n"),
            .emit(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t1"]]]]),
            .emit(["type": "assistant", "message": ["id": "m1", "content": [["type": "text", "text": "Fertig"]], "usage": ["input_tokens": 5, "output_tokens": 1]]]),
            .emit(["type": "result", "subtype": "success", "is_error": false, "usage": ["input_tokens": 9, "output_tokens": 4]]),
        ], root: root)
        let spec = attempt(provider: .claude, in: root, writable: ["."])
        let events = try await drain(try await adapter.start(spec))
        #expect(events == [
            .started(sessionID: "s-fixture"), .toolStarted(itemID: "t1", toolClass: "Write"),
            .usage(UsageSample(inputTokens: 5, outputTokens: 1)), .toolEnded(itemID: "t1", status: "ok"),
            .messageFinal(itemID: "m1:text0", text: "Fertig"), .usage(UsageSample(inputTokens: 9, outputTokens: 4, cumulative: true)),
            .completed(.succeeded),
        ])
        #expect(FileManager.default.fileExists(atPath: root + "/work/claude.txt"))
        let seen = try received(root, spec)
        #expect(seen["prompt"]?.string == "Ändere etwas")
        #expect(seen["env"]?["CLAUDE_CONFIG_DIR"]?.string == root + "/claude-config")
        #expect(seen["env"]?["ANTHROPIC_API_KEY"] == nil)
        #expect(seen["argv"]?.array?.contains("--restricted") == true)
    }

    @Test func cancelInterruptsTheTurn() async throws {
        let root = try workspace()
        let adapter = try adapter([.emit(Self.initLine), .waitForInterrupt], root: root)
        let handle = try await adapter.start(attempt(provider: .claude, in: root))
        async let events = drain(handle)
        try await Task.sleep(for: .milliseconds(300))
        await handle.cancel(reason: "user")
        #expect(try await events == [.started(sessionID: "s-fixture"), .completed(.cancelled)])
    }

    @Test func killedAfterIgnoringTheInterruptLeavesTheOutcomeOpen() async throws {
        let root = try workspace()
        let adapter = try adapter([.emit(Self.initLine), .ignoreInterrupts], root: root)
        let handle = try await adapter.start(attempt(provider: .claude, in: root))
        async let events = drain(handle)
        try await Task.sleep(for: .milliseconds(300))
        await handle.cancel(reason: "user")
        #expect(try await events == [.started(sessionID: "s-fixture")])
    }

    @Test func eachStartLaunchesTheVersionThatPassedTheCheck() async throws {
        let root = try workspace()
        let first = try FixturePrograms.makeExecutable(FixturePrograms.claude([.emit(Self.initLine), .emit(["type": "result", "subtype": "success", "is_error": false])]), in: root, name: "claude-a")
        let second = try FixturePrograms.makeExecutable(
            FixturePrograms.claude([.emit(Self.initLine), .emit(["type": "result", "subtype": "success", "is_error": false])])
                .replacingOccurrences(of: "2.1.328 (Claude Code)", with: "9.9.9 (Claude Code)"),
            in: root, name: "claude-b"
        )
        let link = root + "/claude"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: first)
        let adapter = ClaudeCodeAdapter(
            configuration: ClaudeCodeConfiguration(executable: link, configDirectory: root + "/cfg", temporaryRoot: root + "/runs", home: root, policy: .fixtureTesting),
            host: ProcessHost()
        )
        #expect(try await adapter.probe(ProbeRequest(profile: "k", mode: .automatic)).binaryVersion == "2.1.328")
        let one = attempt(provider: .claude, in: root)
        _ = try await drain(try await adapter.start(one))
        #expect(try received(root, one)["exe"]?.string == first)

        // A self-update switches the link: the next start re-checks and sees the new version.
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: second)
        #expect(try await adapter.probe(ProbeRequest(profile: "k", mode: .automatic)).binaryVersion == "9.9.9")
        let two = attempt(provider: .claude, in: root)
        _ = try await drain(try await adapter.start(two))
        #expect(try received(root, two)["exe"]?.string == second)
    }

    @Test func exitBeforeSessionIsASafeFailure() async throws {
        let root = try workspace()
        let adapter = try adapter([.stderr("Not logged in. Run claude to sign in."), .exit(1)], root: root)
        let events = try await drain(try await adapter.start(attempt(provider: .claude, in: root)))
        #expect(events == [.completed(.failed(reason: "exited before session start: Not logged in. Run claude to sign in."))])
    }

    @Test func endWithoutResultLeavesTheOutcomeOpen() async throws {
        let root = try workspace()
        let adapter = try adapter([.emit(Self.initLine), .exit(0)], root: root)
        #expect(try await drain(try await adapter.start(attempt(provider: .claude, in: root))) == [.started(sessionID: "s-fixture")])
    }

    @Test func malformedOutputFailsTheStream() async throws {
        let root = try workspace()
        let adapter = try adapter([.emit(Self.initLine), .raw("{broken"), .waitForInterrupt], root: root)
        let handle = try await adapter.start(attempt(provider: .claude, in: root))
        await #expect(throws: ProviderError.self) { _ = try await drain(handle) }
    }

    @Test func productPolicyRefusesUnverifiedVersions() async throws {
        let root = try workspace()
        let adapter = try adapter([.emit(Self.initLine)], root: root, policy: AdapterPolicy())
        await #expect(throws: ProviderError.notLiveVerified(provider: .claude, version: "2.1.328")) {
            _ = try await adapter.start(attempt(provider: .claude, in: root))
        }
        let snapshot = try await adapter.probe(ProbeRequest(profile: "kaiorx", mode: .automatic))
        #expect(snapshot.binaryVersion == "2.1.328")
        #expect(snapshot.runModes == [.manual])
        #expect(snapshot.planMode == "offlineVerified")
    }
}

// MARK: Codex App Server

@Suite struct CodexContractTests {
    static func validator(_ name: String) throws -> SchemaValidator {
        try SchemaValidator(file: FixturePrograms.codexSchema(name))
    }

    @Test func requestsWeSendMatchTheSchemaOfThisVersion() throws {
        let requests = try Self.validator("ClientRequest.json")
        let spec = attempt(.author, provider: .codex, in: "/w")
        let review = attempt(.reviewer, provider: .codex, in: "/w")
        var effortful = spec
        effortful.effort = "high"
        let messages: [(String, JSONValue)] = [
            ("initialize", CodexMessages.initialize(clientVersion: "0.1.0")),
            ("thread/start", CodexMessages.threadStart(spec, workingDirectory: "/w/work")),
            ("thread/start", CodexMessages.threadStart(review, workingDirectory: "/w/work")),
            ("turn/start", CodexMessages.turnStart(spec, threadID: "thr-1", workingDirectory: "/w/work")),
            ("turn/start", CodexMessages.turnStart(review, threadID: "thr-1", workingDirectory: "/w/work")),
            ("turn/start", CodexMessages.turnStart(effortful, threadID: "thr-1", workingDirectory: "/w/work")),
            ("turn/interrupt", CodexMessages.turnInterrupt(threadID: "thr-1", turnID: "turn-1")),
        ]
        for (method, params) in messages {
            let envelope: JSONValue = ["id": 1, "method": .string(method), "params": params]
            #expect(requests.errors(envelope) == [], "\(method)")
        }
        #expect(try Self.validator("ClientNotification.json").errors(["method": "initialized"]) == [])
    }

    /// The checker itself must reject what the binary would reject.
    @Test func validatorRejectsInvalidMessages() throws {
        let requests = try Self.validator("ClientRequest.json")
        let spec = attempt(.author, provider: .codex, in: "/w")
        var withoutThread = CodexMessages.turnStart(spec, threadID: "thr-1", workingDirectory: "/w").object!
        withoutThread["threadId"] = nil
        #expect(!requests.errors(["id": 1, "method": "turn/start", "params": .object(withoutThread)]).isEmpty)
        var badSandbox = CodexMessages.turnStart(spec, threadID: "thr-1", workingDirectory: "/w").object!
        badSandbox["sandboxPolicy"] = ["type": "everything"]
        #expect(!requests.errors(["id": 1, "method": "turn/start", "params": .object(badSandbox)]).isEmpty)
        #expect(!requests.errors(["id": 1, "method": "thread/start", "params": ["sandbox": "wide-open"]]).isEmpty)
        #expect(!requests.errors(["id": 1, "method": "no/such/method", "params": [:]]).isEmpty)
        #expect(!requests.errors(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "x"]]]).isEmpty)
        #expect(!(try Self.validator("FileChangeRequestApprovalResponse.json").errors(["decision": "approve"])).isEmpty)
        #expect(!(try Self.validator("ServerNotification.json").errors(["method": "turn/completed", "params": ["threadId": "t", "turn": ["id": "x", "items": [], "status": "done"]]])).isEmpty)
    }

    static func context(_ role: AttemptRole = .author, root: String = "/w/work", writable: [String]? = nil, changes: [String: [String]] = ["fc-1": ["codex.txt"]]) -> ApprovalContext {
        ApprovalContext(role: role, threadID: "thr-1", turnID: "turn-1", workingDirectory: root, writablePaths: writable, fileChanges: changes)
    }

    static let request: JSONValue = ["threadId": "thr-1", "turnId": "turn-1", "itemId": "fc-1", "startedAtMs": 1]

    @Test func approvalAnswersMatchTheSchema() throws {
        let cases: [(String, String, AttemptRole)] = [
            ("item/fileChange/requestApproval", "FileChangeRequestApprovalResponse.json", .author),
            ("item/fileChange/requestApproval", "FileChangeRequestApprovalResponse.json", .reviewer),
            ("item/commandExecution/requestApproval", "CommandExecutionRequestApprovalResponse.json", .author),
            ("item/permissions/requestApproval", "PermissionsRequestApprovalResponse.json", .author),
        ]
        for (method, schema, role) in cases {
            let (answer, _) = try CodexApprovals.decide(method, params: Self.request, context: Self.context(role))
            #expect(try Self.validator(schema).errors(answer) == [], "\(method) \(role)")
        }
        #expect(throws: JSONRPCConnection.Refusal.self) {
            _ = try CodexApprovals.decide("account/chatgptAuthTokens/refresh", params: [:], context: Self.context())
        }
    }

    @Test func fileChangesAreAcceptedOnlyInsideTheWorktree() throws {
        let root = try workspace() + "/work"
        try FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: "/tmp")
        let outside = URL(filePath: root).deletingLastPathComponent().path(percentEncoded: false) + "/outside"
        try FileManager.default.createDirectory(atPath: outside + "/sub", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/deep", withDestinationPath: outside + "/sub")
        try FileManager.default.createSymbolicLink(atPath: root + "/dangling", withDestinationPath: outside + "/new.txt")
        try FileManager.default.createSymbolicLink(atPath: root + "/dangling-relative", withDestinationPath: "../outside/rel.txt")
        func decision(_ params: JSONValue = Self.request, role: AttemptRole = .author, writable: [String]? = nil, paths: [String]) throws -> String? {
            try CodexApprovals.decide("item/fileChange/requestApproval", params: params,
                                      context: Self.context(role, root: root, writable: writable, changes: ["fc-1": paths])).0["decision"]?.string
        }
        #expect(try decision(paths: ["src/a.swift"]) == "accept")
        #expect(try decision(paths: [root + "/src/a.swift"]) == "accept")
        #expect(try decision(role: .reviewer, paths: ["src/a.swift"]) == "decline")
        #expect(try decision(paths: ["../other/a.swift"]) == "decline")
        #expect(try decision(paths: ["/etc/hosts"]) == "decline")
        #expect(try decision(paths: ["link/escape.txt"]) == "decline", "symlink out of the worktree")
        #expect(try decision(paths: ["deep/../escape.txt"]) == "decline", "`..` after a symlink")
        #expect(try decision(paths: ["src/../src/a.swift"]) == "decline", "no `..` at all")
        #expect(try decision(paths: ["dangling"]) == "decline", "dangling symlink")
        #expect(try decision(paths: ["dangling-relative"]) == "decline", "relative dangling symlink")
        #expect(try decision(paths: ["link"]) == "decline", "symlink as target")
        #expect(try decision(paths: ["src/./b.swift"]) == "accept")
        #expect(try decision(paths: [".git/config"]) == "decline")
        #expect(try decision(paths: [".GIT/config"]) == "decline")
        #expect(try decision(paths: [".codex/config.toml"]) == "decline")
        #expect(try decision(paths: ["src/a.swift", "../x"]) == "decline")
        #expect(try decision(writable: ["src"], paths: ["src/a.swift"]) == "accept")
        #expect(try decision(writable: ["src"], paths: ["docs/a.md"]) == "decline")
        #expect(try decision(paths: []) == "decline", "unknown change")
        var grant = Self.request.object!
        grant["grantRoot"] = .string(root)
        #expect(try decision(.object(grant), paths: ["src/a.swift"]) == "decline")
        for key in ["itemId", "threadId", "turnId", "startedAtMs"] {
            var missing = Self.request.object!
            missing[key] = nil
            #expect(try decision(.object(missing), paths: ["src/a.swift"]) == "decline", "missing \(key)")
        }
        var otherTurn = Self.request.object!
        otherTurn["turnId"] = "turn-9"
        #expect(try decision(.object(otherTurn), paths: ["src/a.swift"]) == "decline")
    }
}

@Suite struct CodexAdapterTests {
    func adapter(_ scenario: FixturePrograms.CodexScenario, root: String, authentication: CodexConfiguration.Authentication = .cliManaged, timeout: Duration = .seconds(10)) throws -> CodexAppServerAdapter {
        let executable = try FixturePrograms.makeExecutable(FixturePrograms.codex(scenario), in: root, name: "codex")
        return CodexAppServerAdapter(
            configuration: CodexConfiguration(
                executable: executable, codexHome: root + "/codex-home", temporaryRoot: root + "/runs", home: root,
                authentication: authentication, policy: .fixtureTesting, stopGrace: .milliseconds(500),
                requestTimeout: timeout, recordsTranscript: true
            ),
            host: ProcessHost()
        )
    }

    /// Every message in both directions conforms to the schema of codex-cli 0.170.0.
    func validateTranscript(_ handle: any RunHandle) async throws {
        let transcript = await (handle as! CodexRunHandle).connection.transcript
        let responseSchemas = [
            "initialize": "InitializeResponse.json", "thread/start": "ThreadStartResponse.json",
            "turn/start": "TurnStartResponse.json", "turn/interrupt": "TurnInterruptResponse.json",
            "item/fileChange/requestApproval": "FileChangeRequestApprovalResponse.json",
            "item/commandExecution/requestApproval": "CommandExecutionRequestApprovalResponse.json",
            "item/permissions/requestApproval": "PermissionsRequestApprovalResponse.json",
        ]
        var outgoingMethods: [String: String] = [:]
        var incomingMethods: [String: String] = [:]
        for (outgoing, message) in transcript {
            let id = message["id"].map(\.description)
            if let method = message["method"]?.string {
                let schema = outgoing
                    ? (id == nil ? "ClientNotification.json" : "ClientRequest.json")
                    : (id == nil ? "ServerNotification.json" : "ServerRequest.json")
                #expect(try CodexContractTests.validator(schema).errors(message) == [], "\(method)")
                if let id { if outgoing { outgoingMethods[id] = method } else { incomingMethods[id] = method } }
            } else if let id, let result = message["result"] {
                let method = (outgoing ? incomingMethods[id] : outgoingMethods[id]) ?? "?"
                let file = try #require(responseSchemas[method], "no response schema for \(method)")
                #expect(try CodexContractTests.validator(file).errors(result) == [], "result of \(method)")
            } else {
                #expect(message["error"]?["code"]?.int != nil && message["error"]?["message"]?.string != nil)
            }
        }
        #expect(!transcript.isEmpty)
    }

    @Test func fullTurnWithApprovedFileChange() async throws {
        let root = try workspace()
        let spec = attempt(provider: .codex, in: root)
        let handle = try await adapter(.success, root: root).start(spec)
        let events = try await drain(handle)
        #expect(events == [
            .started(sessionID: "thr-1"), .messageDelta(itemID: "msg-1", text: "Hallo "), .messageDelta(itemID: "msg-1", text: "Welt"),
            .messageFinal(itemID: "msg-1", text: "Hallo Welt"), .toolStarted(itemID: "fc-1", toolClass: "fileChange"),
            .diagnostic(message: "codex approval: file change accept"), .toolEnded(itemID: "fc-1", status: "completed"),
            .usage(UsageSample(inputTokens: 12, outputTokens: 7, cachedTokens: 2, cumulative: true)), .completed(.succeeded),
        ])
        #expect(FileManager.default.fileExists(atPath: root + "/work/codex.txt"))
        try await validateTranscript(handle)
        let seen = try received(root, spec)
        #expect(seen["argv"]?.array?.prefix(4) == ["app-server", "--listen", "stdio://", "--strict-config"])
        #expect(seen["env"]?["CODEX_HOME"]?.string == root + "/codex-home")
        #expect(seen["env"]?["ACCESS_TOKEN"] == nil)
    }

    @Test func reviewerChangesAreDeclined() async throws {
        let root = try workspace()
        let events = try await drain(try await adapter(.success, root: root).start(attempt(.reviewer, provider: .codex, in: root)))
        #expect(events.contains(.toolEnded(itemID: "fc-1", status: "declined")))
        #expect(events.last == .completed(.succeeded))
        #expect(!FileManager.default.fileExists(atPath: root + "/work/codex.txt"))
    }

    @Test func cancelInterruptsTheTurn() async throws {
        let root = try workspace()
        let handle = try await adapter(.interruptible, root: root).start(attempt(provider: .codex, in: root))
        async let events = drain(handle)
        try await Task.sleep(for: .milliseconds(300))
        await handle.cancel(reason: "user")
        #expect(try await events == [.started(sessionID: "thr-1"), .completed(.cancelled)])
        let sent = await (handle as! CodexRunHandle).connection.transcript.filter(\.outgoing).compactMap { $0.line["method"]?.string }
        #expect(sent.contains("turn/interrupt"))
        try await validateTranscript(handle)
    }

    @Test func refusedThreadIsASafeStartFailure() async throws {
        let root = try workspace()
        await #expect(throws: ProviderError.requestFailed(method: "thread/start", message: "not signed in")) {
            _ = try await adapter(.threadStartError, root: root).start(attempt(provider: .codex, in: root))
        }
    }

    @Test func unusualServerRequestsAreRefusedOrGrantNothing() async throws {
        let root = try workspace()
        let handle = try await adapter(.unusualRequests, root: root).start(attempt(provider: .codex, in: root))
        let events = try await drain(handle)
        #expect(events.contains(.diagnostic(message: "codex approval: extra permissions refused")))
        #expect(events.contains(.diagnostic(message: "codex approval: command declined")))
        #expect(events.last == .completed(.succeeded))
        let answers = await (handle as! CodexRunHandle).connection.transcript.filter(\.outgoing).map(\.line).filter { $0["method"] == nil }
        #expect(answers.contains { $0["error"]?["code"]?.int == -32601 })
        #expect(answers.contains { $0["result"]?["permissions"] == [:] })
        try await validateTranscript(handle)
    }

    @Test func droppedServerLeavesTheOutcomeOpen() async throws {
        let root = try workspace()
        let events = try await drain(try await adapter(.dropsAfterApproval, root: root).start(attempt(provider: .codex, in: root)))
        #expect(!events.contains { if case .completed = $0 { true } else { false } })
    }

    @Test func silentServerTimesOutBeforeAnyTurn() async throws {
        let root = try workspace()
        let adapter = try adapter(.silentInitialize, root: root, timeout: .milliseconds(500))
        let start = ContinuousClock.now
        await #expect(throws: ProviderError.requestFailed(method: "initialize", message: "no response within 0.5 seconds")) {
            _ = try await adapter.start(attempt(provider: .codex, in: root))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func cancelWhileTurnStartIsUnansweredStopsTheServer() async throws {
        let root = try workspace()
        let handle = try await adapter(.turnStartHangs, root: root).start(attempt(provider: .codex, in: root))
        async let events = drain(handle, timeout: .seconds(10))
        await handle.cancel(reason: "user")
        // Stopped, but nothing confirms the turn's end: no terminal event.
        #expect(try await events == [.started(sessionID: "thr-1")])
    }

    @Test func crashAfterTurnStartIsNotACancellation() async throws {
        let root = try workspace()
        let handle = try await adapter(.crashAfterTurnStart, root: root).start(attempt(provider: .codex, in: root))
        await handle.cancel(reason: "user")
        let events = try await drain(handle)
        #expect(!events.contains { if case .completed = $0 { true } else { false } })
        #expect(FileManager.default.fileExists(atPath: root + "/work/side-effect.txt"))
    }

    @Test func nonTerminalCompletionLeavesTheOutcomeOpenAndEnds() async throws {
        let root = try workspace()
        let events = try await drain(try await adapter(.unknownTurnStatus, root: root).start(attempt(provider: .codex, in: root)))
        #expect(!events.contains { if case .completed = $0 { true } else { false } })
        #expect(events.contains(.diagnostic(message: "codex outcome unknown: turn/completed with status inProgress")))
    }

    @Test func changeOutsideTheWorktreeIsDeclined() async throws {
        let root = try workspace()
        let handle = try await adapter(.outsideChange, root: root).start(attempt(provider: .codex, in: root))
        let events = try await drain(handle)
        #expect(events.contains(.diagnostic(message: "codex approval: file change decline")))
        #expect(events.contains(.toolEnded(itemID: "fc-1", status: "declined")))
        #expect(!FileManager.default.fileExists(atPath: root + "/escape.txt"))
        try await validateTranscript(handle)
    }

    @Test func widenedPatchIsCheckedWithAllItsPaths() async throws {
        let root = try workspace()
        let handle = try await adapter(.widenedChange, root: root).start(attempt(provider: .codex, in: root))
        let events = try await drain(handle)
        #expect(events.contains(.diagnostic(message: "codex approval: file change decline")))
        #expect(!FileManager.default.fileExists(atPath: root + "/escape.txt"))
        try await validateTranscript(handle)
    }

    @Test func finishedRunsAreReleased() async throws {
        let root = try workspace()
        weak var released: CodexRunHandle?
        do {
            let handle = try await adapter(.success, root: root).start(attempt(provider: .codex, in: root))
            released = handle as? CodexRunHandle
            _ = try await drain(handle)
        }
        for _ in 0..<200 where released != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(released == nil)
    }

    @Test func productPolicyRequiresConfinement() async throws {
        let root = try workspace()
        let executable = try FixturePrograms.makeExecutable(FixturePrograms.codex(.success), in: root, name: "codex")
        let adapter = CodexAppServerAdapter(
            configuration: CodexConfiguration(
                executable: executable, codexHome: root + "/codex-home", temporaryRoot: root + "/runs", home: root,
                policy: .fixtureTestingConfined
            ),
            host: ProcessHost()
        )
        await #expect(throws: ProviderError.confinementRequired) { _ = try await adapter.start(attempt(provider: .codex, in: root)) }
    }

    @Test func signInWithChatGPTPassesOnlyTheAccessToken() async throws {
        let root = try workspace()
        setenv("ACCESS_TOKEN", "host-token-must-not-leak", 1)
        defer { unsetenv("ACCESS_TOKEN") }
        let cli = attempt(provider: .codex, in: root)
        _ = try await drain(try await adapter(.success, root: root).start(cli))
        #expect(try received(root, cli)["env"]?["ACCESS_TOKEN"] == nil)

        let siwc = attempt(provider: .codex, in: root)
        let adapter = try adapter(.success, root: root, authentication: .siwc(baseURL: "https://api.openai.com/v1", accessToken: { "short-lived" }))
        _ = try await drain(try await adapter.start(siwc))
        let seen = try received(root, siwc)
        #expect(seen["env"]?["ACCESS_TOKEN"]?.string == "short-lived")
        let argv = seen["argv"]?.array?.compactMap(\.string) ?? []
        #expect(argv.contains(#"model_providers.kaiorx_siwc.env_key="ACCESS_TOKEN""#))
        #expect(argv.contains("model_providers.kaiorx_siwc.requires_openai_auth=false"))
        #expect(argv.contains(#"shell_environment_policy.inherit="none""#))
    }
}

@Suite struct IdentityCacheTests {
    @Test func binarySwappedDuringTheCheckIsCheckedAgain() async throws {
        let root = try workspace()
        let newer = try FixturePrograms.makeExecutable("#!/bin/sh\necho '9.9.9 (Claude Code)'\n", in: root, name: "claude-new")
        // The old binary answers and then a self-update renames the new one over it.
        let path = try FixturePrograms.makeExecutable("""
            #!/bin/sh
            echo '2.1.328 (Claude Code)'
            mv '\(newer)' "$0"
            """, in: root, name: "claude")
        let identity = try await BinaryIdentityCache().current(path, host: ProcessHost())
        #expect(identity.version == "9.9.9")
    }
}
