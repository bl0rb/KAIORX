import Domain
import Foundation
import Providers
import Synchronization
import Testing
@testable import Orchestration
@testable import Providers
@testable import Storage
@testable import Workspace

/// Regressions from the package F check round (ADR 0005).
@Suite struct SchedulerCheckTests {
    func currentPlan(_ h: SchedulerHarness) async throws -> PlanRevisionID {
        try #require(try await h.store.jobs().first { $0.id == h.job }?.currentPlanID)
    }

    func cancel(_ h: SchedulerHarness, _ key: String) async throws {
        let t = try await h.task(key)
        try await h.store.execute(Command(.transitionTask(id: t.id, to: .cancelled, expectedVersion: t.version)))
    }

    @Test func aProposalBasedOnAnOlderRevisionCannotBeAccepted() async throws {
        let h = try await SchedulerHarness()
        let (ra, _) = try await h.store.proposePlan(job: h.job, draft: PlanDraft(tasks: [planTask("A")]), createdBy: .user, expectedCurrent: nil)
        let (rb, _) = try await h.store.proposePlan(job: h.job, draft: PlanDraft(tasks: [planTask("A"), planTask("B")]), createdBy: .user, expectedCurrent: nil)
        try await h.store.acceptPlan(ra.id, expectedCurrent: nil)
        await #expect(throws: PlanningError.planRevisionMoved(expected: ra.id, actual: ra.id)) { try await h.store.acceptPlan(rb.id, expectedCurrent: ra.id) }
    }

