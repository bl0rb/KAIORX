import Domain
import Foundation
import ProcessHost
import Providers

/// The gate's answer for one provider.
public enum AutomaticVerdict: Sendable, Equatable {
    case allowed
    case blocked(AutomationBlock)
}

/// Why a provider does not run automatically. Stored after the provider in the detail of an
/// `awaitingUserStart` wait reason (`claude:versionNotLiveVerified:2.1.330`); the detail only
/// carries stable codes and versions, so an unchanged reason records no new decision.
/// The outcome of the user's login check (ADR 0013): the subscription verdict, or the cheaper
/// stage that kept the gate from asking the CLI at all.
public enum SubscriptionCheck: Sendable, Equatable {
    case verdict(SubscriptionVerdict)
    case blocked(AutomationBlock)
}

public enum AutomationBlock: Sendable, Equatable {
    /// A simple gate said no (no further reason).
    case notPermitted
    /// The build's channel needs a provider clearance, and there is none.
    case channel(DistributionChannel)
    case notInstalled
    /// The binary could not be identified (hash or `--version` failed, or it kept changing).
    case identityUnknown
    case versionNotListed(String)
    case versionNotLiveVerified(String)
    /// The version passed, but another build of it.
    case buildNotVerified(String)
    /// The last `Confinement.probe` was not effective (or there was none).
    case confinementIneffective
    /// The login is not a pure subscription: `signedOut`, `otherBilling` or `unclear`.
    case notSubscribed(String)

    public func detail(for provider: ProviderKind) -> String {
        switch self {
        case .notPermitted: provider.rawValue
        case .channel(let channel): "\(provider.rawValue):channel:\(channel.rawValue)"
        case .notInstalled: "\(provider.rawValue):notInstalled"
        case .identityUnknown: "\(provider.rawValue):identityUnknown"
        case .versionNotListed(let version): "\(provider.rawValue):versionNotListed:\(version)"
        case .versionNotLiveVerified(let version): "\(provider.rawValue):versionNotLiveVerified:\(version)"
        case .buildNotVerified(let version): "\(provider.rawValue):buildNotVerified:\(version)"
        case .confinementIneffective: "\(provider.rawValue):confinement"
        case .notSubscribed(let kind): "\(provider.rawValue):subscription:\(kind)"
        }
    }

    /// The provider and block of a stored `awaitingUserStart` detail; nil for anything else.
    public static func parse(_ detail: String) -> (ProviderKind, AutomationBlock)? {
        let parts = detail.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, let provider = ProviderKind(rawValue: first) else { return nil }
        let code = parts.count > 1 ? parts[1] : nil
        let argument = parts.count > 2 ? parts[2] : nil
        let block: AutomationBlock?
        switch (code, argument) {
        case (nil, nil): block = .notPermitted
        case ("channel"?, let raw?): block = DistributionChannel(rawValue: raw).map(AutomationBlock.channel)
        case ("notInstalled"?, nil): block = .notInstalled
        case ("identityUnknown"?, nil): block = .identityUnknown
        case ("versionNotListed"?, let version?): block = .versionNotListed(version)
        case ("versionNotLiveVerified"?, let version?): block = .versionNotLiveVerified(version)
        case ("buildNotVerified"?, let version?): block = .buildNotVerified(version)
        case ("confinement"?, nil): block = .confinementIneffective
        case ("subscription"?, let kind?): block = .notSubscribed(kind)
        default: block = nil
        }
        return block.map { (provider, $0) }
    }
}

extension SubscriptionVerdict {
    /// A stable code for a wait reason (plan names and messages stay out of it).
    var code: String {
        switch self {
        case .subscription: "subscription"
        case .signedOut: "signedOut"
        case .otherBilling: "otherBilling"
        case .unclear: "unclear"
        }
    }
}

/// What a gate gets at app start: the running adapters, the agents' process host, a scratch
/// folder for preflight reads and the app's clock.
public struct GateContext: Sendable {
    public var adapters: [any AgentAdapter]
    public var host: ProcessHost
    public var scratch: String
    public var clock: @Sendable () -> Int64

    public init(adapters: [any AgentAdapter], host: ProcessHost, scratch: String, clock: @escaping @Sendable () -> Int64) {
        self.adapters = adapters
        self.host = host
        self.scratch = scratch
        self.clock = clock
    }
}

