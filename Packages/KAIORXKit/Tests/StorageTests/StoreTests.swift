import Domain
import Foundation
import SQLite3
import Synchronization
import Testing
@testable import Storage

/// Deterministic millisecond clock.
final class TestClock: Sendable {
    private let value = Mutex<Int64>(1_800_000_000_000)

    var function: @Sendable () -> Int64 {
        { [self] in self.value.withLock { $0 += 1; return $0 } }
    }
}

struct Seed {
    let project: ProjectID
    let job: JobID
    let task: TaskID
}

struct Fixture {
    let directory: URL
    let path: String
    let clock = TestClock()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "kaiorx-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appending(path: "test.sqlite").path(percentEncoded: false)
    }

    func open(_ migrations: [Migration] = CoreSchema.migrations) throws -> Store {
        try Store(path: path, migrations: migrations, clock: clock.function)
    }

    /// Project and job; with `ready`, the job is active and the task `ready` for an author.
    func seed(_ store: Store, ready: Bool = true) async throws -> Seed {
        let seed = Seed(project: ProjectID(), job: JobID(), task: TaskID())
        try await store.execute(Command(.openProject(id: seed.project, name: "Demo", rootLocator: directory.path(percentEncoded: false))))
        try await store.execute(Command(.createJob(id: seed.job, projectID: seed.project, goal: "Ziel")))
        try await store.execute(Command(.createTask(id: seed.task, jobID: seed.job, title: "Aufgabe")))
        if ready {
            try await store.execute(Command(.transitionJob(id: seed.job, to: .planned, expectedVersion: 1, reason: nil)))
            try await store.execute(Command(.transitionJob(id: seed.job, to: .active, expectedVersion: 2, reason: nil)))
            try await store.execute(Command(.transitionTask(id: seed.task, to: .ready, expectedVersion: 1)))
        }
        return seed
    }

    /// Another `ready` task in the seeded job.
    func readyTask(_ store: Store, job: JobID) async throws -> TaskID {
        let task = TaskID()
        try await store.execute(Command(.createTask(id: task, jobID: job, title: "Weitere")))
        try await store.execute(Command(.transitionTask(id: task, to: .ready, expectedVersion: 1)))
        return task
    }
}

func reservation(_ seed: Seed, task: TaskID? = nil, attempt: AttemptID = AttemptID(), role: AttemptRole = .author) -> AttemptReservation {
    AttemptReservation(
        attemptID: attempt, taskID: task ?? seed.task, projectID: seed.project, role: role, provider: .fake,
        mode: .automatic, model: "fake", specDigest: "d"
    )
}

func transition(_ store: Store, _ id: AttemptID, to state: AttemptState, errorClass: String? = nil) async throws {
    let version = try #require(try await store.attempt(id)).version
    try await store.execute(Command(.transitionAttempt(id: id, to: state, expectedVersion: version, errorClass: errorClass)))
}

func moveTask(_ store: Store, _ id: TaskID, to state: TaskState) async throws {
    let version = try #require(try await store.task(id)).version
    try await store.execute(Command(.transitionTask(id: id, to: state, expectedVersion: version)))
}

func moveJob(_ store: Store, _ id: JobID, to state: JobState, reason: String? = nil) async throws {
    let version = try #require(try await store.jobs().first { $0.id == id }).version
    try await store.execute(Command(.transitionJob(id: id, to: state, expectedVersion: version, reason: reason)))
}

@Suite struct MigrationTests {
    static let current = CoreSchema.migrations.count
    static func extra(_ version: Int, sql: String = "CREATE TABLE extra (x INTEGER) STRICT;") -> Migration {
        Migration(version: version, name: "extra\(version)", sql: sql)
    }

    @Test func appliesOnceAndReopensWithoutChanges() async throws {
        let fixture = try Fixture()
        let first = try fixture.open()
        #expect(first.migrationReport.appliedVersions == Array(1...Self.current))
        #expect(first.migrationReport.backupPath == nil)
        await first.close()

        let second = try fixture.open()
        #expect(second.migrationReport == MigrationReport(previousVersion: Self.current, appliedVersions: [], backupPath: nil))
    }

