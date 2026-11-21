import Domain
import Foundation
import ProcessHost
import Providers
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workbench
@testable import Workspace

/// A job in the app's services with published candidates, built through the real chain (author
/// result, candidate, passing test, imported approving review, approval, publication).
struct PublishedJobFixture {
    let services: AppServices
    let actions: WorkbenchActions
    let repo: String
    let project: ProjectID
    let job: JobID

    var integration: IntegrationService { services.integration! }
    var integrationRef: String { "refs/kaiorx/integrations/\(job.uuidString)" }

    init(_ name: String) async throws {
        let folder = try temporaryFolder(name)
        repo = folder + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try await sh("git init -q -b main && echo a > README.md && git add -A && git commit -qm start", in: repo)
        let configuration = AppConfiguration(
            databasePath: folder + "/db.sqlite", workspaceRoot: folder + "/ws", adapters: { _ in [FakeAdapter(provider: .fake)] }, gate: FakeGate()
        )
        guard case .ready(let services) = await AppBootstrap.start(configuration) else { throw ActionError.unknown("not ready") }
        self.services = services
        actions = WorkbenchActions(services: services)
        project = try await actions.openProject(at: repo)
        job = JobID()
        try await services.store.execute(Command(.createJob(id: job, projectID: project, goal: "Liefern")))
        try await services.store.execute(Command(.transitionJob(id: job, to: .planned, expectedVersion: 1, reason: nil)))
        try await services.store.execute(Command(.transitionJob(id: job, to: .active, expectedVersion: 2, reason: nil)))
        _ = try await services.workspace!.openIntegration(job, baseRevision: "main")
    }

    /// One author result writing `content` to `file`, taken through the whole chain and published.
    @discardableResult
    func publish(_ content: String, to file: String = "a.txt") async throws -> CandidateRecord {
        let store = services.store, workspace = services.workspace!
        let task = TaskID(), attempt = AttemptID()
        try await store.execute(Command(.createTask(id: task, jobID: job, title: "Datei \(file)")))
        try await store.execute(Command(.transitionTask(id: task, to: .ready, expectedVersion: 1)))
        try await store.execute(Command(.reserveAttempt(AttemptReservation(
            attemptID: attempt, taskID: task, projectID: project, role: .author, provider: .claude, mode: .automatic, model: "m", specDigest: "d"
        ))))
        let tip = try #require(try await store.integrationTip(job: job))
        let tree = try await workspace.prepareWorktree(projectID: project, attemptID: attempt, kind: .author, base: tip)
        try "\(content)\n".write(toFile: workspace.path(of: tree) + "/" + file, atomically: true, encoding: .utf8)
        let version = try #require(try await store.attempt(attempt)).version
        try await store.execute(Command(.transitionAttempt(id: attempt, to: .starting, expectedVersion: version, errorClass: nil)))
        _ = try await store.ingest(.started(sessionID: "s"), attemptID: attempt)
        _ = try await store.ingest(.completed(.succeeded), attemptID: attempt)
        _ = try await workspace.seal(tree.id, allowedPrefixes: nil, message: "result")
        guard case .built(let candidate) = try await integration.buildCandidate(from: tree.id) else { throw ActionError.unknown("not built") }
        let commit = try #require(candidate.candidateOID)
        try await integration.runTests(candidate.id, profile: TestProfile(executable: "/bin/sh", arguments: ["-c", "exit 0"]))
        _ = try await integration.importReview(
            candidate.id, text: #"{"candidateOID": "\#(commit)", "verdict": "approve", "summary": "ok", "findings": []}"#
        )
        let approval = try await integration.approve(candidate.id, actor: WorkbenchActor.user)
        try await integration.publish(candidate.id, approval: approval.id)
        return try #require(try await store.candidate(candidate.id))
    }

    func git(_ script: String) async throws -> String { try await sh(script, in: repo) }

    func close() async { await AppBootstrap.shutdown(services) }
}

