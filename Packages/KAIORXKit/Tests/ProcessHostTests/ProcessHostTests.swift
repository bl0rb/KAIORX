import Darwin
import Foundation
import Testing
@testable import ProcessHost

func scratchDirectory() throws -> String {
    let url = FileManager.default.temporaryDirectory.appending(path: "kaiorx-proc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return Confinement.resolved(url.path(percentEncoded: false))
}

func shell(_ script: String, in directory: String, environment: [String: String]? = nil, _ configure: (inout LaunchSpec) -> Void = { _ in }) -> LaunchSpec {
    var spec = LaunchSpec(
        executable: "/bin/sh", arguments: ["-c", script], workingDirectory: directory,
        environment: environment ?? Environment.minimal(temporaryDirectory: directory), timeout: .seconds(20)
    )
    configure(&spec)
    return spec
}

func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

@Suite struct LaunchTests {
    @Test func environmentIsExactlyWhatWasGiven() async throws {
        let dir = try scratchDirectory()
        setenv("KAIORX_TEST_SECRET", "marker-123", 1)
        defer { unsetenv("KAIORX_TEST_SECRET") }
        let result = try await ProcessHost().run(shell("env; /bin/sh -c env", in: dir, environment: ["PATH": "/usr/bin:/bin", "ONLY": "this"]))
        #expect(result.termination == .exited(0))
        let names = Set(result.stdout.text.split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) })
        #expect(!result.stdout.text.contains("marker-123"), "secret leaked to child or grandchild")
        #expect(names.isSubset(of: ["PATH", "ONLY", "PWD", "SHLVL", "_", "OLDPWD"]), "\(names)")
    }

    @Test func minimalEnvironmentNeverInheritsSecrets() {
        setenv("SSH_AUTH_SOCK", "/tmp/agent", 1)
        setenv("ACCESS_TOKEN", "t", 1)
        defer { unsetenv("SSH_AUTH_SOCK"); unsetenv("ACCESS_TOKEN") }
        let env = Environment.minimal(temporaryDirectory: "/tmp/x", inherit: ["HOME", "SSH_AUTH_SOCK", "ACCESS_TOKEN"])
        #expect(env["SSH_AUTH_SOCK"] == nil)
        #expect(env["ACCESS_TOKEN"] == nil)
        #expect(env["TMPDIR"] == "/tmp/x")
    }

    @Test func relativePathsAreRefused() async throws {
        await #expect(throws: ProcessHostError.notAbsolute("sh")) {
            _ = try await ProcessHost().run(LaunchSpec(executable: "sh", workingDirectory: "/"))
        }
        await #expect(throws: ProcessHostError.notAbsolute("tmp")) {
            _ = try await ProcessHost().run(LaunchSpec(executable: "/bin/sh", workingDirectory: "tmp"))
        }
    }

    @Test func missingExecutableFailsToSpawn() async {
        await #expect(throws: ProcessHostError.self) {
            _ = try await ProcessHost().run(LaunchSpec(executable: "/nonexistent/tool", workingDirectory: "/"))
        }
    }

    @Test func workingDirectoryStdinAndExitCode() async throws {
        let dir = try scratchDirectory()
        let result = try await ProcessHost().run(shell("pwd; cat; exit 7", in: dir) { $0.standardInput = Data("hallo\nwelt".utf8) })
        #expect(result.termination == .exited(7))
        #expect(result.stdout.text == "\(dir)\nhallo\nwelt")
    }

    @Test func onlyStandardDescriptorsAreInherited() async throws {
        let dir = try scratchDirectory()
        // A descriptor the host leaves open without CLOEXEC.
        let fd = open(dir + "/held", O_CREAT | O_RDWR, 0o600)
        defer { close(fd) }
        // Lists every open descriptor above 2 as seen by the child itself.
        let script = "for i in $(seq 3 250); do (exec 254<&$i) 2>/dev/null && echo $i; done; exit 0"
        let result = try await ProcessHost().run(shell(script, in: dir))
        let fds = Set(result.stdout.text.split(separator: "\n").compactMap { Int32($0) })
        #expect(fd > 2)
        #expect(fds.isEmpty, "inherited descriptors: \(fds)")
    }

    @Test func streamsOutputWhileRunning() async throws {
        let dir = try scratchDirectory()
        let host = ProcessHost()
        let process = try await host.launch(shell("echo one; echo two >&2; echo three", in: dir) { $0.streamsOutput = true })
        var out = Data(), err = Data()
        for await chunk in try #require(process.output) {
            switch chunk {
            case .stdout(let data): out.append(data)
            case .stderr(let data): err.append(data)
            }
        }
        #expect(String(decoding: out, as: UTF8.self) == "one\nthree\n")
        #expect(String(decoding: err, as: UTF8.self) == "two\n")
        #expect(await process.wait().termination == .exited(0))
    }
}

