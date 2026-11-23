import Domain
import Foundation
import ProcessHost
import Testing
import TestSupport
@testable import Orchestration
@testable import Storage
@testable import Workspace

/// A user repository, a store with project, active job and ready task, and the service.
struct ServiceHarness {
    let host = ProcessHost()
    let checkout: String
    let layout: WorkspaceLayout
    let git: GitRunner
    let storePath: String
    var store: Store
    var service: WorkspaceService
    let project = ProjectID()
    let job = JobID()
    let task = TaskID()

    init() async throws {
        let base = try Scratch.directory("svc")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = Confinement.resolved(base.path(percentEncoded: false))
        checkout = root + "/user"
        try FileManager.default.createDirectory(atPath: checkout, withIntermediateDirectories: true)
        layout = WorkspaceLayout(root: root + "/data")
        git = try GitRunner(host: host, home: layout.gitHome)
        storePath = root + "/test.sqlite"
        store = try Store(path: storePath)
        service = WorkspaceService(store: store, git: git, layout: layout)
        try await sh("git init -q -b main && mkdir src && echo 'let a = 1' > src/a.swift && git add -A && git commit -q -m init")
        try await store.execute(Command(.openProject(id: project, name: "P", rootLocator: checkout)))
        try await store.execute(Command(.createJob(id: job, projectID: project, goal: "Ziel")))
        try await store.execute(Command(.transitionJob(id: job, to: .planned, expectedVersion: 1, reason: nil)))
        try await store.execute(Command(.transitionJob(id: job, to: .active, expectedVersion: 2, reason: nil)))
        try await store.execute(Command(.createTask(id: task, jobID: job, title: "T")))
        try await store.execute(Command(.transitionTask(id: task, to: .ready, expectedVersion: 1)))
    }

    @discardableResult
    func sh(_ script: String, in directory: String? = nil) async throws -> String {
        let result = try await host.run(LaunchSpec(
            executable: "/bin/sh", arguments: ["-c", script], workingDirectory: directory ?? checkout,
            environment: [
                "PATH": "/usr/bin:/bin:" + URL(filePath: git.executable).deletingLastPathComponent().path(percentEncoded: false),
                "HOME": layout.gitHome, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_AUTHOR_NAME": "U", "GIT_AUTHOR_EMAIL": "u@e", "GIT_COMMITTER_NAME": "U", "GIT_COMMITTER_EMAIL": "u@e",
            ],
            timeout: .seconds(30)
        ))
        guard result.termination == .exited(0) else {
            throw GitError.failed(arguments: [script], termination: result.termination, stderr: result.stderr.text)
        }
        return result.stdout.text.trimmingCharacters(in: .newlines)
    }

    func head() async throws -> String { try await sh("git rev-parse HEAD") }

    /// An author attempt reserved through the store, as the run coordinator would.
    func reserveAuthor() async throws -> AttemptID {
        let id = AttemptID()
        try await store.execute(Command(.reserveAttempt(AttemptReservation(
            attemptID: id, taskID: task, projectID: project, role: .author, provider: .fake, mode: .automatic,
            model: "m", specDigest: "d"
        ))))
        return id
    }

    /// Simulates an app restart on the same database.
    mutating func restart() async throws {
        await store.close()
        store = try Store(path: storePath)
        service = WorkspaceService(store: store, git: git, layout: layout)
    }
}

