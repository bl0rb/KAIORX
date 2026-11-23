import Foundation

/// Starts and tracks the host's child processes (agents, Git, tests). There is no general
/// "shell as a service": callers pass a typed `LaunchSpec` with an absolute executable.
///
/// Package C keeps the runner in-process; the signed helper with its pipe protocol follows with
/// the app (ADR 0002).
public actor ProcessHost {
    private var processes: [UUID: ManagedProcess] = [:]
    private var terminals: [UUID: TerminalProcess] = [:]
    private var isDraining = false

    public init() {}

    public var activeCount: Int { processes.count + terminals.count }
    public var acceptsLaunches: Bool { !isDraining }

    public func launch(_ spec: LaunchSpec) throws -> ManagedProcess {
        guard !isDraining else { throw ProcessHostError.draining }
        let process = try ManagedProcess.spawn(spec)
        processes[process.id] = process
        let timeout: Task<Void, Never>? = spec.timeout.map { limit in
            Task {
                try? await Task.sleep(for: limit)
                if !Task.isCancelled { await process.stop(reason: .timeout, grace: spec.stopGrace) }
            }
        }
        Task {
            _ = await process.wait()
            timeout?.cancel()
            self.forget(process.id)
        }
        return process
    }

    /// Launches and waits for the result.
    public func run(_ spec: LaunchSpec) async throws -> ProcessResult {
        try await launch(spec).wait()
    }

    /// Stops accepting launches, lets running processes finish within `timeout`, then stops the
    /// rest. Returns how many had to be stopped.
    @discardableResult
    public func drain(timeout: Duration, grace: Duration = .seconds(2)) async -> Int {
        isDraining = true
        // Terminals are hung up at once: an interactive shell does not finish on its own.
        let open = Array(terminals.values)
        await withTaskGroup(of: Void.self) { group in
            for terminal in open { group.addTask { await terminal.hangUp(grace: grace) } }
        }
        let deadline = ContinuousClock.now + timeout
        while !processes.isEmpty, ContinuousClock.now < deadline {
            await pause(.milliseconds(10))
        }
        let remaining = Array(processes.values)
        await withTaskGroup(of: Void.self) { group in
            for process in remaining {
                group.addTask {
                    await process.stop(reason: .drain, grace: grace)
                    _ = await process.wait()
                }
            }
        }
        return remaining.count + open.count
    }

    /// Accepts launches again after a drain.
    public func resume() {
        isDraining = false
    }

    private func forget(_ id: UUID) {
        processes[id] = nil
    }

    func trackTerminal(_ terminal: TerminalProcess) {
        terminals[terminal.id] = terminal
        Task {
            _ = await terminal.wait()
            self.forgetTerminal(terminal.id)
        }
    }

    private func forgetTerminal(_ id: UUID) {
        terminals[id] = nil
    }
}
