import Domain
import Foundation
import ProcessHost
import Providers
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workbench
@testable import Workspace

/// A temporary folder that disappears with the test process.
func temporaryFolder(_ name: String) throws -> String {
    let path = FileManager.default.temporaryDirectory.appending(path: "kaiorx-wb-\(name)-\(UUID().uuidString)").path(percentEncoded: false)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false)
}

/// Runs a shell script through ProcessHost (tests follow the same rule as the app).
@discardableResult
func sh(_ script: String, in directory: String) async throws -> String {
    let result = try await ProcessHost().run(LaunchSpec(
        executable: "/bin/sh", arguments: ["-c", script], workingDirectory: directory,
        environment: [
            "PATH": "/usr/bin:/bin", "HOME": directory, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "U", "GIT_AUTHOR_EMAIL": "u@e", "GIT_COMMITTER_NAME": "U", "GIT_COMMITTER_EMAIL": "u@e",
        ],
        timeout: .seconds(30)
    ))
    guard result.termination == .exited(0) else { throw GitError.failed(arguments: [script], termination: result.termination, stderr: result.stderr.text) }
    return result.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
}

@Suite struct LabelTests {
    @Test func everyStateHasTextAndSymbol() {
        let labels = TaskState.allCases.map(Labels.task) + AttemptState.allCases.map(Labels.attempt) + CandidateState.allCases.map(Labels.candidate)
            + JobState.allCases.map(Labels.job) + WorktreeState.allCases.map(Labels.worktree)
        #expect(labels.allSatisfy { !$0.text.isEmpty && !$0.symbol.isEmpty })
        let kinds: [WaitReason.Kind] = [.slot, .writeArea, .consent, .quota, .budget, .profileMissing, .noIndependentReviewer, .predecessorEnded,
                                        .predecessorReverted, .awaitingUserStart, .userDecision, .retryLater, .capability]
        #expect(Set(kinds.map { Labels.wait(WaitReason($0)).text }).count == kinds.count)
        #expect(Labels.wait(stored: "userDecision:attemptLimit")?.text == "Wartet auf deine Entscheidung")
        #expect(Labels.duration(3_725_000) == "1 h 02 min" && Labels.duration(75_000) == "1 min 15 s" && Labels.duration(4_000) == "4 s")
    }
}

@Suite struct ProjectionTests {
    func store() throws -> Store { try Store(path: try temporaryFolder("proj") + "/db.sqlite", clock: { 1_000 }) }

    @Test func eventsReReadTheRowsTheyName() async throws {
        let store = try store()
        let project = ProjectID(), job = JobID(), task = TaskID()
        try await store.execute(Command(.openProject(id: project, name: "P", rootLocator: "/tmp")))
        let projector = Projector(store: store, pageSize: 2)
        var state = try await projector.load()
        #expect(state.projects.count == 1 && state.tasks.isEmpty)
        try await store.execute(Command(.createJob(id: job, projectID: project, goal: "Ziel")))
        try await store.execute(Command(.createTask(id: task, jobID: job, title: "Aufgabe")))
        try await store.execute(Command(.transitionTask(id: task, to: .ready, expectedVersion: 1)))
        let delta = try #require(try await projector.step())
        state = delta.state
        #expect(state.tasks[task]?.state == .ready && state.jobs[job] != nil)
        #expect(try await projector.step() == nil)
        // A fresh projector replaying from zero ends in the same state.
        let replay = Projector(store: store)
        _ = try await replay.load()
        #expect(try await replay.load().tasks == state.tasks)
    }

    @Test func coalescingPublishesAtMostPerIntervalAndCriticalAtOnce() {
        var c = Coalescer(interval: 100)
        let results = [
            c.change(at: 0, critical: false, visible: true), c.change(at: 50, critical: false, visible: true),
            c.change(at: 60, critical: true, visible: true), c.change(at: 70, critical: false, visible: false),
        ]
        #expect(results == [true, false, true, false])
        #expect(c.dirty)
        let early = c.tick(at: 100, visible: true)
        let late = c.tick(at: 160, visible: true)
        #expect(!early && late)
        #expect(!c.dirty)
    }
}