@Suite struct WorkspaceServiceTests {
    @Test func attachRecordsTheRepositoryAndRefusesAnotherOne() async throws {
        let harness = try await ServiceHarness()
        let info = try await harness.service.attach(harness.project)
        let project = try #require(try await harness.store.projects().first)
        #expect(project.gitCommonIdentity == "sha1:" + (try #require(info.rootCommit)))
        #expect(project.objectFormat == "sha1")

        // The folder is replaced by a different repository.
        try FileManager.default.removeItem(atPath: harness.checkout + "/.git")
        try await harness.sh("git init -q -b main && git commit -q --allow-empty -m other")
        let other = WorkspaceService(store: harness.store, git: harness.git, layout: harness.layout)
        await #expect(throws: WorkspaceServiceError.repositoryChanged(projectID: harness.project, recorded: project.gitCommonIdentity!)) {
            try await other.attach(harness.project)
        }
        #expect(try await harness.store.projects().first?.gitCommonIdentity == project.gitCommonIdentity)
    }

    @Test func movedRepositoryKeepsItsIdentity() async throws {
        let harness = try await ServiceHarness()
        let info = try await harness.service.attach(harness.project)
        let moved = harness.checkout + "-moved"
        try await harness.sh("git clone -q '\(harness.checkout)' '\(moved)'")
        #expect(try await harness.git.inspect(moved).identity == info.identity)
    }

    @Test func emptyRepositoryCannotBeAttached() async throws {
        let harness = try await ServiceHarness()
        let empty = harness.checkout + "-empty"
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        try await harness.sh("git init -q", in: empty)
        let project = ProjectID()
        try await harness.store.execute(Command(.openProject(id: project, name: "E", rootLocator: empty)))
        await #expect(throws: WorkspaceServiceError.repositoryWithoutCommits(empty)) { try await harness.service.attach(project) }
    }

    @Test func integrationRefIsCreatedOnceAtTheBase() async throws {
        let harness = try await ServiceHarness()
        let base = try await harness.head()
        try await harness.sh("echo dirty >> src/a.swift") // uncommitted work is not part of the base
        let (resolved, ref) = try await harness.service.openIntegration(harness.job, baseRevision: "main")
        #expect(resolved == base)
        #expect(try await harness.sh("git rev-parse \(ref)") == base)
        let job = try #require(try await harness.store.jobs().first)
        #expect(job.baseOID == base)
        #expect(job.integrationRef == ref)
        #expect(try await harness.service.openIntegration(harness.job, baseRevision: "main") == (base, ref))
        #expect(try await harness.store.gitOperations().map(\.state) == [.applied])
    }

    @Test func authorWorktreeIsLinkedToItsAttempt() async throws {
        let harness = try await ServiceHarness()
        let attempt = try await harness.reserveAuthor()
        let record = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: attempt, kind: .author, base: try await harness.head())
        #expect(record.state == .ready)
        #expect(try await harness.store.attempt(attempt)?.worktreeID == record.id)
        let path = harness.service.path(of: record)
        #expect(path.hasPrefix(harness.layout.worktreesRoot))
        #expect(try await harness.sh("git rev-parse HEAD", in: path) == record.baseOID)
        #expect(try await harness.store.gitOperations().map(\.kind) == [.addWorktree])
    }

    @Test func blockedRepositoryGetsNoWorktree() async throws {
        let harness = try await ServiceHarness()
        try await harness.sh("echo '*.bin filter=lfs' > .gitattributes && git add -A && git commit -q -m lfs")
        await #expect(throws: WorkspaceError.blocked([.attributeFilter(path: ".gitattributes", driver: "lfs")])) {
            _ = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: try await harness.head())
        }
        #expect(try await harness.store.worktrees().isEmpty)
    }

    @Test func sealPinsTheResultAndRemovalNeedsNoForce() async throws {
        let harness = try await ServiceHarness()
        let attempt = try await harness.reserveAuthor()
        let record = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: attempt, kind: .author, base: try await harness.head())
        let path = harness.service.path(of: record)
        try await harness.sh("echo 'let a = 2' > src/a.swift", in: path)

        let report = try await harness.service.seal(record.id, allowedPrefixes: ["src"], message: "result")
        let commit = try #require(report.outcome.commit)
        #expect(report.resultRef == "refs/kaiorx/results/\(attempt.uuidString)")
        #expect(try await harness.sh("git rev-parse \(report.resultRef!)") == commit)
        let sealed = try await harness.service.worktree(record.id)
        #expect(sealed.state == .frozen)
        #expect(sealed.resultOID == commit)
        #expect(sealed.savedTree == report.outcome.tree)
        // Frozen: writing fails.
        await #expect(throws: GitError.self) { try await harness.sh("echo x > src/a.swift", in: path) }

        try await harness.service.remove(record.id)
        #expect(try await harness.service.worktree(record.id).state == .removed)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try await harness.store.gitOperations().allSatisfy { $0.state == .applied })
        // The result survives the worktree.
        #expect(try await harness.sh("git show \(commit):src/a.swift") == "let a = 2")
    }

    @Test func unsavedWorkKeepsTheWorktree() async throws {
        let harness = try await ServiceHarness()
        let record = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: try await harness.head())
        let path = harness.service.path(of: record)
        try await harness.sh("echo 'let a = 3' > src/a.swift && ln -s /tmp src/link", in: path)
        let report = try await harness.service.seal(record.id, allowedPrefixes: nil, message: "m")
        #expect(report.outcome.rejected.values.contains(.symlink))
        await #expect(throws: WorkspaceError.unsavedChanges(path)) { try await harness.service.remove(record.id) }
        #expect(try await harness.service.worktree(record.id).state == .needsAttention)
        #expect(FileManager.default.fileExists(atPath: path + "/src/link"))
        try await harness.service.remove(record.id, force: true)
        #expect(try await harness.service.worktree(record.id).state == .removed)
    }

    @Test func testsRunInADisposableConfinedWorktree() async throws {
        let harness = try await ServiceHarness()
        let commit = try await harness.head()
        let pass = try await harness.service.runTests(
            TestProfile(executable: "/bin/sh", arguments: ["-c", "grep -q 'let a' src/a.swift && echo log > \"$TMPDIR/out\""]),
            projectID: harness.project, commit: commit
        )
        #expect(pass.outcome == .passed)
        let fail = try await harness.service.runTests(
            TestProfile(executable: "/bin/sh", arguments: ["-c", "echo x > src/a.swift"]), projectID: harness.project, commit: commit
        )
        #expect(fail.outcome == .failed(exitCode: 1)) // the worktree is read-only for this profile
        let worktrees = try await harness.store.worktrees()
        #expect(worktrees.count == 2)
        #expect(worktrees.allSatisfy { $0.kind == .qa && $0.state == .removed })
    }
}