    @Test func acceptanceRevalidatesAgainstEndedTasks() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("K"), planTask("S", after: ["K"])])
        let current = try await currentPlan(h)
        let (next, _) = try await h.store.proposePlan(job: h.job, draft: PlanDraft(tasks: [planTask("K"), planTask("S", after: ["K"]), planTask("X")]), createdBy: .user, expectedCurrent: current)
        try await cancel(h, "K")
        do {
            try await h.store.acceptPlan(next.id, expectedCurrent: current)
            Issue.record("accepted a plan that cannot complete")
        } catch PlanningError.invalidPlan(let issues) {
            #expect(issues.issues.contains(.unreachable(task: "S", predecessor: "K")))
        }
    }

    @Test func aReadyTaskGoesBackToPendingWhenARevisionAddsAPredecessor() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A"), planTask("B")])
        _ = try await h.scheduler(automatic: false).tick()
        #expect(try await h.task("A").state == .ready)
        let current = try await currentPlan(h)
        let (next, _) = try await h.store.proposePlan(job: h.job, draft: PlanDraft(tasks: [planTask("N"), planTask("A", after: ["N"]), planTask("B")]), createdBy: .user, expectedCurrent: current)
        try await h.store.acceptPlan(next.id, expectedCurrent: current)
        _ = try await h.store.promoteReadyTasks(job: h.job)
        let a = try await h.task("A")
        #expect(a.state == .pending && a.readyAt == nil)
        #expect(try await h.task("N").state == .ready)
    }

    @Test func aStaleEndedReasonIsClearedWhenARevisionReplacesThePredecessor() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A"), planTask("B", after: ["A"])])
        try await cancel(h, "A")
        _ = try await h.store.promoteReadyTasks(job: h.job)
        #expect(try await h.task("B").waitReason == "predecessorEnded:A")
        let current = try await currentPlan(h)
        let (next, _) = try await h.store.proposePlan(job: h.job, draft: PlanDraft(tasks: [planTask("A2"), planTask("B", after: ["A2"])]), createdBy: .user, expectedCurrent: current)
        try await h.store.acceptPlan(next.id, expectedCurrent: current)
        _ = try await h.store.promoteReadyTasks(job: h.job)
        #expect(try await h.task("B").waitReason == nil)
    }

    @Test func plansOfAClosedJobDoNotChange() async throws {
        let h = try await SchedulerHarness()
        try await h.store.execute(Command(.transitionJob(id: h.job, to: .cancelled, expectedVersion: 1, reason: "weg")))
        await #expect(throws: PlanningError.jobClosed(h.job, .cancelled)) {
            _ = try await h.store.proposePlan(job: h.job, draft: PlanDraft(tasks: [planTask("A")]), createdBy: .user, expectedCurrent: nil)
        }
    }

    @Test func planTasksCannotBeStartedPastTheScheduler() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A")])
        _ = try await h.store.promoteReadyTasks(job: h.job)
        let a = try await h.task("A")
        await #expect(throws: PlanningError.taskManagedByScheduler(a.id)) {
            _ = try await h.coordinator.start(StartRequest(taskID: a.id, projectID: h.project, provider: .claude, modelProfile: "x", model: "m", prompt: "p"))
        }
    }

    @Test func anUncertainAttemptFreesItsSlotAfterARestart() async throws {
        let h = try await SchedulerHarness(limits: SchedulerLimits(global: 1, perAccount: 1), script: { _ in FakeScript(steps: [.emit(.started(sessionID: "s")), .end]) })
        try await h.activate([planTask("A"), planTask("B")])
        let scheduler = h.scheduler()
        let first = try #require(try await scheduler.tick().reserved.first)
        _ = try await h.coordinator.waitUntilFinished(first)
        #expect(try await h.store.attempt(first)?.state == .uncertain)
        #expect(try await scheduler.tick().reserved.isEmpty)
        _ = try await h.store.recoverAfterRestart()
        #expect(try await scheduler.tick().reserved.count == 1)
    }

    @Test func revocationStopsTheAccountsAttemptsUnderOtherConsents() async throws {
        let h = try await SchedulerHarness(script: { _ in .waitsForCancel })
        try await h.activate([planTask("A")])
        let attempt = try #require(try await h.scheduler().tick().reserved.first)
        #expect(try await h.store.attempt(attempt)?.consentID == h.authorConsent.id)
        let jobConsent = try await h.store.grantConsent(ConsentDraft(
            projectID: h.project, jobID: h.job, provider: .claude, accountID: h.author, roles: [.author], writeRoots: [""], unconfirmedAttemptLimit: 5
        ))
        h.clock.advance(1)
        // Another consent of the same account, revoked after the reservation, stops the attempt too.
        try await h.store.revokeConsent(jobConsent.id)
        let report = try await h.scheduler().tick()
        #expect(report.cancelledForRevocation == [attempt])
    }

    @Test func theReservationItselfTreatsAnExpiredBlockAsBlocking() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A")])
        _ = try await h.store.promoteReadyTasks(job: h.job)
        try await h.store.blockAccount(h.author, reason: "rateLimited", retryAfterMs: 10_000)
        h.clock.advance(10_000)
        let a = try await h.task("A")
        let profile = try #require(try await h.store.modelProfiles().first { $0.provider == .claude && $0.tier == .fast })
        let outcome = try await h.store.reserveScheduled(ScheduledReservation(
            taskID: a.id, planID: try await currentPlan(h), consentID: h.authorConsent.id, profile: profile, tier: .fast, specDigest: "d",
            reservedTokens: 1_000, sizeUncertain: false, decision: Router.nextTier(planned: .fast, history: [])
        ), limits: h.limits)
        #expect(outcome == .waiting(WaitReason(.quota, "blocked")))
    }

    @Test func technicalStartFailuresDoNotUseTheUnknownQuotaAllowance() async throws {
        let failed = Mutex(true)
        let h = try await SchedulerHarness(unconfirmed: 1, script: { _ in
            failed.withLock { let first = $0; $0 = false; return first } ? FakeScript(startError: "boom", steps: []) : .success()
        })
        try await h.activate([planTask("A")])
        let scheduler = h.scheduler()
        _ = try await scheduler.tick()
        #expect(try await h.authorAttempts("A").first?.errorClass == "startFailed")
        h.clock.advance(60_000)
        #expect(try await scheduler.tick().reserved.count == 1)
    }

    @Test func aUserGrantResumesATaskAfterTheAttemptLimit() async throws {
        let h = try await SchedulerHarness(script: { _ in FakeScript(steps: [.emit(.started(sessionID: "s")), .emit(.completed(.failed(reason: "same")))]) })
        try await h.activate([planTask("A")])
        let scheduler = h.scheduler()
        for _ in 0..<3 {
            _ = try await scheduler.tick()
            _ = try await h.coordinator.waitUntilFinished(try #require(try await h.authorAttempts("A").last).id)
        }
        #expect(try await scheduler.tick().reserved.isEmpty)
        #expect(try await h.task("A").waitReason == "userDecision:attemptLimit")
        try await scheduler.grant(try await h.task("A").id, tier: .intensive, actor: "matze")
        #expect(try await scheduler.tick().reserved.count == 1)
        #expect(try await h.authorAttempts("A").last?.tier == .intensive)
    }

    @Test func anExhaustedWindowStopsLimitingAtItsReset() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A")])
        let reset = h.clock.now + 60_000
        try await h.store.recordQuotaObservation(h.author, QuotaSignal(windowKey: "5h", unit: .percent, used: 100, limit: 100, resetAt: reset), source: "test")
        let scheduler = h.scheduler()
        let waiting = try await scheduler.tick()
        #expect(waiting.waiting.values.contains(WaitReason(.quota, "exhausted")))
        #expect(waiting.nextWakeAt == reset)
        h.clock.advance(60_000)
        #expect(try await scheduler.tick().reserved.count == 1)
    }

    @Test func anExpiredBlockIsLiftedOnlyAfterTheAccessCheck() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A")])
        try await h.store.blockAccount(h.author, reason: "rateLimited", retryAfterMs: 10_000)
        h.clock.advance(10_000)
        _ = try await h.store.promoteReadyTasks(job: h.job)
        let report = try await h.scheduler(access: false).start(try await h.task("A").id, actor: "matze")
        #expect(report.reserved.isEmpty)
        #expect(try await h.authorAttempts("A").isEmpty)
    }

    @Test func aTaskStaysOnItsAccountAfterARateLimit() async throws {
        let limited = Mutex(true)
        let h = try await SchedulerHarness(script: { _ in
            if limited.withLock({ let first = $0; $0 = false; return first }) {
                return FakeScript(steps: [.emit(.started(sessionID: "s")), .emit(.rateLimited(signal: RateLimitSignal(kind: .rateLimit, retryAfterMs: 30_000))), .emit(.completed(.failed(reason: "429")))])
            }
            return .success()
        })
        let second = try await h.store.registerAccount(provider: .claude, identity: "second")
        try await h.store.grantConsent(ConsentDraft(projectID: h.project, provider: .claude, accountID: second, roles: [.author], writeRoots: [""], unconfirmedAttemptLimit: 5))
        try await h.store.createBudget(account: second, job: h.job, tokenLimit: 1_000_000)
        try await h.activate([planTask("A")])
        let scheduler = h.scheduler()
        _ = try await scheduler.tick()
        _ = try await h.coordinator.waitUntilFinished(try #require(try await h.authorAttempts("A").first).id)
        let report = try await scheduler.tick()
        #expect(report.reserved.isEmpty)
        #expect(report.waiting[try await h.task("A").id] == WaitReason(.quota, "blocked"))
    }

    @Test func blocksKeepTheLongerEndAndAreJournaled() async throws {
        let h = try await SchedulerHarness()
        let stop = try await h.store.blockAccount(h.author, reason: "planStop")
        let later = try await h.store.blockAccount(h.author, reason: "rateLimited", retryAfterMs: 30_000)
        #expect(later.id == stop.id && later.until == nil)
        let events = try await h.store.events(limit: 10_000).map(\.kind)
        #expect(events.contains(.quotaBlocked))
        try await h.store.releaseBlock(stop.id)
        #expect(try await h.store.events(limit: 10_000).map(\.kind).contains(.quotaReleased))
    }

    @Test func aFallbackBlockCanBeLiftedOnceAndARetryAfterBlockNot() async throws {
        let h = try await SchedulerHarness()
        let fallback = try await h.store.blockAccount(h.author, reason: "rateLimited")
        try await h.store.releaseBlock(fallback.id)
        let again = try await h.store.blockAccount(h.author, reason: "rateLimited")
        await #expect(throws: PlanningError.blockNotReleasable(again.id)) { try await h.store.releaseBlock(again.id) }
        let other = try await h.store.registerAccount(provider: .claude, identity: "other")
        try await h.store.grantConsent(ConsentDraft(projectID: h.project, provider: .claude, accountID: other, writeRoots: [""]))
        let timed = try await h.store.blockAccount(other, reason: "rateLimited", retryAfterMs: 5_000)
        await #expect(throws: PlanningError.blockNotReleasable(timed.id)) { try await h.store.releaseBlock(timed.id) }
    }

    @Test func aTimedManualBlockStaysTimedAfterAFailedAccessCheck() async throws {
        let h = try await SchedulerHarness()
        try await h.store.blockAccount(h.author, reason: "manual", until: h.clock.now + 60_000)
        h.clock.advance(60_000)
        let report = try await h.scheduler(access: false).tick()
        #expect(report.nextWakeAt != nil)
        #expect(try await h.store.openBlocks().allSatisfy { $0.until != nil })
    }

    @Test func anUnresolvedReservationCanBeSettledByTheUser() async throws {
        let h = try await SchedulerHarness(budget: 1_500, script: { _ in .waitsForCancel })
        try await h.activate([planTask("A")])
        let attempt = try #require(try await h.scheduler().tick().reserved.first)
        try await h.coordinator.cancel(attempt, reason: "t")
        _ = try await h.coordinator.waitUntilFinished(attempt)
        #expect(try await h.store.budgetRemaining(account: h.author, job: h.job) == 500)
        try await h.store.resolveReservation(attempt: attempt, settledTokens: nil)
        #expect(try await h.store.budgetRemaining(account: h.author, job: h.job) == 1_500)
    }

    @Test func theRepairPromptCarriesTheLastCountedFailure() async throws {
        let prompts = Mutex<[String]>([])
        let step = Mutex(0)
        let h = try await SchedulerHarness(script: { spec in
            prompts.withLock { $0.append(spec.prompt) }
            let n = step.withLock { $0 += 1; return $0 }
            if n == 1 { return FakeScript(steps: [.emit(.started(sessionID: "s")), .emit(.completed(.failed(reason: "compile error in Parser")))]) }
            if n == 2 { return FakeScript(steps: [.emit(.started(sessionID: "s")), .emit(.rateLimited(signal: RateLimitSignal(kind: .rateLimit, retryAfterMs: 1_000))), .emit(.completed(.failed(reason: "429")))]) }
            return .success()
        })
        try await h.activate([planTask("A")])
        let scheduler = h.scheduler()
        for _ in 0..<3 {
            _ = try await scheduler.tick()
            if let last = try await h.authorAttempts("A").last { _ = try await h.coordinator.waitUntilFinished(last.id) }
            h.clock.advance(1_000)
        }
        let all = prompts.withLock { $0 }
        #expect(all.count == 3)
        #expect(all.last?.contains("compile error in Parser") == true)
    }

    @Test func reviewsOfPlanTasksRunUnderTheReviewerConsent() async throws {
        let h = try await SchedulerHarness()
        try await h.activate([planTask("A", writes: ["src/A"])])
        let tree = try await PlannedIntegrationTests().result(h, "A", "mkdir -p src/A && echo x > src/A/f", writes: ["src/A"])
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        try await h.integration.runTests(candidate.id, profile: TestProfile(executable: "/bin/sh", arguments: ["-c", "exit 0"]))
        let review = try await h.integration.startReview(candidate.id, provider: .fake, model: "r", criteria: "")
        #expect(try await h.store.attempt(review)?.accountID == h.reviewer)
        await #expect(throws: PlanningError.noReviewerConsent(.codex)) {
            _ = try await h.integration.startReview(candidate.id, provider: .codex, model: "r", criteria: "")
        }
    }
}