@Suite struct TimelineTests {
    func event(_ ordinal: Int, _ agent: AgentEvent?, purged: Bool = false) -> EventRecord {
        EventRecord(
            seq: Int64(ordinal), eventID: EventID(), schemaVersion: 1, projectID: ProjectID(), taskID: nil, attemptID: AttemptID(), ordinal: ordinal,
            kind: agent?.kind ?? .attemptStateChanged, at: Int64(ordinal), payloadID: nil, payload: agent.flatMap { try? JSONEncoder().encode($0) },
            dedupKey: nil, payloadPurgedAt: purged ? 1 : nil
        )
    }

    @Test func deltasMergeRowsAreBoundedAndGapsAndPurgesShow() {
        var timeline = Timeline(maxRows: 4, maxItemBytes: 10)
        timeline.append([event(1, .started(sessionID: "s")), event(2, .messageDelta(itemID: "m", text: "Hallo ")), event(3, .messageDelta(itemID: "m", text: "Welt und mehr"))])
        #expect(timeline.rows.map(\.kind) == [.started, .message])
        #expect(timeline.rows[1].text == "Hallo Welt" && timeline.rows[1].truncated)
        timeline.append([event(5, .toolStarted(itemID: "t", toolClass: "read")), event(6, nil, purged: true), event(7, .completed(.succeeded))])
        #expect(timeline.rows.count == 4 && timeline.droppedRows == 2)
        #expect(timeline.rows.map(\.kind) == [.gap, .tool, .purged, .completed])
        #expect(timeline.rows[0].text.contains("1 Ereignisse fehlen"))
        // Old pages are ignored.
        timeline.append([event(2, .messageDelta(itemID: "x", text: "alt"))])
        #expect(timeline.rows.count == 4 && timeline.lastOrdinal == 7)
    }

    @Test func copiedLogTextIsRedacted() {
        let text = "Token sk-ant-abcdefghijklmnopqrstuvwxyz0123 und weiter"
        let redacted = LogRedactor.redact(text)
        #expect(!redacted.contains("sk-ant-abc") && redacted.contains("[entfernt: anthropicKey]") && redacted.hasSuffix("und weiter"))
    }
}

@Suite struct EditorTests {
    @Test func onlyTheCheckoutIsWritableAndEveryOtherStateSaysWhy() {
        let project = ProjectID()
        #expect(EditorFiles.access(.checkout(project: project, path: "a.txt")) == .writable)
        #expect(EditorFiles.access(.commit(project: project, oid: "abc", path: "a.txt")) == .readOnly(.commit))
        #expect(EditorFiles.access(.worktree(WorktreeID(), path: "a"), attemptActive: true) == .readOnly(.activeAttempt))
        #expect(EditorFiles.access(.worktree(WorktreeID(), path: "a")) == .readOnly(.worktree))
        #expect(ReadOnlyReason.frozen.text.contains("Eingefroren"))
    }

