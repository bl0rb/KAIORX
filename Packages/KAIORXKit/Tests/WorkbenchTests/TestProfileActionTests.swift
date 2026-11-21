import Domain
import Foundation
import Providers
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workbench

/// ADR 0010 in the app's actions: propose, confirm what the sheet showed, run tests on a
/// candidate, list and remove.
@Suite struct TestProfileActionTests {
    func services(_ name: String) async throws -> (AppServices, ProjectID) {
        let folder = try temporaryFolder(name)
        let repo = folder + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try await sh("git init -q -b main && echo a > README.md && git add -A && git commit -qm start", in: repo)
        let configuration = AppConfiguration(
            databasePath: folder + "/db.sqlite", workspaceRoot: folder + "/ws", adapters: { _ in [FakeAdapter(provider: .fake)] }, gate: FakeGate()
        )
        guard case .ready(let services) = await AppBootstrap.start(configuration) else { throw ActionError.unavailable("start") }
        let project = try await WorkbenchActions(services: services).openProject(at: repo)
        return (services, project)
    }

    @Test func aConfirmedProfileRunsOnACandidateFromTheActions() async throws {
        let (services, project) = try await services("profile-flow")
        let actions = WorkbenchActions(services: services)
        let (_, _, candidate) = try await UITestSeed.builtCandidate(services: services, project: project, title: "Leerwert dokumentieren")
        #expect(candidate.state == .built)

        // Without a confirmed profile nothing runs.
        await #expect(throws: TestProfileError.noneConfirmed) { try await actions.runTests(candidate.id) }
        var form = TestProfileForm()
        form.name = "Schnelltest"
        form.executable = "/bin/sh"
        form.arguments = "-c\ntest -f LEERWERT.md && exit 0"
        form.testInputPrefixes = "Tests\n"
        let spec = try form.spec().get()
        #expect(spec.arguments == ["-c", "test -f LEERWERT.md && exit 0"] && spec.testInputPrefixes == ["Tests"])
        let proposed = try await actions.proposeTestProfile(project: project, spec)
        await #expect(throws: TestProfileError.noneConfirmed) { try await actions.runTests(candidate.id) }
        await #expect(throws: TestProfileError.notConfirmed("Schnelltest")) { try await actions.runTests(candidate.id, profile: proposed.id) }

        // The sheet names the full command and the digest it binds to.
        let sheet = DecisionSheet.confirmTestProfile(proposed)
        #expect(sheet.scope.contains("Befehl: /bin/sh -c 'test -f LEERWERT.md && exit 0'"))
        #expect(sheet.scope.contains("Prüfsumme: \(proposed.digest)") && sheet.rejectLabel == "Nicht bestätigen")

        // A change after the sheet was shown refuses the confirmation.
        var changed = spec
        changed.timeoutSeconds = 30
        let replaced = try await actions.proposeTestProfile(project: project, changed)
        await #expect(throws: TestProfileStoreError.digestChanged(shown: proposed.digest, stored: replaced.digest)) {
            try await actions.confirmTestProfile(proposed.id, digest: proposed.digest)
        }
        let confirmed = try await actions.confirmTestProfile(replaced.id, digest: replaced.digest)
        #expect(confirmed.isConfirmed && confirmed.confirmedBy == WorkbenchActor.user)
        #expect(try await actions.testProfiles(project: project).map(\.id) == [replaced.id])

        // „Tests ausführen“ runs it on exactly the candidate's commit.
        let result = try await actions.runTests(candidate.id)
        #expect(result.status == .passed && result.candidateOID == candidate.candidateOID && result.profileDigest == replaced.digest)
        #expect(try await services.store.candidate(candidate.id)?.state == .reviewing)
        let commit = try #require(candidate.candidateOID)
        #expect(try await services.integration?.gateItems(candidate.id) == [.noIndependentReview(commit)])

        // Removing the profile withdraws the result from the gate.
        try await actions.removeTestProfile(replaced.id)
        #expect(try await actions.testProfiles(project: project).isEmpty)
        #expect(try await services.integration?.gateItems(candidate.id) == [.noPassingTest(commit), .noConfirmedTestProfile, .noIndependentReview(commit)])
        await AppBootstrap.shutdown(services)
    }

    @Test func aRedTestRejectsAndChoosingAmongProfilesIsExplicit() async throws {
        let (services, project) = try await services("profile-red")
        let actions = WorkbenchActions(services: services)
        let (_, task, candidate) = try await UITestSeed.builtCandidate(services: services, project: project, title: "Rot")
        let red = try await actions.proposeTestProfile(project: project, TestProfileSpec(name: "Rot", executable: "/bin/sh", arguments: ["-c", "exit 3"]))
        try await actions.confirmTestProfile(red.id, digest: red.digest)
        let green = try await actions.proposeTestProfile(project: project, TestProfileSpec(name: "Grün", executable: "/usr/bin/true"))
        try await actions.confirmTestProfile(green.id, digest: green.digest)
        await #expect(throws: TestProfileError.ambiguous(["Grün", "Rot"])) { try await actions.runTests(candidate.id) }
        let result = try await actions.runTests(candidate.id, profile: red.id)
        #expect(result.status == .failed && result.exitCode == 3)
        #expect(try await services.store.candidate(candidate.id)?.state == .rejected)
        #expect(try await services.store.task(task)?.state == .needsChanges)
        #expect(Labels.testStatus(result.status).text == "Tests fehlgeschlagen")
        await AppBootstrap.shutdown(services)
    }

    @Test func theFormAndTheCommandLineReadAsTheyRun() {
        var form = TestProfileForm()
        form.name = " Unit "
        form.executable = "/usr/bin/make"
        form.arguments = "test\n\nARGS=a b\r\n"
        form.timeoutSeconds = "zehn"
        #expect(form.spec() == .failure(TestProfileFormError(messages: ["Das Zeitlimit muss eine ganze Zahl von Sekunden sein."])))
        form.timeoutSeconds = "120"
        let spec = try? form.spec().get()
        #expect(spec == TestProfileSpec(name: "Unit", executable: "/usr/bin/make", arguments: ["test", "ARGS=a b"], timeoutSeconds: 120))
        #expect(TestProfileForm(spec!).arguments == "test\nARGS=a b")
        #expect(Labels.commandLine(spec!) == "/usr/bin/make test 'ARGS=a b'")
        #expect(Labels.commandLine(TestProfileSpec(name: "q", executable: "/bin/sh", arguments: ["-c", "echo 'x'", ""])) == #"/bin/sh -c 'echo '\''x'\''' ''"#)
        form.executable = "make"
        form.workingDirectory = "../x"
        guard case .failure(let error) = form.spec() else { Issue.record("accepted"); return }
        #expect(error.messages.count == 2 && error.messages[0].contains("absoluten Pfad"))
        let record = TestProfileRecord(
            id: TestProfileID(), projectID: ProjectID(), spec: spec!, digest: spec!.digest, confirmedDigest: nil, confirmedAt: nil, confirmedBy: nil,
            createdAt: 1, updatedAt: 1
        )
        #expect(Labels.testProfile(record).text == "Nicht bestätigt")
        #expect(TestStatus.allCases.map { Labels.testStatus($0).text }.count == Set(TestStatus.allCases.map { Labels.testStatus($0).text }).count)
        #expect(Labels.gate(.noConfirmedTestProfile) == "Kein bestätigtes Testprofil im Projekt")
    }
}
