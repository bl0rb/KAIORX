import Domain
import Foundation
import ProcessHost
@testable import Providers
import Synchronization
import Testing
@testable import Orchestration
@testable import Storage

/// Injected stand-ins for the gate's sources: the installed binary, the sandbox probe and the
/// subscription preflight. Nothing here starts a real `claude` or `codex` (CLAUDE.md).
final class FakeGateSources: Sendable {
    struct State {
        var identity: BinaryIdentity?
        var identityFails = false
        var confinement: ConfinementStatus = .effective
        var verdict: SubscriptionVerdict = .subscription(plan: "max")
        var identityCalls = 0
        var confinementCalls = 0
        var subscriptionCalls = 0
    }

    let state: Mutex<State>

    init(identity: BinaryIdentity?) { state = Mutex(State(identity: identity)) }

    func set(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
    var snapshot: State { state.withLock { $0 } }

    var sources: AutomationGate.Sources {
        AutomationGate.Sources(
            installed: { [self] _ in
                try state.withLock { s in
                    s.identityCalls += 1
                    if s.identityFails { throw ProviderError.binaryChanged("/x") }
                    return s.identity
                }
            },
            confinement: { [self] in state.withLock { s in s.confinementCalls += 1; return s.confinement } },
            subscription: { [self] _ in state.withLock { s in s.subscriptionCalls += 1; return s.verdict } }
        )
    }

    /// The installed build of a `liveVerified` matrix entry (what the owner's acceptance passed).
    static func verifiedClaude() throws -> BinaryIdentity {
        let entry = try #require(CompatibilityMatrix.entries.first { $0.provider == .claude && $0.status == .liveVerified })
        return BinaryIdentity(path: "/bin/claude", resolvedPath: "/bin/claude", sha256: try #require(entry.builds.first), version: entry.version)
    }
}

extension SchedulerHarness {
    func scheduler(gate: any CapabilityGate) -> Scheduler {
        Scheduler(store: store, coordinator: coordinator, workspace: service, gate: gate, limits: limits)
    }

    func gate(_ channel: DistributionChannel, _ fake: FakeGateSources, clearances: [ProviderClearance] = []) -> AutomationGate {
        let clock = self.clock
        return AutomationGate(channel: channel, clearances: clearances, sources: fake.sources, clock: { clock.now })
    }
}

@Suite struct AutomationGateSchedulerTests {
    @Test func theDistributedChannelNeverReservesAProviderOnItsOwn() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A")])
        let fake = FakeGateSources(identity: try FakeGateSources.verifiedClaude())
        let gate = h.gate(.distributed, fake)
        let scheduler = h.scheduler(gate: gate)
        for _ in 0..<3 {
            let report = try await scheduler.tick()
            #expect(report.reserved.isEmpty)
            h.clock.advance(1_000)
        }
        let a = try await h.task("A")
        #expect(try await h.store.attempts(taskID: a.id).isEmpty)
        #expect(a.waitReason == "awaitingUserStart:claude:channel:distributed")
        // Nothing about the installation is read for automation: no binary, no auth status.
        #expect(fake.snapshot.identityCalls == 0 && fake.snapshot.subscriptionCalls == 0 && fake.snapshot.confinementCalls == 0)
        #expect(await gate.automaticVerdict(.codex) == .blocked(.channel(.distributed)))
        // The user's own start stays allowed in every channel.
        let started = try await scheduler.start(a.id, actor: "matze")
        #expect(started.reserved.count == 1)
    }

    @Test func anUnlistedInstalledVersionWaitsWithItsVersionInsteadOfFailingAtStart() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A")])
        let fake = FakeGateSources(identity: BinaryIdentity(path: "/bin/claude", resolvedPath: "/bin/claude", sha256: "abc", version: "9.9.9"))
        let scheduler = h.scheduler(gate: h.gate(.personal, fake))
        let first = try await scheduler.tick()
        let a = try await h.task("A")
        #expect(first.reserved.isEmpty && first.awaitingUserStart == [a.id])
        #expect(a.waitReason == "awaitingUserStart:claude:versionNotListed:9.9.9")
        let decisions = try await h.store.decisions(task: a.id).count
        // No reserve-then-fail loop: later ticks reserve nothing and record no new decision.
        for _ in 0..<3 {
            h.clock.advance(60_000)
            #expect(try await scheduler.tick().reserved.isEmpty)
        }
        #expect(try await h.store.attempts(taskID: a.id).isEmpty)
        #expect(try await h.store.decisions(task: a.id).count == decisions)
        #expect(fake.snapshot.subscriptionCalls == 0)
    }