    @Test func saveChecksTheFingerprintAndWritesAtomically() throws {
        let root = try temporaryFolder("editor")
        let file = root + "/notes.txt"
        try Data("eins\n".utf8).write(to: URL(filePath: file))
        chmod(file, 0o640)
        var document = try EditorDocument.open(.checkout(project: ProjectID(), path: "notes.txt"), root: root)
        #expect(document.access == .writable && document.text == "eins\n" && !document.isDirty)
        document.text = "zwei\n"
        guard case .saved = try document.save() else { Issue.record("not saved"); return }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "zwei\n" && !document.isDirty)
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        // Someone else changes the file: the save is refused and the disk text offered.
        try Data("fremd\n".utf8).write(to: URL(filePath: file))
        document.text = "drei\n"
        guard case .externalChange(let disk, let fingerprint) = try document.save() else { Issue.record("no conflict"); return }
        #expect(disk == "fremd\n" && fingerprint != nil)
        #expect(document.conflictDiff.contains { $0.kind == .removed && $0.text == "fremd" })
        // Keeping one's own text overwrites exactly that disk version; a newer one blocks again.
        try Data("noch neuer\n".utf8).write(to: URL(filePath: file))
        document.keepMine()
        guard case .externalChange = try document.save() else { Issue.record("overwrote an unseen version"); return }
        document.keepMine()
        guard case .saved = try document.save() else { Issue.record("not saved after keeping"); return }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "drei\n")
        try Data("fremd\n".utf8).write(to: URL(filePath: file))
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "fremd\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root).allSatisfy { !$0.hasPrefix(".kaiorx-save-") })
    }

    @Test func protectedPathsSymlinksAndEscapesAreRefused() throws {
        let root = try temporaryFolder("editor-guard")
        let outside = try temporaryFolder("outside")
        try FileManager.default.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/link.txt", withDestinationPath: outside + "/x.txt")
        try FileManager.default.createSymbolicLink(atPath: root + "/dir", withDestinationPath: outside)
        try Data([0, 1, 2]).write(to: URL(filePath: root + "/bin.dat"))
        #expect(EditorFiles.resolve(root: root, path: ".git/config") == .failure(.protectedPath))
        #expect(EditorFiles.resolve(root: root, path: "../x") == .failure(.outsideRoot))
        #expect(EditorFiles.resolve(root: root, path: "dir/x.txt") == .failure(.notRegularFile))
        do {
            let outcome = try EditorFiles.save(root: root, path: "link.txt", text: "x", expected: nil)
            #expect(outcome == .refused(.outsideRoot) || outcome == .refused(.notRegularFile), "\(outcome)")
        } catch { Issue.record("threw \(error)") }
        #expect(try EditorFiles.open(root: root, path: "bin.dat").access == .readOnly(.binary))
        #expect(!FileManager.default.fileExists(atPath: outside + "/x.txt"))
    }
}

@Suite struct DiffTests {
    @Test func fileChangesKnowRenamesBinariesSymlinksAndOddPaths() async throws {
        let repo = try temporaryFolder("diff")
        try await sh("git init -q -b main && printf 'a\\nb\\nc\\nd\\ne\\n' > alt.txt && printf 'x' > 'mit leer.txt' && git add -A && git commit -qm one", in: repo)
        let base = try await sh("git rev-parse HEAD", in: repo)
        try await sh("""
            git mv alt.txt neu.txt && printf '\\000\\001' > bild.bin && ln -s neu.txt verweis && printf 'y\\n' >> 'mit leer.txt' \
            && printf 'ü' > 'grüße.txt' && git add -A && git commit -qm two
            """, in: repo)
        let head = try await sh("git rev-parse HEAD", in: repo)
        let git = try GitRunner(host: ProcessHost(), home: try temporaryFolder("home"))
        let info = try await git.inspect(repo)
        let files = try await git.fileChanges(from: base, to: head, in: info)
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        #expect(byPath["neu.txt"]?.status == .renamed && byPath["neu.txt"]?.oldPath == "alt.txt")
        #expect(byPath["bild.bin"]?.isBinary == true && byPath["bild.bin"]?.status == .added)
        #expect(byPath["verweis"]?.isSymlink == true)
        #expect(byPath["mit leer.txt"]?.added == 1)
        #expect(byPath["grüße.txt"]?.status == .added)
        #expect(DiffFileRow(byPath["neu.txt"]!).displayPath == "alt.txt → neu.txt")
        let diff = try await git.fileDiff(from: base, to: head, file: byPath["mit leer.txt"]!, in: info)
        #expect(!diff.truncated && DiffParser.parse(diff.text).contains { $0.kind == .added && $0.text == "xy" })
        let cut = try await git.fileDiff(from: base, to: head, file: byPath["mit leer.txt"]!, in: info, byteLimit: 40)
        #expect(cut.truncated && cut.text.utf8.count <= 40)
    }

    @Test func parsedLinesCarryNumbersSymbolsAndEscapes() {
        let text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -3,2 +3,3 @@\n x\n-y\n+z\u{202E}evil\n+w\n\\ No newline at end of file\n"
        let lines = DiffParser.parse(text)
        let added = lines.filter { $0.kind == .added }
        #expect(added.map(\.newLine) == [4, 5])
        #expect(added[0].text == "z\\u{202E}evil" && added[0].symbol == "plus")
        #expect(lines.first { $0.kind == .removed }?.oldLine == 4)
        #expect(lines.first { $0.kind == .context }?.accessibilityLabel == "Unverändert, Zeile 3: x")
        #expect(lines.contains { $0.kind == .noNewline })
    }
}

