import CryptoKit
import Darwin
import Foundation
import ProcessHost
import Testing
@testable import Workspace

func tempDirectory(_ label: String) throws -> String {
    let url = FileManager.default.temporaryDirectory.appending(path: "kaiorx-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return Confinement.resolved(url.path(percentEncoded: false))
}

/// A user repository with one commit on `main`, plus KAIORX's own folder.
struct RepoFixture {
    let host = ProcessHost()
    let git: GitRunner
    let checkout: String
    let layout: WorkspaceLayout

    init() async throws {
        layout = WorkspaceLayout(root: try tempDirectory("data"))
        git = try GitRunner(host: host, home: layout.gitHome)
        checkout = try tempDirectory("user")
        try await sh("git init -q -b main && mkdir -p src docs && echo 'let a = 1' > src/a.swift && echo doc > docs/readme.md && printf '\\000\\001' > src/data.bin")
        try await commit("initial")
    }

    var environment: [String: String] {
        [
            "PATH": "/usr/bin:/bin:" + URL(filePath: git.executable).deletingLastPathComponent().path(percentEncoded: false),
            "HOME": layout.gitHome, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "U", "GIT_AUTHOR_EMAIL": "u@example.com", "GIT_COMMITTER_NAME": "U", "GIT_COMMITTER_EMAIL": "u@example.com",
        ]
    }

    /// Shell in the user checkout (setting up fixtures, as a user would).
    @discardableResult
    func sh(_ script: String, in directory: String? = nil) async throws -> String {
        let result = try await host.run(LaunchSpec(
            executable: "/bin/sh", arguments: ["-c", script], workingDirectory: directory ?? checkout,
            environment: environment, timeout: .seconds(30)
        ))
        guard result.termination == .exited(0) else {
            throw GitError.failed(arguments: [script], termination: result.termination, stderr: result.stderr.text)
        }
        return result.stdout.text.trimmingCharacters(in: .newlines)
    }

    @discardableResult
    func commit(_ message: String) async throws -> String {
        try await sh("git add -A && git commit -q -m '\(message)' && git rev-parse HEAD")
    }

    func repository() async throws -> RepositoryInfo { try await git.inspect(checkout) }

    func location(_ path: String) async throws -> WorktreeLocation {
        try git.locate(worktree: path, in: try await repository())
    }

    func worktree(_ name: String, base: String) async throws -> String {
        let path = layout.worktreePath(token: "p/\(name)")
        try await git.addWorktree(at: path, base: base, lockReason: "kaiorx:\(name)", in: try await repository())
        return Confinement.resolved(path)
    }

    /// Byte-level fingerprint of the user's checkout per path: files, index, HEAD and refs.
    func checkoutFingerprint() throws -> [String: String] {
        let root = URL(filePath: checkout)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [])!
        var paths: [String] = []
        for case let url as URL in enumerator {
            var relative = String(url.path(percentEncoded: false).dropFirst(root.path(percentEncoded: false).count))
            while relative.hasPrefix("/") { relative.removeFirst() }
            // Git's own bookkeeping for linked worktrees and objects may change; the user's files,
            // index, HEAD and branches may not.
            if relative.hasPrefix(".git/worktrees") || relative.hasPrefix(".git/objects") || relative.hasPrefix(".git/refs/kaiorx")
                || relative.hasPrefix(".git/logs/refs/kaiorx") { continue }
            paths.append(relative)
        }
        var result: [String: String] = [:]
        for relative in paths {
            let data = FileManager.default.contents(atPath: checkout + "/" + relative) ?? Data()
            result[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
}

@Suite struct RepositoryTests {
    @Test func inspectDescribesTheCheckout() async throws {
        let fixture = try await RepoFixture()
        let repo = try await fixture.repository()
        #expect(repo.topLevel == fixture.checkout)
        #expect(repo.commonDirectory == fixture.checkout + "/.git")
        #expect(repo.objectFormat == "sha1")
        #expect(repo.headBranch == "main")
        #expect(repo.headOID.map(repo.isValidOID) == true)
        #expect(try await fixture.git.resolveCommit("main", in: repo) == repo.headOID)
    }

    @Test func nonRepositoriesAreRejected() async throws {
        let fixture = try await RepoFixture()
        let plain = try tempDirectory("plain")
        await #expect(throws: GitError.notARepository(plain)) { _ = try await fixture.git.inspect(plain) }
        let bare = try tempDirectory("bare")
        try await fixture.sh("git init -q --bare", in: bare)
        await #expect(throws: GitError.bareRepository(bare)) { _ = try await fixture.git.inspect(bare) }
    }

    @Test func cleanRepositoryHasNoBlockers() async throws {
        let fixture = try await RepoFixture()
        let repo = try await fixture.repository()
        #expect(try await fixture.git.blockers(at: repo.headOID!, in: repo).isEmpty)
    }

    @Test func filtersMergeDriversAndSubmodulesBlock() async throws {
        let fixture = try await RepoFixture()
        try await fixture.sh("""
            printf '*.bin filter=lfs diff=lfs\\n*.txt merge=union\\n*.csv merge=custom\\n' > .gitattributes
            git config filter.secret.clean 'cat' && git config merge.ours.driver true
            git add .gitattributes && mkdir -p vendor/lib
            git update-index --add --cacheinfo 160000,$(git rev-parse HEAD),vendor/lib
            git commit -q -m attributes
            """)
        let head = try await fixture.sh("git rev-parse HEAD")
        #expect(try await fixture.sh("git ls-tree HEAD vendor/lib").hasPrefix("160000"))
        let repo = try await fixture.repository()
        let blockers = try await fixture.git.blockers(at: head, in: repo)
        #expect(blockers == [
            .attributeFilter(path: ".gitattributes", driver: "lfs"),
            .attributeMergeDriver(path: ".gitattributes", driver: "custom"),
            .configuredFilter(name: "secret"), .configuredMergeDriver(name: "ours"), .submodules,
        ])
    }
}

@Suite struct WorktreeTests {
    @Test func attemptWorktreeIsDetachedLockedAndOutsideTheCheckout() async throws {
        let fixture = try await RepoFixture()
        let repo = try await fixture.repository()
        let base = repo.headOID!
        let path = try await fixture.worktree("a1", base: base)
        #expect(path.hasPrefix(fixture.layout.worktreesRoot))
        #expect(!path.hasPrefix(fixture.checkout))
        let registered = try await fixture.git.registeredWorktrees(in: repo).first { $0.path == path }
        #expect(registered?.head == base)
        #expect(registered?.lockReason == "kaiorx:a1")
        #expect(try await fixture.sh("git symbolic-ref -q HEAD || echo detached", in: path) == "detached")
    }

    @Test func inventoryHandlesAwkwardPathsAndSymlinks() async throws {
        let fixture = try await RepoFixture()
        let path = try await fixture.worktree("a2", base: try await fixture.repository().headOID!)
        try await fixture.sh("""
            echo changed > src/a.swift; rm docs/readme.md
            printf x > 'src/with space.txt'; printf x > "src/$(printf 'line\\nbreak').txt"; printf x > 'src/ümlaut-🙂.txt'
            ln -s /etc/hosts src/link
            """, in: path)
        let entries = try await fixture.git.inventory(of: try await fixture.location(path))
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        #expect(byPath["src/a.swift"]?.kind == .modified)
        #expect(byPath["docs/readme.md"]?.kind == .deleted)
        #expect(byPath["src/with space.txt"]?.kind == .untracked)
        #expect(byPath["src/line\nbreak.txt"]?.kind == .untracked)
        #expect(byPath["src/ümlaut-🙂.txt"]?.kind == .untracked)
        #expect(byPath["src/link"]?.isSymlink == true)
        #expect(entries.count == 6)
    }

    @Test func sealCommitsOnlyAcceptedChangesWithoutTouchingTheWorktree() async throws {
        let fixture = try await RepoFixture()
        let repo = try await fixture.repository()
        let base = repo.headOID!
        let path = try await fixture.worktree("a3", base: base)
        try await fixture.sh("""
            echo 'let a = 2' > src/a.swift; printf '\\000\\002' > src/data.bin; echo new > 'src/neu datei.swift'
            echo outside > docs/readme.md; ln -s ../docs src/docs-link; mkdir -p src/nested/.git && echo x > src/nested/.git/config
            """, in: path)
        let indexBefore = try await fixture.sh("shasum \"$(git rev-parse --git-path index)\"", in: path)

        let outcome = try await fixture.git.buildResult(of: try await fixture.location(path), base: base, allowedPrefixes: ["src"], message: "result a3")
        #expect(Set(outcome.accepted.map(\.path)) == ["src/a.swift", "src/data.bin", "src/neu datei.swift"])
        #expect(outcome.rejected.mapKeys(\.path) == ["docs/readme.md": .outsideAllowedPaths, "src/docs-link": .symlink])
        #expect(outcome.binaryPaths == ["src/data.bin"])
        let commit = try #require(outcome.commit)
        #expect(try await fixture.sh("git rev-parse \(commit)^", in: path) == base)
        #expect(try await fixture.sh("git show \(commit):'src/neu datei.swift'", in: path) == "new")
        #expect(try await fixture.sh("git show \(commit):docs/readme.md", in: path) == "doc")
        // Git never lists a nested `.git` folder; it cannot end up in the result.
        #expect(try await fixture.sh("git ls-tree -r --name-only \(commit) src/nested", in: path) == "")
        // Worktree index and HEAD are unchanged; the result exists only as an object.
        #expect(try await fixture.sh("shasum \"$(git rev-parse --git-path index)\"", in: path) == indexBefore)
        #expect(try await fixture.sh("git rev-parse HEAD", in: path) == base)
    }

    @Test func unchangedWorktreeSealsAsEmpty() async throws {
        let fixture = try await RepoFixture()
        let base = try await fixture.repository().headOID!
        let path = try await fixture.worktree("a4", base: base)
        let outcome = try await fixture.git.buildResult(of: try await fixture.location(path), base: base, allowedPrefixes: nil, message: "m")
        #expect(outcome.commit == nil)
        #expect(outcome.accepted.isEmpty)
    }

    @Test func refsAreCreateOnlyOrCompareAndSwap() async throws {
        let fixture = try await RepoFixture()
        let repo = try await fixture.repository()
        let base = repo.headOID!
        try await fixture.sh("echo more >> docs/readme.md")
        let other = try await fixture.commit("second") // moves main, not our refs
        let ref = "refs/kaiorx/results/r1"
        try await fixture.git.updateRef(ref, to: base, expectedOld: nil, in: repo)
        #expect(try await fixture.git.readRef(ref, in: repo) == base)
        await #expect(throws: WorkspaceError.refConflict(ref: ref, expected: nil, actual: base)) {
            try await fixture.git.updateRef(ref, to: other, expectedOld: nil, in: repo)
        }
        await #expect(throws: WorkspaceError.refConflict(ref: ref, expected: other, actual: base)) {
            try await fixture.git.updateRef(ref, to: other, expectedOld: other, in: repo)
        }
        try await fixture.git.updateRef(ref, to: other, expectedOld: base, in: repo)
        #expect(try await fixture.git.readRef(ref, in: repo) == other)
        #expect(try await fixture.git.readRef("refs/kaiorx/results/missing", in: repo) == nil)
    }

    @Test func frozenWorktreeRejectsWrites() async throws {
        let fixture = try await RepoFixture()
        let path = try await fixture.worktree("a5", base: try await fixture.repository().headOID!)
        try GitRunner.setWritable(path, writable: false)
        await #expect(throws: GitError.self) { try await fixture.sh("echo x > src/a.swift", in: path) }
        await #expect(throws: GitError.self) { try await fixture.sh("echo x > src/new.txt", in: path) }
        try GitRunner.setWritable(path, writable: true)
        try await fixture.sh("echo x > src/new.txt", in: path)
    }

    @Test func removalProtectsUnsavedWorkAndForeignWorktrees() async throws {
        let fixture = try await RepoFixture()
        let repo = try await fixture.repository()
        let base = repo.headOID!
        let path = try await fixture.worktree("a6", base: base)
        try await fixture.sh("echo 'let a = 3' > src/a.swift; ln -s /tmp src/link", in: path)
        let outcome = try await fixture.git.buildResult(of: try await fixture.location(path), base: base, allowedPrefixes: nil, message: "m")
        try GitRunner.setWritable(path, writable: false)

        await #expect(throws: WorkspaceError.notOwned(path: path, lockReason: "kaiorx:a6")) {
            try await fixture.git.removeWorktree(at: path, lockReason: "kaiorx:other", savedTree: outcome.tree, force: false, in: repo)
        }
        // The rejected symlink is not in the sealed tree: removing would lose it.
        await #expect(throws: WorkspaceError.unsavedChanges(path)) {
            try await fixture.git.removeWorktree(at: path, lockReason: "kaiorx:a6", savedTree: outcome.tree, force: false, in: repo)
        }
        try await fixture.git.removeWorktree(at: path, lockReason: "kaiorx:a6", savedTree: outcome.tree, force: true, in: repo)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try await fixture.git.registeredWorktrees(in: repo).allSatisfy { $0.path != path })
    }

    @Test func savedWorktreeIsRemovedWithoutForce() async throws {
        let fixture = try await RepoFixture()
        let repo = try await fixture.repository()
        let base = repo.headOID!
        let path = try await fixture.worktree("a7", base: base)
        try await fixture.sh("echo 'let a = 4' > src/a.swift", in: path)
        let outcome = try await fixture.git.buildResult(of: try await fixture.location(path), base: base, allowedPrefixes: nil, message: "m")
        try await fixture.git.removeWorktree(at: path, lockReason: "kaiorx:a7", savedTree: outcome.tree, force: false, in: repo)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func missingWorktreeFolderIsPruned() async throws {
        let fixture = try await RepoFixture()
        let repo = try await fixture.repository()
        let path = try await fixture.worktree("a8", base: repo.headOID!)
        try FileManager.default.removeItem(atPath: path)
        try await fixture.git.removeWorktree(at: path, lockReason: "kaiorx:a8", savedTree: nil, force: false, in: repo)
        #expect(try await fixture.git.registeredWorktrees(in: repo).allSatisfy { $0.path != path })
    }
}