    @Test func connectionUsesForeignKeysAndWAL() async throws {
        let store = try Fixture().open()
        let (foreignKeys, journal) = try await store.pragmas()
        #expect(foreignKeys == 1)
        #expect(journal == "wal")
    }

    @Test func changedAppliedMigrationIsRejected() async throws {
        let fixture = try Fixture()
        try await fixture.open().close()
        var edited = CoreSchema.migrations
        edited[0] = Migration(version: 1, name: "core", sql: edited[0].sql + "\n-- edited")
        #expect(throws: MigrationError.checksumMismatch(version: 1)) { try fixture.open(edited) }
    }

    @Test func newerDatabaseIsRejected() async throws {
        let fixture = try Fixture()
        try await fixture.open(CoreSchema.migrations + [Self.extra(Self.current + 1)]).close()
        #expect(throws: MigrationError.databaseNewerThanApp(databaseVersion: Self.current + 1, appVersion: Self.current)) {
            try fixture.open()
        }
    }

    @Test func upgradeFromVersionOneKeepsDataAndTakesABackup() async throws {
        let fixture = try Fixture()
        let old = try fixture.open([CoreSchema.v1])
        let project = ProjectID()
        try await old.execute(Command(.openProject(id: project, name: "Alt", rootLocator: "/tmp/alt")))
        await old.close()

        let upgraded = try fixture.open()
        #expect(upgraded.migrationReport.previousVersion == 1)
        #expect(upgraded.migrationReport.appliedVersions == Array(2...Self.current))
        let backupPath = try #require(upgraded.migrationReport.backupPath)
        #expect(backupPath.contains("backup-v1-"))
        let attributes = try FileManager.default.attributesOfItem(atPath: backupPath)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let migrated = try #require(try await upgraded.projects().first)
        #expect(migrated.id == project)
        #expect(migrated.objectFormat == nil)
    }

    @Test func failingMigrationLeavesTheDatabaseUntouched() async throws {
        let fixture = try Fixture()
        try await fixture.open().close()
        let ok = Self.extra(Self.current + 1)
        let broken = Self.extra(Self.current + 2, sql: "INSERT INTO missing VALUES (1);")
        #expect(throws: SQLiteError.self) { try fixture.open(CoreSchema.migrations + [ok, broken]) }

        let store = try fixture.open()
        #expect(store.migrationReport == MigrationReport(previousVersion: Self.current, appliedVersions: [], backupPath: nil))
        #expect(try await store.tableExists("extra") == false)
    }

    @Test func gapsInMigrationVersionsAreRejected() throws {
        let fixture = try Fixture()
        #expect(throws: MigrationError.invalidSequence) { try fixture.open(CoreSchema.migrations + [Self.extra(Self.current + 2)]) }
    }
}

@Suite struct ProcessLockTests {
    @Test func secondStoreOnTheSameDatabaseIsRefused() async throws {
        let fixture = try Fixture()
        let first = try fixture.open()
        #expect(throws: StoreError.databaseInUse(path: fixture.path)) { try fixture.open() }
        await first.close()
        // Closing releases the lock.
        let second = try fixture.open()
        await second.close()
    }

    @Test func lockIsReleasedWhenTheStoreIsDropped() throws {
        let fixture = try Fixture()
        do { _ = try fixture.open() }
        _ = try fixture.open()
    }
}