@Suite struct DeliveryTests {
    /// The sheet's preview uses the service's own name check and suffix rule: whatever the
    /// preview names is exactly what the service creates, and what it refuses the service refuses.
    @Test func thePreviewFollowsTheServicesNameRules() async throws {
        let f = try await PublishedJobFixture("preview")
        try await f.publish("eins")
        try await f.git("git branch feature/x && git pack-refs --all")

        #expect(try await f.actions.deliveryPreview(job: f.job, name: "").problems == [.emptyName])
        let main = try await f.actions.deliveryPreview(job: f.job, name: "Main")
        #expect(main.branchName == "Main-2" && main.problems.isEmpty)
        #expect(try await f.actions.deliveryPreview(job: f.job, name: "ma\u{0308}in").branchName == "ma\u{0308}in")
        #expect(try await f.actions.deliveryPreview(job: f.job, name: "feature/x/y").problems == [.noFreeName])

        let names = ["Main", "lieferung", "Lieferung", "feature", "feature/x/y", "@", "@{-1}", "x@{u}", "-x", "a b", "a..b", ".a", "a.lock",
                     "a/", "a//b", "a~b", "a^b", "a:b", "a?b", "a*b", "a[b", "a\\b", "HEAD", "kaiorx/ä", "a\u{7}b"]
        for name in names {
            let preview = try await f.actions.deliveryPreview(job: f.job, name: name)
            do {
                let created = try await f.integration.createDeliveryBranch(job: f.job, name: name)
                #expect(preview.branchName == created, "\(name): preview \(preview.branchName ?? "nil"), created \(created)")
            } catch let error as MergeError {
                #expect(preview.branchName == nil, "\(name): preview \(preview.branchName ?? "nil"), refused \(error)")
                #expect(preview.problems == [error == .invalidBranchName(name) ? .invalidName : .noFreeName], "\(name)")
            }
        }
        await f.close()
    }

    @Test func deliveringCreatesTheShownBranchAndLeavesTheCheckoutAlone() async throws {
        let f = try await PublishedJobFixture("deliver")
        let candidate = try await f.publish("eins")
        try await f.git("echo 'user edit' >> README.md")
        let user = try await f.git("git status --porcelain=v1; git rev-parse HEAD; git symbolic-ref HEAD; git for-each-ref refs/heads")

        let preview = try await f.actions.deliveryPreview(job: f.job, name: "kaiorx/lieferung")
        #expect(preview.target == candidate.candidateOID && preview.publishedCandidates == 1 && preview.integrationRef == f.integrationRef)
        let sheet = DecisionSheet.deliver(preview, jobTitle: "Liefern")
        #expect(sheet.canApprove && sheet.title == "In neuen Branch liefern")
        #expect(sheet.action.contains("„kaiorx/lieferung“") && sheet.action.contains(Labels.short(preview.target)))
        #expect(sheet.scope.contains("Neuer Branch: refs/heads/kaiorx/lieferung"))
        #expect(sheet.scope.contains("Integrationsstand: \(preview.target)"))
        #expect(sheet.scope.contains { $0.contains("Checkout") && $0.contains("unverändert") })
        #expect(sheet.ifRejected.contains("kein Branch"))
        #expect(sheet.delivery == ShownDelivery(job: f.job, name: "kaiorx/lieferung", target: preview.target))

        #expect(try await f.actions.deliver(sheet: sheet) == "kaiorx/lieferung")
        #expect(try await f.git("git rev-parse refs/heads/kaiorx/lieferung") == candidate.candidateOID)
        #expect(try await f.git("git status --porcelain=v1; git rev-parse HEAD; git symbolic-ref HEAD; git for-each-ref refs/heads | grep -v kaiorx/lieferung") == user)

        // A taken name (case-insensitively) is named in the sheet with the suffix that is used.
        let taken = DecisionSheet.deliver(try await f.actions.deliveryPreview(job: f.job, name: "KAIORX/Lieferung"), jobTitle: "Liefern")
        #expect(taken.scope.contains { $0.contains("„KAIORX/Lieferung“ ist schon belegt") && $0.contains("„KAIORX/Lieferung-2“") })
        #expect(try await f.actions.deliver(sheet: taken) == "KAIORX/Lieferung-2")
        await f.close()
    }

    @Test func aMovedIntegrationStateRefusesTheShownDelivery() async throws {
        let f = try await PublishedJobFixture("moved")
        try await f.publish("eins")
        let sheet = DecisionSheet.deliver(try await f.actions.deliveryPreview(job: f.job, name: "lieferung"), jobTitle: "Liefern")
        try await f.publish("zwei", to: "b.txt")
        await #expect(throws: IntegrationError.self) { try await f.actions.deliver(sheet: sheet) }
        #expect(try await f.git("git for-each-ref --format='%(refname)' refs/heads") == "refs/heads/main")
        do { try await f.actions.deliver(sheet: sheet) } catch {
            #expect(IntegrationMessages.text(error).hasPrefix("Der Integrationsstand hat sich geändert"))
        }
        await f.close()
    }

