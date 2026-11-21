import Darwin
import Foundation
import ProcessHost
import Synchronization

/// One synthetic escape attempt a confined process makes (ADR 0002 §5). Each probe runs a small
/// shell or Perl script under the given `Confinement` through `ProcessHost`, and the suite
/// checks the effect itself where it can (a marker read back, a file on disk, a connection the
/// listener received, a job launchd lists). "Blocked" needs proof on both sides: the script shows
/// it ran (a first line with the run's token) and the attempt shows the refusal itself (EPERM,
/// LaunchServices' permErr, defaults' write error). A probe that failed to start, found no tool or
/// failed otherwise is inconclusive, never blocked.
public enum IsolationProbe: String, CaseIterable, Sendable, Codable {
    /// Reads a marker in a folder of the (fake) home folder that holds no credentials (`Documents`).
    case readHiddenHome
    /// Reads a marker in a credential folder of the home folder (`.ssh`).
    case readCredentials
    /// Reads the KAIORX data: the support folder (database, provider logins) and the workspace root.
    case readDataRoot
    /// Writes outside every writable root (a sibling folder and the home folder).
    case writeOutsideRoots
    /// Writes into the worktree; allowed only for roles that write it.
    case writeWorktree
    /// Rewrites or moves the worktree's `.git` link file.
    case writeGitLink
    /// Connects over TCP to a listener on 127.0.0.1 that the caller opened.
    case networkLoopback
    /// Resolves a host name.
    case networkDNS
    /// Starts a child in its own session (`setsid`) that should not outlive the process group stop.
    case setsidSurvivor
    /// Submits a benign launchd job (`launchctl submit`) that would run outside the sandbox.
    case launchctlSubmit
    /// Opens a synthetic background app through LaunchServices (`open`), which would run outside the sandbox.
    case launchServicesOpen
    /// Writes a preference to a bench domain (`defaults write`); cfprefsd writes it, not the process.
    case defaultsWrite

    /// Touches the user's login session (launchd, LaunchServices, cfprefsd). Runs only when the
    /// caller opts in (`KAIORX_INTRUSIVE_PROBES=1` in tests) and always cleans up afterwards.
    public var isIntrusive: Bool {
        switch self {
        case .launchctlSubmit, .launchServicesOpen, .defaultsWrite: true
        default: false
        }
    }

    /// The probes that never touch the user's session.
    public static let nonIntrusive: [IsolationProbe] = allCases.filter { !$0.isIntrusive }

    /// What a role must block. Everything not listed may be reached, either by design (network
    /// for `agentCLI`, the worktree for a writing role, the home folder for roles that keep it
    /// visible) or as a recorded gap (`setsidSurvivor`, ADR 0002 §5).
    public static func mustBlock(_ role: RoleProfile, hidesHome: Bool? = nil) -> Set<IsolationProbe> {
        var result: Set<IsolationProbe> = [
            .readCredentials, .readDataRoot, .writeOutsideRoots, .writeGitLink, .launchctlSubmit, .launchServicesOpen, .defaultsWrite,
        ]
        var writesWorktree = false
        var network = false
        var homeHidden = false
        switch role {
        case .author: writesWorktree = true
        case .reviewer: break
        case .testRunner(let writes): writesWorktree = writes
        case .agentCLI(_, let writes, _, _):
            writesWorktree = writes
            network = true
            homeHidden = true
        }
        if !writesWorktree { result.insert(.writeWorktree) }
        if !network { result.formUnion([.networkLoopback, .networkDNS]) }
        if hidesHome ?? homeHidden { result.insert(.readHiddenHome) }
        return result
    }
}

public enum IsolationProbeOutcome: Sendable, Equatable {
    /// The attempt had no effect; the detail says what stopped it.
    case blocked(String)
    /// The attempt took effect; the detail says where.
    case reached(String)
    /// Neither could be established (for example a DNS lookup while offline).
    case inconclusive(String)
    /// Not run (an intrusive probe without opt-in, a missing system tool).
    case skipped(String)

    public var isBlocked: Bool { if case .blocked = self { true } else { false } }
    public var isReached: Bool { if case .reached = self { true } else { false } }
}

public struct IsolationProbeResult: Sendable, Equatable {
    public let probe: IsolationProbe
    public let outcome: IsolationProbeOutcome
}

