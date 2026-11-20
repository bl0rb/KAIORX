import Foundation
import Testing
@testable import ProcessHost

@Suite struct TerminalProcessTests {
    let env = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": NSTemporaryDirectory(), "LANG": "C"]

    /// Reads until `marker` shows up (or the deadline passes); returns everything read.
    func collect(_ terminal: TerminalProcess, until marker: String, seconds: Double = 10) async -> String {
        var text = ""
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !text.contains(marker) {
            guard let chunk = await terminal.read() else { break }
            text += String(decoding: chunk, as: UTF8.self)
        }
        return text
    }

    @Test func thePTYIsTheControllingTerminal() async throws {
        let host = ProcessHost()
        let terminal = try await host.launchTerminal(TerminalSpec(
            executable: "/bin/sh", arguments: ["-c", "tty -s && echo CTTY-OK; stty size; echo DONE"], workingDirectory: "/tmp", environment: env,
            rows: 33, columns: 101
        ))
        let text = await collect(terminal, until: "DONE")
        #expect(text.contains("CTTY-OK"))
        #expect(text.contains("33 101"))
        #expect(await terminal.wait() == .exited(0))
    }

    @Test func ctrlCReachesTheForegroundJobAndResizeIsSeen() async throws {
        let host = ProcessHost()
        let terminal = try await host.launchTerminal(TerminalSpec(
            executable: "/bin/sh",
            arguments: ["-c", "trap 'echo GOT-INT' INT; trap 'stty size' WINCH; echo READY; while :; do sleep 0.05; done"],
            workingDirectory: "/tmp", environment: env
        ))
        _ = await collect(terminal, until: "READY")
        terminal.resize(rows: 40, columns: 120)
        #expect(await collect(terminal, until: "40 120").contains("40 120"))
        terminal.write(Data([0x03]))
        #expect(await collect(terminal, until: "GOT-INT").contains("GOT-INT"))
        await terminal.hangUp(grace: .seconds(1))
        #expect(await terminal.hasExited)
    }

    @Test func aFloodBlocksInsteadOfFillingMemoryAndHangUpEndsIt() async throws {
        let host = ProcessHost()
        let terminal = try await host.launchTerminal(TerminalSpec(executable: "/usr/bin/yes", workingDirectory: "/tmp", environment: env))
        var total = 0
        for _ in 0..<10 { total += await terminal.read()?.count ?? 0 }
        #expect(total > 0)
        // Nobody reads now: `yes` blocks on the full PTY and stays alive.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!terminal.hasExited)
        await terminal.hangUp(grace: .seconds(1))
        #expect(terminal.hasExited)
    }

    @Test func drainHangsUpTerminals() async throws {
        let host = ProcessHost()
        let terminal = try await host.launchTerminal(TerminalSpec(executable: "/bin/sh", arguments: ["-c", "while :; do sleep 1; done"], workingDirectory: "/tmp", environment: env))
        _ = await host.drain(timeout: .seconds(1), grace: .seconds(1))
        #expect(terminal.hasExited)
        await #expect(throws: ProcessHostError.draining) {
            _ = try await host.launchTerminal(TerminalSpec(executable: "/bin/sh", workingDirectory: "/tmp", environment: env))
        }
    }
}

@Suite struct TerminalProcessCheckTests {
    let env = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": NSTemporaryDirectory(), "LANG": "C"]

    /// A program that never reads its input, a paste that fills the PTY, then a hang-up: the
    /// hang-up returns and the program ends (it used to wait for the stuck write forever).
    @Test func aFullInputQueueNeitherBlocksHangUpNorLaterInput() async throws {
        let host = ProcessHost()
        let terminal = try await host.launchTerminal(TerminalSpec(executable: "/bin/sleep", arguments: ["30"], workingDirectory: "/tmp", environment: env))
        terminal.write(Data("ls\n".utf8))
        terminal.write(Data(repeating: 0x61, count: 64 * 1024))
        terminal.write(Data([0x03]))
        let started = ContinuousClock.now
        await terminal.hangUp(grace: .milliseconds(500))
        #expect(terminal.hasExited)
        #expect(ContinuousClock.now - started < .seconds(5))
        // Writes after the hang-up are dropped, not sent to a reused descriptor.
        terminal.write(Data("nach dem Auflegen".utf8))
        #expect(await terminal.read() == nil)
    }
}