@Suite struct TerminalSessionTests {
    @Test func theShellEnvironmentKeepsProviderDataAndAgentSocketsOut() async throws {
        let host = [
            "HOME": "/Users/u", "USER": "u", "LANG": "de_DE.UTF-8", "CLAUDE_CONFIG_DIR": "/secret/claude", "CODEX_HOME": "/secret/codex",
            "SSH_AUTH_SOCK": "/tmp/agent", "OPENAI_API_KEY": "sk-x", "ANTHROPIC_API_KEY": "sk-ant-x", "KAIORX_MARKER": "markerwort",
        ]
        let env = TerminalSessions.environment(host: host, shell: "/bin/zsh")
        for name in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "SSH_AUTH_SOCK", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "KAIORX_MARKER"] { #expect(env[name] == nil) }
        #expect(env["HOME"] == "/Users/u" && env["SHELL"] == "/bin/zsh" && env["TERM"] == "xterm-256color")
        // The marker is not visible in the shell nor in a grandchild.
        let folder = try temporaryFolder("term")
        var spec = TerminalSessions.spec(folder: folder, rows: 24, columns: 80, host: host)
        spec.executable = "/bin/sh"
        spec.arguments = ["-c", "/bin/sh -c 'env' ; echo END"]
        let terminal = try await ProcessHost().launchTerminal(spec)
        var text = ""
        while !text.contains("END"), let chunk = await terminal.read() { text += String(decoding: chunk, as: UTF8.self) }
        #expect(!text.contains("markerwort") && !text.contains("/secret/") && !text.contains("SSH_AUTH_SOCK"))
        #expect(text.contains("TERM_PROGRAM=KAIORX"))
    }

    @Test func onlyWebLinksBecomeRequests() {
        #expect(TerminalRequest.link("https://example.org/x") != nil)
        #expect(TerminalRequest.link("file:///etc/passwd") == nil)
        #expect(TerminalRequest.link("javascript:alert(1)") == nil)
        #expect(TerminalSessions.shell().hasPrefix("/"))
    }
}

@Suite struct OfflineTests {
    /// No network code in the app's own targets (offline start, ARCHITEKTURPLAN §4).
    @Test func noNetworkAPIsAreUsed() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources")
        let enumerator = FileManager.default.enumerator(atPath: sources.path(percentEncoded: false))
        var offenders: [String] = []
        while let file = enumerator?.nextObject() as? String {
            guard file.hasSuffix(".swift") else { continue }
            let text = try String(contentsOf: sources.appending(path: file), encoding: .utf8)
            if text.contains("URLSession") || text.contains("import Network") || text.contains("NWConnection") { offenders.append(file) }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}

@Suite struct RestoreTests {
    /// A database at version `v` of this build, with a project, closed again.
    func database(_ folder: String, version: Int? = nil, clock: Int64 = 10) async throws -> String {
        let path = folder + "/db.sqlite"
        let migrations = version.map { Array(CoreSchema.migrations.prefix($0)) } ?? CoreSchema.migrations
        let store = try Store(path: path, migrations: migrations, clock: { clock })
        try await store.execute(Command(.openProject(id: ProjectID(), name: "P", rootLocator: folder)))
        await store.close()
        return path
    }

    @Test func anUpgradeBackupRestoresAndConsentsAreRevoked() async throws {
        let folder = try temporaryFolder("restore")
        let path = try await database(folder, version: 7, clock: 10)
        // Opening with this build upgrades and takes the backup v7.
        let store = try Store(path: path, clock: { 20 })
        let project = try #require(try await store.projects().first)
        try await store.execute(Command(.openProject(id: ProjectID(), name: "Später", rootLocator: folder + "/b")))
        await store.close()
        let backup = try #require(BackupRestore.backups(of: path).first)
        #expect(backup.version == 7 && backup.time == 20)
        #expect(try BackupRestore.validate(backup, database: path) == 7)
        let report = try BackupRestore.restore(backup, database: path, now: 30)
        #expect(report.previousBackup?.hasSuffix(".backup-v8-30") == true)
        let reopened = try Store(path: path, clock: { 40 })
        #expect(try await reopened.projects().map(\.id) == [project.id])
        await reopened.close()
    }

