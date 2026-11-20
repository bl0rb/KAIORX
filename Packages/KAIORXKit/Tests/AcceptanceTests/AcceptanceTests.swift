import CryptoKit
import Domain
import Foundation
import ProcessHost
import Synchronization
import Testing
@testable import Acceptance
@testable import Providers
@testable import Workspace

/// The kit itself, verified without real CLIs: fixture programs stand in for `claude` (CLAUDE.md).

func temporaryRoot(_ name: String) throws -> String {
    let path = FileManager.default.temporaryDirectory.appending(path: "kaiorx-acc-\(name)-\(UUID().uuidString)").path(percentEncoded: false)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return Confinement.resolved(path)
}

/// Answers consents with the phrase it was shown, yes/no questions with "ja", other questions with
/// scripted answers.
final class ScriptedPrompter: OwnerPrompter, Sendable {
    private let state = Mutex<(shown: [String], answers: [String])>(([], []))
    init(answers: [String] = []) { state.withLock { $0.answers = answers } }

    var shown: [String] { state.withLock { $0.shown } }

    func show(_ text: String) { state.withLock { $0.shown.append(text) } }

    func ask(_ prompt: String) -> String? {
        state.withLock { state in
            if let last = state.shown.last, let range = last.range(of: "tippe genau: ") {
                return String(last[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !state.answers.isEmpty { return state.answers.removeFirst() }
            return "ja"
        }
    }
}

/// A Claude stand-in for the kit: `--version`, `--help` with every flag of the profile,
/// `auth status --json` (signed out when `$CLAUDE_CONFIG_DIR/logged-out` exists), and runs that
/// act on the prompt: read FACTS.md, write the allowed file, wait to be interrupted, or refuse.
let claudeFixture = #"""
#!/usr/bin/perl
use strict; use warnings; use JSON::PP; use Time::HiRes qw(sleep);
$| = 1;
my $cfg = $ENV{CLAUDE_CONFIG_DIR} // '';
my $out = sub { print JSON::PP->new->canonical->encode($_[0]), "\n" };
if (@ARGV && $ARGV[0] eq '--version') { print "2.1.328 (Claude Code)\n"; exit 0; }
if (@ARGV && $ARGV[0] eq '--help') { print "-p --output-format --verbose --include-partial-messages --restricted --safe-mode --strict-mcp-config --disable-slash-commands --permission-mode --permission-prompts --no-session-persistence --model --effort --tools --allowedTools\n"; exit 0; }
if (@ARGV >= 2 && $ARGV[0] eq 'auth') {
  if (-e "$cfg/logged-out") { $out->({loggedIn => JSON::PP::false}); exit 1; }
  $out->({loggedIn => JSON::PP::true, authMethod => 'claude.ai', subscriptionType => 'max', email => 'owner@example.org', orgId => '7c9e6679-7425-40de-944b-e07fc1f90ae7'});
  exit 0;
}
{ open(my $r, '>>', "$cfg/runs") or die; print $r "run\n"; close $r; }
if (-e "$cfg/logged-out") { print STDERR "Not logged in\n"; exit 1; }
my $prompt = do { local $/; <STDIN> };
$out->({type => 'system', subtype => 'init', session_id => 'sess-1234', cwd => $ENV{PWD} // ''});
my $say = sub { $out->({type => 'assistant', message => {id => 'msg-' . int(rand(1e6)), content => [{type => 'text', text => $_[0]}], usage => {input_tokens => 3, output_tokens => 2}}}) };
if ($prompt =~ /FACTS\.md/) {
  open(my $f, '<', 'FACTS.md') or die; my $text = do { local $/; <$f> }; close $f;
  my ($word) = $text =~ /lautet (\S+)\./; $say->($word);
} elsif ($prompt =~ /ergebnis\.txt/) {
  open(my $f, '>', 'allowed/ergebnis.txt') or die; print $f "OK"; close $f;
  $say->('erledigt; aussen.txt verweigert');
  $out->({type => 'result', subtype => 'success', is_error => JSON::PP::false, permission_denials => [{tool_name => 'Write', tool_input => {file_path => 'aussen.txt'}}]}); exit 0;
} elsif ($prompt =~ /docs/) {
  $SIG{INT} = sub { $out->({type => 'result', subtype => 'error_during_execution', is_error => JSON::PP::true}); exit 0; };
  $say->('Ich beginne mit Kapitel 1.');
  while (1) { sleep(0.05); }
} else {
  $say->('Das geht nicht: Zugriff verweigert.');
}
$out->({type => 'result', subtype => 'success', is_error => JSON::PP::false, usage => {input_tokens => 3, output_tokens => 2}});
"""#

@Suite struct OwnerGuardTests {
    @Test func everyAutomatedContextIsRefused() {
        let clean = OwnerGuard.Context(environment: ["HOME": "/Users/u", "TERM": "xterm"], interactive: true, ancestors: ["zsh", "login", "Terminal"])
        #expect(OwnerGuard.refusals(clean).isEmpty)
        var pipe = clean
        pipe.interactive = false
        #expect(!OwnerGuard.refusals(pipe).isEmpty)
        for marker in ["CI", "GITHUB_ACTIONS", "XCTestConfigurationFilePath", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CODEX_SANDBOX"] {
            var context = clean
            context.environment[marker] = "1"
            #expect(!OwnerGuard.refusals(context).isEmpty, "\(marker)")
        }
        for parent in ["claude", "codex", "node", "Claude Helper"] {
            var context = clean
            context.ancestors = ["zsh", parent, "launchd"]
            #expect(!OwnerGuard.refusals(context).isEmpty, "\(parent)")
        }
        // The real test process is refused too (not a terminal session, test runner variables).
        #expect(!OwnerGuard.refusals(.current()).isEmpty)
    }

    @Test func consentNeedsTheExactPhraseForThisStepAndBinary() {
        let phrase = Consent.phrase(step: .read, provider: "claude", version: "2.1.328", sha256: "abcdef123456")
        #expect(phrase == "read claude 2.1.328 abcdef")
        let wrong = ScriptedPrompter(answers: [])
        final class Fixed: OwnerPrompter, Sendable {
            let answer: String
            init(_ answer: String) { self.answer = answer }
            func show(_ text: String) {}
            func ask(_ prompt: String) -> String? { answer }
        }
        #expect(!Consent.obtain(Fixed("ja"), step: .read, provider: "claude", version: "2.1.328", sha256: "abcdef123456", details: []))
        #expect(!Consent.obtain(Fixed("author claude 2.1.328 abcdef"), step: .read, provider: "claude", version: "2.1.328", sha256: "abcdef123456", details: []))
        #expect(Consent.obtain(wrong, step: .read, provider: "claude", version: "2.1.328", sha256: "abcdef123456", details: []))
    }
}

@Suite struct VerdictTests {
    @Test func claudeAuthStatusIsJudgedConservatively() {
        func verdict(_ json: String, _ code: Int32 = 0) -> SubscriptionVerdict { ClaudeAuthStatus(output: json, exitCode: code).verdict }
        #expect(verdict(#"{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "max"}"#) == .subscription(plan: "max"))
        #expect(verdict(#"{"loggedIn": false}"#) == .signedOut)
        #expect(!verdict(#"{"loggedIn": true, "apiKeySource": "ANTHROPIC_API_KEY"}"#).allowsRun)
        #expect(!verdict(#"{"loggedIn": true, "authMethod": "api_key"}"#).allowsRun)
        #expect(!verdict(#"{"loggedIn": true, "provider": "bedrock"}"#).allowsRun)
        #expect(!verdict(#"{"loggedIn": true, "authMethod": "claude.ai"}"#).allowsRun)
        #expect(!verdict("not json", 1).allowsRun)
    }

    @Test func codexAccountIsJudgedBySchemaFields() throws {
        func verdict(_ json: String) throws -> SubscriptionVerdict { CodexAccountReport(account: try JSONValue.parse(json), rateLimits: nil).verdict }
        #expect(try verdict(#"{"account": {"type": "chatgpt", "email": "a@b.c", "planType": "plus"}, "requiresOpenaiAuth": true}"#) == .subscription(plan: "plus"))
        #expect(try !verdict(#"{"account": {"type": "apiKey"}, "requiresOpenaiAuth": true}"#).allowsRun)
        #expect(try !verdict(#"{"account": {"type": "chatgpt", "email": null, "planType": "free"}, "requiresOpenaiAuth": true}"#).allowsRun)
        #expect(try verdict(#"{"account": null, "requiresOpenaiAuth": true}"#) == .signedOut)
    }
}

@Suite struct RedactorTests {
    @Test func identifiersSecretsAndPathsAreReplacedAndLeftoversFailClosed() throws {
        let redactor = FixtureRedactor(denylist: ["matzeprivat", "KAIORX-CANARY-geheim"], paths: [("/Users/matzeprivat", "<home>"), ("/tmp/run/repo-a", "<repo-a>")])
        var placeholders: [String: String] = [:]
        let line = #"{"type":"system","session_id":"sess-9","cwd":"/tmp/run/repo-a","email":"me@example.org","token":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlMTIz","path":"/Users/matzeprivat/x"}"#
        let out = try redactor.redact(line, placeholders: &placeholders)
        #expect(!out.contains("sess-9") && !out.contains("me@example.org") && !out.contains("eyJhbGci") && !out.contains("matzeprivat"))
        #expect(out.contains("\"type\":\"system\""))
        // The same value gets the same placeholder across lines.
        let again = try redactor.redact(#"{"session_id":"sess-9"}"#, placeholders: &placeholders)
        #expect(again.contains(placeholders["sess-9"]!))
        #expect(throws: FixtureRedactor.Failure.self) { try redactor.redact("plain text KAIORX-CANARY-geheim", placeholders: &placeholders) }
        #expect(throws: FixtureRedactor.Failure.self) { try redactor.redact("key AKIAABCDEFGHIJKLMNOP", placeholders: &placeholders) }
    }
}

@Suite struct NativeBinaryTests {
    @Test func theNpmLauncherResolvesToTheVendoredMachOBinary() throws {
        let root = try temporaryRoot("npm")
        let package = root + "/lib/node_modules/@openai/codex"
        #if arch(arm64)
        let vendor = package + "/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin"
        #else
        let vendor = package + "/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin"
        #endif
        try FileManager.default.createDirectory(atPath: package + "/bin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: vendor, withIntermediateDirectories: true)
        try Data("#!/usr/bin/env node\n".utf8).write(to: URL(filePath: package + "/bin/codex.js"))
        var magic = UInt32(0xFEED_FACF).littleEndian
        try Data(bytes: &magic, count: 4).write(to: URL(filePath: vendor + "/codex"))
        chmod(vendor + "/codex", 0o755)
        try FileManager.default.createDirectory(atPath: root + "/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/bin/codex", withDestinationPath: "../lib/node_modules/@openai/codex/bin/codex.js")
        #expect(try NativeBinary.resolve(root + "/bin/codex") == Confinement.resolved(vendor + "/codex"))
        try Data("#!/bin/sh\n".utf8).write(to: URL(filePath: root + "/other"))
        #expect(throws: NativeBinary.ResolutionError.self) { try NativeBinary.resolve(root + "/other") }
    }
}

@Suite struct PolicyTests {
    @Test func ownerAcceptanceBindsTheBinaryAndTheProductNeedsLiveVerification() throws {
        let identity = BinaryIdentity(path: "/x", resolvedPath: "/x", sha256: "aaa", version: "2.1.328")
        #expect(throws: ProviderError.notLiveVerified(provider: .claude, version: "2.1.328")) { try AdapterPolicy().check(.claude, identity: identity) }
        try AdapterPolicy.ownerAcceptance(binarySHA256: "aaa").check(.claude, identity: identity)
        #expect(throws: ProviderError.binaryChanged("/x")) { try AdapterPolicy.ownerAcceptance(binarySHA256: "bbb").check(.claude, identity: identity) }
        var unknown = identity
        unknown.version = "9.9.9"
        #expect(throws: ProviderError.self) { try AdapterPolicy.ownerAcceptance(binarySHA256: "aaa").check(.claude, identity: unknown) }
        #expect(AdapterPolicy.ownerAcceptance(binarySHA256: "aaa").requiresConfinement)
    }

    /// The owner policy is used only by the kit; the fixture policy only by tests.
    @Test func bypassPoliciesStayWhereTheyBelong() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appending(path: "Sources").path(percentEncoded: false)
        var offenders: [String] = []
        // The package's sources and the app target (which links the library).
        let app = root.deletingLastPathComponent().deletingLastPathComponent().appending(path: "App").path(percentEncoded: false)
        for (base, prefix) in [(sources, ""), (app, "App/")] {
            let enumerator = FileManager.default.enumerator(atPath: base)
            while let name = enumerator?.nextObject() as? String {
                let file = prefix + name
                guard name.hasSuffix(".swift"), file != "Providers/Compatibility.swift" else { continue }
                let text = try String(contentsOfFile: base + "/" + name, encoding: .utf8)
                if text.contains(".ownerAcceptance(") && !file.hasPrefix("Acceptance/") { offenders.append(file) }
                if text.contains("fixtureTesting") { offenders.append(file) }
            }
        }
        #expect(FileManager.default.fileExists(atPath: app + "/AppModel.swift"))
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// Every liveVerified entry rests on a committed, passed report; today none is live.
    @Test func everyMatrixEntryHasConsistentEvidence() {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path(percentEncoded: false)
        for entry in CompatibilityMatrix.entries {
            #expect(EvidenceCheck.problems(entry, repositoryRoot: repository).isEmpty, "\(entry.provider) \(entry.version)")
        }
    }
}

@Suite struct ReportTests {
    func passedReport(sha: String) throws -> Data {
        let report = AcceptanceReport(
            runID: "r1", date: "2026-11-20", macOS: "x", arch: "arm64", kaiorxCommit: nil,
            providers: [AcceptanceReport.Provider(
                provider: "claude", mode: "claudeSubscription", model: "m", version: "2.1.328", binarySHA256: sha, nativePath: "~/b",
                signing: [], verdict: "Abo", steps: StepID.allCases.filter { $0 != .parallel }.map {
                    AcceptanceReport.Step(id: $0.rawValue, title: $0.title, required: $0.required, status: "passed", evidence: [], limitation: nil)
                },
                passed: true, restrictions: [], fixtures: []
            )],
            parallel: nil
        )
        return try report.json()
    }

    @Test func theMatrixProposalAndItsEvidenceCheckAgree() throws {
        let sourcePath = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Providers/Compatibility.swift").path(percentEncoded: false)
        let source = try String(contentsOfFile: sourcePath, encoding: .utf8)
        let root = try temporaryRoot("evidence")
        let json = try passedReport(sha: "bin-sha")
        try FileManager.default.createDirectory(atPath: root + "/docs/live-acceptance/r1", withIntermediateDirectories: true)
        try json.write(to: URL(filePath: root + "/docs/live-acceptance/r1/report.json"))
        let reportSHA = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
        let proposed = try MatrixProposal.propose(
            source: source, provider: "claude", version: "2.1.328", binarySHA256: "bin-sha", reportPath: "docs/live-acceptance/r1/report.json",
            reportSHA256: reportSHA, mode: "claudeSubscription"
        )
        #expect(proposed.contains(#"provider: .claude, version: "2.1.328", status: .liveVerified,"#))
        #expect(proposed.contains(#"builds: ["bin-sha"],"#) && proposed.contains("reportSHA256: \"\(reportSHA)\""))
        #expect(proposed.contains(#"provider: .codex, version: "0.170.0", status: .offlineVerified,"#))
        let entry = CompatibilityEntry(provider: .claude, version: "2.1.328", status: .liveVerified, notes: "", schemaDigest: nil, builds: ["bin-sha"],
                                       evidence: LiveEvidence(reportPath: "docs/live-acceptance/r1/report.json", reportSHA256: reportSHA, mode: "claudeSubscription"))
        #expect(EvidenceCheck.problems(entry, repositoryRoot: root).isEmpty)
        var other = entry
        other.builds = ["another-build"]
        #expect(EvidenceCheck.problems(other, repositoryRoot: root) == ["Programm-SHA weicht ab"])
        try Data("{}".utf8).write(to: URL(filePath: root + "/docs/live-acceptance/r1/report.json"))
        #expect(EvidenceCheck.problems(entry, repositoryRoot: root) == ["Bericht verändert"])
        var bare = entry
        bare.evidence = nil
        #expect(EvidenceCheck.problems(bare, repositoryRoot: root) == ["liveVerified ohne Beleg"])
        #expect(throws: MatrixProposal.Failure.self) {
            try MatrixProposal.propose(source: source, provider: "claude", version: "0.0.1", binarySHA256: "x", reportPath: "x", reportSHA256: "x", mode: "x")
        }
    }
}

@Suite struct RunnerTests {
    /// The whole step order against the Claude fixture: identity, login, billing, read (with the
    /// home folder hidden, as in the product), isolation probes (home canary denied), the hidden
    /// home step covered by the read without another turn, author, cancel, then the revocation
    /// waits for the owner and passes on resume.
    @Test func aRunGoesThroughEveryStepAndWritesAPrivateReport() async throws {
        let root = try temporaryRoot("run")
        let home = try temporaryRoot("home")
        let binary = try temporaryRoot("bin") + "/claude"
        try Data(claudeFixture.utf8).write(to: URL(filePath: binary))
        chmod(binary, 0o755)
        let config = root + "/claude-config"
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        let folders = RunFolders(root: root + "/run")
        var state = RunState(runID: "test-run", createdAt: 1_700_000_000_000, kaiorxCommit: nil, providers: [
            ProviderRun(provider: .claude, configuredPath: binary, nativePath: binary, model: "claude-test", configDirectory: config),
        ])
        try folders.create()
        try state.save(folders.root)
        let prompter = ScriptedPrompter(answers: ["ja", "ja", "Kontoeinstellungen", "überspringen"])
        // The real home path of a directory URL ends with "/": the kit must normalise it.
        var context = KitContext(folders: folders, home: home + "/", host: ProcessHost(), prompter: prompter, turnTimeout: .seconds(30), compatibilitySource: nil)
        context.allowsScriptBinaries = true
        let runner = AcceptanceRunner(state: state, context: context)
        #expect(try await runner.run() == false)
        state = await runner.state
        let steps = state.providers[0].steps
        for step in [StepID.identify, .auth, .billing, .read, .hiddenHome, .author, .cancel] {
            #expect(steps[step]?.status == .passed, "\(step): \(steps[step].map { "\($0)" } ?? "nil")")
        }
        #expect(steps[.isolation]?.status == .passed, "\(steps[.isolation]!)")
        #expect(steps[.isolation]?.evidence.contains("Benutzerordner lesen: verweigert") == true)
        #expect(steps[.hiddenHome]?.evidence == ["Abgedeckt durch den lesenden Auftrag, der mit verborgenem Benutzerordner läuft"])
        #expect(steps[.read]?.evidence.contains("Benutzerordner verborgen: ja") == true)
        #expect(steps[.isolation]?.evidence.contains("Nachbar-Repository lesen: verweigert") == true)
        #expect(steps[.isolation]?.evidence.contains("Git-Metadaten schreiben: verweigert") == true)
        #expect(steps[.revoke]?.status == .waitingForOwner)
        #expect(steps[.quota]?.status == .skipped)
        // Resumed while still signed in: no model run is started, the step fails.
        let runsBefore = try String(contentsOfFile: config + "/runs", encoding: .utf8).count
        var earlyContext = context
        earlyContext.prompter = ScriptedPrompter(answers: ["überspringen"])
        let early = AcceptanceRunner(state: state, context: earlyContext)
        var earlyState = state
        _ = try await early.run()
        earlyState = await early.state
        #expect(earlyState.providers[0].steps[.revoke]?.status == .failed)
        #expect(try String(contentsOfFile: config + "/runs", encoding: .utf8).count == runsBefore)
        // The owner revokes the login; resume finds no subscription and a refused start.
        FileManager.default.createFile(atPath: config + "/logged-out", contents: Data())
        let resumed = AcceptanceRunner(state: state, context: context)
        #expect(try await resumed.run() == true)
        state = await resumed.state
        #expect(state.providers[0].steps[.revoke]?.status == .passed)
        #expect(state.providers[0].steps[.wrongAccount]?.status == .skipped)
        // With the home folder hidden every required step passes against the fixture.
        #expect(state.providers[0].passed, "\(state.providers[0].restrictions)")
        // The report and the fixtures hold nothing private.
        let report = AcceptanceReport.make(state, home: home)
        let text = String(decoding: try report.json(), as: UTF8.self) + report.markdown()
        let fixtures = try FileManager.default.contentsOfDirectory(atPath: folders.fixtures)
            .map { try String(contentsOfFile: folders.fixtures + "/" + $0, encoding: .utf8) }.joined()
        #expect(!fixtures.isEmpty && fixtures.contains("<canary-facts>"))
        for secret in [home, "owner@example.org", "7c9e6679-7425-40de-944b-e07fc1f90ae7", "sess-1234", state.canaries["home"]!, state.canaries["neighbour"]!] {
            #expect(!text.contains(secret) && !fixtures.contains(secret), "\(secret.prefix(12))")
        }
        #expect(!FileManager.default.fileExists(atPath: home + "/.kaiorx-acceptance-test-run"))
        #expect(state.providers[0].accountFingerprint != nil)
    }
}

@Suite struct HiddenHomeStepTests {
    /// The read already runs with the home folder hidden (the product default); the optional
    /// hidden-home step only refers to it and never starts another model turn.
    @Test func theHiddenHomeStepIsCoveredByTheReadWithoutAnotherTurn() async throws {
        let (runner, _, _) = try StandardErrorRecordingTests().runner()
        await runner.setStep(.read, StepResult(status: .passed))
        let covered = await runner.perform(.hiddenHome, provider: 0)
        #expect(covered == StepResult(status: .passed, evidence: ["Abgedeckt durch den lesenden Auftrag, der mit verborgenem Benutzerordner läuft"]))
        await runner.setStep(.read, StepResult(status: .failed))
        let open = await runner.perform(.hiddenHome, provider: 0)
        #expect(open.status == .skipped && open.limitation == "Nicht abgedeckt: der lesende Auftrag hat nicht bestanden")
    }

    /// A readable home folder is now a leak like any other, not a recorded restriction.
    @Test func aReadableHomeIsAnIsolationLeak() {
        let result = AcceptanceRunner.isolationResult(evidence: ["Benutzerordner lesen: möglich"], leaks: ["Benutzerordner lesen"], agentLeak: false)
        #expect(result.status == .failed && result.limitation == "Isolation verletzt: Benutzerordner lesen")
        #expect(AcceptanceRunner.isolationResult(evidence: [], leaks: [], agentLeak: false).status == .passed)
        #expect(AcceptanceRunner.isolationResult(evidence: [], leaks: [], agentLeak: true).limitation == "Isolation verletzt: Agent las geschützte Inhalte")
    }
}

@Suite struct StandardErrorRecordingTests {
    func runner() throws -> (AcceptanceRunner, RunFolders, String) {
        let root = try temporaryRoot("stderr")
        let home = try temporaryRoot("home")
        let folders = RunFolders(root: root + "/run")
        try folders.create()
        let state = RunState(runID: "stderr-run", createdAt: 1_700_000_000_000, kaiorxCommit: nil, providers: [
            ProviderRun(provider: .claude, configuredPath: root + "/missing", nativePath: root + "/missing", model: "m", configDirectory: root + "/config"),
        ])
        var context = KitContext(folders: folders, home: home, host: ProcessHost(), prompter: ScriptedPrompter(answers: []), turnTimeout: .seconds(5), compatibilitySource: nil)
        context.allowsScriptBinaries = true
        return (AcceptanceRunner(state: state, context: context), folders, home)
    }

    /// A step that ends with an error keeps what was recorded, and the standard error separately.
    @Test func aFailedStepKeepsItsRecordingAndItsStandardError() async throws {
        let (runner, folders, home) = try runner()
        let recorder = await runner.recorder
        recorder.sink(true, #"{"method":"initialize"}"#)
        recorder.errorSink("ERROR open \(home)/x: denied")
        let result = await runner.perform(.identify, provider: 0)
        #expect(result.status == .failed)
        #expect(result.evidence.contains("Aufzeichnung: claude-?-identify.jsonl"), "\(result.evidence)")
        #expect(result.evidence.contains("Fehlerausgabe: claude-?-identify-stderr.log"))
        let log = try String(contentsOfFile: folders.fixtures + "/claude-?-identify-stderr.log", encoding: .utf8)
        #expect(log == "ERROR open <home>/x: denied\n")
        #expect(await runner.state.providers[0].fixtures == ["claude-?-identify-stderr.log", "claude-?-identify.jsonl"])
        #expect(await runner.notes.isEmpty)
    }

    /// A private value in the standard error costs only that file, not the protocol recording;
    /// standard error alone is written too.
    @Test func standardErrorIsRedactedOnItsOwn() async throws {
        let (runner, folders, _) = try runner()
        let recorder = await runner.recorder
        let canary = await runner.state.canaries["home"]!
        recorder.sink(true, "{}")
        recorder.errorSink("read \(canary)")
        #expect(await runner.storeFixture(0, step: .author) == "claude-?-author.jsonl")
        #expect(!FileManager.default.fileExists(atPath: folders.fixtures + "/claude-?-author-stderr.log"))
        #expect(await runner.notes.contains("Fehlerausgabe verworfen: privater Wert nach Redaktion (Kanarienwert Benutzerordner in Zeile 1)"))
        #expect(await !runner.notes.joined().contains(canary))

        recorder.errorSink("only standard error")
        #expect(await runner.storeFixture(0, step: .cancel) == nil)
        #expect(FileManager.default.fileExists(atPath: folders.fixtures + "/claude-?-cancel-stderr.log"))
        #expect(await runner.state.providers[0].fixtures == ["claude-?-author.jsonl", "claude-?-cancel-stderr.log"])
    }
}

@Suite struct CheckRoundTests {
    @Test func displayNamesAndNestedOrganisationsAreRedactedButShortUserNamesDoNotDiscardLines() throws {
        let redactor = FixtureRedactor(denylist: ["kai"], paths: [])
        var placeholders: [String: String] = [:]
        let line = #"< {"account":{"type":"chatgpt","planType":"team","workspaceName":"Werkworks GmbH"},"orgName":"Firma XY","organization":{"name":"Muster AG"},"clientInfo":{"name":"kaiorx"}}"#
        let out = try redactor.redact(line, placeholders: &placeholders)
        #expect(out.hasPrefix("< "))
        #expect(!out.contains("Werkworks") && !out.contains("Firma XY") && !out.contains("Muster AG"))
        #expect(out.contains("\"planType\":\"team\"") && out.contains("kaiorx"))
        #expect(throws: FixtureRedactor.Failure.self) { try redactor.redact("user kai here", placeholders: &placeholders) }
    }

    @Test func authVerdictsRefuseMixedBillingFailedCommandsAndUsagePlans() throws {
        #expect(!ClaudeAuthStatus(output: #"{"loggedIn":true,"subscriptionType":"max","apiKeyConfigured":true}"#, exitCode: 0).verdict.allowsRun)
        #expect(!ClaudeAuthStatus(output: #"{"loggedIn":true,"subscriptionType":"max","sources":[{"apiKeySource":"helper"}]}"#, exitCode: 0).verdict.allowsRun)
        #expect(!ClaudeAuthStatus(output: #"{"loggedIn":true,"subscriptionType":"max"}"#, exitCode: 2).verdict.allowsRun)
        for plan in ["self_serve_business_usage_based", "enterprise_cbp_usage_based", "ent26", "free"] {
            let report = CodexAccountReport(account: try JSONValue.parse(#"{"account":{"type":"chatgpt","email":null,"planType":"\#(plan)"},"requiresOpenaiAuth":true}"#), rateLimits: nil)
            #expect(!report.verdict.allowsRun, "\(plan)")
        }
    }

    @Test func evidenceMustCoverExactlyTheBuildAndEveryRequiredStep() throws {
        let root = try temporaryRoot("evidence2")
        try FileManager.default.createDirectory(atPath: root + "/r", withIntermediateDirectories: true)
        func write(_ report: AcceptanceReport) throws -> String {
            let data = try report.json()
            try data.write(to: URL(filePath: root + "/r/report.json"))
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        var report = AcceptanceReport(runID: "r", date: "d", macOS: "m", arch: "a", kaiorxCommit: nil, providers: [AcceptanceReport.Provider(
            provider: "claude", mode: "claudeSubscription", model: "m", version: "2.1.328", binarySHA256: "good", nativePath: "~/b", signing: [], verdict: nil,
            steps: StepID.allCases.map { AcceptanceReport.Step(id: $0.rawValue, title: $0.title, required: $0.required, status: "passed", evidence: [], limitation: nil) },
            passed: true, restrictions: [], fixtures: [])], parallel: nil)
        func entry(_ sha: String, builds: [String]) -> CompatibilityEntry {
            CompatibilityEntry(provider: .claude, version: "2.1.328", status: .liveVerified, notes: "", schemaDigest: nil, builds: builds,
                               evidence: LiveEvidence(reportPath: "r/report.json", reportSHA256: sha, mode: "claudeSubscription"))
        }
        var sha = try write(report)
        #expect(EvidenceCheck.problems(entry(sha, builds: ["good"]), repositoryRoot: root).isEmpty)
        #expect(!EvidenceCheck.problems(entry(sha, builds: ["good", "unchecked"]), repositoryRoot: root).isEmpty)
        // A report that drops a required step (or marks it optional) does not count.
        report.providers[0].steps.removeAll { $0.id == StepID.isolation.rawValue }
        sha = try write(report)
        #expect(EvidenceCheck.problems(entry(sha, builds: ["good"]), repositoryRoot: root) == ["Pflichtschritt nicht bestanden"])
    }
}

@Suite struct LiveRunFollowUpTests {
    @Test func passedStepsAreNoRestriction() {
        var run = ProviderRun(provider: .codex, configuredPath: "/x", nativePath: "/x", model: "m", configDirectory: "/c")
        run.steps[.billing] = StepResult(status: .passed)
        run.steps[.quota] = StepResult(status: .passed, limitation: "Erschöpfung nicht herbeigeführt")
        run.steps[.read] = StepResult(status: .failed)
        #expect(!run.restrictions.contains { $0.hasPrefix("Abrechnung") })
        #expect(run.restrictions.contains("Kontingent beobachten: Erschöpfung nicht herbeigeführt"))
        #expect(run.restrictions.contains("Lesender Auftrag: failed"))
        #expect(run.restrictions.contains("Programm identifizieren: nicht ausgeführt"))
    }

    @Test func protocolItemsKeepTheirContentAccountsDoNot() throws {
        let redactor = FixtureRedactor(denylist: [], paths: [])
        var placeholders: [String: String] = [:]
        let line = #"< {"method":"item/completed","params":{"item":{"id":"i-9","type":"agentMessage","text":"Das Kennwort lautet X.","phase":"final"},"threadId":"thr-77"},"account":{"email":"a@b.c","planType":"plus"}}"#
        let out = try redactor.redact(line, placeholders: &placeholders)
        #expect(out.contains("Das Kennwort lautet X.") && out.contains("\"phase\":\"final\""))
        #expect(!out.contains("i-9") && !out.contains("thr-77") && !out.contains("a@b.c") && out.contains("\"planType\":\"plus\""))
    }

    @Test func standardErrorKeepsItsEndAndIsDiscardedWithTheProtocolLines() {
        let recorder = LineRecorder()
        recorder.sink(true, "{}")
        for index in 0..<(LineRecorder.errorLineLimit + 5) { recorder.errorSink("zeile \(index)") }
        let errors = recorder.takeErrors()
        #expect(errors.count == LineRecorder.errorLineLimit)
        #expect(errors.first == "zeile 5" && errors.last == "zeile \(LineRecorder.errorLineLimit + 4)")
        #expect(recorder.take() == ["> {}"])

        // A discarded recording must not leave its standard error for the next step.
        recorder.errorSink("alt")
        _ = recorder.take()
        #expect(recorder.takeErrors().isEmpty)
    }

    @Test func plainStandardErrorLinesAreRedactedAndFailClosed() throws {
        let redactor = FixtureRedactor(denylist: ["matzetest"], paths: [("/Users/someone", "<home>")])
        var placeholders: [String: String] = [:]
        #expect(try redactor.redact("ERROR open /Users/someone/x: denied", placeholders: &placeholders) == "ERROR open <home>/x: denied")
        #expect(throws: FixtureRedactor.Failure.self) { try redactor.redact("user matzetest", placeholders: &placeholders) }
    }

    /// Fourth live run: four Claude recordings were discarded without a hint. The failure names
    /// the kind, the line and where in the JSON, never the value.
    @Test func aDiscardedRecordingSaysWhatAndWhereButNotTheValue() throws {
        let redactor = FixtureRedactor(denylist: ["matzetest"], paths: [], labels: ["matzetest": "Benutzername"])
        let lines = [
            #"< {"type":"system","subtype":"init"}"#,
            #"< {"type":"assistant","message":{"content":[{"type":"text","text":"Hallo matzetest"}]}}"#,
        ]
        #expect(throws: FixtureRedactor.Failure.privateValueRemains("Benutzername in Zeile 2, assistant: message.content[].text")) {
            try redactor.redact(lines: lines)
        }
        // A key that is itself private is not named.
        #expect(throws: FixtureRedactor.Failure.privateValueRemains("Benutzername in Zeile 1, result: ?")) {
            try redactor.redact(lines: [#"< {"type":"result","matzetest":1}"#])
        }
        // Plain text lines and secrets.
        #expect(throws: FixtureRedactor.Failure.privateValueRemains("Benutzername in Zeile 1")) {
            try redactor.redact(lines: ["user matzetest"])
        }
        #expect(throws: FixtureRedactor.Failure.privateValueRemains("secret:assignment in Zeile 1, user: message.content[].content")) {
            try redactor.redact(lines: [#"< {"type":"user","message":{"content":[{"content":"password = hunter2hunter2"}]}}"#])
        }
    }

    /// Claude derives folder names from paths (`/Users/x/a b` → `-Users-x-a-b`); those are
    /// replaced like the paths themselves.
    @Test func pathsAreAlsoReplacedInTheirDashedForm() throws {
        let redactor = FixtureRedactor(denylist: ["matzetest"], paths: [("/Users/matzetest/Library/Application Support/run", "<run>")])
        var placeholders: [String: String] = [:]
        let out = try redactor.redact("projects/-Users-matzetest-Library-Application-Support-run-data/x", placeholders: &placeholders)
        #expect(out == "projects/<run>-data/x")
    }
}