/// Crash at each Git boundary, then restart and reconcile.
@Suite struct WorkspaceRecoveryTests {
    @Test func crashBeforeTheRefUpdateRepeatsIt() async throws {
        var harness = try await ServiceHarness()
        let commit = try await harness.head()
        let ref = "refs/kaiorx/integrations/\(harness.job.uuidString)"
        let operation = try await harness.store.prepareRefUpdate(projectID: harness.project, worktreeID: nil, ref: ref, expectedOld: nil, desiredNew: commit)
        try await harness.restart()

        let report = try await harness.service.reconcile()
        #expect(report.applied == [operation])
        #expect(try await harness.sh("git rev-parse \(ref)") == commit)
        #expect(try await harness.store.jobs().first?.integrationRef == ref)
        #expect(try await harness.service.reconcile().isEmpty)
    }

    @Test func crashAfterTheRefUpdateCompletesTheJournal() async throws {
        var harness = try await ServiceHarness()
        let record = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: try await harness.head())
        let path = harness.service.path(of: record)
        try await harness.sh("echo 'let a = 5' > src/a.swift", in: path)
        let outcome = try await harness.git.buildResult(of: try await harness.service.location(of: record), base: record.baseOID, allowedPrefixes: nil, message: "m")
        let commit = try #require(outcome.commit)
        let ref = "refs/kaiorx/results/\(record.id.uuidString)"
        let operation = try await harness.store.prepareRefUpdate(projectID: harness.project, worktreeID: record.id, ref: ref, expectedOld: nil, desiredNew: commit)
        try await harness.git.updateRef(ref, to: commit, expectedOld: nil, in: try await harness.git.inspect(harness.checkout))
        try await harness.restart()