@Suite struct TestRunTests {
    func run(_ fixture: RepoFixture, script: String, writesWorktree: Bool = false, timeout: Int = 30) async throws -> TestReport {
        let base = try await fixture.repository().headOID!
        let path = try await fixture.worktree("qa-\(UUID().uuidString.prefix(8))", base: base)
        let temp = try fixture.layout.runTemporaryDirectory(UUID().uuidString)
        let profile = TestProfile(executable: "/bin/sh", arguments: ["-c", script], timeoutSeconds: timeout, writesWorktree: writesWorktree)
        return await fixture.git.runTests(
            profile, in: try await fixture.location(path), commit: base, runTemporaryDirectory: temp,
            confinement: RoleProfile.testRunner(writesWorktree: writesWorktree).confinement(worktree: path, runTemporaryDirectory: temp, layout: fixture.layout)
        )
    }

    @Test func passingFailingAndTimedOutAreDistinct() async throws {
        let fixture = try await RepoFixture()
        #expect(try await run(fixture, script: "grep -q 'let a' src/a.swift").outcome == .passed)
        #expect(try await run(fixture, script: "exit 3").outcome == .failed(exitCode: 3))
        #expect(try await run(fixture, script: "kill -SEGV $$").outcome == .crashed(signal: SIGSEGV))
        #expect(try await run(fixture, script: "sleep 30", timeout: 1).outcome == .timedOut)
    }