@Suite struct CommandTests {
    @Test func repeatedCommandIsAnsweredFromTheJournal() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let command = Command(.createTask(id: TaskID(), jobID: seed.job, title: "Zweite"))
        let first = try await store.execute(command)
        let eventsBefore = try await store.events().count
        let second = try await store.execute(command)
        #expect(!first.isReplay)
        #expect(second.isReplay)
        #expect(second.objectID == first.objectID)
        #expect(try await store.events().count == eventsBefore)
        #expect(try await store.tasks(jobID: seed.job).count == 2)
    }

    @Test func reusedCommandKeyWithOtherPayloadFails() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let key = CommandID()
        try await store.execute(Command(id: key, .createTask(id: TaskID(), jobID: seed.job, title: "A")))
        await #expect(throws: StoreError.commandKeyReused(key)) {
            try await store.execute(Command(id: key, .createTask(id: TaskID(), jobID: seed.job, title: "B")))
        }
    }

    @Test func reopeningTheSameFolderReturnsTheSameProject() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let again = try await store.execute(Command(.openProject(
            id: ProjectID(), name: "Anders", rootLocator: fixture.directory.path(percentEncoded: false)
        )))
        #expect(again.objectID == seed.project.uuidString)
        #expect(try await store.projects().count == 1)
    }

    @Test func staleVersionIsRejectedAndNothingChanges() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store, ready: false)
        try await store.execute(Command(.transitionTask(id: seed.task, to: .ready, expectedVersion: 1)))
        let before = try await store.snapshot()
        await #expect(throws: StoreError.versionConflict(entity: "task", id: seed.task.uuidString, expected: 1, actual: 2)) {
            try await store.execute(Command(.transitionTask(id: seed.task, to: .blocked, expectedVersion: 1)))
        }
        #expect(try await store.snapshot() == before)
    }

    @Test func invalidTransitionRollsBack() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store, ready: false)
        let before = try await store.snapshot()
        await #expect(throws: DomainError.self) {
            try await store.execute(Command(.transitionTask(id: seed.task, to: .integrated, expectedVersion: 1)))
        }
        #expect(try await store.snapshot() == before)
    }

    @Test func missingParentIsReported() async throws {
        let store = try Fixture().open()
        let job = JobID()
        await #expect(throws: StoreError.notFound(entity: "job", id: job.uuidString)) {
            try await store.execute(Command(.createTask(id: TaskID(), jobID: job, title: "x")))
        }
    }

    @Test func foreignKeysAreEnforcedBelowTheStore() async throws {
        let store = try Fixture().open()
        await #expect(throws: SQLiteError.self) {
            try await store.rawRun(
                "INSERT INTO task (id, job_id, title, state, version, created_at) VALUES ('t', 'missing', 'x', 'pending', 1, 0)"
            )
        }
    }

    @Test func textWithEmbeddedNULRoundTrips() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let task = TaskID()
        try await store.execute(Command(.createTask(id: task, jobID: seed.job, title: "a\u{0}b – ü")))
        #expect(try await store.task(task)?.title == "a\u{0}b – ü")
    }
}

@Suite struct SideStateTests {
    @Test func pausedJobResumesOnlyWhereItStopped() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store, ready: false)
        try await moveJob(store, seed.job, to: .paused, reason: "Urlaub")
        #expect(try await store.jobs().first?.resumeState == .draft)
        await #expect(throws: DomainError.invalidTransition(entity: "job", from: "paused", to: "active")) {
            try await moveJob(store, seed.job, to: .active)
        }
        try await moveJob(store, seed.job, to: .needsAttention, reason: "Rückfrage")
        #expect(try await store.jobs().first?.resumeState == .draft)
        try await moveJob(store, seed.job, to: .draft)
        let job = try #require(try await store.jobs().first)
        #expect(job.state == .draft)
        #expect(job.resumeState == nil)
    }

    @Test func pauseCancelAndAttentionRequireAReason() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store, ready: false)
        for state in [JobState.paused, .needsAttention, .cancelled] {
            await #expect(throws: DomainError.reasonRequired(entity: "job", state: state.rawValue)) {
                try await moveJob(store, seed.job, to: state, reason: state == .cancelled ? "" : nil)
            }
        }
        try await moveJob(store, seed.job, to: .cancelled, reason: "Nicht mehr nötig")
        #expect(try await store.jobs().first?.stateReason == "Nicht mehr nötig")
    }

    @Test func blockedTaskCannotSkipAhead() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store, ready: false)
        try await moveTask(store, seed.task, to: .blocked)
        #expect(try await store.task(seed.task)?.resumeState == .pending)
        await #expect(throws: DomainError.self) { try await moveTask(store, seed.task, to: .awaitingMerge) }
        try await moveTask(store, seed.task, to: .pending)
        #expect(try await store.task(seed.task)?.resumeState == nil)
    }
}