public struct IsolationProbeReport: Sendable, Equatable {
    public let results: [IsolationProbeResult]

    public subscript(probe: IsolationProbe) -> IsolationProbeOutcome? {
        results.first { $0.probe == probe }?.outcome
    }

    public var reached: Set<IsolationProbe> { Set(results.filter(\.outcome.isReached).map(\.probe)) }

    /// Probes the role must block that were not shown to be blocked (reached or inconclusive).
    /// Skipped probes are not violations; a self-test that requires them must run them.
    public func violations(of role: RoleProfile, hidesHome: Bool? = nil) -> [IsolationProbeResult] {
        let required = IsolationProbe.mustBlock(role, hidesHome: hidesHome)
        return results.filter { result in
            guard required.contains(result.probe) else { return false }
            switch result.outcome {
            case .blocked, .skipped: return false
            case .reached, .inconclusive: return true
            }
        }
    }
}

/// A synthetic world shaped like the product's folders, with a marker wherever a confined
/// process must not reach: a fake home folder with `Documents` and `.ssh`, KAIORX's support folder
/// inside it (`Library/Application Support/KAIORX` with a database file and the provider state
/// folders), the workspace root with a worktree (a `.git` link file) and a run folder, and a
/// folder outside every root. Never the real home folder.
public struct IsolationProbeFixture: Sendable {
    public let base: String
    public let home: String
    public let support: String
    public let layout: WorkspaceLayout
    public let worktree: String
    public let runTemporaryDirectory: String
    /// Neither writable nor hidden for any role.
    public let outside: String
    /// The content of every marker; unique per fixture.
    public let nonce: String

    public static let markerName = "kaiorx-probe-marker"

    /// Creates the fixture below `parent` (a temporary folder, never the real home folder).
    public static func create(in parent: String) throws -> IsolationProbeFixture {
        let nonce = "kaiorx-probe-" + UUID().uuidString.lowercased()
        let base = Confinement.resolved(parent) + "/isolation-probes-" + UUID().uuidString.prefix(8).lowercased()
        let home = base + "/home"
        let support = home + "/Library/Application Support/KAIORX"
        let layout = WorkspaceLayout(root: support + "/workspace")
        let worktree = layout.worktreePath(token: "probe/worktree")
        let run = layout.runsRoot + "/probe"
        let outside = base + "/outside"
        let fixture = IsolationProbeFixture(
            base: base, home: home, support: support, layout: layout,
            worktree: worktree, runTemporaryDirectory: run, outside: outside, nonce: nonce
        )
        let fm = FileManager.default
        for folder in [
            home + "/Documents", home + "/.ssh", layout.root, worktree, run, outside, layout.gitHome,
            fixture.stateDirectory(.claude), fixture.stateDirectory(.codex),
        ] {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        for path in [fixture.hiddenHomeMarker, fixture.credentialMarker] + fixture.dataRootMarkers {
            try Data(nonce.utf8).write(to: URL(filePath: path))
        }
        try Data("let probe = 1\n".utf8).write(to: URL(filePath: worktree + "/main.swift"))
        try Data(fixture.gitLinkContent.utf8).write(to: URL(filePath: worktree + "/.git"))
        return fixture
    }

    /// Removes everything the fixture created.
    public func remove() {
        try? FileManager.default.removeItem(atPath: base)
    }

    /// KAIORX's state folder for a provider CLI, as `ProviderAdapters` places it.
    public func stateDirectory(_ cli: RoleProfile.AgentCLI) -> String {
        support + (cli == .claude ? "/claude-config" : "/codex-home")
    }

    public var hiddenHomeMarker: String { home + "/Documents/" + Self.markerName }
    public var credentialMarker: String { home + "/.ssh/" + Self.markerName }
    /// The database in the support folder and a file in the workspace root.
    public var dataRootMarkers: [String] { [support + "/kaiorx.sqlite", layout.root + "/" + Self.markerName] }
    var gitLinkContent: String { "gitdir: \(base)/repository.git/worktrees/probe\n" }
}

/// A TCP listener on 127.0.0.1 with a free port. It accepts connections on its own thread and
/// records the first line each one sends, so the loopback probe checks what actually arrived.
public final class LoopbackListener: Sendable {
    public let port: UInt16
    private let socket: Int32
    private let received = Mutex<[String]>([])
    private let stopped = Mutex(false)