    @Test func backupsOlderThanAForgetAreRefused() async throws {
        let folder = try temporaryFolder("restore-ledger")
        let path = try await database(folder, version: 7, clock: 10)
        let store = try Store(path: path, clock: { 20 })
        let project = try #require(try await store.projects().first)
        let note = try await store.addMemory(MemoryDraft(scope: .project, projectID: project.id, title: "t", body: "geheim", sources: [.user(at: 1)]))
        // Keep the backup on disk for this test: forget without running the purge job.
        _ = try await store.forgetMemory([note.entryID])
        await store.close()
        #expect(PurgeLedger.newest(database: path) == 20)
        let backup = try #require(BackupRestore.backups(of: path).first)
        #expect(throws: RestoreError.predatesForget(backupTime: 20, forgetTime: 20)) { try BackupRestore.validate(backup, database: path) }
        #expect(throws: RestoreError.self) { try BackupRestore.restore(backup, database: path, now: 30) }
    }

    @Test func foreignNewerOrInUseDatabasesAreRefused() async throws {
        let folder = try temporaryFolder("restore-guard")
        let path = try await database(folder)
        // A file named like a backup that is not a SQLite database of this schema.
        FileManager.default.createFile(atPath: path + ".backup-v3-99", contents: Data("kein sqlite".utf8))
        let fake = try #require(BackupRestore.backups(of: path).first)
        #expect(throws: (any Error).self) { try BackupRestore.validate(fake, database: path) }
        let open = try Store(path: path, clock: { 50 })
        let other = try await database(try temporaryFolder("restore-other"), version: 6)
        _ = other
        #expect(throws: RestoreError.self) { try BackupRestore.restore(fake, database: path, now: 60) }
        await open.close()
    }