@Suite struct AttemptTests {
    @Test func onlyOneActiveAuthorPerTask() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let first = AttemptID()
        try await store.execute(Command(.reserveAttempt(reservation(seed, attempt: first))))
        await #expect(throws: StoreError.activeAuthorExists(taskID: seed.task, attemptID: first)) {
            try await store.execute(Command(.reserveAttempt(reservation(seed))))
        }
        // A reviewer is not an author.
        try await store.execute(Command(.reserveAttempt(reservation(seed, role: .reviewer))))

        try await transition(store, first, to: .failed, errorClass: "test")
        let second = AttemptID()
        try await store.execute(Command(.reserveAttempt(reservation(seed, attempt: second))))
        #expect(try await store.attempt(second)?.ordinal == 2)
        #expect(try await store.task(seed.task)?.currentAttemptID == second)
    }

    @Test func taskFollowsItsAuthorAttempt() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let first = AttemptID()
        try await store.execute(Command(.reserveAttempt(reservation(seed, attempt: first))))
        #expect(try await store.task(seed.task)?.state == .running)
        try await transition(store, first, to: .cancelled)
        #expect(try await store.task(seed.task)?.state == .ready)

        let second = AttemptID()
        try await store.execute(Command(.reserveAttempt(reservation(seed, attempt: second))))
        try await transition(store, second, to: .starting)
        _ = try await store.ingest(.completed(.succeeded), attemptID: second)
        #expect(try await store.task(seed.task)?.state == .resultReady)
    }

    @Test func authorNeedsAnActiveJobAndAReadyTask() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store, ready: false)
        await #expect(throws: StoreError.jobNotActive(jobID: seed.job, state: .draft)) {
            try await store.execute(Command(.reserveAttempt(reservation(seed))))
        }
        try await moveJob(store, seed.job, to: .planned)
        try await moveJob(store, seed.job, to: .active)
        await #expect(throws: StoreError.taskNotReady(taskID: seed.task, state: .pending)) {
            try await store.execute(Command(.reserveAttempt(reservation(seed))))
        }
        try await moveTask(store, seed.task, to: .ready)
        try await moveTask(store, seed.task, to: .blocked)
        await #expect(throws: StoreError.taskNotReady(taskID: seed.task, state: .blocked)) {
            try await store.execute(Command(.reserveAttempt(reservation(seed))))
        }
    }

    @Test func reservationMustMatchTheTasksProject() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        var wrong = reservation(seed)
        wrong.projectID = ProjectID()
        await #expect(throws: StoreError.projectMismatch(taskID: seed.task, expected: wrong.projectID)) {
            try await store.execute(Command(.reserveAttempt(wrong)))
        }
    }

    @Test func uncertainAttemptKeepsTheAuthorSlot() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let id = AttemptID()
        try await store.execute(Command(.reserveAttempt(reservation(seed, attempt: id))))
        try await transition(store, id, to: .starting)
        try await transition(store, id, to: .uncertain)
        #expect(try await store.task(seed.task)?.state == .running)
        await #expect(throws: StoreError.activeAuthorExists(taskID: seed.task, attemptID: id)) {
            try await store.execute(Command(.reserveAttempt(reservation(seed))))
        }
    }

    @Test func terminalAttemptIsImmutable() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let id = AttemptID()
        try await store.execute(Command(.reserveAttempt(reservation(seed, attempt: id))))
        try await transition(store, id, to: .cancelled)
        let attempt = try #require(try await store.attempt(id))
        #expect(attempt.endedAt != nil)
        await #expect(throws: DomainError.self) { try await transition(store, id, to: .starting) }
    }

    @Test func reservingForAClosedTaskFails() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        try await moveTask(store, seed.task, to: .cancelled)
        await #expect(throws: StoreError.taskNotOpen(taskID: seed.task, state: .cancelled)) {
            try await store.execute(Command(.reserveAttempt(reservation(seed))))
        }
    }
}

@Suite struct IngestTests {
    func startingAttempt(_ fixture: Fixture, _ store: Store) async throws -> AttemptID {
        let seed = try await fixture.seed(store)
        let id = AttemptID()
        try await store.execute(Command(.reserveAttempt(reservation(seed, attempt: id))))
        try await transition(store, id, to: .starting)
        return id
    }