@Suite struct FloodAndEOFTests {
    @Test func floodingBothStreamsNeverBlocksAndIsBounded() async throws {
        let dir = try scratchDirectory()
        let script = "(yes out | head -c 3000000) & (yes err | head -c 3000000 >&2) & wait"
        let result = try await ProcessHost().run(shell(script, in: dir) { $0.outputLimit = 1000 })
        #expect(result.termination == .exited(0))
        #expect(result.stdout.data.count == 1000)
        #expect(result.stderr.data.count == 1000)
        #expect(result.stdout.totalBytes == 3_000_000)
        #expect(result.stderr.totalBytes == 3_000_000)
        #expect(result.stdout.isTruncated)
        #expect(!result.outputCutOff)
    }

    @Test func leftoverGroupMembersAreKilledWhenTheLeaderExits() async throws {
        let dir = try scratchDirectory()
        let result = try await ProcessHost().run(shell("sleep 60 >/dev/null 2>&1 & echo $!", in: dir))
        let grandchild = try #require(pid_t(result.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!isAlive(grandchild))
    }

    @Test func pipeHeldOutsideTheGroupIsCutOff() async throws {
        let dir = try scratchDirectory()
        // A child in its own session keeps stdout open after the leader exits.
        // The parent waits until the child has left the group (sync pipe closed after setsid).
        let perl = "use POSIX; pipe(R, W); my $p = fork(); if ($p == 0) { close R; POSIX::setsid(); close W; sleep 10; exit 0 } close W; my $x = <R>; print \"$p\\n\";"
        let result = try await ProcessHost().run(LaunchSpec(
            executable: "/usr/bin/perl", arguments: ["-e", perl], workingDirectory: dir,
            environment: Environment.minimal(temporaryDirectory: dir), timeout: .seconds(20)
        ))
        let escaped = try #require(pid_t(result.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(escaped, SIGKILL) }
        #expect(result.termination == .exited(0))
        #expect(result.outputCutOff)
        #expect(result.duration < .seconds(5))
    }
}

@Suite struct StopTests {
    @Test func interruptStopsACooperativeProcess() async throws {
        let dir = try scratchDirectory()
        let host = ProcessHost()
        let process = try await host.launch(LaunchSpec(executable: "/bin/sleep", arguments: ["30"], workingDirectory: dir))
        await process.stop(grace: .milliseconds(500))
        let result = await process.wait()
        #expect(result.termination == .signaled(SIGINT))
        #expect(result.stopReason == .requested)
    }

    @Test func stubbornProcessGroupIsKilled() async throws {
        let dir = try scratchDirectory()
        let host = ProcessHost()
        let process = try await host.launch(shell("trap '' INT TERM; sleep 30 & while :; do sleep 1; done", in: dir))
        try await Task.sleep(for: .milliseconds(100))
        await process.stop(grace: .milliseconds(100))
        let result = await process.wait()
        #expect(result.termination == .signaled(SIGKILL))
        // Stopping a reaped process sends nothing.
        #expect(!process.signalGroup(SIGTERM))
        await process.stop()
    }

    @Test func timeoutStopsTheProcess() async throws {
        let dir = try scratchDirectory()
        let result = try await ProcessHost().run(LaunchSpec(
            executable: "/bin/sleep", arguments: ["30"], workingDirectory: dir,
            timeout: .milliseconds(200), stopGrace: .milliseconds(200)
        ))
        #expect(result.timedOut)
        #expect(result.duration < .seconds(5))
    }