    @Test func onlyTheVerifiedBuildOfALiveVerifiedVersionPasses() async throws {
        let verified = try FakeGateSources.verifiedClaude()
        let fake = FakeGateSources(identity: verified)
        let gate = AutomationGate(channel: .personal, sources: fake.sources)
        #expect(await gate.automaticVerdict(.claude) == .allowed)
        fake.set { $0.identity?.sha256 = "another-build" }
        #expect(await gate.automaticVerdict(.claude) == .blocked(.buildNotVerified(verified.version)))
        // An offline-verified version names the installed version too.
        let offline = try #require(CompatibilityMatrix.entries.first { $0.provider == .claude && $0.status == .offlineVerified })
        fake.set { $0.identity = BinaryIdentity(path: "/b", resolvedPath: "/b", sha256: "x", version: offline.version) }
        #expect(await gate.automaticVerdict(.claude) == .blocked(.versionNotLiveVerified(offline.version)))
        fake.set { $0.identity = nil }
        #expect(await gate.automaticVerdict(.claude) == .blocked(.notInstalled))
        fake.set { $0.identityFails = true }
        #expect(await gate.automaticVerdict(.claude) == .blocked(.identityUnknown))
        #expect(await gate.automaticVerdict(.fake) == .blocked(.notPermitted))
    }

    @Test func anIneffectiveConfinementProbeBlocksAutomation() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A")])
        let fake = FakeGateSources(identity: try FakeGateSources.verifiedClaude())
        fake.set { $0.confinement = .unavailable("write outside the writable roots was not blocked") }
        let gate = h.gate(.personal, fake)
        let scheduler = h.scheduler(gate: gate)
        #expect(try await scheduler.tick().reserved.isEmpty)
        #expect(try await h.task("A").waitReason == "awaitingUserStart:claude:confinement")
        // Probed once, not on every tick; the subscription is not even asked.
        _ = try await scheduler.tick()
        #expect(fake.snapshot.confinementCalls == 1 && fake.snapshot.subscriptionCalls == 0)
        // A new, effective probe (on demand) lets the next tick reserve.
        fake.set { $0.confinement = .effective }
        #expect(await gate.refreshConfinement() == .effective)
        #expect(try await scheduler.tick().reserved.count == 1)
    }

    @Test func aVerdictOtherThanSubscriptionBlocksAndIsCachedBriefly() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A")])
        let fake = FakeGateSources(identity: try FakeGateSources.verifiedClaude())
        fake.set { $0.verdict = .otherBilling("apiKeySource") }
        let scheduler = h.scheduler(gate: h.gate(.personal, fake))
        #expect(try await scheduler.tick().reserved.isEmpty)
        #expect(try await h.task("A").waitReason == "awaitingUserStart:claude:subscription:otherBilling")
        // Within the TTL the cached verdict holds, even after the login changed.
        fake.set { $0.verdict = .signedOut }
        h.clock.advance(AutomationGate.defaultSubscriptionTTL - 1)
        #expect(try await scheduler.tick().reserved.isEmpty)
        #expect(fake.snapshot.subscriptionCalls == 1)
        #expect(try await h.task("A").waitReason == "awaitingUserStart:claude:subscription:otherBilling")
        h.clock.advance(1)
        #expect(try await scheduler.tick().reserved.isEmpty)
        #expect(try await h.task("A").waitReason == "awaitingUserStart:claude:subscription:signedOut")
        fake.set { $0.verdict = .subscription(plan: "max") }
        h.clock.advance(AutomationGate.defaultSubscriptionTTL)
        #expect(try await scheduler.tick().reserved.count == 1)
        #expect(fake.snapshot.subscriptionCalls == 3)
    }

    @Test func thePersonalChannelRunsAVerifiedConfinedSubscribedInstall() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A"), planTask("B", after: ["A"])])
        let fake = FakeGateSources(identity: try FakeGateSources.verifiedClaude())
        let scheduler = h.scheduler(gate: h.gate(.personal, fake))
        let report = try await scheduler.tick()
        #expect(report.reserved.count == 1 && report.awaitingUserStart.isEmpty)
        try await h.finish("A")
        #expect(try await scheduler.tick().reserved.count == 1)
        #expect(h.starts.count == 2)
        // One subscription read for both reservations (cached), one probe.
        #expect(fake.snapshot.subscriptionCalls == 1 && fake.snapshot.confinementCalls == 1)
    }

    @Test func accessAfterABlockIsReadAfreshFromTheVerdict() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A")])
        let fake = FakeGateSources(identity: try FakeGateSources.verifiedClaude())
        fake.set { $0.verdict = .signedOut }
        let gate = h.gate(.personal, fake)
        _ = try await h.store.blockAccount(h.author, reason: "rateLimited")
        h.clock.advance(60_000)
        let report = try await h.scheduler(gate: gate).tick()
        #expect(report.reserved.isEmpty)
        // A failed check blocks again, with doubling.
        #expect(report.nextWakeAt == h.clock.now + 120_000)
        // Fresh each time, never from the cache.
        fake.set { $0.verdict = .subscription(plan: "max") }
        #expect(await gate.accessRestored(.claude, account: h.author))
        #expect(fake.snapshot.subscriptionCalls >= 2)
    }
}