    @Test func startedEventMovesToRunningAndKeepsSession() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let id = try await startingAttempt(fixture, store)
        _ = try await store.ingest(.started(sessionID: "s-1"), attemptID: id)
        let attempt = try #require(try await store.attempt(id))
        #expect(attempt.state == .running)
        #expect(attempt.sessionHandle == "s-1")
        #expect(attempt.startedAt != nil)
        #expect(try await store.ingest(.started(sessionID: "s-2"), attemptID: id) == .ignored(.redundantStart))
        #expect(try await store.attempt(id)?.sessionHandle == "s-1")
    }

    @Test func startedAfterAnEarlyCancelKeepsTheSession() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let id = try await startingAttempt(fixture, store)
        try await transition(store, id, to: .cancelling)
        guard case .recorded = try await store.ingest(.started(sessionID: "s-42"), attemptID: id) else {
            Issue.record("started was not recorded"); return
        }
        let attempt = try #require(try await store.attempt(id))
        #expect(attempt.state == .cancelling)
        #expect(attempt.sessionHandle == "s-42")
        #expect(attempt.startedAt != nil)
        #expect(try await store.events().last?.kind == .attemptStarted)
    }

    @Test func firstNonStartEventAlsoProvesTheRun() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let id = try await startingAttempt(fixture, store)
        _ = try await store.ingest(.messageDelta(itemID: "m", text: "hi"), attemptID: id)
        #expect(try await store.attempt(id)?.state == .running)
        let kinds = try await store.events().filter { $0.attemptID == id }.map(\.kind)
        #expect(kinds.suffix(2) == [.attemptStarted, .messageDelta])
    }

    @Test func identicalDeltasAreBothKeptButDedupKeysAreNot() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let id = try await startingAttempt(fixture, store)
        _ = try await store.ingest(.started(sessionID: nil), attemptID: id)
        _ = try await store.ingest(.messageDelta(itemID: "m", text: "a"), attemptID: id)
        _ = try await store.ingest(.messageDelta(itemID: "m", text: "a"), attemptID: id)
        // An empty key is no key.
        _ = try await store.ingest(.messageDelta(itemID: "m", text: "a"), attemptID: id, dedupKey: "")
        _ = try await store.ingest(.messageDelta(itemID: "m", text: "a"), attemptID: id, dedupKey: "")
        _ = try await store.ingest(.usage(UsageSample(outputTokens: 3)), attemptID: id, dedupKey: "msg-1")
        #expect(try await store.ingest(.usage(UsageSample(outputTokens: 3)), attemptID: id, dedupKey: "msg-1") == .ignored(.duplicate))
        let events = try await store.events().filter { $0.attemptID == id }
        #expect(events.filter { $0.kind == .messageDelta }.count == 4)
        #expect(events.filter { $0.kind == .usageObserved }.count == 1)
        #expect(events.allSatisfy { $0.dedupKey != "" })
    }

    @Test func eventsAfterTerminalAreIgnored() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let id = try await startingAttempt(fixture, store)
        _ = try await store.ingest(.started(sessionID: nil), attemptID: id)
        _ = try await store.ingest(.completed(.cancelled), attemptID: id)
        #expect(try await store.ingest(.messageDelta(itemID: "m", text: "late"), attemptID: id) == .ignored(.afterTerminal))
        #expect(try await store.ingest(.completed(.succeeded), attemptID: id) == .ignored(.afterTerminal))
        #expect(try await store.attempt(id)?.state == .cancelled)
    }

    @Test func failedCompletionRecordsErrorClass() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let id = try await startingAttempt(fixture, store)
        _ = try await store.ingest(.completed(.failed(reason: "boom")), attemptID: id)
        let attempt = try #require(try await store.attempt(id))
        #expect(attempt.state == .failed)
        #expect(attempt.errorClass == "providerFailed")
    }

    @Test func eventsBeforeStartAreRejected() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        let id = AttemptID()
        try await store.execute(Command(.reserveAttempt(reservation(seed, attempt: id))))
        await #expect(throws: StoreError.unexpectedEvent(attemptID: id, state: .reserved)) {
            try await store.ingest(.started(sessionID: nil), attemptID: id)
        }
    }

    @Test func journalOrderAndCursorReplay() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let id = try await startingAttempt(fixture, store)
        _ = try await store.ingest(.started(sessionID: nil), attemptID: id)
        _ = try await store.ingest(.messageFinal(itemID: "m", text: "x"), attemptID: id)
        _ = try await store.ingest(.completed(.succeeded), attemptID: id)

        let all = try await store.events()
        #expect(all.map(\.seq) == all.map(\.seq).sorted())
        #expect(Set(all.map(\.seq)).count == all.count)
        let ordinals = all.filter { $0.attemptID == id }.compactMap(\.ordinal)
        #expect(ordinals == Array(1...ordinals.count))
        #expect(all.allSatisfy { $0.schemaVersion == 1 })

        let cursor = all[2].seq
        #expect(try await store.events(after: cursor) == Array(all.dropFirst(3)))
        #expect(try await store.events(after: 0, limit: 2) == Array(all.prefix(2)))

        let completion = try #require(all.last { $0.kind == .attemptCompleted })
        #expect(try JSONDecoder().decode(AgentEvent.self, from: #require(completion.payload)) == .completed(.succeeded))
        #expect(all.last?.kind == .taskStateChanged)
    }
}

