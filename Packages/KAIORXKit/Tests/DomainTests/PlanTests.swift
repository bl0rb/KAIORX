import Foundation
import Testing
@testable import Domain

@Suite struct PlanValidatorTests {
    func task(_ key: String, after predecessors: [String] = [], parent: String? = nil, writes: [String]? = ["src/\(UUID().uuidString.prefix(4))"],
              criteria: [String] = ["Test grün"]) -> PlanTaskDraft {
        PlanTaskDraft(key: key, title: key, criteria: criteria, writePaths: writes, predecessors: predecessors, parent: parent)
    }

    func issues(_ draft: PlanDraft, ended: Set<String> = []) -> [PlanIssue] {
        if case .failure(let failure) = PlanValidator.validate(draft, ended: ended) { return failure.issues }
        return []
    }

    @Test func diamondIsValidAndOrdersByRemainingPath() throws {
        let draft = PlanDraft(tasks: [task("A"), task("B", after: ["A"]), task("C", after: ["A"]), task("D", after: ["B", "C"]), task("E")])
        let plan = try PlanValidator.validate(draft).get()
        #expect(plan.task("D")?.predecessors == ["B", "C"])
        let lengths = plan.remainingPathLengths(finished: [])
        #expect(lengths["A"] == 3 && lengths["B"] == 2 && lengths["D"] == 1 && lengths["E"] == 1)
        #expect(plan.remainingPathLengths(finished: ["A"])["A"] == 2)
    }

    @Test func cyclesAreNamed() {
        let found = issues(PlanDraft(tasks: [task("A", after: ["C"]), task("B", after: ["A"]), task("C", after: ["B"])]))
        guard case .cycle(let keys)? = found.first else { Issue.record("no cycle: \(found)"); return }
        #expect(keys.first == keys.last && Set(keys) == ["A", "B", "C"])
        #expect(issues(PlanDraft(tasks: [task("A", after: ["A"])])) == [.selfDependency("A")])
    }

    @Test func parentsExpandToTheirLeaves() throws {
        let draft = PlanDraft(tasks: [
            task("parser", writes: nil), task("lexer", parent: "parser"), task("ast", after: ["lexer"], parent: "parser"),
            task("docs"), task("examples", after: ["parser", "docs"]),
        ])
        let plan = try PlanValidator.validate(draft).get()
        #expect(plan.tasks.map(\.key) == ["lexer", "ast", "docs", "examples"])
        #expect(plan.task("examples")?.predecessors == ["lexer", "ast", "docs"])
        // A child depending on its own parent waits for itself.
        #expect(issues(PlanDraft(tasks: [task("p"), task("c", after: ["p"], parent: "p")])).contains { if case .cycle = $0 { true } else { false } })
    }

    @Test func structuralErrorsAreAllReported() {
        let found = issues(PlanDraft(tasks: [task("A"), task("A"), task("B", after: ["X"]), task("C", parent: "Y")]))
        #expect(found.contains(.duplicateKey("A")))
        #expect(found.contains(.unknownPredecessor(task: "B", predecessor: "X")))
        #expect(found.contains(.unknownParent(task: "C", parent: "Y")))
        #expect(issues(PlanDraft(tasks: [])) == [.emptyPlan])
        #expect(issues(PlanDraft(tasks: [task("A", criteria: [" ", ""])])) == [.noCriterion("A")])
    }

    @Test func oversizedPlansGoBackForRevision() {
        let many = PlanDraft(tasks: (1...13).map { task("t\($0)") })
        #expect(issues(many) == [.oversized(leaves: 13, depth: 1)])
        let deep = PlanDraft(tasks: [task("a"), task("b", parent: "a"), task("c", parent: "b"), task("d", parent: "c")])
        #expect(issues(deep) == [.oversized(leaves: 1, depth: 4)])
    }

    @Test func endedPredecessorsMakeCompletionUnreachable() {
        #expect(issues(PlanDraft(tasks: [task("A"), task("B", after: ["A"])]), ended: ["A"]) == [.unreachable(task: "B", predecessor: "A")])
    }

