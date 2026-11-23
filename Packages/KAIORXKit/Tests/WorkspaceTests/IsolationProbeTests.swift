import Foundation
import ProcessHost
import Testing
@testable import Workspace

/// The shared isolation probe suite (ADR 0002 §5) against the product profiles, on a synthetic
/// fake home folder. Intrusive probes (launchd, LaunchServices, cfprefsd) run only with
/// `KAIORX_INTRUSIVE_PROBES=1`.
@Suite(.serialized) struct IsolationProbeTests {
    struct Setup {
        let host = ProcessHost()
        let fixture: IsolationProbeFixture
        let listener: LoopbackListener

        init() throws {
            fixture = try IsolationProbeFixture.create(in: try tempDirectory("probes"))
            listener = try LoopbackListener()
        }

        func run(_ confinement: Confinement?, probes: [IsolationProbe] = IsolationProbe.allCases) async -> IsolationProbeReport {
            await IsolationProbes(host: host).run(probes, confinement: confinement, fixture: fixture, listener: listener)
        }

        func testRunner(writesWorktree: Bool) -> Confinement {
            RoleProfile.testRunner(writesWorktree: writesWorktree).confinement(
                worktree: fixture.worktree, runTemporaryDirectory: fixture.runTemporaryDirectory, layout: fixture.layout, home: fixture.home
            )
        }

        func agentCLI(_ cli: RoleProfile.AgentCLI, writesWorktree: Bool) -> Confinement {
            RoleProfile.agentCLIConfinement(
                cli, writesWorktree: writesWorktree, worktree: fixture.worktree, runTemporaryDirectory: fixture.runTemporaryDirectory,
                stateDirectory: fixture.stateDirectory(cli), layout: fixture.layout, home: fixture.home, executable: "/usr/bin/true"
            )!
        }

        func close() {
            listener.stop()
            fixture.remove()
        }
    }

    static func describe(_ report: IsolationProbeReport) -> String {
        report.results.map { "\($0.probe.rawValue): \($0.outcome)" }.joined(separator: "\n")
    }

    /// The control: without confinement every probe reaches its target, so a "blocked" under a
    /// profile is the profile's doing and not a broken probe.
    @Test func everyProbeDetectsAnEscapeWhenUnconfined() async throws {
        let setup = try Setup()
        defer { setup.close() }
        let report = await setup.run(nil)
        for probe in IsolationProbe.allCases where probe != .networkDNS {
            let outcome = try #require(report[probe])
            if probe.isIntrusive, !IsolationProbes.intrusiveOptIn {
                #expect(outcome == .skipped("intrusive probe without opt-in (KAIORX_INTRUSIVE_PROBES=1)"))
            } else {
                #expect(outcome.isReached, "\(probe): \(outcome)")
            }
        }
        // Offline the unconfined lookup fails without a sandbox refusal.
        #expect(report[.networkDNS]?.isBlocked == false, "\(Self.describe(report))")
        // The fixture is restored after each probe.
        #expect(try String(contentsOfFile: setup.fixture.worktree + "/.git", encoding: .utf8) == setup.fixture.gitLinkContent)
    }

    @Test(arguments: [false, true]) func testRunnerBlocksWhatItMust(writesWorktree: Bool) async throws {
        let setup = try Setup()
        defer { setup.close() }
        let report = await setup.run(setup.testRunner(writesWorktree: writesWorktree))
        let role = RoleProfile.testRunner(writesWorktree: writesWorktree)
        #expect(report.violations(of: role).isEmpty, "\(Self.describe(report))")
        #expect(report[.writeWorktree]?.isReached == writesWorktree)
        #expect(report[.networkLoopback]?.isBlocked == true)
        #expect(report[.networkDNS]?.isBlocked == true)
        // Recorded gaps (ADR 0002 §5): the home folder stays readable for test runs (toolchains
        // live there), and a `setsid` child outlives the process group stop.
        #expect(report[.readHiddenHome]?.isReached == true)
        #expect(report[.setsidSurvivor]?.isReached == true)
    }

    @Test(arguments: [RoleProfile.AgentCLI.claude, .codex], [false, true])
    func agentCLIBlocksWhatItMust(cli: RoleProfile.AgentCLI, writesWorktree: Bool) async throws {
        let setup = try Setup()
        defer { setup.close() }
        let confinement = setup.agentCLI(cli, writesWorktree: writesWorktree)
        let report = await setup.run(confinement)
        let role = RoleProfile.agentCLI(stateDirectory: setup.fixture.stateDirectory(cli), writesWorktree: writesWorktree)
        #expect(report.violations(of: role).isEmpty, "\(cli) \(writesWorktree)\n\(Self.describe(report))")
        #expect(report[.readHiddenHome]?.isBlocked == true)
        #expect(report[.writeWorktree]?.isReached == writesWorktree)
        // The CLI needs its provider: network stays open (loopback included), a recorded gap.
        #expect(report[.networkLoopback]?.isReached == true)
        #expect(report[.networkDNS]?.isBlocked == false)
        #expect(report[.setsidSurvivor]?.isReached == true)
    }

    /// The support folder holds the database and the provider logins (`codex-home/auth.json`);
    /// every role hides it, not only the workspace root, while a CLI keeps its own state folder.
    @Test func everyRoleHidesTheSupportFolderButTheCLIKeepsItsState() async throws {
        let setup = try Setup()
        defer { setup.close() }
        let login = setup.fixture.stateDirectory(.codex) + "/auth.json"
        try Data("token".utf8).write(to: URL(filePath: login))
        let script = "cat \"$1\" >/dev/null 2>&1 && echo LOGIN; exit 0"
        func reads(_ confinement: Confinement) async throws -> Bool {
            try await setup.host.run(LaunchSpec(
                executable: "/bin/sh", arguments: ["-c", script, "sh", login], workingDirectory: setup.fixture.worktree,
                environment: Environment.minimal(temporaryDirectory: setup.fixture.runTemporaryDirectory), timeout: .seconds(10),
                confinement: confinement
            )).stdout.text == "LOGIN\n"
        }
        #expect(try await !reads(setup.testRunner(writesWorktree: true)))
        #expect(try await !reads(setup.agentCLI(.claude, writesWorktree: true)))
        #expect(try await reads(setup.agentCLI(.codex, writesWorktree: true)))
    }

