import Darwin
import Foundation
import Synchronization

/// What a user terminal runs: an absolute executable with an explicit environment, on its own
/// pseudo terminal (Plan/macos-und-git.md: an intentionally started terminal process uses its
/// own PTY). The process leads a new session, so the PTY is its controlling terminal and
/// Ctrl-C reaches its foreground job.
public struct TerminalSpec: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]
    public var rows: UInt16
    public var columns: UInt16

    public init(executable: String, arguments: [String] = [], workingDirectory: String, environment: [String: String], rows: UInt16 = 24, columns: UInt16 = 80) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.rows = rows
        self.columns = columns
    }
}

/// A process on a pseudo terminal. Output is pulled (`read`): nothing is read while the consumer
/// does not ask, so a flooding program blocks on the full PTY instead of filling memory.
public final class TerminalProcess: Sendable {
    public let id = UUID()
    public let pid: pid_t

    private struct State {
        var master: Int32
        var reaped = false
        var termination: Termination?
        var waiters: [CheckedContinuation<Termination, Never>] = []
    }

    private let state: Mutex<State>
    private let io = DispatchQueue(label: "kaiorx.terminal.io")
    private let writes = DispatchQueue(label: "kaiorx.terminal.write")

    private init(pid: pid_t, master: Int32) {
        self.pid = pid
        self.state = Mutex(State(master: master))
    }