    @Test func writeAreasAreNormalizedAndChecked() throws {
        #expect(try WriteArea.resolve(nil) == .wholeProject)
        #expect(try WriteArea.resolve(["./src//a/", "."]) == .wholeProject)
        #expect(try WriteArea.resolve(["./src//a/"]) == .paths(["src/a"]))
        for bad in ["/etc", "../x", "src/../../x", "a/.git/hooks", "~/x", "a\\b"] {
            #expect(throws: PlanIssue.unresolvablePath(bad)) { try WriteArea.resolve([bad]) }
        }
        #expect(issues(PlanDraft(tasks: [task("A", writes: ["../up"])])) == [.unresolvablePath("../up")])
    }

    @Test func overlapIsByWholePathComponents() throws {
        let src = try WriteArea.resolve(["src"]), srcA = try WriteArea.resolve(["src/a"]), srcAb = try WriteArea.resolve(["src/ab"])
        #expect(src.overlaps(srcA) && srcA.overlaps(src))
        #expect(!srcA.overlaps(srcAb))
        #expect(WriteArea.wholeProject.overlaps(srcA))
        #expect(try WriteArea.resolve(["Docs"]).overlaps(try WriteArea.resolve(["docs/api"])))
        #expect(try WriteArea.resolve(["Caf\u{e9}"]).overlaps(try WriteArea.resolve(["Cafe\u{301}/x"])))
        // Shared manifests serialize tasks that would otherwise not touch.
        let one = try WriteArea.resolve(["Sources/A", "Package.swift"]), two = try WriteArea.resolve(["Sources/B", "Package.resolved"])
        #expect(one.overlaps(two))
        #expect(!(try WriteArea.resolve(["Sources/A"])).overlaps(two))
    }

    @Test func consentRootsCoverAreas() throws {
        #expect(try WriteArea.resolve(["src/a", "Package.swift"]).isCovered(by: ["src", "Package.swift"]))
        #expect(!(try WriteArea.resolve(["docs"])).isCovered(by: ["src"]))
        #expect(!WriteArea.wholeProject.isCovered(by: ["src"]))
        #expect(WriteArea.wholeProject.isCovered(by: [""]))
        #expect(!(try WriteArea.resolve(["src"])).isCovered(by: []))
    }

    @Test func difficultyMapsToTiers() {
        #expect(DifficultyEvidence(multipleModules: true, moreThanThreeFiles: false, unclearApproach: false, noReproducibleTest: false).tier(risk: .normal) == .fast)
        #expect(DifficultyEvidence(multipleModules: true, moreThanThreeFiles: true).tier(risk: .normal) == .standard)
        #expect(DifficultyEvidence(multipleModules: true, moreThanThreeFiles: true, unclearApproach: true).tier(risk: .normal) == .intensive)
        #expect(DifficultyEvidence().tier(risk: .sensitive) == .standard)
        #expect(DifficultyEvidence().isUncertain)
        #expect(!DifficultyEvidence(multipleModules: false, moreThanThreeFiles: false, unclearApproach: false, noReproducibleTest: false).isUncertain)
    }

    @Test func diffNamesTaskAndEdgeChanges() throws {
        let old = try PlanValidator.validate(PlanDraft(tasks: [task("A", writes: ["a"]), task("B", after: ["A"], writes: ["b"])])).get()
        var changedB = task("B", writes: ["b2"])
        changedB.predecessors = []
        let new = try PlanValidator.validate(PlanDraft(tasks: [task("A", writes: ["a"]), changedB, task("C", after: ["B"], writes: ["c"])])).get()
        let diff = PlanDiff(from: old, to: new)
        #expect(diff.addedTasks == ["C"] && diff.removedTasks.isEmpty && diff.changedTasks == ["B"])
        #expect(diff.addedEdges == [PlanEdge(predecessor: "B", successor: "C")])
        #expect(diff.removedEdges == [PlanEdge(predecessor: "A", successor: "B")])
        #expect(try PlanDraft(tasks: [task("A", writes: ["a"])]).digest() == PlanDraft(tasks: [task("A", writes: ["a"])]).digest())
    }
}

