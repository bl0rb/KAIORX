import Domain
import Foundation
import Synchronization
import Testing
@testable import Orchestration
@testable import Providers

/// ADR 0013: „Anmeldung prüfen“ reads the subscription now, past the gate's cache, and the
/// fresh verdict is the one automatic starts use.
@Suite struct LoginCheckGateTests {
    @Test func aCheckReadsPastTheCacheAndLiftsAStaleRefusal() async throws {
        let fake = FakeGateSources(identity: try FakeGateSources.verifiedClaude())
        fake.set { $0.verdict = .signedOut }
        let gate = AutomationGate(channel: .personal, sources: fake.sources, clock: { 1_000 })
        await gate.refreshConfinement()
        #expect(await gate.automaticVerdict(.claude) != .allowed)
        #expect(fake.snapshot.subscriptionCalls == 1)
        // The user logs in; the cached refusal would hold for five minutes.
        fake.set { $0.verdict = .subscription(plan: "max") }
        #expect(await gate.automaticVerdict(.claude) != .allowed)
        #expect(fake.snapshot.subscriptionCalls == 1)
        #expect(await gate.checkSubscription(.claude) == .verdict(.subscription(plan: "max")))
        #expect(fake.snapshot.subscriptionCalls == 2)
        #expect(await gate.automaticVerdict(.claude) == .allowed)
        #expect(fake.snapshot.subscriptionCalls == 2)
    }

    /// Only an accepted, confined build is asked; otherwise the check names the stage.
    @Test func anUnacceptedBuildIsNotAsked() async throws {
        let fake = FakeGateSources(identity: BinaryIdentity(path: "/c", resolvedPath: "/c", sha256: "x", version: "9.9.9"))
        let gate = AutomationGate(channel: .personal, sources: fake.sources)
        #expect(await gate.checkSubscription(.claude) == .blocked(.versionNotListed("9.9.9")))
        fake.set { $0.identity = try? FakeGateSources.verifiedClaude(); $0.confinement = .unavailable("aus") }
        await gate.refreshConfinement()
        #expect(await gate.checkSubscription(.claude) == .blocked(.confinementIneffective))
        #expect(fake.snapshot.subscriptionCalls == 0)
    }

    /// A read that began before the user asked (it may predate the login) is not the answer.
    @Test func aCheckDoesNotTakeAReadThatBeganBeforeIt() async throws {
        let identity = try FakeGateSources.verifiedClaude()
        // Each read sees the login state at its start, then waits for the latch.
        let loggedIn = Mutex(false), calls = Mutex(0), latch = Latch()
        let sources = AutomationGate.Sources(
            installed: { _ in identity }, confinement: { .effective },
            subscription: { _ in
                let seen = loggedIn.withLock { $0 }
                calls.withLock { $0 += 1 }
                await latch.wait()
                return seen ? .subscription(plan: "max") : .signedOut
            }
        )
        let gate = AutomationGate(channel: .personal, sources: sources, clock: { 1_000 })
        await gate.refreshConfinement()
        let tick = Task { await gate.automaticVerdict(.claude) }
        while calls.withLock({ $0 }) == 0 { await Task.yield() }
        // The user logs in while the tick's read is still running, then asks.
        loggedIn.withLock { $0 = true }
        let check = Task { await gate.checkSubscription(.claude) }
        try await Task.sleep(for: .milliseconds(50))
        latch.release()
        #expect(await tick.value != .allowed)
        #expect(await check.value == .verdict(.subscription(plan: "max")))
        #expect(calls.withLock { $0 } == 2)
        #expect(await gate.automaticVerdict(.claude) == .allowed)
    }

    @Test func aChannelWithoutAutomationReadsNothing() async throws {
        let fake = FakeGateSources(identity: try FakeGateSources.verifiedClaude())
        let gate = AutomationGate(channel: .distributed, sources: fake.sources)
        #expect(await gate.checkSubscription(.claude) == nil)
        #expect(await gate.checkSubscription(.fake) == nil)
        #expect(fake.snapshot.subscriptionCalls == 0)
        #expect(await AutomationGate(channel: .personal).checkSubscription(.claude) == nil)
    }
}