    @Test func drainStopsLateProcessesAndRefusesNewOnes() async throws {
        let dir = try scratchDirectory()
        let host = ProcessHost()
        let quick = try await host.launch(LaunchSpec(executable: "/bin/sleep", arguments: ["0.05"], workingDirectory: dir))
        let slow = try await host.launch(LaunchSpec(executable: "/bin/sleep", arguments: ["30"], workingDirectory: dir))
        let stopped = await host.drain(timeout: .milliseconds(500), grace: .milliseconds(200))
        #expect(stopped == 1)
        #expect(await quick.wait().termination == .exited(0))
        #expect(await slow.wait().stopReason == .drain)
        await #expect(throws: ProcessHostError.draining) {
            _ = try await host.launch(LaunchSpec(executable: "/bin/sleep", arguments: ["0"], workingDirectory: dir))
        }
        await host.resume()
        #expect(try await host.run(LaunchSpec(executable: "/usr/bin/true", workingDirectory: dir)).termination == .exited(0))
    }

    @Test func twoProcessesRunAtTheSameTime() async throws {
        let dir = try scratchDirectory()
        let host = ProcessHost()
        let script = "perl -MTime::HiRes=time -e 'printf(\"%.3f\\n\", time); select(undef,undef,undef,0.3); printf(\"%.3f\\n\", time)'"
        async let a = host.run(shell(script, in: dir))
        async let b = host.run(shell(script, in: dir))
        let intervals = try await [a, b].map { result in
            result.stdout.text.split(separator: "\n").compactMap { Double($0) }
        }
        let (first, second) = (intervals[0], intervals[1])
        #expect(first.count == 2 && second.count == 2)
        #expect(first[0] < second[1] && second[0] < first[1], "runs did not overlap: \(intervals)")
    }
}

@Suite struct ConfinementTests {
    @Test func probeReportsEffectiveSandbox() async throws {
        let dir = try scratchDirectory()
        #expect(await Confinement.probe(host: ProcessHost(), scratch: URL(filePath: dir)) == .effective)
    }

    @Test func writesOutsideAndReadsOfHiddenRootsAreBlockedForGrandchildren() async throws {
        let root = try scratchDirectory()
        let worktrees = root + "/worktrees"
        let own = worktrees + "/own", neighbor = worktrees + "/neighbor", temp = root + "/tmp"
        for path in [own, neighbor, temp] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        try "secret".write(toFile: neighbor + "/marker", atomically: true, encoding: .utf8)
        try "theirs".write(toFile: root + "/user-file", atomically: true, encoding: .utf8)

        let script = """
            echo mine > own.txt && echo own-write
            /bin/sh -c 'echo x > ../neighbor/injected' 2>/dev/null && echo NEIGHBOR-WRITE
            /bin/sh -c 'cat ../neighbor/marker' 2>/dev/null && echo NEIGHBOR-READ
            /bin/sh -c 'echo x >> ../../user-file' 2>/dev/null && echo USER-WRITE
            echo t > "$TMPDIR/t" && echo temp-write
            /usr/bin/perl -MIO::Socket::INET -e 'IO::Socket::INET->new(PeerAddr=>"127.0.0.1",PeerPort=>9,Timeout=>1) or print "$!\n"' | grep -q 'not permitted' && echo network-denied
            exit 0
            """
        let result = try await ProcessHost().run(shell(script, in: own) {
            $0.environment = Environment.minimal(temporaryDirectory: temp)
            $0.confinement = Confinement(writableRoots: [own, temp], hiddenRoots: [worktrees], visibleRoots: [own])
        })
        let lines = Set(result.stdout.text.split(separator: "\n").map(String.init))
        #expect(lines == ["own-write", "temp-write", "network-denied"], "\(lines) / \(result.stderr.text)")
        #expect(!FileManager.default.fileExists(atPath: neighbor + "/injected"))
        #expect(try String(contentsOfFile: root + "/user-file", encoding: .utf8) == "theirs")
    }