    static func spawn(_ spec: TerminalSpec) throws -> TerminalProcess {
        guard spec.executable.hasPrefix("/") else { throw ProcessHostError.notAbsolute(spec.executable) }
        guard spec.workingDirectory.hasPrefix("/") else { throw ProcessHostError.notAbsolute(spec.workingDirectory) }
        for (key, value) in spec.environment where key.isEmpty || key.contains("=") || key.contains("\0") || value.contains("\0") {
            throw ProcessHostError.invalidEnvironment(key)
        }
        if let bad = ([spec.executable] + spec.arguments).first(where: { $0.contains("\0") }) { throw ProcessHostError.invalidArgument(bad) }

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw ProcessHostError.pipeFailed(errno: errno) }
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            close(master)
            throw ProcessHostError.pipeFailed(errno: errno)
        }
        let slavePath = String(cString: name)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        // Non-blocking: a write to a full PTY must not block the input queue (or a hang-up).
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        // The host holds the slave open (never as its controlling terminal) until the child has
        // it: the window size set now survives, a size set before the first open would not.
        let hold = open(slavePath, O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard hold >= 0 else {
            close(master)
            throw ProcessHostError.pipeFailed(errno: errno)
        }
        defer { close(hold) }
        var size = winsize(ws_row: spec.rows, ws_col: spec.columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(hold, TIOCSWINSZ, &size)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Opened in the child after `setsid`: as the new session's leader without a controlling
        // terminal, the open makes the PTY its controlling terminal.
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        if #available(macOS 26.0, *) {
            posix_spawn_file_actions_addchdir(&actions, spec.workingDirectory)
        } else {
            posix_spawn_file_actions_addchdir_np(&actions, spec.workingDirectory)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new session (and with it a new process group, pgid == pid); not SETPGROUP, which
        // would make `setsid` fail for a group leader.
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = ([spec.executable] + spec.arguments).map { strdup($0) } + [nil]
        let envp = spec.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, spec.executable, &actions, &attributes, argv, envp)
        guard rc == 0 else {
            close(master)
            throw ProcessHostError.spawnFailed(errno: rc, executable: spec.executable)
        }
        let process = TerminalProcess(pid: pid, master: master)
        Thread.detachNewThread { [process] in process.awaitExit() }
        return process
    }

    // MARK: Public API

    public var hasExited: Bool { state.withLock { $0.reaped } }

    /// The next output bytes (at most `maximum`), waiting until there are some; nil at the end
    /// (the program exited and the PTY is drained, or the terminal was hung up).
    ///
    /// The master is non-blocking and every `read`/`write` on it happens under the lock after
    /// checking it is still open, so a hang-up can close it at any time without a later call
    /// touching a closed (or reused) descriptor number.
    public func read(maximum: Int = 64 * 1024) async -> Data? {
        await withCheckedContinuation { continuation in
            io.async { [self] in
                var buffer = [UInt8](repeating: 0, count: max(1, maximum))
                while true {
                    guard let fd = state.withLock({ $0.master >= 0 ? $0.master : nil }) else { continuation.resume(returning: nil); return }
                    var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    if poll(&entry, 1, 100) < 0, errno != EINTR { continuation.resume(returning: nil); return }
                    let (count, error): (Int, Int32) = state.withLock { state in
                        guard state.master == fd else { return (0, EBADF) }
                        let count = Darwin.read(fd, &buffer, buffer.count)
                        return (count, count < 0 ? errno : 0)
                    }
                    if count > 0 { continuation.resume(returning: Data(buffer[0..<count])); return }
                    if count < 0, error == EINTR || error == EAGAIN { continue }
                    // 0, EIO or a closed master: the terminal ended.
                    continuation.resume(returning: nil)
                    return
                }
            }
        }
    }

    /// How long input may wait for room in a full PTY before the rest of it is dropped (a
    /// program that does not read must not hold back later keystrokes such as Ctrl-C forever).
    public static let inputStall: Duration = .seconds(2)

    /// Writes user input (keystrokes, paste) in order, off the caller's thread.
    public func write(_ data: Data) {
        writes.async { [self] in
            var offset = 0
            var stalledSince: ContinuousClock.Instant?
            while offset < data.count {
                guard let fd = state.withLock({ $0.master >= 0 ? $0.master : nil }) else { return }
                var entry = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&entry, 1, 50)
                let (written, error): (Int, Int32) = state.withLock { state in
                    guard state.master == fd else { return (-1, EBADF) }
                    let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
                    return (written, written < 0 ? errno : 0)
                }
                if written > 0 {
                    offset += written
                    stalledSince = nil
                    continue
                }
                guard error == EAGAIN || error == EINTR else { return }
                let now = ContinuousClock.now
                if let since = stalledSince, now - since > Self.inputStall { return }
                if stalledSince == nil { stalledSince = now }
            }
        }
    }

    /// New window size; the foreground job gets SIGWINCH from the kernel.
    public func resize(rows: UInt16, columns: UInt16) {
        state.withLock { state in
            guard state.master >= 0 else { return }
            var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(state.master, TIOCSWINSZ, &size)
        }
    }

    /// Hangs up: closing the master sends SIGHUP to the session; after `grace` the leader's
    /// process group is killed if it is still there. Never waits for pending input or output.
    public func hangUp(grace: Duration = .seconds(2)) async {
        // Closed under the lock: no read or write can be inside a syscall on it now.
        state.withLock { state in
            if state.master >= 0 { close(state.master) }
            state.master = -1
        }
        let deadline = ContinuousClock.now + grace
        while ContinuousClock.now < deadline, !hasExited { await pause(.milliseconds(10)) }
        let killed = state.withLock { state -> Bool in
            guard !state.reaped else { return false }
            killpg(pid, SIGKILL)
            return true
        }
        if killed { _ = await wait() }
    }

    /// The exit once the program has ended.
    public func wait() async -> Termination {
        await withCheckedContinuation { continuation in
            let ready: Termination? = state.withLock { state in
                if let termination = state.termination { return termination }
                state.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    private func awaitExit() {
        // Wait without reaping, then reap under the lock: `hangUp` signals only while the PID
        // still belongs to this child.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
        var status: Int32 = 0
        let waiters = state.withLock { state -> [CheckedContinuation<Termination, Never>] in
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            let termination: Termination = (status & 0x7f) == 0 ? .exited((status >> 8) & 0xff) : .signaled(status & 0x7f)
            state.reaped = true
            state.termination = termination
            defer { state.waiters = [] }
            return state.waiters
        }
        let termination = state.withLock { $0.termination! }
        waiters.forEach { $0.resume(returning: termination) }
    }
}

extension ProcessHost {
    /// Starts a program on its own PTY (a user terminal). Tracked like other children: `drain`
    /// hangs it up.
    public func launchTerminal(_ spec: TerminalSpec) throws -> TerminalProcess {
        guard acceptsLaunches else { throw ProcessHostError.draining }
        let process = try TerminalProcess.spawn(spec)
        trackTerminal(process)
        return process
    }
}