    @Test func readOnlyRunCannotTouchTheWorktreeButMayUseItsTemp() async throws {
        let fixture = try await RepoFixture()
        let report = try await run(fixture, script: "echo x >> src/a.swift; echo y > \"$TMPDIR/build.log\"; exit 0")
        #expect(report.outcome == .passed)
        #expect(report.process?.stderr.text.contains("not permitted") == true)
    }

    @Test func changedInputsInvalidateTheRun() async throws {
        let fixture = try await RepoFixture()
        let report = try await run(fixture, script: "echo hacked > src/a.swift; echo out > build.txt", writesWorktree: true)
        #expect(report.outcome == .inputsModified(["src/a.swift"]))
        #expect(report.untrackedOutputs == ["build.txt"])
    }

    @Test func profilesCannotLeaveTheWorktree() async throws {
        let fixture = try await RepoFixture()
        let base = try await fixture.repository().headOID!
        let path = try await fixture.worktree("qa-escape", base: base)
        let report = await fixture.git.runTests(
            TestProfile(executable: "/usr/bin/true", workingDirectory: "../.."), in: try await fixture.location(path), commit: base,
            runTemporaryDirectory: try fixture.layout.runTemporaryDirectory("x"), confinement: nil
        )
        guard case .infrastructureError = report.outcome else { Issue.record("got \(report.outcome)"); return }
    }
}