    public init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, generic, &length) == 0
            }
        }
        guard bound else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        socket = fd
        port = UInt16(bigEndian: address.sin_port)
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "kaiorx.loopback-listener"
        thread.start()
    }

    /// Lines received so far (one per connection).
    public var lines: [String] { received.withLock { $0 } }

    /// Stops accepting; the accept thread closes the socket within 100 ms. Call it when done:
    /// the thread keeps the listener alive until then.
    public func stop() {
        stopped.withLock { $0 = true }
    }

    private func acceptLoop() {
        defer { Darwin.close(socket) }
        while !stopped.withLock({ $0 }) {
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            let client = accept(socket, nil, nil)
            guard client >= 0 else { continue }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = read(client, &buffer, buffer.count)
            Darwin.close(client)
            if count > 0 {
                let line = String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                received.withLock { $0.append(line) }
            }
        }
    }
}

/// Runs the isolation probes under a confinement. Reused as the per-Mac self-test of the
/// unattended mode and as the counter-check for a VM (package I); see ADR 0002 §5.
public struct IsolationProbes: Sendable {
    public let host: ProcessHost
    /// Name for the DNS probe; an unconfined lookup of it reaches the resolver.
    public var dnsName: String = "apple.com"
    /// The tools the probe scripts start (replaceable in tests: a probe that cannot start or
    /// finds no tool must come out inconclusive, never blocked).
    var tools = Tools()

    struct Tools: Sendable {
        var shell = "/bin/sh"
        var launchctl = IsolationProbes.launchctl
        var open = "/usr/bin/open"
        var defaults = IsolationProbes.defaults
    }

    public init(host: ProcessHost) {
        self.host = host
    }

    /// The opt-in for intrusive probes in tests and developer runs.
    public static var intrusiveOptIn: Bool { ProcessInfo.processInfo.environment["KAIORX_INTRUSIVE_PROBES"] == "1" }

    static let perl = "/usr/bin/perl"
    static let launchctl = "/bin/launchctl"
    static let defaults = "/usr/bin/defaults"
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Runs `probes` in order. `confinement` `nil` runs them unconfined: the control that shows
    /// each probe detects an escape. Intrusive probes run only with `intrusive`.
    public func run(
        _ probes: [IsolationProbe] = IsolationProbe.allCases, confinement: Confinement?, fixture: IsolationProbeFixture,
        listener: LoopbackListener, intrusive: Bool = IsolationProbes.intrusiveOptIn
    ) async -> IsolationProbeReport {
        var results: [IsolationProbeResult] = []
        for probe in probes {
            let outcome: IsolationProbeOutcome
            if probe.isIntrusive, !intrusive {
                outcome = .skipped("intrusive probe without opt-in (KAIORX_INTRUSIVE_PROBES=1)")
            } else {
                outcome = await run(probe, confinement: confinement, fixture: fixture, listener: listener)
            }
            results.append(IsolationProbeResult(probe: probe, outcome: outcome))
        }
        return IsolationProbeReport(results: results)
    }

    private func run(
        _ probe: IsolationProbe, confinement: Confinement?, fixture: IsolationProbeFixture, listener: LoopbackListener
    ) async -> IsolationProbeOutcome {
        let context = Context(host: host, confinement: confinement, fixture: fixture, tools: tools)
        do {
            switch probe {
            case .readHiddenHome: return try await context.read([fixture.hiddenHomeMarker])
            case .readCredentials: return try await context.read([fixture.credentialMarker])
            case .readDataRoot: return try await context.read(fixture.dataRootMarkers)
            case .writeOutsideRoots:
                return try await context.write([fixture.outside + "/written-" + context.token, fixture.home + "/written-" + context.token])
            case .writeWorktree: return try await context.write([fixture.worktree + "/written-" + context.token])
            case .writeGitLink: return try await context.writeGitLink()
            case .networkLoopback: return try await context.loopback(listener)
            case .networkDNS: return try await context.resolve(dnsName)
            case .setsidSurvivor: return try await context.setsidSurvivor()
            case .launchctlSubmit: return try await context.launchctlSubmit()
            case .launchServicesOpen: return try await context.launchServicesOpen()
            case .defaultsWrite: return try await context.defaultsWrite()
            }
        } catch {
            return .inconclusive("probe failed to run: \(error)")
        }
    }
}