    /// The per-Mac self-test (package I.4) must fail closed on a broken profile.
    @Test func aBrokenProfileFailsTheSelfTest() async throws {
        let setup = try Setup()
        defer { setup.close() }
        let broken = Confinement(writableRoots: ["/"], allowsNetwork: true)
        let report = await setup.run(broken, probes: IsolationProbe.nonIntrusive)
        let violations = Set(report.violations(of: .testRunner(writesWorktree: false)).map(\.probe))
        #expect(violations.isSuperset(of: [.readDataRoot, .readCredentials, .writeOutsideRoots, .writeWorktree, .writeGitLink, .networkLoopback]))
    }

    @Test func intrusiveProbesAreSkippedWithoutOptIn() async throws {
        let setup = try Setup()
        defer { setup.close() }
        let probes = IsolationProbe.allCases.filter(\.isIntrusive)
        let report = await IsolationProbes(host: setup.host).run(
            probes, confinement: nil, fixture: setup.fixture, listener: setup.listener, intrusive: false
        )
        #expect(report.results.allSatisfy { if case .skipped = $0.outcome { true } else { false } })
        #expect(report.violations(of: .testRunner(writesWorktree: false)).isEmpty)
        #expect(Set(probes) == [.launchctlSubmit, .launchServicesOpen, .defaultsWrite])
    }

    /// A probe whose script never runs proves nothing (ADR 0002 §5): it is inconclusive, never
    /// blocked. Safe without the opt-in: the shell never starts, so nothing reaches the session;
    /// only the cleanup of unique, never-created names runs.
    @Test(arguments: ["/nonexistent/sh", "/usr/bin/true"]) func aProbeWhoseScriptCannotStartIsInconclusive(shell: String) async throws {
        let setup = try Setup()
        defer { setup.close() }
        var probes = IsolationProbes(host: setup.host)
        probes.tools.shell = shell
        let checked: [IsolationProbe] = [.writeGitLink, .launchctlSubmit, .launchServicesOpen, .defaultsWrite]
        for confinement in [setup.testRunner(writesWorktree: false), setup.agentCLI(.claude, writesWorktree: true)] {
            let report = await probes.run(checked, confinement: confinement, fixture: setup.fixture, listener: setup.listener, intrusive: true)
            for probe in checked {
                let outcome = try #require(report[probe])
                #expect(!outcome.isBlocked && !outcome.isReached, "\(probe): \(outcome)")
            }
            #expect(Set(report.violations(of: .testRunner(writesWorktree: false)).map(\.probe)) == Set(checked))
        }
    }

    /// A missing tool (wrong path) is not a sandbox refusal either.
    @Test func aMissingToolIsInconclusive() async throws {
        let setup = try Setup()
        defer { setup.close() }
        var probes = IsolationProbes(host: setup.host)
        let missing = setup.fixture.base + "/missing"
        probes.tools.launchctl = missing + "/launchctl"
        probes.tools.open = missing + "/open"
        probes.tools.defaults = missing + "/defaults"
        let checked: [IsolationProbe] = [.launchctlSubmit, .launchServicesOpen, .defaultsWrite]
        let report = await probes.run(
            checked, confinement: setup.testRunner(writesWorktree: false), fixture: setup.fixture, listener: setup.listener, intrusive: true
        )
        for probe in checked {
            let outcome = try #require(report[probe])
            #expect(outcome == .inconclusive("tool missing: \(missing)/\(probe == .launchctlSubmit ? "launchctl" : probe == .defaultsWrite ? "defaults" : "open")"))
        }
    }

    @Test func mustBlockFollowsTheRole() {
        let reviewer = IsolationProbe.mustBlock(.reviewer)
        #expect(reviewer.contains(.writeWorktree) && reviewer.contains(.networkDNS) && !reviewer.contains(.readHiddenHome))
        let author = IsolationProbe.mustBlock(.agentCLI(stateDirectory: "/s", writesWorktree: true))
        #expect(!author.contains(.writeWorktree) && !author.contains(.networkLoopback) && author.contains(.readHiddenHome))
        #expect(IsolationProbe.mustBlock(.testRunner(writesWorktree: true), hidesHome: true).contains(.readHiddenHome))
        #expect(!IsolationProbe.mustBlock(.reviewer).contains(.setsidSurvivor))
    }

    /// Opt-in only: touches launchd, LaunchServices and cfprefsd of the user's session, with
    /// cleanup. Every profile blocks all three.
    @Test(.enabled(if: IsolationProbes.intrusiveOptIn)) func intrusiveProbesAreBlockedByEveryProfile() async throws {
        let setup = try Setup()
        defer { setup.close() }
        let probes = IsolationProbe.allCases.filter(\.isIntrusive)
        for confinement in [
            setup.testRunner(writesWorktree: false), setup.testRunner(writesWorktree: true),
            setup.agentCLI(.claude, writesWorktree: true), setup.agentCLI(.codex, writesWorktree: false),
        ] {
            let report = await setup.run(confinement, probes: probes)
            #expect(report.results.allSatisfy { $0.outcome.isBlocked }, "\(Self.describe(report))")
        }
    }
}