@Suite struct RestartTests {
    /// Package B acceptance: reopening after every state change yields the same state.
    @Test func reopenAfterEveryChangeYieldsTheSameState() async throws {
        let fixture = try Fixture()
        let project = ProjectID(), job = JobID(), task = TaskID(), attempt = AttemptID()
        let seed = Seed(project: project, job: job, task: task)
        let steps: [@Sendable (Store) async throws -> Void] = [
            { try await $0.execute(Command(.openProject(id: project, name: "P", rootLocator: "/tmp/p"))) },
            { try await $0.execute(Command(.createJob(id: job, projectID: project, goal: "Ziel"))) },
            { try await moveJob($0, job, to: .planned) },
            { try await moveJob($0, job, to: .paused, reason: "Pause") },
            { try await moveJob($0, job, to: .planned) },
            { try await moveJob($0, job, to: .active) },
            { try await $0.execute(Command(.createTask(id: task, jobID: job, title: "T"))) },
            { try await moveTask($0, task, to: .ready) },
            { try await $0.execute(Command(.reserveAttempt(reservation(seed, attempt: attempt)))) },
            { try await transition($0, attempt, to: .starting) },
            { _ = try await $0.ingest(.started(sessionID: "s"), attemptID: attempt) },
            { _ = try await $0.ingest(.messageDelta(itemID: "m", text: "a"), attemptID: attempt) },
            { _ = try await $0.ingest(.usage(UsageSample(inputTokens: 1)), attemptID: attempt, dedupKey: "u1") },
            { _ = try await $0.ingest(.completed(.succeeded), attemptID: attempt) },
        ]
        var store = try fixture.open()
        for (index, step) in steps.enumerated() {
            try await step(store)
            let before = try await store.snapshot()
            await store.close()
            store = try fixture.open()
            let after = try await store.snapshot()
            #expect(after == before, "state differs after reopening at step \(index)")
        }
        #expect(try await store.attempt(attempt)?.state == .succeeded)
        #expect(try await store.task(task)?.state == .resultReady)
    }

    @Test func recoveryMarksLostRunsUncertainAndCancelsUnstartedReservations() async throws {
        let fixture = try Fixture()
        var store = try fixture.open()
        let seed = try await fixture.seed(store)
        let otherTask = try await fixture.readyTask(store, job: seed.job)
        let running = AttemptID(), reserved = AttemptID()
        try await store.execute(Command(.reserveAttempt(reservation(seed, attempt: running))))
        try await transition(store, running, to: .starting)
        _ = try await store.ingest(.started(sessionID: nil), attemptID: running)
        try await store.execute(Command(.reserveAttempt(reservation(seed, task: otherTask, attempt: reserved))))
        await store.close()

        store = try fixture.open()
        let report = try await store.recoverAfterRestart()
        #expect(report.uncertain == [running])
        #expect(report.cancelledReservations == [reserved])
        #expect(try await store.attempt(running)?.state == .uncertain)
        #expect(try await store.attempt(running)?.errorClass == "processLostOnRestart")
        #expect(try await store.attempt(reserved)?.state == .cancelled)
        #expect(try await store.task(otherTask)?.state == .ready)
        #expect(try await store.activeAttempts().map(\.id) == [running])
        #expect(try await store.events().last(where: { $0.attemptID == running })?.kind == .recoveryRequired)

        // Recovery is idempotent.
        #expect(try await store.recoverAfterRestart().isEmpty)
    }