@Suite struct PackageFParsingChecks {
    @Test func aPresentRiskOrParentMustBeValid() {
        #expect(throws: PlanProposal.ParseError.invalidTask(0, "risk")) {
            try PlanProposal.parse(#"{"tasks": [{"key": "a", "title": "a", "risk": "Sensitive"}]}"#)
        }
        #expect(throws: PlanProposal.ParseError.invalidTask(0, "parent")) {
            try PlanProposal.parse(#"{"tasks": [{"key": "a", "title": "a", "parent": 3}]}"#)
        }
        #expect(throws: PlanProposal.ParseError.invalidTask(0, "multipleModules")) {
            try PlanProposal.parse(#"{"tasks": [{"key": "a", "title": "a", "difficulty": {"multipleModules": "yes"}}]}"#)
        }
    }

    @Test func manifestNamesAreMatchedWithoutLetterCase() throws {
        #expect(try WriteArea.resolve(["package.swift"]).overlaps(try WriteArea.resolve(["Package.resolved"])))
        #expect(try WriteArea.resolve(["App.XCODEPROJ/project.pbxproj"]).overlaps(try WriteArea.resolve(["Package.swift"])))
    }

    @Test func codexHTTP429VariantsAreRateLimits() throws {
        let exhausted = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"responseTooManyFailedAttempts": {"httpStatusCode": 429}}"#.utf8))
        #expect(CodexRunHandle.limitKind(exhausted) == .rateLimit)
        let server = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"responseStreamDisconnected": {"httpStatusCode": 500}}"#.utf8))
        #expect(CodexRunHandle.limitKind(server) == nil)
    }
}
