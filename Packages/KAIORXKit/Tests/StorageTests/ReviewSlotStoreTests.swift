import Domain
import Foundation
import Testing
@testable import Storage

/// The store checks the review slots in the reviewer's reservation transaction (ADR 0011 §8,
/// ADR 0005 §6); the sheet's check is only a pre-check.
@Suite struct ReviewSlotStoreTests {
    func reviewer(_ seed: Seed, task: TaskID, account: AccountID? = nil) -> AttemptReservation {
        var r = reservation(seed, task: task, role: .reviewer)
        r.accountID = account
        return r
    }

    /// An open author attempt on a further task: it holds one slot (of `account`, if given).
    @discardableResult
    func author(_ store: Store, _ fixture: Fixture, _ seed: Seed, account: AccountID? = nil) async throws -> AttemptID {
        let task = try await fixture.readyTask(store, job: seed.job)
        var r = reservation(seed, task: task)
        r.accountID = account
        try await store.execute(Command(.reserveAttempt(r)))
        return r.attemptID
    }

    func reviewers(_ store: Store, _ task: TaskID) async throws -> [AttemptRecord] {
        try await store.attempts(taskID: task).filter { $0.role == .reviewer }
    }

    @Test func reviewerRefusedWhenGlobalSlotsFull() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let author = try await author(store, fixture, seed)
        let command = Command(.reserveAttempt(reviewer(seed, task: seed.task)))
        let limits = SchedulerLimits(global: 1, perAccount: 5)
        await #expect(throws: PlanningError.slotsFull(global: true, provider: .fake)) {
            try await store.execute(command, reviewerSlots: limits)
        }
        #expect(try await reviewers(store, seed.task).isEmpty)
        #expect(try await store.events(after: 0, limit: 100_000).allSatisfy { !($0.kind == .attemptReserved && $0.taskID == seed.task) })
        #expect(try await store.testCount("SELECT COUNT(*) FROM command WHERE id = ?", [.text(command.id.uuidString)]) == 0)

        // Once the slot is free, the same command reserves (nothing of the refusal was kept).
        try await transition(store, author, to: .cancelled)
        let outcome = try await store.execute(command, reviewerSlots: limits)
        #expect(!outcome.isReplay)
        #expect(try await reviewers(store, seed.task).count == 1)
    }

    @Test func reviewerRefusedWhenAccountSlotFull() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let a = try await store.registerAccount(provider: .fake, identity: "a")
        let b = try await store.registerAccount(provider: .fake, identity: "b")
        try await author(store, fixture, seed, account: a)
        let limits = SchedulerLimits(global: 5, perAccount: 1)
        await #expect(throws: PlanningError.slotsFull(global: false, provider: .fake)) {
            try await store.execute(Command(.reserveAttempt(reviewer(seed, task: seed.task, account: a))), reviewerSlots: limits)
        }
        #expect(try await reviewers(store, seed.task).isEmpty)
        try await store.execute(Command(.reserveAttempt(reviewer(seed, task: seed.task, account: b))), reviewerSlots: limits)
        #expect(try await reviewers(store, seed.task).map(\.accountID) == [b])
        // Without an account only the global limit applies.
        let other = try await fixture.readyTask(store, job: seed.job)
        try await store.execute(Command(.reserveAttempt(reviewer(seed, task: other))), reviewerSlots: limits)
        #expect(try await reviewers(store, other).count == 1)
    }

    @Test func earlierRefusalsComeBeforeFullSlots() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let full = SchedulerLimits(global: 1, perAccount: 1)

        // An open reviewer holds a slot itself: a second start reports the open reviewer.
        let open = reviewer(seed, task: seed.task)
        try await store.execute(Command(.reserveAttempt(open)))
        await #expect(throws: StoreError.activeReviewerExists(taskID: seed.task, attemptID: open.attemptID)) {
            try await store.execute(Command(.reserveAttempt(reviewer(seed, task: seed.task))), reviewerSlots: full)
        }

        // A blocked account is reported before full slots.
        let blocked = try await store.registerAccount(provider: .fake, identity: "blocked")
        _ = try await store.blockAccount(blocked, reason: "manual")
        let other = try await fixture.readyTask(store, job: seed.job)
        await #expect(throws: PlanningError.accountBlocked(blocked)) {
            try await store.execute(Command(.reserveAttempt(reviewer(seed, task: other, account: blocked))), reviewerSlots: full)
        }

    }

    @Test func forgottenContentIsReportedBeforeFullSlots() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let hardening = ChainHardeningStoreTests()
        let authorAttempt = try await hardening.authorResult(store, seed)
        _ = try await hardening.candidate(store, seed, author: authorAttempt, oid: ChainHardeningStoreTests.candidateOID)
        try await author(store, fixture, seed)
        try await store.rawExecute("UPDATE attempt SET content_purged_at = 1 WHERE id = '\(authorAttempt.uuidString)'")
        await #expect(throws: MemoryError.candidateContentPurged(seed.task)) {
            try await store.execute(Command(.reserveAttempt(reviewer(seed, task: seed.task))), reviewerSlots: SchedulerLimits(global: 1, perAccount: 1))
        }
    }

    @Test func aReplayIsNotRefused() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let command = Command(.reserveAttempt(reviewer(seed, task: seed.task)))
        let first = try await store.execute(command, reviewerSlots: SchedulerLimits(global: 1, perAccount: 1))
        #expect(!first.isReplay)
        // The reviewer now holds the only slot; a second window sending the same command replays it.
        let again = try await store.execute(command, reviewerSlots: SchedulerLimits(global: 1, perAccount: 1))
        #expect(again.isReplay && again.objectID == first.objectID)
    }

    @Test func withoutLimitsNothingChanges() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        try await author(store, fixture, seed)
        try await store.execute(Command(.reserveAttempt(reviewer(seed, task: seed.task))))
        #expect(try await reviewers(store, seed.task).count == 1)
    }

    @Test func aLostUncertainAttemptFreesItsSlot() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let lost = try await author(store, fixture, seed)
        try await store.rawExecute("UPDATE attempt SET state = 'uncertain', process_lost = 1 WHERE id = '\(lost.uuidString)'")
        #expect(try await store.activeAttemptCount(account: nil) == 0)
        try await store.execute(Command(.reserveAttempt(reviewer(seed, task: seed.task))), reviewerSlots: SchedulerLimits(global: 1, perAccount: 1))
        #expect(try await reviewers(store, seed.task).count == 1)
    }

    @Test func anAuthorReservationIgnoresReviewerSlots() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        try await store.execute(Command(.reserveAttempt(reservation(seed))), reviewerSlots: SchedulerLimits(global: 0, perAccount: 0))
        #expect(try await store.attempts(taskID: seed.task).map(\.role) == [.author])
    }
}
