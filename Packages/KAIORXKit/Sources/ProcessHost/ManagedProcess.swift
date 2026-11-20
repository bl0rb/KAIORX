import Darwin
import Foundation
import Synchronization

/// One child process in its own process group.
///
/// Signals go to the whole group and only while the group leader has not been reaped: the
/// leader is detected with `waitid(WNOWAIT)`, leftover group members are killed while the zombie
/// still reserves the group ID, and only then is it reaped. A PID alone never legitimises a signal.
public final class ManagedProcess: Sendable {
    public let id = UUID()
    public let pid: pid_t
    /// Output chunks while the process runs; `nil` unless `LaunchSpec.streamsOutput`.
    public let output: AsyncStream<OutputChunk>?

    private struct State {
        var reaped = false
        var result: ProcessResult?
        var waiters: [CheckedContinuation<ProcessResult, Never>] = []
        var stopReason: StopReason?
        var stdout = CapturedOutput()
        var stderr = CapturedOutput()
        var cutOffRequested = false
        /// Host end of an interactive stdin pipe.
        var input: Int32?
    }

    private let state = Mutex(State())
    private let readerDone = DispatchSemaphore(value: 0)
    /// Serialises writes to an interactive stdin, off the caller's thread.
    private let inputQueue = DispatchQueue(label: "kaiorx.process.input")
    private let started = ContinuousClock.now
    private let outputLimit: Int

    private init(pid: pid_t, outputLimit: Int, output: AsyncStream<OutputChunk>?) {
        self.pid = pid
        self.outputLimit = outputLimit
        self.output = output
    }

    // MARK: Spawn

    static func spawn(_ spec: LaunchSpec) throws -> ManagedProcess {
        guard spec.executable.hasPrefix("/") else { throw ProcessHostError.notAbsolute(spec.executable) }
        guard spec.workingDirectory.hasPrefix("/") else { throw ProcessHostError.notAbsolute(spec.workingDirectory) }

        var (executable, arguments) = (spec.executable, spec.arguments)
        if let confinement = spec.confinement {
            guard FileManager.default.isExecutableFile(atPath: Confinement.sandboxExecutable) else {
                throw ProcessHostError.confinementUnavailable("\(Confinement.sandboxExecutable) not found")
            }
            (executable, arguments) = confinement.wrap(executable: executable, arguments: arguments)
        }

        for (key, value) in spec.environment where key.isEmpty || key.contains("=") || key.contains("\0") || value.contains("\0") {
            throw ProcessHostError.invalidEnvironment(key)
        }
        if let bad = ([executable] + arguments).first(where: { $0.contains("\0") }) {
            throw ProcessHostError.invalidArgument(bad)
        }

        // On failure, close whatever was already created.
        var created: [Int32] = []
        func pipeOrCleanUp(sigpipeSafe: Bool) throws -> (read: Int32, write: Int32) {
            do {
                let pipe = try makePipe(sigpipeSafe: sigpipeSafe)
                created += [pipe.read, pipe.write]
                return pipe
            } catch {
                created.forEach { close($0) }
                throw error
            }
        }
        let stdoutPipe = try pipeOrCleanUp(sigpipeSafe: false)
        let stderrPipe = try pipeOrCleanUp(sigpipeSafe: false)
        // Only the host writes stdin; a child that exits early must not kill it with SIGPIPE.
        let stdinPipe = spec.standardInput == nil && !spec.interactiveInput ? nil : try pipeOrCleanUp(sigpipeSafe: true)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdinPipe {
            posix_spawn_file_actions_adddup2(&actions, stdinPipe.read, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe.write, 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe.write, 2)
        // `addchdir` exists from the macOS 26 SDK (Swift 6.2) on; older SDKs only know `_np`.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            posix_spawn_file_actions_addchdir(&actions, spec.workingDirectory)
        } else {
            posix_spawn_file_actions_addchdir_np(&actions, spec.workingDirectory)
        }
        #else
        posix_spawn_file_actions_addchdir_np(&actions, spec.workingDirectory)
        #endif

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group; only fds 0-2 survive; default signal handlers; nothing blocked.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = spec.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        // Child ends belong to the child now (or to nobody on failure).
        close(stdoutPipe.write)
        close(stderrPipe.write)
        if let stdinPipe { close(stdinPipe.read) }
        guard rc == 0 else {
            close(stdoutPipe.read)
            close(stderrPipe.read)
            if let stdinPipe { close(stdinPipe.write) }
            throw ProcessHostError.spawnFailed(errno: rc, executable: executable)
        }

        var continuation: AsyncStream<OutputChunk>.Continuation?
        var stream: AsyncStream<OutputChunk>?
        if spec.streamsOutput {
            let (s, c) = AsyncStream<OutputChunk>.makeStream()
            stream = s
            continuation = c
        }
        let process = ManagedProcess(pid: pid, outputLimit: max(0, spec.outputLimit), output: stream)

        if let stdinPipe {
            let fd = stdinPipe.write
            if spec.interactiveInput {
                process.state.withLock { $0.input = fd }
                if let data = spec.standardInput { process.inputQueue.async { _ = writeAll(data, to: fd) } }
            } else if let data = spec.standardInput {
                Thread.detachNewThread {
                    _ = writeAll(data, to: fd)
                    close(fd)
                }
            }
        }
        let (outFD, errFD) = (stdoutPipe.read, stderrPipe.read)
        let chunks = continuation
        Thread.detachNewThread { [process] in process.readOutput(stdout: outFD, stderr: errFD, continuation: chunks) }
        Thread.detachNewThread { [process] in process.awaitExit() }
        return process
    }