    @Test func bootstrapShowsRecoveryForANewerDatabaseAndRunsAStagedRestore() async throws {
        let folder = try temporaryFolder("boot")
        let path = try await database(folder, version: 7, clock: 10)
        let configuration = AppConfiguration(databasePath: path, workspaceRoot: folder + "/ws", adapters: { _ in [FakeAdapter()] }, clock: { 20 })
        guard case .ready(let services) = await AppBootstrap.start(configuration) else { Issue.record("not ready"); return }
        #expect(!services.degraded && services.scheduler != nil)
        let account = try await services.store.registerAccount(provider: .fake, identity: "u")
        let consent = try await services.store.grantConsent(ConsentDraft(
            projectID: try #require(try await services.store.projects().first).id, provider: .fake, accountID: account, mode: .automatic,
            roles: [.author], writeRoots: []
        ))
        await AppBootstrap.shutdown(services)
        let backup = try #require(BackupRestore.backups(of: path).first)
        try AppBootstrap.stageRestore(backup, database: path)
        let outcome = await AppBootstrap.start(configuration)
        guard case .ready(let restored) = outcome else { Issue.record("restore failed: \(outcome)"); return }
        #expect(restored.restored?.restored == backup)
        #expect(!FileManager.default.fileExists(atPath: AppBootstrap.pendingRestorePath(for: path)))
        #expect(try await restored.store.consents(project: try #require(try await restored.store.projects().first).id).allSatisfy { $0.revokedAt != nil })
        _ = consent
        await AppBootstrap.shutdown(restored)
        // A database from a newer build opens the recovery screen, not a crash.
        let newer = try Store(path: path, migrations: CoreSchema.migrations + [Migration(version: CoreSchema.migrations.count + 1, name: "zukunft", sql: "CREATE TABLE zukunft (x INTEGER) STRICT;")], clock: { 30 })
        await newer.close()
        guard case .recovery(.databaseNewerThanApp, _) = await AppBootstrap.start(configuration) else { Issue.record("no recovery"); return }
    }
}

struct FakeGate: CapabilityGate {
    func allowsAutomatic(_ provider: ProviderKind) async -> Bool { true }
    func accessRestored(_ provider: ProviderKind, account: AccountID) async -> Bool { true }
}

@Suite struct ActionFlowTests {
    /// The app's main path without UI: open a repository, create a job, see the consent wait,
    /// consent, and the scheduler starts the author.
    @Test func aNewJobWaitsForConsentThenRuns() async throws {
        let folder = try temporaryFolder("flow")
        let repo = folder + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try await sh("git init -q -b main && echo a > README.md && git add -A && git commit -qm start", in: repo)
        let configuration = AppConfiguration(
            databasePath: folder + "/db.sqlite", workspaceRoot: folder + "/ws",
            adapters: { _ in [FakeAdapter(provider: .fake), FakeAdapter(provider: .codex)] }, gate: FakeGate()
        )
        guard case .ready(let services) = await AppBootstrap.start(configuration) else { Issue.record("not ready"); return }
        for tier in CapabilityTier.allCases {
            try await services.store.registerModelProfile(ModelProfile(provider: .fake, role: .author, tier: tier, model: "f-\(tier.rawValue)", typicalTokens: 1_000, verifiedAt: 1))
        }
        try await services.store.registerModelProfile(ModelProfile(provider: .codex, role: .reviewer, tier: .fast, model: "r", typicalTokens: 500, verifiedAt: 1))
        let actions = WorkbenchActions(services: services)
        let project = try await actions.openProject(at: repo)
        let job = try await actions.createJob(
            project: project, goal: "Ziel", tasks: [PlanTaskDraft(key: "t1", title: "Aufgabe", criteria: ["fertig"])], budget: ([.fake, .codex], 200_000)
        )
        _ = try await services.scheduler!.tick()
        let task = try #require(try await services.store.tasks(jobID: job).first)
        #expect(task.waitReason.flatMap(WaitReason.init(stored:))?.kind == .consent)
        let pending = try await PendingDecisions.collect(try await Projector(store: services.store).load(), project: project, gate: { _ in [] }, openFindings: { _ in false })
        #expect(pending.contains { if case .task(_, let reason) = $0 { reason.kind == .consent } else { false } })
        let sheet = DecisionSheet.consent([.fake, .codex].map { WorkbenchActions.consentDraft(project: project, provider: $0) })
        #expect(sheet.scope.contains { $0.hasPrefix("Testanbieter") } && sheet.scope.contains { $0.hasPrefix("Codex") })
        for provider in [ProviderKind.fake, .codex] { try await actions.grantConsent(project: project, provider: provider) }
        let after = try await services.scheduler!.tick()
        #expect(after.reserved.count == 1, "\(after)")
        await AppBootstrap.shutdown(services)
    }
}

@Suite struct CheckRoundTests {
    @Test func crlfLinesSeparatorsAndC1AreVisible() {
        let lines = DiffParser.parse("@@ -1,2 +1,2 @@\n-old\r\n+evil\r\n ctx\r\n")
        #expect(lines.filter { $0.kind == .added }.map(\.text) == ["evil\\u{0D}"])
        #expect(lines.filter { $0.kind == .removed }.count == 1 && lines.filter { $0.kind == .context }.count == 1)
        #expect(DiffParser.escape("a\u{2028}b\u{0085}c") == "a\\u{2028}b\\u{85}c")
    }

    @Test func redactionCoversValuesQuotesAndWholeKeys() {
        let text = "password: hunter2hunter2 und API_KEY=\"abcd1234efgh\" sonst\n-----BEGIN RSA PRIVATE KEY-----\nMIIEgeheim\n-----END RSA PRIVATE KEY-----\nEnde"
        let redacted = LogRedactor.redact(text)
        #expect(!redacted.contains("hunter2") && !redacted.contains("abcd1234") && !redacted.contains("MIIEgeheim"))
        #expect(redacted.contains("sonst") && redacted.hasSuffix("Ende"))
    }

    @Test func attemptsFirstSeenFailedAreAnnounced() {
        var old = WorkspaceState()
        old.cursor = 5
        var new = old
        let task = TaskRecord(id: TaskID(), jobID: JobID(), title: "Doku", state: .ready, currentAttemptID: nil, version: 1, createdAt: 1)
        new.tasks[task.id] = task
        let attempt = AttemptRecord(
            id: AttemptID(), taskID: task.id, role: .author, ordinal: 1, provider: .fake, mode: .automatic, model: "m", effort: nil,
            state: .failed, specDigest: "d", sessionHandle: nil, reservedAt: 1, startedAt: nil, endedAt: 2, errorClass: nil, version: 1
        )
        new.attempts[attempt.id] = attempt
        #expect(Announcements.changes(from: old, to: new) == ["Doku: Fehlgeschlagen"])
    }