    @Test func closedStoreRefusesWork() async throws {
        let store = try Fixture().open()
        await store.close()
        await #expect(throws: StoreError.closed) { try await store.projects() }
    }
}

@Suite struct FilePermissionTests {
    @Test func databaseFileIsOwnerOnly() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        _ = try await fixture.seed(store)
        for suffix in ["", "-wal", "-shm", ".lock"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: fixture.path + suffix)
            #expect((attributes[.posixPermissions] as? Int) == 0o600, "\(suffix)")
        }
    }
}

extension Store {
    func pragmas() throws -> (foreignKeys: Int64, journalMode: String) {
        let db = try connection()
        let foreignKeys = try db.query("PRAGMA foreign_keys") { $0.int(0) }.first ?? -1
        let journal = try db.query("PRAGMA journal_mode") { try $0.requiredText(0) }.first ?? ""
        return (foreignKeys, journal)
    }

    func rawRun(_ sql: String) throws {
        try connection().run(sql)
    }

    func tableExists(_ name: String) throws -> Bool {
        try !connection().query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(name)]) { $0.int(0) }.isEmpty
    }
}

@Suite struct TaskAttemptCouplingTests {
    func runningAuthor(_ fixture: Fixture, _ store: Store) async throws -> (Seed, AttemptID) {
        let seed = try await fixture.seed(store)
        let id = AttemptID()
        try await store.execute(Command(.reserveAttempt(reservation(seed, attempt: id))))
        try await transition(store, id, to: .starting)
        _ = try await store.ingest(.started(sessionID: nil), attemptID: id)
        return (seed, id)
    }

    @Test func taskBlockedDuringTheRunResumesToTheOutcome() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let (seed, id) = try await runningAuthor(fixture, store)
        try await moveTask(store, seed.task, to: .blocked)
        _ = try await store.ingest(.completed(.succeeded), attemptID: id)
        let blocked = try #require(try await store.task(seed.task))
        #expect(blocked.state == .blocked)
        #expect(blocked.resumeState == .resultReady)
        await #expect(throws: StoreError.taskManagedByAttempt(taskID: seed.task, from: .blocked, to: .running)) {
            try await moveTask(store, seed.task, to: .running)
        }
        try await moveTask(store, seed.task, to: .resultReady)
    }

    @Test func blockedWhileRunningMayResumeWhileTheAuthorRuns() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let (seed, id) = try await runningAuthor(fixture, store)
        try await moveTask(store, seed.task, to: .blocked)
        try await moveTask(store, seed.task, to: .running)
        _ = try await store.ingest(.completed(.failed(reason: "x")), attemptID: id)
        #expect(try await store.task(seed.task)?.state == .ready)
    }

    @Test func commandsCannotFakeTheAuthorsMoves() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        let seed = try await fixture.seed(store)
        await #expect(throws: StoreError.taskManagedByAttempt(taskID: seed.task, from: .ready, to: .running)) {
            try await moveTask(store, seed.task, to: .running)
        }
        let id = AttemptID()
        try await store.execute(Command(.reserveAttempt(reservation(seed, attempt: id))))
        for target in [TaskState.resultReady, .ready] {
            await #expect(throws: StoreError.taskManagedByAttempt(taskID: seed.task, from: .running, to: target)) {
                try await moveTask(store, seed.task, to: target)
            }
        }
    }
}

@Suite struct LockPathTests {
    @Test func symlinkedFolderSharesTheLock() async throws {
        let fixture = try Fixture()
        let link = fixture.directory.deletingLastPathComponent().appending(path: "kaiorx-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory)
        let store = try fixture.open()
        let viaLink = link.appending(path: "test.sqlite").path(percentEncoded: false)
        #expect(throws: StoreError.databaseInUse(path: viaLink)) { try Store(path: viaLink) }
        await store.close()
    }

    @Test func spawnedChildDoesNotInheritTheLock() async throws {
        let fixture = try Fixture()
        let store = try fixture.open()
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("2"), nil]
        defer { argv.forEach { free($0) } }
        #expect(posix_spawn(&pid, "/bin/sleep", nil, nil, argv, environ) == 0)
        defer { kill(pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0) }
        await store.close()
        let reopened = try fixture.open()
        await reopened.close()
    }
}