    // MARK: Public API

    /// The result once the process has exited and its output is collected.
    public func wait() async -> ProcessResult {
        await withCheckedContinuation { continuation in
            let ready: ProcessResult? = state.withLock { state in
                if let result = state.result { return result }
                state.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    public var hasExited: Bool { state.withLock { $0.reaped } }

    /// Writes to an interactive stdin. Writes are ordered and never block the caller's thread.
    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            inputQueue.async { [self] in
                guard let fd = state.withLock({ $0.input }) else {
                    continuation.resume(throwing: ProcessHostError.inputClosed)
                    return
                }
                let error = writeAll(data, to: fd)
                if error == 0 { continuation.resume() } else { continuation.resume(throwing: ProcessHostError.writeFailed(errno: error)) }
            }
        }
    }

    /// Closes an interactive stdin (the child sees EOF) after pending writes.
    public func closeInput() {
        inputQueue.async { [self] in
            if let fd = state.withLock({ state -> Int32? in defer { state.input = nil }; return state.input }) { close(fd) }
        }
    }

    /// Interrupt, then terminate, then kill the process group, waiting `grace` between steps.
    /// Returns at once if the process has already been reaped.
    /// `interruptFirst: false` skips SIGINT when the caller already asked politely (for example
    /// over a protocol) and waited.
    public func stop(reason: StopReason = .requested, grace: Duration = .seconds(2), interruptFirst: Bool = true) async {
        state.withLock { if $0.stopReason == nil, !$0.reaped { $0.stopReason = reason } }
        for signal in interruptFirst ? [SIGINT, SIGTERM] : [SIGTERM] {
            guard signalGroup(signal) else { return }
            if await waitForExit(within: grace) { return }
        }
        _ = signalGroup(SIGKILL)
    }

    /// Sends a signal to the process group if the leader has not been reaped yet.
    @discardableResult
    public func signalGroup(_ signal: Int32) -> Bool {
        state.withLock { state in
            guard !state.reaped else { return false }
            killpg(pid, signal)
            return true
        }
    }

    private func waitForExit(within duration: Duration) async -> Bool {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            if hasExited { return true }
            await pause(.milliseconds(10))
        }
        return hasExited
    }

    // MARK: Threads