    @Test func loginCommandsUseKAIORXsOwnFolders() {
        #expect(Onboarding.loginCommand(.codex, configDirectory: "/A B/codex-home") == "CODEX_HOME='/A B/codex-home' codex login")
        #expect(Onboarding.loginCommand(.claude, configDirectory: "/x/claude-config") == "CLAUDE_CONFIG_DIR='/x/claude-config' claude")
        let items = Onboarding.checklist(ProbeResults(gitPath: "/usr/bin/git"))
        #expect(items.contains { $0.id == "git" && $0.status == .ok })
        let sheet = DecisionSheet.moreAttempts(TaskRecord(id: TaskID(), jobID: JobID(), title: "T", state: .ready, currentAttemptID: nil, version: 1, createdAt: 1), reason: WaitReason(.userDecision, "attemptLimit"))
        #expect(sheet.scope.first == "Grund des Halts: Versuchsgrenze erreicht")
    }

    @Test func aFolderThatIsNoRepositoryLeavesNoProject() async throws {
        let folder = try temporaryFolder("norepo")
        let configuration = AppConfiguration(databasePath: folder + "/db.sqlite", workspaceRoot: folder + "/ws", adapters: { _ in [] })
        guard case .ready(let services) = await AppBootstrap.start(configuration) else { Issue.record("not ready"); return }
        let plain = folder + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        await #expect(throws: ActionError.self) { try await WorkbenchActions(services: services).openProject(at: plain) }
        #expect(try await services.store.projects().isEmpty)
        await AppBootstrap.shutdown(services)
    }
}

@Suite struct RestoreCheckTests {
    func database(_ folder: String, version: Int, clock: Int64) async throws -> String {
        let path = folder + "/db.sqlite"
        let store = try Store(path: path, migrations: Array(CoreSchema.migrations.prefix(version)), clock: { clock })
        try await store.execute(Command(.openProject(id: ProjectID(), name: "P", rootLocator: folder)))
        await store.close()
        return path
    }

    @Test func aForgetTheLedgerMissedStillBlocksOlderBackups() async throws {
        let folder = try temporaryFolder("ledger-missing")
        let path = try await database(folder, version: 7, clock: 10)
        let store = try Store(path: path, clock: { 20 })
        let project = try #require(try await store.projects().first)
        let note = try await store.addMemory(MemoryDraft(scope: .project, projectID: project.id, title: "t", body: "geheim", sources: [.user(at: 1)]))
        _ = try await store.forgetMemory([note.entryID])
        await store.close()
        try FileManager.default.removeItem(atPath: PurgeLedger.path(for: path))
        let backup = try #require(BackupRestore.backups(of: path).first)
        #expect(throws: RestoreError.predatesForget(backupTime: 20, forgetTime: 20)) { try BackupRestore.restore(backup, database: path, now: 30) }
    }

    @Test func aDamagedDatabaseIsKeptAndReplaced() async throws {
        let folder = try temporaryFolder("damaged")
        let path = try await database(folder, version: 7, clock: 10)
        let store = try Store(path: path, clock: { 20 })
        await store.close()
        let backup = try #require(BackupRestore.backups(of: path).first)
        try Data("kaputt".utf8).write(to: URL(filePath: path))
        let report = try BackupRestore.restore(backup, database: path, now: 30)
        #expect(report.previousBackup?.contains(".damaged-") == true)
        #expect(FileManager.default.contents(atPath: report.previousBackup!) == Data("kaputt".utf8))
        let reopened = try Store(path: path, clock: { 40 })
        #expect(try await reopened.projects().count == 1)
        await reopened.close()
    }