    @Test func profileQuotesPathsSafely() {
        let profile = Confinement(writableRoots: ["/tmp/a \"b\" \\c"]).profile()
        #expect(profile.contains(#"(subpath "/private/tmp/a \"b\" \\c")"#))
    }
}

@Suite struct ProcessReviewFixTests {
    @Test func pauseKeepsItsDurationInACancelledTask() async {
        let task = Task {
            let start = ContinuousClock.now
            for _ in 0..<10 { await pause(.milliseconds(10)) }
            return ContinuousClock.now - start
        }
        task.cancel()
        #expect(await task.value >= .milliseconds(90))
    }

    @Test func environmentKeysCannotShadowOtherVariables() async throws {
        let dir = try scratchDirectory()
        for key in ["PATH=/tmp/evil", "", "A\0B"] {
            await #expect(throws: ProcessHostError.invalidEnvironment(key)) {
                _ = try await ProcessHost().run(LaunchSpec(executable: "/usr/bin/true", workingDirectory: dir, environment: [key: "x"]))
            }
        }
        await #expect(throws: ProcessHostError.self) {
            _ = try await ProcessHost().run(LaunchSpec(executable: "/usr/bin/true", arguments: ["a\0b"], workingDirectory: dir))
        }
    }

    @Test func childStdoutKeepsDefaultSigpipeBehaviour() async throws {
        let dir = try scratchDirectory()
        let result = try await ProcessHost().run(shell("perl -MFcntl -e 'print fcntl(STDOUT, 74, 0) + 0'", in: dir))
        #expect(result.stdout.text == "0")
    }
}

@Suite struct StopAndProtectionTests {
    @Test func stopCanSkipTheInterrupt() async throws {
        let dir = try scratchDirectory()
        let process = try await ProcessHost().launch(LaunchSpec(executable: "/bin/sleep", arguments: ["30"], workingDirectory: dir))
        await process.stop(grace: .milliseconds(500), interruptFirst: false)
        #expect(await process.wait().termination == .signaled(SIGTERM))
    }

    @Test func protectedFolderStaysReadOnlyInsideAWritableRoot() async throws {
        let state = try scratchDirectory()
        try FileManager.default.createDirectory(atPath: state + "/rules", withIntermediateDirectories: true)
        let script = "echo x > rules/new && echo RULES; echo y > config.toml && echo CONFIG; echo z > sessions && echo sessions-ok; exit 0"
        let result = try await ProcessHost().run(shell(script, in: state) {
            $0.confinement = Confinement(writableRoots: [state], protectedPaths: [state + "/rules/", state + "/config.toml"])
        })
        #expect(result.stdout.text == "sessions-ok\n")
    }

    /// Third live run: Codex canonicalizes `CODEX_HOME` inside the hidden home folder; that needs
    /// the metadata of every folder above it, but not their contents.
    @Test func visibleRootInsideAHiddenOneCanBeResolvedWithoutListingItsParents() async throws {
        let root = try scratchDirectory()
        let home = root + "/home"
        let state = home + "/Library/Support/state"
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        try "secret".write(toFile: home + "/canary", atomically: true, encoding: .utf8)
        try "own".write(toFile: state + "/own", atomically: true, encoding: .utf8)
        let script = """
            /bin/realpath '\(state)' >/dev/null && echo resolved
            /bin/cat own >/dev/null && echo own-read
            /bin/ls '\(home)' >/dev/null 2>&1 && echo HOME-LISTED
            /bin/ls '\(home)/Library' >/dev/null 2>&1 && echo LIBRARY-LISTED
            /bin/cat '\(home)/canary' >/dev/null 2>&1 && echo CANARY-READ
            exit 0
            """
        let result = try await ProcessHost().run(shell(script, in: state) {
            $0.confinement = Confinement(writableRoots: [state], hiddenRoots: [home], visibleRoots: [state])
        })
        #expect(result.stdout.text == "resolved\nown-read\n", "\(result.stdout.text) / \(result.stderr.text)")
    }
}