    private func readOutput(stdout: Int32, stderr: Int32, continuation: AsyncStream<OutputChunk>.Continuation?) {
        for fd in [stdout, stderr] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var open: [Int32: Bool] = [stdout: true, stderr: true]
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while open.values.contains(true) {
            if state.withLock({ $0.cutOffRequested }) { break }
            var fds = open.filter(\.value).map { pollfd(fd: $0.key, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&fds, nfds_t(fds.count), 100)
            if ready < 0, errno != EINTR { break }
            for entry in fds where entry.revents != 0 {
                while true {
                    let count = read(entry.fd, &buffer, buffer.count)
                    if count > 0 {
                        let chunk = Data(buffer[0..<count])
                        let isStdout = entry.fd == stdout
                        record(chunk, stdout: isStdout)
                        continuation?.yield(isStdout ? .stdout(chunk) : .stderr(chunk))
                    } else if count == 0 {
                        open[entry.fd] = false
                        break
                    } else {
                        if errno == EINTR { continue }
                        if errno != EAGAIN { open[entry.fd] = false }
                        break
                    }
                }
            }
        }
        close(stdout)
        close(stderr)
        continuation?.finish()
        readerDone.signal()
    }

    private func record(_ chunk: Data, stdout: Bool) {
        state.withLock { state in
            var captured = stdout ? state.stdout : state.stderr
            let room = max(0, outputLimit - captured.data.count)
            if room > 0 { captured.data.append(chunk.prefix(room)) }
            captured.totalBytes += chunk.count
            if stdout { state.stdout = captured } else { state.stderr = captured }
        }
    }

    private func awaitExit() {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
        var status: Int32 = 0
        state.withLock { state in
            // The zombie leader still reserves the group ID: clean up leftovers, then reap.
            killpg(pid, SIGKILL)
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            state.reaped = true
        }
        closeInput()
        // Output may stay open if a process outside the group kept a pipe.
        var cutOff = false
        if readerDone.wait(timeout: .now() + 2) == .timedOut {
            state.withLock { $0.cutOffRequested = true }
            readerDone.wait()
            cutOff = true
        }
        let termination: Termination = (status & 0x7f) == 0
            ? .exited((status >> 8) & 0xff)
            : .signaled(status & 0x7f)
        let duration = ContinuousClock.now - started
        let waiters: [CheckedContinuation<ProcessResult, Never>]
        let result: ProcessResult
        (result, waiters) = state.withLock { state in
            let result = ProcessResult(
                termination: termination, stdout: state.stdout, stderr: state.stderr,
                stopReason: state.stopReason, outputCutOff: cutOff, duration: duration
            )
            state.result = result
            let waiters = state.waiters
            state.waiters = []
            return (result, waiters)
        }
        waiters.forEach { $0.resume(returning: result) }
    }
}

/// Sleeps even in a cancelled task: stop and drain must keep their timing during shutdown
/// instead of spinning.
func pause(_ duration: Duration) async {
    let nanoseconds = UInt64(duration.components.seconds) * 1_000_000_000 + UInt64(duration.components.attoseconds / 1_000_000_000)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) { continuation.resume() }
    }
}

private func makePipe(sigpipeSafe: Bool) throws -> (read: Int32, write: Int32) {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { throw ProcessHostError.pipeFailed(errno: errno) }
    for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    // The flag belongs to the open file, so the child would inherit it; set it only where the
    // host itself writes.
    if sigpipeSafe { _ = fcntl(fds[1], F_SETNOSIGPIPE, 1) }
    return (fds[0], fds[1])
}

/// Returns 0 or the errno of the failed write.
private func writeAll(_ data: Data, to fd: Int32) -> Int32 {
    data.withUnsafeBytes { buffer in
        guard var pointer = buffer.baseAddress else { return 0 }
        var remaining = buffer.count
        while remaining > 0 {
            let written = write(fd, pointer, remaining)
            if written < 0 {
                if errno == EINTR { continue }
                return errno
            }
            remaining -= written
            pointer += written
        }
        return 0
    }
}
