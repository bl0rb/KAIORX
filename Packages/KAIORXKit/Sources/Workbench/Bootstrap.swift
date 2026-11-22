import Domain
import Foundation
import Orchestration
import os
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
    /// Decides automatic starts. The default is the product gate of a distributed build: no
    /// real provider runs on its own (ADR 0009).
    public var gate: any CapabilityGate
    public var clock: WorkbenchClock
    public var limits: SchedulerLimits
    /// Where the real providers' model profiles come from. The default registers none, so tests,
    /// UI tests and benchmarks keep their own fakes; the real app uses the verified catalog.
    public var profileRegistration: ProfileRegistration

    public init(
        databasePath: String, workspaceRoot: String, adapters: @escaping @Sendable (ProcessHost) -> [any AgentAdapter],
        gate: any CapabilityGate = AutomationGate(channel: .distributed), limits: SchedulerLimits = SchedulerLimits(),
        clock: @escaping WorkbenchClock = { Int64(Date().timeIntervalSince1970 * 1000) }, profileRegistration: ProfileRegistration = .none
    ) {
        self.databasePath = databasePath
        self.workspaceRoot = workspaceRoot
        self.adapters = adapters
        self.gate = gate
        self.limits = limits
        self.clock = clock
        self.profileRegistration = profileRegistration
    }

    /// The real app: `~/Library/Application Support/KAIORX`, gated for the build's channel
    /// (read from the app's Info.plist; unknown means distributed).
    public static func standard(
        adapters: @escaping @Sendable (ProcessHost) -> [any AgentAdapter], channel: DistributionChannel = .current()
    ) throws -> AppConfiguration {
        let database = try AppPaths.defaultDatabaseURL()
        let folder = try AppPaths.supportFolder()
        return AppConfiguration(
            databasePath: database.path(percentEncoded: false), workspaceRoot: workspaceRoot(support: folder), adapters: adapters,
            gate: AutomationGate(channel: channel), profileRegistration: .verifiedCatalog(installed: nil)
        )
    }

    /// Where the real app keeps worktrees and its other workspace files.
    public static func workspaceRoot(support: String) -> String { support + "/workspace" }
}

/// Which model profiles of the real providers the app registers at start (ADR 0012).
public enum ProfileRegistration: Sendable {
    /// None: whoever configures the app registers its own (tests, UI tests, benchmarks).
    case none
    /// From `VerifiedModelProfiles`, synced at every start. `installed` names each provider's
    /// installed binary; nil asks the app's `AutomationGate` (which reads nothing in a channel
    /// without automation), so the version probe is the one the adapters cache for their starts.
    case verifiedCatalog(installed: (@Sendable (ProviderKind) async -> BinaryIdentity?)?)
}

/// How the start-up profile sync went; a failure is recorded, never fatal.
public enum ProfileSyncOutcome: Sendable, Equatable {
    case synced(ModelProfileSyncReport)
    case failed(String)
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
    /// The candidate chain's host-only driver (ADR 0011); built only after the Git journal was
    /// repaired, like the scheduler.
    public let chain: CandidateChain?
    public let recovery: RecoveryReport
    public let restored: RestoreReport?
    /// The model profile sync at this start; nil when the configuration registers none.
    public let profileSync: ProfileSyncOutcome?

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
        let adapters = configuration.adapters(agents)
        let coordinator = RunCoordinator(store: store, adapters: adapters)
        // The gate binds the running adapters and probes the confinement before any tick.
        await configuration.gate.prepare(GateContext(
            adapters: adapters, host: agents, scratch: configuration.workspaceRoot + "/preflight", clock: configuration.clock
        ))
        // The real providers' profiles, before the scheduler and the chain can look for one.
        let profileSync = await syncProfiles(configuration, store: store)
        let git = try? GitRunner(host: agents, home: configuration.workspaceRoot + "/git-home")
        let recovery: RecoveryReport
        do { recovery = try await coordinator.bootstrap() }
        catch { return .recovery(.storeFailed(String(describing: error)), backups: BackupRestore.backups(of: database)) }
        var workspace: WorkspaceService?, integration: IntegrationService?, memory: MemoryBroker?, scheduler: Scheduler?
        var chain: CandidateChain?
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
                // The chain seals, builds and collects only after journal repair (ADR 0011).
                chain = CandidateChain(
                    store: store, workspace: service, integration: integrationService, git: git, coordinator: coordinator,
                    limits: configuration.limits, gate: configuration.gate
                )
            }
            workspace = service
        }
        return .ready(AppServices(
            configuration: configuration, store: store, agents: agents, terminals: terminals, coordinator: coordinator, git: git,
            workspace: workspace, integration: integration, memory: memory, scheduler: scheduler, chain: chain, recovery: recovery,
            restored: restored, profileSync: profileSync
        ))
    }

    /// Registers the verified catalog's profiles (ADR 0012); a failure is reported, not fatal.
    static func syncProfiles(_ configuration: AppConfiguration, store: Store) async -> ProfileSyncOutcome? {
        guard case .verifiedCatalog(let lookup) = configuration.profileRegistration else { return nil }
        var installed: [ProviderKind: BinaryIdentity] = [:]
        for provider in ModelProfileSync.managed.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let lookup {
                installed[provider] = await lookup(provider)
            } else if let gate = configuration.gate as? AutomationGate {
                installed[provider] = await gate.installedIdentity(provider)
            }
        }
        let outcome: ProfileSyncOutcome
        do { outcome = .synced(try await ModelProfileSync.run(store: store, installed: installed)) }
        catch { outcome = .failed(String(describing: error)) }
        // The onboarding list shows the outcome; the unified log keeps it for a later diagnosis.
        switch outcome {
        case .failed(let reason): profileLog.error("Modellprofil-Abgleich fehlgeschlagen: \(reason, privacy: .public)")
        case .synced(let report): profileLog.notice("Modellprofile abgeglichen: \(report.inserted.count) neu, \(report.updated.count) nachgeführt, \(report.removed.count) entfernt")
        }
        return outcome
    }

    private static let profileLog = Logger(subsystem: "dev.kaiorx.KAIORX", category: "profiles")

    /// Quitting: running attempts are stopped (they become `uncertain` only if the stop fails),
    /// terminals hang up, then the store closes.
    public static func shutdown(_ services: AppServices, grace: Duration = .seconds(5)) async {
        _ = await services.agents.drain(timeout: grace)
        _ = await services.terminals.drain(timeout: .seconds(2))
        await services.store.close()
    }
}