private struct Context {
    let host: ProcessHost
    let confinement: Confinement?
    let fixture: IsolationProbeFixture
    let tools: IsolationProbes.Tools
    /// Unique per probe run; names files, jobs and domains.
    let token = UUID().uuidString.prefix(12).lowercased()

    static let denied = "Operation not permitted"

    var environment: [String: String] {
        Environment.minimal(temporaryDirectory: fixture.runTemporaryDirectory, inherit: [], extra: ["HOME": fixture.home])
    }

    func spec(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(15)) -> LaunchSpec {
        LaunchSpec(
            executable: executable, arguments: arguments, workingDirectory: fixture.worktree, environment: environment,
            timeout: timeout, stopGrace: .milliseconds(300), confinement: confinement
        )
    }

    /// A confined shell script; `arguments` become `$1…`.
    func shell(_ script: String, _ arguments: [String] = []) async throws -> ProcessResult {
        try await host.run(spec(tools.shell, ["-c", script, "probe"] + arguments))
    }

    /// An unconfined helper (verification and cleanup), never a probe.
    @discardableResult
    func helper(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        try await host.run(LaunchSpec(
            executable: executable, arguments: arguments, workingDirectory: fixture.base, environment: environment, timeout: .seconds(15)
        ))
    }

    func read(_ paths: [String]) async throws -> IsolationProbeOutcome {
        let script = #"""
            for f in "$@"; do
              if c=$(cat "$f" 2>&1); then printf 'READ %s %s\n' "$f" "$c"; else printf 'ERR %s %s\n' "$f" "$c"; fi
            done
            exit 0
            """#
        let lines = try await shell(script, paths).stdout.text.split(separator: "\n").map(String.init)
        let reached = paths.filter { path in lines.contains("READ \(path) \(fixture.nonce)") }
        if !reached.isEmpty { return .reached("read \(reached.joined(separator: ", "))") }
        let errors = lines.filter { $0.hasPrefix("ERR ") }
        if errors.count == paths.count, errors.allSatisfy({ $0.contains(Self.denied) }) { return .blocked(Self.denied) }
        return .inconclusive(lines.joined(separator: "; "))
    }

    func write(_ paths: [String]) async throws -> IsolationProbeOutcome {
        let script = #"""
            for f in "$@"; do printf '%s' "$TOKEN" > "$f" 2>/dev/null || printf 'ERR %s\n' "$f"; done
            exit 0
            """#
        let result = try await shell("TOKEN=\(fixture.nonce); export TOKEN\n" + script, paths)
        defer { for path in paths { try? FileManager.default.removeItem(atPath: path) } }
        let reached = paths.filter { (try? String(contentsOfFile: $0, encoding: .utf8)) == fixture.nonce }
        if !reached.isEmpty { return .reached("wrote \(reached.joined(separator: ", "))") }
        let errors = result.stdout.text.split(separator: "\n").filter { $0.hasPrefix("ERR ") }
        return errors.count == paths.count ? .blocked("write refused") : .inconclusive(result.stdout.text + result.stderr.text)
    }

    func writeGitLink() async throws -> IsolationProbeOutcome {
        let link = fixture.worktree + "/.git"
        let moved = fixture.worktree + "/.git-moved-" + token
        // The first line proves the script ran; each attempt reports its own error text.
        let script = #"""
            printf 'RAN %s\n' "$1"
            if e=$( { printf 'gitdir: /tmp/evil\n' >> "$2"; } 2>&1 ); then echo APPENDED; else printf 'ERR append %s\n' "$e"; fi
            if e=$(mv "$2" "$3" 2>&1); then echo MOVED; else printf 'ERR move %s\n' "$e"; fi
            exit 0
            """#
        let result = try await shell(script, [token, link, moved])
        let fm = FileManager.default
        let changed = (try? String(contentsOfFile: link, encoding: .utf8)) != fixture.gitLinkContent
        let wasMoved = fm.fileExists(atPath: moved)
        // Restore the fixture for the next probe.
        if wasMoved { try? fm.removeItem(atPath: link); try? fm.moveItem(atPath: moved, toPath: link) }
        if changed || wasMoved { try? Data(fixture.gitLinkContent.utf8).write(to: URL(filePath: link)) }
        if changed || wasMoved {
            return .reached([changed ? "rewrote .git" : nil, wasMoved ? "moved .git" : nil].compactMap(\.self).joined(separator: ", "))
        }
        let lines = result.stdout.text.split(separator: "\n").map(String.init)
        guard lines.first == "RAN \(token)" else { return .inconclusive("probe script did not run: \(Self.text(result))") }
        // Blocked only when the sandbox refused both attempts, not a missing file or another error.
        let refused = ["ERR append ", "ERR move "].allSatisfy { prefix in
            lines.contains { $0.hasPrefix(prefix) && $0.contains(Self.denied) }
        }
        return refused ? .blocked(Self.denied) : .inconclusive(lines.joined(separator: "; "))
    }

    /// The output of a confined attempt with a system tool (`attempt`).
    struct Attempt {
        /// The script's first line proved it ran.
        var ran = false
        /// The tool was not executable at its path.
        var missingTool: String?
        /// The tool's exit status; `nil` when the script ended before reporting it.
        var status: Int32?
        /// What the tool printed (stdout and stderr).
        var output = ""
        /// Everything the script printed, for the detail of an inconclusive outcome.
        var raw = ""
    }

    /// Runs `command` (shell code that starts the tool as `"$t"`, with `arguments` as `$1…`) in
    /// a confined script that first proves it ran and that the tool exists, then reports the
    /// tool's exit status. Only such an attempt can show a refusal (ADR 0002 §5).
    func attempt(_ tool: String, _ command: String, _ arguments: [String]) async throws -> Attempt {
        let script = #"""
            printf 'RAN %s\n' "$1"; t=$2; shift 2
            [ -x "$t" ] || { printf 'MISSING %s\n' "$t"; exit 0; }
            """# + "\n" + command + " 2>&1\n" + #"printf '\nexit=%s\n' "$?""#
        let result = try await shell(script, [token, tool] + arguments)
        var attempt = Attempt(raw: Self.text(result))
        var lines = result.stdout.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard lines.first == "RAN \(token)" else { return attempt }
        attempt.ran = true
        lines.removeFirst()
        if let missing = lines.first, missing.hasPrefix("MISSING ") {
            attempt.missingTool = String(missing.dropFirst("MISSING ".count))
            return attempt
        }
        if let last = lines.last, last.hasPrefix("exit="), let status = Int32(last.dropFirst("exit=".count)) {
            attempt.status = status
            lines.removeLast()
        }
        attempt.output = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return attempt
    }

    /// Why an attempt shows nothing about the sandbox, or `nil` when the tool ran to an exit status.
    static func unproven(_ attempt: Attempt) -> IsolationProbeOutcome? {
        if !attempt.ran { return .inconclusive("probe script did not run: \(attempt.raw)") }
        if let tool = attempt.missingTool { return .inconclusive("tool missing: \(tool)") }
        if attempt.status == nil { return .inconclusive("probe script ended early: \(attempt.raw)") }
        return nil
    }

    static func text(_ result: ProcessResult) -> String {
        (result.stdout.text + result.stderr.text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func loopback(_ listener: LoopbackListener) async throws -> IsolationProbeOutcome {
        guard FileManager.default.isExecutableFile(atPath: IsolationProbes.perl) else { return .skipped("no \(IsolationProbes.perl)") }
        let message = "\(fixture.nonce)-\(token)"
        let script = #"""
            use IO::Socket::INET;
            my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1", PeerPort => $ARGV[0], Proto => "tcp", Timeout => 3);
            if ($s) { print $s "$ARGV[1]\n"; close($s); print "CONNECTED\n"; } else { print "FAILED errno=", ($! + 0), " $!\n"; }
            """#
        let result = try await host.run(spec(IsolationProbes.perl, ["-e", script, String(listener.port), message]))
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if listener.lines.contains(message) { return .reached("connected to 127.0.0.1:\(listener.port)") }
            if !result.stdout.text.hasPrefix("CONNECTED") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let output = result.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.contains("errno=1 ") ? .blocked(Self.denied) : .inconclusive(output + result.stderr.text)
    }

    func resolve(_ name: String) async throws -> IsolationProbeOutcome {
        guard FileManager.default.isExecutableFile(atPath: IsolationProbes.perl) else { return .skipped("no \(IsolationProbes.perl)") }
        let script = #"""
            use Socket qw(getaddrinfo SOCK_STREAM);
            $! = 0;
            my ($err, @res) = getaddrinfo($ARGV[0], "443", {socktype => SOCK_STREAM});
            if (!$err && @res) { print "RESOLVED ", scalar(@res), "\n"; } else { print "FAILED errno=", ($! + 0), " $err\n"; }
            """#
        let output = try await host.run(spec(IsolationProbes.perl, ["-e", script, name])).stdout.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if output.hasPrefix("RESOLVED") { return .reached("resolved \(name)") }
        // The resolver is reached over a socket to mDNSResponder; the sandbox refuses it with EPERM.
        if output.contains("errno=1 ") { return .blocked(Self.denied) }
        return .inconclusive("lookup failed without a sandbox refusal (offline?): \(output)")
    }

    func setsidSurvivor() async throws -> IsolationProbeOutcome {
        guard FileManager.default.isExecutableFile(atPath: IsolationProbes.perl) else { return .skipped("no \(IsolationProbes.perl)") }
        let pidFile = fixture.runTemporaryDirectory + "/survivor-" + token
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        // The child leaves the process group, drops the pipes and sleeps; the leader stays until stopped.
        let script = #"""
            /usr/bin/perl -e 'use POSIX; my $pid = fork(); if ($pid == 0) { POSIX::setsid(); open(STDIN, "<", "/dev/null"); open(STDOUT, ">", "/dev/null"); open(STDERR, ">", "/dev/null"); exec("/bin/sleep", "20"); } open(my $f, ">", $ARGV[0]) or die; print $f $pid; close($f);' "$1"
            exec /bin/sleep 20
            """#
        let process = try await host.launch(spec("/bin/sh", ["-c", script, "probe", pidFile], timeout: .seconds(25)))
        var survivor: pid_t?
        let deadline = ContinuousClock.now + .seconds(5)
        while survivor == nil, ContinuousClock.now < deadline, !process.hasExited {
            if let text = try? String(contentsOfFile: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespaces)) {
                survivor = pid
            } else {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        await process.stop(reason: .requested, grace: .milliseconds(300))
        let result = await process.wait()
        guard let survivor else { return .inconclusive("no child started: \(result.stderr.text)") }
        try await Task.sleep(for: .milliseconds(100))
        let alive = Self.isSleep(survivor)
        if alive { kill(survivor, SIGKILL) }
        return alive ? .reached("pid \(survivor) outlived the process group stop") : .blocked("stopped with the process group")
    }

    /// The pid is alive and runs `sleep` (guards against a reused pid before killing it).
    static func isSleep(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        var name = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return false }
        return String(decoding: name.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self) == "sleep"
    }

    func launchctlSubmit() async throws -> IsolationProbeOutcome {
        let label = "com.kaiorx.probe." + token
        let marker = fixture.outside + "/launchd-" + token
        // The job writes outside every writable root; it could only do that outside the sandbox.
        let command = #"""
            "$t" submit -l "$1" -- /bin/sh -c 'printf "%s" "$0" > "$1"; exec /bin/sleep 30' "$2" "$3"
            """#
        let outcome: IsolationProbeOutcome
        do {
            let attempt = try await self.attempt(tools.launchctl, command, [label, fixture.nonce, marker])
            var reached = false
            let deadline = ContinuousClock.now + .seconds(2)
            while !reached, ContinuousClock.now < deadline {
                reached = (try? String(contentsOfFile: marker, encoding: .utf8)) == fixture.nonce
                // A refused submit needs no waiting; the listing below still checks launchd.
                if !reached, attempt.status != 0 { break }
                if !reached { try await Task.sleep(for: .milliseconds(50)) }
            }
            let listed = try await helper(IsolationProbes.launchctl, ["list", label]).termination.isSuccess
            if reached || listed {
                outcome = .reached(reached ? "launchd ran the job outside the sandbox" : "launchd accepted the job")
            } else if let unproven = Self.unproven(attempt) {
                outcome = unproven
            } else if attempt.status == 1, attempt.output.isEmpty {
                // launchctl exits with launchd's error code and prints nothing: 1 is EPERM.
                outcome = .blocked("launchd refused the job (\(Self.denied))")
            } else {
                outcome = .inconclusive("submit ended with exit \(attempt.status ?? -1) without a refusal, job not found: \(attempt.output)")
            }
        } catch {
            outcome = .inconclusive("probe failed to run: \(error)")
        }
        // Cleanup always: remove the job (also stops it) and its marker.
        _ = try? await helper(IsolationProbes.launchctl, ["remove", label])
        try? FileManager.default.removeItem(atPath: marker)
        return outcome
    }

    func launchServicesOpen() async throws -> IsolationProbeOutcome {
        let app = fixture.runTemporaryDirectory + "/KAIORXProbe-" + token + ".app"
        let marker = fixture.outside + "/launchservices-" + token
        let fm = FileManager.default
        let outcome: IsolationProbeOutcome
        do {
            try fm.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "CFBundleIdentifier": "com.kaiorx.probe." + token, "CFBundleExecutable": "probe", "CFBundlePackageType": "APPL",
                "CFBundleName": "KAIORXProbe", "LSBackgroundOnly": true,
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: URL(filePath: app + "/Contents/Info.plist"))
            let executable = app + "/Contents/MacOS/probe"
            try Data("#!/bin/sh\nprintf '%s' '\(fixture.nonce)' > '\(marker)'\n".utf8).write(to: URL(filePath: executable))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
            // `open` of the bundle's URL; the app writes outside every writable root.
            let attempt = try await self.attempt(tools.open, #""$t" -g -j "$1""#, [app])
            var reached = false
            let deadline = ContinuousClock.now + .seconds(5)
            while !reached, ContinuousClock.now < deadline {
                reached = (try? String(contentsOfFile: marker, encoding: .utf8)) == fixture.nonce
                if !reached, attempt.status != 0 { break }
                if !reached { try await Task.sleep(for: .milliseconds(50)) }
            }
            if reached {
                outcome = .reached("LaunchServices started an app outside the sandbox")
            } else if let unproven = Self.unproven(attempt) {
                outcome = unproven
            } else if attempt.status != 0, attempt.output.contains("error -54") {
                // -54 is permErr: the sandbox's `(deny lsopen)`, not a missing or broken app.
                outcome = .blocked("LaunchServices refused: \(attempt.output)")
            } else {
                outcome = .inconclusive("open ended with exit \(attempt.status ?? -1) without a refusal, app did not run: \(attempt.output)")
            }
        } catch {
            outcome = .inconclusive("probe failed to run: \(error)")
        }
        // Cleanup always: unregister the synthetic app, remove it and the marker.
        if fm.isExecutableFile(atPath: IsolationProbes.lsregister) {
            _ = try? await helper(IsolationProbes.lsregister, ["-u", app])
        }
        try? fm.removeItem(atPath: app)
        try? fm.removeItem(atPath: marker)
        return outcome
    }

    func defaultsWrite() async throws -> IsolationProbeOutcome {
        let domain = "com.kaiorx.probe." + token
        let outcome: IsolationProbeOutcome
        do {
            let attempt = try await self.attempt(tools.defaults, #""$t" write "$1" probe "$2""#, [domain, fixture.nonce])
            let read = try await helper(IsolationProbes.defaults, ["read", domain, "probe"])
            if read.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines) == fixture.nonce {
                outcome = .reached("cfprefsd stored the preference")
            } else if let unproven = Self.unproven(attempt) {
                outcome = unproven
            } else if attempt.status != 0, attempt.output.contains("Could not write domain") {
                // cfprefsd refused the write (`(deny user-preference-write)`) and defaults said so.
                outcome = .blocked("not stored: \(attempt.output)")
            } else {
                outcome = .inconclusive("write ended with exit \(attempt.status ?? -1) without a refusal, not stored: \(attempt.output)")
            }
        } catch {
            outcome = .inconclusive("probe failed to run: \(error)")
        }
        // Cleanup always: delete the domain and any file cfprefsd left (the real user's
        // preferences folder holds only this bench domain's file; nothing else is touched).
        _ = try? await helper(IsolationProbes.defaults, ["delete", domain])
        for folder in [fixture.home, Self.accountHome].compactMap(\.self) {
            try? FileManager.default.removeItem(atPath: folder + "/Library/Preferences/" + domain + ".plist")
        }
        return outcome
    }

    /// The account's home folder (cfprefsd stores preferences there whatever `HOME` says).
    static var accountHome: String? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        return String(cString: dir)
    }
}