    @Test func consentsAreRevokedEvenIfTheFirstStartAfterTheRestoreFails() async throws {
        let folder = try temporaryFolder("marker")
        let path = try await database(folder, version: 7, clock: 10)
        let store = try Store(path: path, clock: { 20 })
        let project = try #require(try await store.projects().first)
        let account = try await store.registerAccount(provider: .fake, identity: "u")
        _ = try await store.grantConsent(ConsentDraft(projectID: project.id, provider: .fake, accountID: account, writeRoots: [""]))
        await store.close()
        // The consent is in a backup taken now (v8 → v8 has no upgrade backup: take one by hand).
        let backupPath = path + ".backup-v8-25"
        let source = try SQLiteConnection(path: path)
        try source.backup(to: backupPath)
        source.close()
        let backup = try #require(BackupRestore.backups(of: path).first { $0.path == backupPath })
        _ = try BackupRestore.restore(backup, database: path, now: 30)
        // The app dies before opening the store: the marker survives, the next start revokes.
        #expect(FileManager.default.fileExists(atPath: BackupRestore.consentMarker(for: path)))
        let configuration = AppConfiguration(databasePath: path, workspaceRoot: folder + "/ws", adapters: { _ in [] }, clock: { 40 })
        guard case .ready(let services) = await AppBootstrap.start(configuration) else { Issue.record("not ready"); return }
        #expect(try await services.store.consents(project: project.id).allSatisfy { $0.revokedAt != nil })
        #expect(!FileManager.default.fileExists(atPath: BackupRestore.consentMarker(for: path)))
        await AppBootstrap.shutdown(services)
    }
}

/// The app's real adapters get the product confinement (ADR 0002, ADR 0008 point 6): the same
/// `agentCLI` profile the owner's acceptance measures, home hidden, state folder writable.
@Suite struct ProviderAdapterConfinementTests {
    func spec(_ provider: ProviderKind, role: AttemptRole, worktree: String?) -> AttemptSpec {
        AttemptSpec(
            attemptID: AttemptID(), taskID: TaskID(), projectID: ProjectID(), role: role, provider: provider, runMode: .automatic,
            modelProfile: "m", effectiveModel: "m", workingDirectory: worktree, prompt: "p"
        )
    }

    @Test func bothRealAdaptersAreConfinedWithTheHomeFolderHidden() throws {
        let support = try temporaryFolder("support")
        let home = try temporaryFolder("home")
        let bin = try temporaryFolder("bin")
        let adapters = ProviderAdapters.make(host: ProcessHost(), support: support, home: home + "/") { provider in bin + "/" + provider.rawValue }
        let worktree = AppConfiguration.workspaceRoot(support: support) + "/worktrees/w1"
        let temporary = support + "/tmp/run-1"
        #expect(adapters.count == 2)
        for adapter in adapters {
            let parts: (@Sendable (AttemptSpec, String) -> Confinement?, String, AdapterPolicy)? = switch adapter {
            case let claude as ClaudeCodeAdapter: (claude.configuration.confinement, claude.configuration.configDirectory, claude.configuration.policy)
            case let codex as CodexAppServerAdapter: (codex.configuration.confinement, codex.configuration.codexHome, codex.configuration.policy)
            default: nil
            }
            let (configure, state, policy) = try #require(parts)
            #expect(policy.requiresConfinement)
            let provider = adapter.provider
            let author = try #require(configure(spec(provider, role: .author, worktree: worktree), temporary))
            let resolvedHome = Confinement.resolved(home)
            #expect(author.hiddenRoots.map(Confinement.resolved).contains(resolvedHome))
            #expect(author.hiddenRoots.map(Confinement.resolved).contains(Confinement.resolved(AppConfiguration.workspaceRoot(support: support))))
            #expect(Set(author.writableRoots) == [worktree, temporary, state])
            #expect(author.allowsNetwork)
            #expect(author.visibleRoots.map(Confinement.resolved).contains(resolvedHome + "/Library/Keychains") == (provider == .claude))
            #expect(!author.visibleRoots.contains { resolvedHome.hasPrefix(Confinement.resolved($0)) })
            let reviewer = try #require(configure(spec(provider, role: .reviewer, worktree: worktree), temporary))
            #expect(!reviewer.writableRoots.contains(worktree))
            // No worktree: no confinement, so the adapter refuses to start (fail closed).
            #expect(configure(spec(provider, role: .reviewer, worktree: nil), temporary) == nil)
        }
    }

    @Test func aMissingCLIGetsNoAdapter() throws {
        let support = try temporaryFolder("support")
        let adapters = ProviderAdapters.make(host: ProcessHost(), support: support, home: try temporaryFolder("home")) { $0 == .codex ? "/opt/codex" : nil }
        #expect(adapters.map(\.provider) == [.codex])
    }
}