/// The product's automatic-start gate (ADR 0009). In this order, cheapest first:
/// 1. channel: a `distributed` build needs a `ProviderClearance` for the provider (none exists);
/// 2. the installed binary (version and SHA, cached per path and file signature) has a
///    `liveVerified` matrix entry that names its build;
/// 3. the last `Confinement.probe` was effective;
/// 4. the subscription preflight (`claude auth status`, Codex `account/read`) says subscription,
///    cached for a short time.
/// Explicit user starts never ask the gate. Every check fails closed, and tests inject all
/// sources, so no test reaches a real binary.
public actor AutomationGate: CapabilityGate {
    public struct Sources: Sendable {
        /// The installed binary; nil when the provider is not installed.
        public var installed: @Sendable (ProviderKind) async throws -> BinaryIdentity?
        public var confinement: @Sendable () async -> ConfinementStatus
        /// The provider's auth verdict, read without inference (ADR 0008 §2).
        public var subscription: @Sendable (ProviderKind) async throws -> SubscriptionVerdict

        public init(
            installed: @escaping @Sendable (ProviderKind) async throws -> BinaryIdentity?,
            confinement: @escaping @Sendable () async -> ConfinementStatus,
            subscription: @escaping @Sendable (ProviderKind) async throws -> SubscriptionVerdict
        ) {
            self.installed = installed
            self.confinement = confinement
            self.subscription = subscription
        }

        /// The real adapters of the app: their identity caches, `authStatus` and `inspect`.
        public static func live(_ context: GateContext) -> Sources {
            let adapters = context.adapters, host = context.host, root = context.scratch
            return Sources(
                installed: { provider in
                    switch adapters.first(where: { $0.provider == provider }) {
                    case let claude as ClaudeCodeAdapter: try await claude.installedIdentity()
                    case let codex as CodexAppServerAdapter: try await codex.installedIdentity()
                    default: nil
                    }
                },
                confinement: {
                    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    return await Confinement.probe(host: host, scratch: URL(filePath: root))
                },
                subscription: { provider in
                    let scratch = root + "/auth-" + UUID().uuidString
                    defer { try? FileManager.default.removeItem(atPath: scratch) }
                    switch adapters.first(where: { $0.provider == provider }) {
                    case let claude as ClaudeCodeAdapter: return try await claude.authStatus(scratch: scratch).verdict
                    case let codex as CodexAppServerAdapter: return try await codex.inspect(scratch: scratch).verdict
                    default: return .unclear("kein Adapter")
                    }
                }
            )
        }
    }

    public nonisolated let channel: DistributionChannel
    private let clearances: [ProviderClearance]
    private let subscriptionTTL: Int64
    private var sources: Sources?
    private var clock: @Sendable () -> Int64
    private var confinement: ConfinementStatus?
    private var verdicts: [ProviderKind: (verdict: SubscriptionVerdict, at: Int64)] = [:]
    /// The running read per provider and its number; a fresh read only joins one started after it was asked for.
    private var pending: [ProviderKind: (task: Task<SubscriptionVerdict, Never>, number: Int)] = [:]
    private var reads = 0

    /// Default TTL of a subscription verdict: long enough not to run the status read every
    /// tick, short enough that a log-out stops automation within minutes.
    public static let defaultSubscriptionTTL: Int64 = 5 * 60_000

    /// Without `sources` the gate binds the app's adapters in `prepare`; until then (and in a
    /// configuration without adapters) every provider is blocked.
    public init(
        channel: DistributionChannel, clearances: [ProviderClearance] = ProviderClearance.entries, sources: Sources? = nil,
        subscriptionTTL: Int64 = AutomationGate.defaultSubscriptionTTL,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.channel = channel
        self.clearances = clearances
        self.sources = sources
        self.subscriptionTTL = subscriptionTTL
        self.clock = clock
    }

    /// Binds the live sources (unless injected) and probes the confinement once, if any
    /// provider could run automatically in this channel at all.
    public func prepare(_ context: GateContext) async {
        if sources == nil {
            sources = .live(context)
            clock = context.clock
        }
        if [ProviderKind.claude, .codex].contains(where: channelPermits) { _ = await refreshConfinement() }
    }

    public func allowsAutomatic(_ provider: ProviderKind) async -> Bool {
        await automaticVerdict(provider) == .allowed
    }

    public func automaticVerdict(_ provider: ProviderKind) async -> AutomaticVerdict {
        if let block = await cheaperStages(provider) { return .blocked(block) }
        let verdict = await subscription(provider, fresh: false)
        guard verdict.allowsRun else { return .blocked(.notSubscribed(verdict.code)) }
        return .allowed
    }

    /// After a quota block: the same cheaper stages as `automaticVerdict` first (in the
    /// distributed channel without clearance nothing about the installation is read), then the
    /// auth verdict read afresh, not taken from the cache. A failed stage keeps the block; the
    /// scheduler renews it timed, with doubling up to its maximum, so nothing is read in a loop.
    public func accessRestored(_ provider: ProviderKind, account: AccountID) async -> Bool {
        guard await cheaperStages(provider) == nil else { return false }
        return await subscription(provider, fresh: true).allowsRun
    }

    /// Stages 1 to 3 (channel, installed build, confinement); nil when all passed.
    private func cheaperStages(_ provider: ProviderKind) async -> AutomationBlock? {
        guard provider == .claude || provider == .codex else { return .notPermitted }
        guard channelPermits(provider) else { return .channel(channel) }
        guard let sources else { return .identityUnknown }
        let identity: BinaryIdentity
        do {
            guard let installed = try await sources.installed(provider) else { return .notInstalled }
            identity = installed
        } catch {
            return .identityUnknown
        }
        switch CompatibilityMatrix.liveVerification(provider, identity: identity) {
        case .verified: break
        case .versionNotListed: return .versionNotListed(identity.version)
        case .versionNotLiveVerified: return .versionNotLiveVerified(identity.version)
        case .buildNotVerified: return .buildNotVerified(identity.version)
        }
        let status: ConfinementStatus
        if let confinement { status = confinement } else { status = await refreshConfinement() }
        guard status == .effective else { return .confinementIneffective }
        return nil
    }

    /// The installed binary as automation sees it, for the model profile sync at app start
    /// (ADR 0012). nil without reading anything when the channel permits no automation for the
    /// provider (ADR 0009 §3), and nil when it is not installed or could not be identified.
    public func installedIdentity(_ provider: ProviderKind) async -> BinaryIdentity? {
        guard provider == .claude || provider == .codex, channelPermits(provider), let sources else { return nil }
        return try? await sources.installed(provider)
    }

    // MARK: Confinement

    /// The last probe result; nil before the first probe.
    public var lastConfinement: ConfinementStatus? { confinement }

    /// Probes the sandbox now (at start and on demand); without sources it stays ineffective.
    @discardableResult
    public func refreshConfinement() async -> ConfinementStatus {
        guard let sources else { return .unavailable("nicht geprüft") }
        let status = await sources.confinement()
        confinement = status
        return status
    }

    /// A probe the app ran itself (onboarding) counts as the latest result.
    public func record(confinement status: ConfinementStatus) {
        confinement = status
    }

    // MARK: Subscription

    /// The user's „Anmeldung prüfen“ (ADR 0013): the cheaper stages first (only an accepted,
    /// confined build is ever asked), then a fresh read past the cache, kept as the latest
    /// verdict, so a task waiting for a login starts at the next tick. Nil where the gate reads
    /// nothing (a channel without automation for this provider, no adapters bound).
    public func checkSubscription(_ provider: ProviderKind) async -> SubscriptionCheck? {
        guard provider == .claude || provider == .codex, channelPermits(provider), sources != nil else { return nil }
        if let block = await cheaperStages(provider) { return .blocked(block) }
        return .verdict(await subscription(provider, fresh: true, startedAfterAsking: true))
    }

    /// `fresh` skips the cache; `startedAfterAsking` (the user's check) also never takes the
    /// answer of a read that began before the call, which may predate a login. Other callers
    /// share a read in flight (ADR 0009 §6).
    private func subscription(_ provider: ProviderKind, fresh: Bool, startedAfterAsking: Bool = false) async -> SubscriptionVerdict {
        let now = clock()
        if !fresh, let cached = verdicts[provider], now - cached.at < subscriptionTTL, now >= cached.at { return cached.verdict }
        let asked = reads
        while let running = pending[provider] {
            if !startedAfterAsking || running.number > asked { return await running.task.value }
            _ = await running.task.value
            // The finished read's own caller may not have resumed yet: never wait on it twice.
            if pending[provider]?.number == running.number { pending[provider] = nil }
        }
        guard let sources else { return .unclear("nicht geprüft") }
        let task = Task<SubscriptionVerdict, Never> {
            do { return try await sources.subscription(provider) } catch { return .unclear("Prüfung fehlgeschlagen") }
        }
        reads += 1
        let number = reads
        pending[provider] = (task, number)
        let verdict = await task.value
        if pending[provider]?.number == number { pending[provider] = nil }
        verdicts[provider] = (verdict, clock())
        return verdict
    }

    private func channelPermits(_ provider: ProviderKind) -> Bool {
        switch channel {
        case .personal: true
        case .distributed: clearances.contains { $0.permits(provider, in: .distributed, at: clock()) }
        }
    }
}