        let report = try await harness.service.reconcile()
        #expect(report.applied == [operation])
        let recovered = try await harness.service.worktree(record.id)
        #expect(recovered.state == .frozen)
        #expect(recovered.resultOID == commit)
        #expect(recovered.savedTree == outcome.tree)
        // Exactly one published result.
        #expect(try await harness.sh("git for-each-ref --format='%(refname)' refs/kaiorx/results") == ref)
    }

    @Test func refMovedByOthersNeedsAttention() async throws {
        var harness = try await ServiceHarness()
        let base = try await harness.head()
        try await harness.sh("git commit -q --allow-empty -m other")
        let other = try await harness.head()
        let ref = "refs/kaiorx/integrations/\(harness.job.uuidString)"
        let operation = try await harness.store.prepareRefUpdate(projectID: harness.project, worktreeID: nil, ref: ref, expectedOld: nil, desiredNew: base)
        try await harness.sh("git update-ref \(ref) \(other)")
        try await harness.restart()
        #expect(try await harness.service.reconcile().needsAttention == [operation])
        #expect(try await harness.sh("git rev-parse \(ref)") == other)
        #expect(try await harness.store.jobs().first?.integrationRef == nil)
    }

    @Test func worktreeCreationIsResolvedEitherWay() async throws {
        var harness = try await ServiceHarness()
        let base = try await harness.head()
        let repository = try await harness.git.inspect(harness.checkout)
        // A: journaled, never created.  B: created by Git, journal not completed.
        let (lost, lostOperation) = try await harness.store.registerWorktree(WorktreeRegistration(
            projectID: harness.project, attemptID: nil, pathToken: "\(harness.project.uuidString)/lost", baseOID: base, kind: .author,
            ownerNonce: String(repeating: "a", count: 32)
        ))
        let (made, madeOperation) = try await harness.store.registerWorktree(WorktreeRegistration(
            projectID: harness.project, attemptID: nil, pathToken: "\(harness.project.uuidString)/made", baseOID: base, kind: .author,
            ownerNonce: String(repeating: "b", count: 32)
        ))
        try await harness.git.addWorktree(at: harness.layout.worktreePath(token: made.pathToken), base: base, lockReason: made.lockReason, in: repository)
        try await harness.restart()

        let report = try await harness.service.reconcile()
        #expect(Set(report.applied) == [madeOperation])
        #expect(report.failed == [lostOperation])
        #expect(try await harness.service.worktree(lost.id).state == .removed)
        #expect(try await harness.service.worktree(made.id).state == .ready)
    }

    @Test func missingAndOrphanedWorktreesAreReportedNotDeleted() async throws {
        var harness = try await ServiceHarness()
        let base = try await harness.head()
        let known = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: base)
        let repository = try await harness.git.inspect(harness.checkout)
        // Someone removed our worktree behind our back.
        try await harness.sh("git worktree unlock '\(harness.service.path(of: known))' && git worktree remove --force '\(harness.service.path(of: known))'")
        // A KAIORX-locked worktree the database does not know.
        let orphan = harness.layout.worktreePath(token: "\(harness.project.uuidString)/orphan")
        try await harness.git.addWorktree(at: orphan, base: base, lockReason: "kaiorx:unknown:\(String(repeating: "c", count: 32))", in: repository)
        try await harness.restart()

        let report = try await harness.service.reconcile()
        #expect(report.missingWorktrees == [known.id])
        #expect(report.orphanedWorktrees == [Confinement.resolved(orphan)])
        #expect(try await harness.service.worktree(known.id).state == .needsAttention)
        #expect(FileManager.default.fileExists(atPath: orphan))
    }

    @Test func secondOpenOperationOnTheSameRefIsRefused() async throws {
        let harness = try await ServiceHarness()
        let commit = try await harness.head()
        let ref = "refs/kaiorx/integrations/x"
        try await harness.store.prepareRefUpdate(projectID: harness.project, worktreeID: nil, ref: ref, expectedOld: nil, desiredNew: commit)
        await #expect(throws: StoreError.gitOperationOpen(ref)) {
            try await harness.store.prepareRefUpdate(projectID: harness.project, worktreeID: nil, ref: ref, expectedOld: nil, desiredNew: commit)
        }
    }
}

@Suite struct WorkspaceReviewFixTests {
    @Test func unrelatedHistoryOnAnotherBranchKeepsTheIdentity() async throws {
        let harness = try await ServiceHarness()
        let info = try await harness.service.attach(harness.project)
        try await harness.sh("git checkout -q --orphan pages && git rm -rqf . && echo p > p.txt && git add p.txt && git commit -q -m pages")
        let again = WorkspaceService(store: harness.store, git: harness.git, layout: harness.layout)
        #expect(try await again.attach(harness.project).headBranch == "pages")
        #expect(info.identity != nil)
    }

    @Test func sealStatusAndRejectionsArePersisted() async throws {
        var harness = try await ServiceHarness()
        let base = try await harness.head()
        let empty = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: base)
        #expect(try await harness.service.seal(empty.id, allowedPrefixes: nil, message: "m").status == .empty)

