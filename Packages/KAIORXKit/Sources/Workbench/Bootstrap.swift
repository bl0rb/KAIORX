import Domain
import Foundation
import Orchestration
import ProcessHost
import Providers
import Storage
import Workspace

/// Where the app keeps its data and which adapters it uses; injected, so tests and UI tests run
/// on a temporary database with the fake adapter.
public struct AppConfiguration: Sendable {
    public var databasePath: String
    public var workspaceRoot: String
    public var adapters: @Sendable (ProcessHost) -> [any AgentAdapter]
    public var gate: any CapabilityGate
    public var clock: WorkbenchClock
    public var limits: SchedulerLimits

    public init(
        databasePath: String, workspaceRoot: String, adapters: @escaping @Sendable (ProcessHost) -> [any AgentAdapter],
        gate: any CapabilityGate = CompatibilityGate(), limits: SchedulerLimits = SchedulerLimits(),
        clock: @escaping WorkbenchClock = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.databasePath = databasePath
        self.workspaceRoot = workspaceRoot
        self.adapters = adapters
        self.gate = gate
        self.limits = limits
        self.clock = clock
    }

    /// The real app: `~/Library/Application Support/KAIORX`.
    public static func standard(adapters: @escaping @Sendable (ProcessHost) -> [any AgentAdapter]) throws -> AppConfiguration {
        let database = try AppPaths.defaultDatabaseURL()
        let folder = try AppPaths.supportFolder()
        return AppConfiguration(databasePath: database.path(percentEncoded: false), workspaceRoot: workspaceRoot(support: folder), adapters: adapters)
    }

    /// Where the real app keeps worktrees and its other workspace files.
    public static func workspaceRoot(support: String) -> String { support + "/workspace" }
}

/// Why the app cannot open normally; the recovery screen offers restore or quit, never a crash.
public enum StartupIssue: Sendable, Equatable {
    case databaseNewerThanApp(databaseVersion: Int, appVersion: Int)
    case checksumMismatch(version: Int)
    case databaseInUse
    case restoreFailed(String)
    case storeFailed(String)
}

/// The running services. Git may be missing (degraded mode: stored state only).
public struct AppServices: Sendable {
    public let configuration: AppConfiguration
    public let store: Store
    public let agents: ProcessHost
    public let terminals: ProcessHost
    public let coordinator: RunCoordinator
    public let git: GitRunner?
    public let workspace: WorkspaceService?
    public let integration: IntegrationService?
    public let memory: MemoryBroker?
    public let scheduler: Scheduler?
    public let recovery: RecoveryReport
    public let restored: RestoreReport?

    public var degraded: Bool { git == nil }
}

public enum BootstrapOutcome: Sendable {
    case ready(AppServices)
    case recovery(StartupIssue, backups: [BackupInfo])
}

/// The app's start, in the order the runtime contract needs (ADR 0007): a staged restore, the
/// store (migrations and backup), process hosts, Git, run recovery with purge jobs, Git journal
/// recovery, then the scheduler. Nothing here needs a network.
public enum AppBootstrap {
    /// The file that stages a restore for the next start (the store is closed then).
    public static func pendingRestorePath(for database: String) -> String { database + ".restore-pending" }

    public static func stageRestore(_ backup: BackupInfo, database: String) throws {
        try Data(backup.path.utf8).write(to: URL(filePath: pendingRestorePath(for: database)), options: [.atomic])
        chmod(pendingRestorePath(for: database), 0o600)
    }

    public static func start(_ configuration: AppConfiguration) async -> BootstrapOutcome {
        let database = configuration.databasePath
        var restored: RestoreReport?
        let pending = pendingRestorePath(for: database)
        if let data = FileManager.default.contents(atPath: pending) {
            try? FileManager.default.removeItem(atPath: pending)
            let path = String(decoding: data, as: UTF8.self)
            guard let backup = BackupRestore.backups(of: database).first(where: { $0.path == path }) else {
                return .recovery(.restoreFailed("Sicherung nicht gefunden"), backups: BackupRestore.backups(of: database))
            }
            do { restored = try BackupRestore.restore(backup, database: database, now: configuration.clock()) }
            catch { return .recovery(.restoreFailed(String(describing: error)), backups: BackupRestore.backups(of: database)) }
        }
        let store: Store
        do {
            store = try Store(path: database, clock: configuration.clock)
        } catch let MigrationError.databaseNewerThanApp(db, app) {
            return .recovery(.databaseNewerThanApp(databaseVersion: db, appVersion: app), backups: BackupRestore.backups(of: database))
        } catch let MigrationError.checksumMismatch(version) {
            return .recovery(.checksumMismatch(version: version), backups: BackupRestore.backups(of: database))
        } catch let error as StoreError {
            if case .databaseInUse = error { return .recovery(.databaseInUse, backups: []) }
            return .recovery(.storeFailed(String(describing: error)), backups: BackupRestore.backups(of: database))
        } catch {
            return .recovery(.storeFailed(String(describing: error)), backups: BackupRestore.backups(of: database))
        }
        // After a restore no consent from the backup counts: the user grants again. The marker
        // is written before the restore copies and removed only after the revocation committed,
        // so a crash or a failed start in between repeats it. Nothing runs before it.
        let marker = BackupRestore.consentMarker(for: database)
        if FileManager.default.fileExists(atPath: marker) {
            do {
                try await store.revokeAllConsents(reason: "restored")
                try FileManager.default.removeItem(atPath: marker)
            } catch {
                await store.close()
                return .recovery(.restoreFailed("Zustimmungen konnten nicht widerrufen werden: \(error)"), backups: BackupRestore.backups(of: database))
            }
        }
        let agents = ProcessHost(), terminals = ProcessHost()
        let coordinator = RunCoordinator(store: store, adapters: configuration.adapters(agents))
        let git = try? GitRunner(host: agents, home: configuration.workspaceRoot + "/git-home")
        let recovery: RecoveryReport
        do { recovery = try await coordinator.bootstrap() }
        catch { return .recovery(.storeFailed(String(describing: error)), backups: BackupRestore.backups(of: database)) }
        var workspace: WorkspaceService?, integration: IntegrationService?, memory: MemoryBroker?, scheduler: Scheduler?
        if let git {
            let service = WorkspaceService(store: store, git: git, layout: WorkspaceLayout(root: configuration.workspaceRoot))
            let integrationService = IntegrationService(store: store, workspace: service, git: git, coordinator: coordinator)
            // Journal repair before anything else touches Git; a failure leaves Git work held.
            if (try? await integrationService.recover()) != nil {
                let broker = MemoryBroker(store: store, workspace: service, git: git, coordinator: coordinator)
                memory = broker
                scheduler = Scheduler(
                    store: store, coordinator: coordinator, workspace: service, gate: configuration.gate, limits: configuration.limits, memory: broker
                )
                integration = integrationService
            }
            workspace = service
        }
        return .ready(AppServices(
            configuration: configuration, store: store, agents: agents, terminals: terminals, coordinator: coordinator, git: git,
            workspace: workspace, integration: integration, memory: memory, scheduler: scheduler, recovery: recovery, restored: restored
        ))
    }

    /// Quitting: running attempts are stopped (they become `uncertain` only if the stop fails),
    /// terminals hang up, then the store closes.
    public static func shutdown(_ services: AppServices, grace: Duration = .seconds(5)) async {
        _ = await services.agents.drain(timeout: grace)
        _ = await services.terminals.drain(timeout: .seconds(2))
        await services.store.close()
    }
}