/// Package C acceptance: two parallel fixture processes in separate worktrees, blocked neighbour
/// access, and a user checkout that stays byte-identical.
@Suite struct IsolationAcceptanceTests {
    @Test func twoConfinedAuthorsWorkInParallelWithoutTouchingEachOtherOrTheUser() async throws {
        let fixture = try await RepoFixture()
        // Unsaved user work: a modified tracked file, a staged change and an untracked file.
        try await fixture.sh("echo 'user edit' >> src/a.swift; echo staged > staged.txt; git add staged.txt; echo scratch > notes.txt")
        let fingerprint = try fixture.checkoutFingerprint()
        let repo = try await fixture.repository()
        let base = repo.headOID!
        let a = try await fixture.worktree("author-a", base: base)
        let b = try await fixture.worktree("author-b", base: base)

        let script = #"""
            perl -MTime::HiRes=time -e 'printf("start %.3f\n", time)'
            echo "$1" > src/a.swift && echo own-write
            cat "$2/src/a.swift" >/dev/null 2>&1 && echo NEIGHBOR-READ
            echo x > "$2/src/a.swift" 2>/dev/null && echo NEIGHBOR-WRITE
            echo x >> "$3/src/a.swift" 2>/dev/null && echo USER-WRITE
            echo x >> "$4/config" 2>/dev/null && echo GITDIR-WRITE
            cat "$5" >/dev/null 2>&1 && echo DATA-READ
            perl -e 'select(undef,undef,undef,0.3)'
            perl -MTime::HiRes=time -e 'printf("end %.3f\n", time)'
            exit 0
            """#
        func launch(_ own: String, _ neighbor: String, marker: String) async throws -> ProcessResult {
            let temp = try fixture.layout.runTemporaryDirectory(UUID().uuidString)
            let database = fixture.layout.root + "/kaiorx.sqlite"
            FileManager.default.createFile(atPath: database, contents: Data("db".utf8))
            return try await fixture.host.run(LaunchSpec(
                executable: "/bin/sh", arguments: ["-c", script, "fixture", marker, neighbor, fixture.checkout, repo.commonDirectory, database],
                workingDirectory: own, environment: Environment.minimal(temporaryDirectory: temp), timeout: .seconds(30),
                confinement: RoleProfile.author.confinement(worktree: own, runTemporaryDirectory: temp, layout: fixture.layout)
            ))
        }
        async let runA = launch(a, b, marker: "from-a")
        async let runB = launch(b, a, marker: "from-b")
        let results = try await [runA, runB]

        var intervals: [(Double, Double)] = []
        for result in results {
            let lines = result.stdout.text.split(separator: "\n").map(String.init)
            let flags = Set(lines.filter { !$0.hasPrefix("start") && !$0.hasPrefix("end") })
            #expect(flags == ["own-write"], "\(flags)")
            let start = lines.first { $0.hasPrefix("start ") }.flatMap { Double($0.dropFirst(6)) } ?? 0
            let end = lines.first { $0.hasPrefix("end ") }.flatMap { Double($0.dropFirst(4)) } ?? 0
            intervals.append((start, end))
        }
        #expect(intervals[0].0 < intervals[1].1 && intervals[1].0 < intervals[0].1, "not parallel: \(intervals)")
        #expect(try String(contentsOfFile: a + "/src/a.swift", encoding: .utf8) == "from-a\n")
        #expect(try String(contentsOfFile: b + "/src/a.swift", encoding: .utf8) == "from-b\n")

        // Seal both, pin results, remove the worktrees: the user's checkout is unchanged.
        for (name, path) in [("author-a", a), ("author-b", b)] {
            let outcome = try await fixture.git.buildResult(of: try await fixture.location(path), base: base, allowedPrefixes: ["src"], message: name)
            try await fixture.git.updateRef("refs/kaiorx/results/\(name)", to: try #require(outcome.commit), expectedOld: nil, in: repo)
            try await fixture.git.removeWorktree(at: path, lockReason: "kaiorx:\(name)", savedTree: outcome.tree, force: false, in: repo)
        }
        let after = try fixture.checkoutFingerprint()
        let changed = Set(after.keys).union(fingerprint.keys).filter { after[$0] != fingerprint[$0] }
        #expect(changed.isEmpty, "changed in the user checkout: \(changed.sorted())")
        let status = try await fixture.sh("git status --porcelain=v1")
        #expect(Set(status.split(separator: "\n")) == ["A  staged.txt", " M src/a.swift", "?? notes.txt"], "\(status)")
        #expect(try await fixture.git.inspect(fixture.checkout).headBranch == "main")
    }
}

extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        Dictionary<T, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}

@Suite struct ReviewFixTests {
    /// An author rewrites its `.git` link file to a repository with a malicious filter. The
    /// sandbox refuses the write; and even with the file replaced, host Git ignores it.
    @Test func gitLinkFileCannotRedirectHostGit() async throws {
        let fixture = try await RepoFixture()
        let repo = try await fixture.repository()
        let base = repo.headOID!
        let path = try await fixture.worktree("evil", base: base)
        let temp = try fixture.layout.runTemporaryDirectory("evil")
        let confined = try await fixture.host.run(LaunchSpec(
            executable: "/bin/sh", arguments: ["-c", "echo 'gitdir: /tmp/x' > .git && echo REWROTE; exit 0"], workingDirectory: path,
            environment: Environment.minimal(temporaryDirectory: temp), timeout: .seconds(10),
            confinement: RoleProfile.author.confinement(worktree: path, runTemporaryDirectory: temp, layout: fixture.layout)
        ))
        #expect(!confined.stdout.text.contains("REWROTE"))

        // Unconfined attacker: redirect `.git` to its own repository with a clean filter.
        let marker = fixture.layout.root + "/PWNED"
        try await fixture.sh("""
            git init -q --bare evil.git && echo '\(repo.commonDirectory)/objects' > evil.git/objects/info/alternates
            git --git-dir=evil.git config filter.x.clean 'touch \(marker) && cat'
            echo '* filter=x' > .gitattributes && echo changed > src/a.swift
            echo "gitdir: $(pwd)/evil.git" > .git
            """, in: path)
        let outcome = try await fixture.git.buildResult(of: try await fixture.location(path), base: base, allowedPrefixes: ["src"], message: "m")
        #expect(!FileManager.default.fileExists(atPath: marker), "attacker's filter ran in host Git")
        #expect(outcome.commit != nil)
    }

    @Test func untrackedNestedRepositoryIsRejectedNotCommittedAsGitlink() async throws {
        let fixture = try await RepoFixture()
        let base = try await fixture.repository().headOID!
        let path = try await fixture.worktree("nested", base: base)
        try await fixture.sh("mkdir -p src/inner && cd src/inner && git init -q && echo x > f && git add f && git commit -q -m i && cd ../.. && echo y >> src/a.swift", in: path)
        let outcome = try await fixture.git.buildResult(of: try await fixture.location(path), base: base, allowedPrefixes: nil, message: "m")
        #expect(outcome.rejected.mapKeys(\.path) == ["src/inner": .submodule])
        let commit = try #require(outcome.commit)
        #expect(try await fixture.sh("git ls-tree -r \(commit) src/inner", in: path) == "")
    }

    @Test func hfsIgnorableGitNamesAreRejectedAndSealingSucceeds() async throws {
        let fixture = try await RepoFixture()
        let base = try await fixture.repository().headOID!
        let path = try await fixture.worktree("hfs", base: base)
        try await fixture.sh("mkdir -p \"sub/.git$(printf '\\342\\200\\214')\" && echo x > \"sub/.git$(printf '\\342\\200\\214')/config\" && echo z >> src/a.swift", in: path)
        let outcome = try await fixture.git.buildResult(of: try await fixture.location(path), base: base, allowedPrefixes: nil, message: "m")
        #expect(outcome.rejected.values.contains(.gitMetadata))
        #expect(outcome.commit != nil)
        #expect(GitRunner.isGitMetadataComponent(".GIT"))
        #expect(GitRunner.isGitMetadataComponent("git~1"))
        #expect(!GitRunner.isGitMetadataComponent("git~notes"))
        #expect(!GitRunner.isGitMetadataComponent(".github"))
    }

    @Test func includedFiltersAndAttributesFilesBlock() async throws {
        let fixture = try await RepoFixture()
        let repo = try await fixture.repository()
        try await fixture.sh("""
            printf '[filter "x"]\\n\\tsmudge = cat\\n[core]\\n\\tattributesFile = attrs\\n' > .git/extra.cfg
            git config include.path extra.cfg
            """)
        let blockers = try await fixture.git.blockers(at: repo.headOID!, in: repo)
        #expect(blockers.contains(.configuredFilter(name: "x")))
        #expect(blockers.contains(.configuredAttributesFile("attrs")))
    }

    @Test func removalRecoversFoldersAnAgentLockedItselfOutOf() async throws {
        let fixture = try await RepoFixture()
        let repo = try await fixture.repository()
        let path = try await fixture.worktree("mode000", base: repo.headOID!)
        try await fixture.sh("mkdir -p junk/deep && echo x > junk/deep/f && chmod 000 junk", in: path)
        try await fixture.git.removeWorktree(at: path, lockReason: "kaiorx:mode000", savedTree: nil, force: true, in: repo)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

@Suite struct SecondReviewWorkspaceTests {
    @Test func unregisteredFolderIsOnlyDeletedWithForce() async throws {
        let fixture = try await RepoFixture()
        let repo = try await fixture.repository()
        let path = try await fixture.worktree("forgotten", base: repo.headOID!)
        try await fixture.sh("echo work > src/unsaved.swift", in: path)
        try await fixture.sh("cp -R '\(path)' '\(path).keep' && git worktree remove -f -f '\(path)' && mv '\(path).keep' '\(path)'")
        await #expect(throws: WorkspaceError.unregisteredFolder(path)) {
            try await fixture.git.removeWorktree(at: path, lockReason: "kaiorx:forgotten", savedTree: nil, force: false, in: repo)
        }
        #expect(FileManager.default.fileExists(atPath: path + "/src/unsaved.swift"))
        try await fixture.git.removeWorktree(at: path, lockReason: "kaiorx:forgotten", savedTree: nil, force: true, in: repo)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func relativeWorktreePointersAreResolved() async throws {
        let fixture = try await RepoFixture()
        try await fixture.sh("git config worktree.useRelativePaths true")
        let repo = try await fixture.repository()
        let path = try await fixture.worktree("relative", base: repo.headOID!)
        let pointer = try String(contentsOfFile: repo.commonDirectory + "/worktrees/relative/gitdir", encoding: .utf8)
        #expect(!pointer.hasPrefix("/"))
        #expect(try await fixture.location(path).path == path)
    }

    @Test func attributeFilesAreParsedLikeGit() {
        let crlf = GitRunner.attributeBlockers(Data("# c\r\n* filter=evil\r\n".utf8), path: "a")
        #expect(crlf == [.attributeFilter(path: "a", driver: "evil")])
        let cr = GitRunner.attributeBlockers(Data("*\rfilter=cr\n".utf8), path: "a")
        #expect(cr == [.attributeFilter(path: "a", driver: "cr")])
        let macro = GitRunner.attributeBlockers(Data("[attr]m filter=macro\n* m\n".utf8), path: "a")
        #expect(macro == [.attributeFilter(path: "a", driver: "macro")])
    }

    @Test func mixedCaseAttributesFileBlocks() async throws {
        let fixture = try await RepoFixture()
        try await fixture.sh("printf '* filter=x\\n' > .GitAttributes && git add .GitAttributes && git commit -q -m attrs")
        let repo = try await fixture.repository()
        #expect(try await fixture.git.blockers(at: repo.headOID!, in: repo) == [.attributeFilter(path: ".GitAttributes", driver: "x")])
    }

    @Test func ntfsNamesAndFoldersTurnedIntoLinksDoNotBreakSealing() async throws {
        let fixture = try await RepoFixture()
        let base = try await fixture.repository().headOID!
        let path = try await fixture.worktree("ntfs", base: base)
        try await fixture.sh("mkdir -p 'a/.git:x' && echo x > 'a/.git:x/f' && rm -rf docs && ln -s /tmp docs && echo z >> src/a.swift", in: path)
        let outcome = try await fixture.git.buildResult(of: try await fixture.location(path), base: base, allowedPrefixes: nil, message: "m")
        #expect(outcome.rejected.mapKeys(\.path) == ["a/.git:x/f": .gitMetadata, "docs": .symlink, "docs/readme.md": .symlink])
        #expect(Set(outcome.accepted.map(\.path)) == ["src/a.swift"])
        #expect(outcome.commit != nil)
        #expect(GitRunner.isGitMetadataComponent(".git::$INDEX_ALLOCATION"))
        #expect(GitRunner.isGitMetadataComponent("GIT~1:x"))
    }
}