        let rejectedOnly = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: base)
        try await harness.sh("echo x > outside.txt", in: harness.service.path(of: rejectedOnly))
        #expect(try await harness.service.seal(rejectedOnly.id, allowedPrefixes: ["src"], message: "m").status == .rejectedOnly)

        let committed = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: base)
        try await harness.sh("echo 'let a = 9' > src/a.swift; ln -s /tmp src/link", in: harness.service.path(of: committed))
        #expect(try await harness.service.seal(committed.id, allowedPrefixes: nil, message: "m").status == .committed)

        try await harness.restart()
        let records = try await harness.store.worktrees()
        #expect(records.map(\.sealStatus) == [.empty, .rejectedOnly, .committed])
        #expect(records[1].rejectedPaths == ["outside.txt": "outsideAllowedPaths"])
        #expect(records[2].rejectedPaths == ["src/link": "symlink"])
        #expect(records[2].resultOID != nil)
    }

    @Test func failedSealLeavesTheWorktreeWritable() async throws {
        let harness = try await ServiceHarness()
        let attempt = try await harness.reserveAuthor()
        let record = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: attempt, kind: .author, base: try await harness.head())
        let path = harness.service.path(of: record)
        try await harness.sh("echo 'let a = 7' > src/a.swift", in: path)
        // Another open operation on the same result ref makes the seal fail after the build.
        try await harness.store.prepareRefUpdate(
            projectID: harness.project, worktreeID: nil, ref: "refs/kaiorx/results/\(attempt.uuidString)", expectedOld: nil,
            desiredNew: record.baseOID
        )
        await #expect(throws: StoreError.self) { _ = try await harness.service.seal(record.id, allowedPrefixes: nil, message: "m") }
        #expect(try await harness.service.worktree(record.id).state == .ready)
        try await harness.sh("echo more >> src/a.swift", in: path)
    }

    @Test func testRunsCannotReadTheDatabaseOutsideTheLayout() async throws {
        let harness = try await ServiceHarness()
        #expect(!harness.storePath.hasPrefix(harness.layout.root))
        let report = try await harness.service.runTests(
            TestProfile(executable: "/bin/cat", arguments: [harness.storePath]), projectID: harness.project, commit: try await harness.head()
        )
        #expect(report.outcome == .failed(exitCode: 1))
        #expect(report.process?.stderr.text.contains("not permitted") == true)
    }
}

@Suite struct RecoveryReviewFixTests {
    @Test func incompleteCheckoutIsNotReady() async throws {
        var harness = try await ServiceHarness()
        let base = try await harness.head()
        let (record, operation) = try await harness.store.registerWorktree(WorktreeRegistration(
            projectID: harness.project, attemptID: nil, pathToken: "\(harness.project.uuidString)/partial", baseOID: base,
            kind: .author, ownerNonce: String(repeating: "d", count: 32)
        ))
        // Git registered and locked the worktree, but no files were checked out.
        let path = harness.layout.worktreePath(token: record.pathToken)
        try FileManager.default.createDirectory(atPath: harness.layout.worktreesRoot + "/" + harness.project.uuidString, withIntermediateDirectories: true)
        try await harness.sh("git worktree add -q --no-checkout --detach --lock --reason '\(record.lockReason)' '\(path)' \(base)")
        try await harness.restart()
        #expect(try await harness.service.reconcile().needsAttention == [operation])
        #expect(try await harness.service.worktree(record.id).state == .needsAttention)
    }