    @Test func invalidNamesAndUnpublishedJobsBlockTheSheet() async throws {
        let f = try await PublishedJobFixture("blocked")
        let empty = try await f.actions.deliveryPreview(job: f.job, name: "lieferung")
        #expect(empty.problems == [.nothingPublished])
        let sheet = DecisionSheet.deliver(empty, jobTitle: "Liefern")
        #expect(!sheet.canApprove && sheet.blockers == [DeliveryProblem.nothingPublished.text])
        await #expect(throws: ActionError.self) { try await f.actions.deliver(sheet: sheet) }

        try await f.publish("eins")
        let invalid = DecisionSheet.deliver(try await f.actions.deliveryPreview(job: f.job, name: "@{-1}"), jobTitle: "Liefern")
        #expect(!invalid.canApprove && invalid.blockers == [DeliveryProblem.invalidName.text])
        #expect(try await f.git("git for-each-ref --format='%(refname)' refs/heads") == "refs/heads/main")
        #expect(IntegrationMessages.text(MergeError.invalidBranchName("x")) == DeliveryProblem.invalidName.text)
        #expect(IntegrationMessages.text(MergeError.noFreeBranchName("x")).hasPrefix("Der Name ist belegt"))
        await f.close()
    }

    @Test func aRevertIsBuiltOnceAndTheSheetSaysWhy() async throws {
        let f = try await PublishedJobFixture("revert")
        let original = try await f.publish("eins")
        let task = try await f.services.store.task(try #require(original.taskID))
        let sheet = DecisionSheet.revert(original, task: task, openRevert: try await f.actions.openRevert(of: original.id))
        #expect(sheet.canApprove && sheet.title == "Veröffentlichung zurücknehmen")
        #expect(sheet.action.contains(Labels.short(original.candidateOID!)))
        #expect(sheet.scope.contains("Zurückgenommener Commit: \(original.candidateOID!)"))
        #expect(sheet.scope.contains { $0.contains("Test, Review und Freigabe") })
        #expect(sheet.ifRejected == "Es wird nichts gebaut; die Veröffentlichung bleibt bestehen.")

        guard case .built(let revert) = try await f.actions.revert(original.id, sheet: sheet) else { Issue.record("no revert"); return }
        #expect(revert.kind == .revert && revert.revertsCandidateID == original.id && revert.state == .built)
        #expect(try await f.services.store.task(try #require(revert.taskID))?.state == .verifying)
        // The integration target is unchanged until the revert is approved and published.
        #expect(try await f.git("git rev-parse \(f.integrationRef)") == original.candidateOID)

        let open = try await f.actions.openRevert(of: original.id)
        #expect(open?.id == revert.id)
        let again = DecisionSheet.revert(original, task: task, openRevert: open)
        #expect(!again.canApprove && again.blockers.first?.hasPrefix("Für diese Veröffentlichung gibt es schon einen offenen Revert") == true)
        await #expect(throws: ActionError.self) { _ = try await f.actions.revert(original.id, sheet: again) }
        // The service refuses as well, should the sheet be stale.
        do {
            _ = try await f.actions.revert(original.id, sheet: sheet)
            Issue.record("second revert built")
        } catch {
            #expect(error as? IntegrationStoreError == .openRevertExists(revert.id))
            #expect(IntegrationMessages.text(error) == "Für diese Veröffentlichung gibt es schon einen offenen Revert.")
        }
        await f.close()
    }

    @Test func aConflictingRevertAndAnUnpublishedCandidateAreReported() async throws {
        let f = try await PublishedJobFixture("conflict")
        let original = try await f.publish("eins", to: "f.txt")
        try await f.publish("zwei", to: "f.txt")
        let sheet = DecisionSheet.revert(original, task: nil, openRevert: nil)
        guard case .conflicted(let revert, let paths) = try await f.actions.revert(original.id, sheet: sheet) else {
            Issue.record("expected a conflict")
            return
        }
        #expect(paths == ["f.txt"] && revert.state == .conflicted)
        #expect(try await f.services.store.task(try #require(revert.taskID))?.state == .conflict)
        #expect(RevertOutcome.conflicted(revert, paths: paths).text.contains("Konflikte in einer Datei: f.txt"))

        // Only a published candidate offers the revert.
        let blocked = DecisionSheet.revert(revert, task: nil, openRevert: nil)
        #expect(blocked.blockers == ["Nur veröffentlichte Kandidaten lassen sich zurücknehmen."])
        #expect(IntegrationMessages.text(IntegrationError.candidateNotIn(revert.id, .conflicted)) == "Der Kandidat ist nicht veröffentlicht (Zustand: Konflikt).")
        await f.close()
    }
}