@Suite struct RouterTests {
    let fpX = "x", fpY = "y"

    @Test func firstRepairEscalateAndLimit() {
        #expect(Router.nextTier(planned: .standard, history: []).outcome == .first(.standard))
        let one = [CountedAttempt(tier: .standard, failure: .redTest(fingerprint: fpX))]
        #expect(Router.nextTier(planned: .standard, history: one).outcome == .repair(.standard))
        let two = one + [CountedAttempt(tier: .standard, failure: .redTest(fingerprint: fpX))]
        let escalated = Router.nextTier(planned: .standard, history: two)
        #expect(escalated.outcome == .escalate(.intensive) && escalated.rule == "repeatedFingerprint" && escalated.remainingAttempts == 1)
        let different = one + [CountedAttempt(tier: .standard, failure: .providerFailed(fingerprint: fpY))]
        #expect(Router.nextTier(planned: .standard, history: different).outcome == .repair(.standard))
        let three = two + [CountedAttempt(tier: .intensive, failure: .redTest(fingerprint: fpY))]
        #expect(Router.nextTier(planned: .standard, history: three).outcome == .userDecision(reason: "attemptLimit"))
    }

    @Test func secondBlockingFindingEscalatesAndTopTierNeedsTheUser() {
        let blocking = [CountedAttempt(tier: .fast, failure: .blockingFinding), CountedAttempt(tier: .fast, failure: .blockingFinding)]
        #expect(Router.nextTier(planned: .fast, history: blocking).outcome == .escalate(.standard))
        let top = [CountedAttempt(tier: .intensive, failure: .redTest(fingerprint: fpX)), CountedAttempt(tier: .intensive, failure: .redTest(fingerprint: fpX))]
        #expect(Router.nextTier(planned: .intensive, history: top).outcome == .userDecision(reason: "topTierReached"))
    }

    @Test func fingerprintsIgnoreVolatileDetails() {
        let a = "Test failed at /private/tmp/wt-1/Sources/A.swift:12 commit 1a2b3c4d5e after 0.35 s"
        let b = "Test failed at /private/tmp/wt-2/Sources/A.swift:98 commit ffeeddccbb after 1.20 s"
        #expect(FailureFingerprint.of(a) == FailureFingerprint.of(b))
        #expect(FailureFingerprint.normalize("in /tmp/wt/x.swift:3", worktreeRoot: "/tmp/wt") == "in <wt>/x.swift:<n>")
        #expect(FailureFingerprint.of("assertion A") != FailureFingerprint.of("assertion B"))
    }

    @Test func profilesAreChosenSmallestUsableFirst() {
        let fast = ModelProfile(provider: .fake, role: .author, tier: .fast, model: "f", verifiedAt: 1)
        let std = ModelProfile(provider: .fake, role: .author, tier: .standard, model: "s", verifiedAt: 1)
        let unverified = ModelProfile(provider: .fake, role: .author, tier: .standard, model: "u")
        let disabled = ModelProfile(provider: .fake, role: .author, tier: .intensive, model: "d", verifiedAt: 1, disabledReason: "quota")
        let all = [disabled, unverified, std, fast]
        #expect(ModelProfile.smallest(all, provider: .fake, role: .author, atLeast: .fast) == fast)
        #expect(ModelProfile.smallest(all, provider: .fake, role: .author, atLeast: .standard) == std)
        #expect(ModelProfile.smallest(all, provider: .fake, role: .author, atLeast: .intensive) == nil)
        #expect(ModelProfile.smallest(all, provider: .codex, role: .author, atLeast: .fast) == nil)
    }

    @Test func startRetryDelaysAreDeterministicAndGrow() {
        let task = TaskID()
        let d0 = StartRetry.delayMs(task: task, retry: 0), d1 = StartRetry.delayMs(task: task, retry: 1)
        #expect(d0 == StartRetry.delayMs(task: task, retry: 0))
        #expect((30_000..<45_000).contains(d0) && (60_000..<90_000).contains(d1))
    }
}