    @Test func interruptedRemovalIsFinishedOnlyWhereItIsSafe() async throws {
        var harness = try await ServiceHarness()
        let base = try await harness.head()
        let unlocked = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: base)
        let forced = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .qa, base: base)
        let careful = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: base)
        let unlockedOperation = try await harness.store.prepareWorktreeRemoval(unlocked.id)
        let forcedOperation = try await harness.store.prepareWorktreeRemoval(forced.id, force: true)
        let carefulOperation = try await harness.store.prepareWorktreeRemoval(careful.id)
        let unlockedPath = harness.service.path(of: unlocked)
        // A: an older version unlocked, then crashed.
        try await harness.sh("git worktree unlock '\(unlockedPath)'")
        // B, C: Git forgot the worktree, the folder (with test output / with work) stayed.
        for record in [forced, careful] {
            let path = harness.service.path(of: record)
            try await harness.sh("echo out > '\(path)/output.txt' && cp -R '\(path)' '\(path).keep' && git worktree remove -f -f '\(path)' && mv '\(path).keep' '\(path)'")
        }
        try await harness.restart()

        let report = try await harness.service.reconcile()
        #expect(Set(report.applied) == [unlockedOperation, forcedOperation])
        #expect(report.needsAttention == [carefulOperation])
        #expect(!FileManager.default.fileExists(atPath: unlockedPath))
        #expect(!FileManager.default.fileExists(atPath: harness.service.path(of: forced)))
        // Unforced and not comparable: the folder and its work stay.
        #expect(FileManager.default.fileExists(atPath: harness.service.path(of: careful) + "/output.txt"))
        #expect(try await harness.service.worktree(careful.id).state == .needsAttention)
    }

    @Test func deletedFolderOfALockedWorktreeIsMissing() async throws {
        var harness = try await ServiceHarness()
        let record = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: try await harness.head())
        try FileManager.default.removeItem(atPath: harness.service.path(of: record))
        try await harness.restart()
        #expect(try await harness.service.reconcile().missingWorktrees == [record.id])
    }

    @Test func oneBrokenProjectDoesNotBlockTheOthers() async throws {
        var harness = try await ServiceHarness()
        let commit = try await harness.head()
        let broken = ProjectID()
        try await harness.store.execute(Command(.openProject(id: broken, name: "Weg", rootLocator: harness.checkout + "-gone")))
        let stuck = try await harness.store.prepareRefUpdate(projectID: broken, worktreeID: nil, ref: "refs/kaiorx/integrations/x", expectedOld: nil, desiredNew: commit)
        let fine = try await harness.store.prepareRefUpdate(projectID: harness.project, worktreeID: nil, ref: "refs/kaiorx/integrations/y", expectedOld: nil, desiredNew: commit)
        try await harness.restart()
        let report = try await harness.service.reconcile()
        #expect(report.applied == [fine])
        #expect(report.skipped.keys.contains(stuck))
        #expect(try await harness.store.gitOperations(state: .prepared).map(\.id) == [stuck])
    }
}

@Suite struct SecondReviewFixTests {
    @Test func sealingTwiceIsRefused() async throws {
        let harness = try await ServiceHarness()
        let record = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: try await harness.head())
        try await harness.sh("echo 'let a = 8' > src/a.swift", in: harness.service.path(of: record))
        _ = try await harness.service.seal(record.id, allowedPrefixes: nil, message: "m")
        try await harness.store.transitionWorktree(record.id, to: .needsAttention)
        try await harness.store.transitionWorktree(record.id, to: .ready)
        await #expect(throws: WorkspaceServiceError.alreadySealed(record.id)) {
            _ = try await harness.service.seal(record.id, allowedPrefixes: nil, message: "m")
        }
    }

    @Test func worktreeOnlyFiltersFromIncludeIfBlockTheCheckout() async throws {
        let harness = try await ServiceHarness()
        try await harness.sh("""
            printf '[filter "x"]\\n\\tclean = touch PWNED && cat\\n' > .git/wt.cfg
            git config 'includeIf.gitdir:**/worktrees/**.path' wt.cfg
            """)
        await #expect(throws: WorkspaceError.blocked([.configuredFilter(name: "x")])) {
            _ = try await harness.service.prepareWorktree(projectID: harness.project, attemptID: nil, kind: .author, base: try await harness.head())
        }
        let repository = try await harness.git.inspect(harness.checkout)
        #expect(try await harness.git.registeredWorktrees(in: repository).count == 1)
        #expect(try await harness.store.worktrees().map(\.state) == [.removed])
    }

    @Test func pendingMigrationBackupsAreHiddenFromTests() async throws {
        var harness = try await ServiceHarness()
        let backup = harness.storePath + ".backup-v1-123"
        FileManager.default.createFile(atPath: backup, contents: Data("SQLite format 3".utf8))
        try await harness.restart()
        let report = try await harness.service.runTests(
            TestProfile(executable: "/bin/cat", arguments: [backup]), projectID: harness.project, commit: try await harness.head()
        )
        #expect(report.outcome == .failed(exitCode: 1))
    }
}