@Suite struct AutomationGateTests {
    @Test func aGateWithoutSourcesFailsClosed() async {
        let gate = AutomationGate(channel: .personal)
        #expect(await gate.automaticVerdict(.claude) == .blocked(.identityUnknown))
        #expect(await !gate.accessRestored(.claude, account: AccountID()))
        #expect(await gate.refreshConfinement() != .effective)
    }

    @Test func aValidClearanceOpensTheDistributedChannelUntilItExpires() async throws {
        let fake = FakeGateSources(identity: try FakeGateSources.verifiedClaude())
        let clearance = ProviderClearance(
            provider: .claude, channel: .distributed, scope: "test", documentPath: "docs/provider-clearance/x.md", documentSHA256: "0", expiresOn: "2026-11-30"
        )
        let end = try #require(clearance.expiresAt)
        let now = Mutex<Int64>(end - 1)
        let gate = AutomationGate(channel: .distributed, clearances: [clearance], sources: fake.sources, clock: { now.withLock { $0 } })
        #expect(await gate.automaticVerdict(.claude) == .allowed)
        #expect(await gate.automaticVerdict(.codex) == .blocked(.channel(.distributed)))
        now.withLock { $0 = end }
        #expect(await gate.automaticVerdict(.claude) == .blocked(.channel(.distributed)))
    }

    @Test func prepareProbesOnlyWhenAutomationIsPossible() async throws {
        let context = GateContext(adapters: [], host: ProcessHost(), scratch: NSTemporaryDirectory(), clock: { 0 })
        let distributed = FakeGateSources(identity: nil)
        await AutomationGate(channel: .distributed, sources: distributed.sources).prepare(context)
        #expect(distributed.snapshot.confinementCalls == 0)
        let personal = FakeGateSources(identity: nil)
        let gate = AutomationGate(channel: .personal, sources: personal.sources)
        await gate.prepare(context)
        #expect(personal.snapshot.confinementCalls == 1)
        #expect(await gate.lastConfinement == .effective)
        await gate.record(confinement: .unavailable("x"))
        #expect(await gate.lastConfinement == .unavailable("x"))
    }

    @Test func blockDetailsRoundTrip() {
        let blocks: [AutomationBlock] = [
            .notPermitted, .channel(.distributed), .notInstalled, .identityUnknown, .versionNotListed("9.9.9"),
            .versionNotLiveVerified("2.1.328"), .buildNotVerified("2.1.329"), .confinementIneffective, .notSubscribed("signedOut"),
        ]
        for block in blocks {
            let parsed = AutomationBlock.parse(block.detail(for: .codex))
            #expect(parsed?.0 == .codex && parsed?.1 == block, "\(block)")
        }
        #expect(AutomationBlock.notPermitted.detail(for: .claude) == "claude")
        #expect(AutomationBlock.parse("attemptLimit") == nil)
        #expect(AutomationBlock.parse("claude:somethingNew") == nil)
    }
}
