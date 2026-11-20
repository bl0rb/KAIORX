import Domain
import Foundation
import Memory
import ProcessHost
import Providers
import Synchronization
import Testing
@testable import Orchestration
@testable import Storage
@testable import Workspace

/// Regression tests for the package G check round.
@Suite struct MemoryRetrievalCheckTests {
    func evidence(_ m: MemoryHarness, _ revision: MemoryRevisionRecord) async throws -> MemorySourceID {
        try #require(try await m.store.memorySources(revision.id, viewer: nil).first?.id)
    }

    @Test func pinsAndGraphNeighboursFollowTheContradictionRule() async throws {
        let m = try await MemoryHarness()
        let pin = try await m.note(.project, "Pin", "zebrapin immer", pinned: true)
        let counter = try await m.note(.project, "Gegen", "zebrapin nie")
        try await m.grantAll([pin])
        try await m.store.addMemoryEdge(from: pin.id, to: counter.id, type: .contradicts, evidence: try await evidence(m, pin))
        let empty = try await m.store.memoryCandidates(m.reader(m.t1), query: nil, stale: [])
        #expect(empty.pins.isEmpty && empty.withheld == [pin.id])

        let hit = try await m.note(.project, "Treffer", "zebrahit steht hier")
        let neighbour = try await m.note(.project, "Nachbar", "nachbartext ohne Suchwort")
        let conflict = try await m.note(.project, "Konflikt", "widerspricht dem Nachbarn")
        try await m.grantAll([hit, neighbour])
        try await m.store.addMemoryEdge(from: hit.id, to: neighbour.id, type: .dependsOn, evidence: try await evidence(m, hit))
        try await m.store.addMemoryEdge(from: neighbour.id, to: conflict.id, type: .contradicts, evidence: try await evidence(m, neighbour))
        let c = try await m.store.memoryCandidates(m.reader(m.t1), query: QueryTerms.ftsQuery(["zebrahit"]), stale: [])
        #expect(c.hits.map(\.revisionID) == [hit.id])
        #expect(!c.neighbours.values.map(\.revisionID).contains(neighbour.id))
        #expect(try await m.hits(m.reader(m.t1), "zebrahit") == [hit.id])
    }

    @Test func anExpiredContradictorWithholdsTheFact() async throws {
        let m = try await MemoryHarness()
        let fact = try await m.note(.project, "Fakt", "zebraexp gilt")
        let expired = try await m.store.addMemory(MemoryDraft(
            scope: .project, projectID: m.project, title: "Alt", body: "zebraexp galt", sources: [.user(at: 1)], validUntil: m.h.clock.now - 1
        ))
        try await m.grantAll([fact, expired])
        try await m.store.addMemoryEdge(from: fact.id, to: expired.id, type: .contradicts, evidence: try await evidence(m, fact))
        let c = try await m.store.memoryCandidates(m.reader(m.t1), query: QueryTerms.ftsQuery(["zebraexp"]), stale: [])
        #expect(c.hits.isEmpty && c.withheld == [fact.id])
    }

    @Test func dottedTermsAndIdentifiersFromTheTextsAreFound() async throws {
        let m = try await MemoryHarness()
        let version = try await m.note(.project, "Umstieg", "Der Umstieg auf Swift 6.2 braucht strikte Nebenläufigkeit.")
        let digest = try await m.note(.project, "Prüfsumme", "Wir bilden sha256Digest über den Inhalt.")
        try await m.grantAll([version, digest])
        #expect(try await m.store.searchMemory(QueryTerms.ftsQuery(["6.2"])!, project: m.project).map(\.id) == [version.id])
        #expect(try await m.store.searchMemory(QueryTerms.ftsQuery(["Digest"])!, project: m.project).map(\.id) == [digest.id])
        let terms = QueryTerms.extract(
            texts: ["Fix the crash when saving user settings in preferences window after login timeout", "Make buildCandidate robust"],
            paths: ["Sources/A/One.swift", "Sources/B/Two.swift", "docs/adr", "Tests/C/Three.swift"]
        )
        #expect(Array(terms.prefix(5)) == ["buildCandidate", "One.swift", "Two.swift", "adr", "Three.swift"])
    }
}

@Suite struct MemoryDispatchCheckTests {
    @Test func aDeselectionAfterRenderingRefusesTheDispatch() async throws {
        let m = try await MemoryHarness()
        let a = try await m.note(.project, "Eins", "zebrasel eins")
        let b = try await m.note(.project, "Zwei", "zebrasel zwei")
        try await m.grantAll([a, b])
        let attempt = try await m.attempt(m.t1)
        let manifest = try await m.broker.prepare(attempt: attempt, reviewerProvider: .fake, query: MemoryQuery(texts: ["zebrasel"]))
        #expect(manifest.items.count == 2)
        // The text was rendered from both items; the user deselects one before the transaction.
        try await m.store.deselectManifestItems(manifest.id, positions: [1])
        await #expect(throws: MemoryError.dispatchRefused("manifestChanged")) {
            try await m.store.dispatchManifest(manifest.id, stale: [], rendered: manifest.items)
        }
        #expect(try await m.store.attempt(attempt)?.state == .reserved)
        #expect(try await m.store.manifest(manifest.id).delivery == .revoked)
    }

    func spec(_ m: MemoryHarness, _ attempt: AttemptID) -> AttemptSpec {
        AttemptSpec(
            attemptID: attempt, taskID: m.t1, projectID: m.project, role: .author, provider: .claude, runMode: .automatic,
            modelProfile: "p", effectiveModel: "m", prompt: "x"
        )
    }

    func dispatched(_ m: MemoryHarness) async throws -> AttemptID {
        let note = try await m.note(.project, "Start", "zebrastart")
        try await m.grantAll([note])
        let attempt = try await m.attempt(m.t1)
        let manifest = try await m.broker.prepare(attempt: attempt, reviewerProvider: .fake, query: MemoryQuery(texts: ["zebrastart"]))
        _ = try await m.broker.dispatch(manifest.id)
        #expect(try await m.store.attempt(attempt)?.state == .starting)
        return attempt
    }

    @Test func aCancelBetweenDispatchAndLaunchEndsTheAttempt() async throws {
        let m = try await MemoryHarness()
        let attempt = try await dispatched(m)
        try await m.h.coordinator.cancel(attempt, reason: "user")
        #expect(try await m.store.attempt(attempt)?.state == .cancelling)
        let result = try await m.h.coordinator.launch(attempt, spec: spec(m, attempt))
        #expect(result == .cancelledBeforeStart(attempt))
        #expect(try await m.store.attempt(attempt)?.state == .cancelled)
    }

    @Test func aMissingAdapterAfterDispatchFailsTheAttempt() async throws {
        let m = try await MemoryHarness()
        let attempt = try await dispatched(m)
        let bare = RunCoordinator(store: m.store, adapters: [])
        guard case .failedToStart = try await bare.launch(attempt, spec: spec(m, attempt)) else { Issue.record("not failed"); return }
        let record = try #require(try await m.store.attempt(attempt))
        #expect(record.state == .failed && record.errorClass == "adapterUnavailable")
    }

    @Test func aLateStartedEventDoesNotRestoreARevokedSessionHandle() async throws {
        let m = try await MemoryHarness()
        let attempt = try await dispatched(m)
        let revision = try #require(try await m.store.manifests(attempt: attempt).first?.items.first?.revisionID)
        let grant = try #require(try await m.store.grantMemory([revision], to: m.project, provider: .claude).first)
        // Revoked while still starting: the late `started` neither restores the handle nor in `cancelling`.
        #expect(try await m.store.revokeMemoryGrant(grant) == [attempt])
        _ = try await m.store.ingest(.started(sessionID: "sess-1"), attemptID: attempt)
        #expect(try await m.store.attempt(attempt)?.sessionHandle == nil)

        let second = try await dispatchedOnT2(m)
        let revision2 = try #require(try await m.store.manifests(attempt: second).first?.items.first?.revisionID)
        let grant2 = try #require(try await m.store.grantMemory([revision2], to: m.project, provider: .claude).first)
        _ = try await m.broker.revokeGrant(grant2)
        #expect(try await m.store.attempt(second)?.state == .cancelling)
        _ = try await m.store.ingest(.started(sessionID: "sess-2"), attemptID: second)
        #expect(try await m.store.attempt(second)?.sessionHandle == nil)
    }

    func dispatchedOnT2(_ m: MemoryHarness) async throws -> AttemptID {
        let note = try await m.note(.project, "Zweiter", "zebrazwei")
        try await m.grantAll([note])
        let attempt = try await m.attempt(m.t2)
        let manifest = try await m.broker.prepare(attempt: attempt, reviewerProvider: .fake, query: MemoryQuery(texts: ["zebrazwei"]))
        _ = try await m.broker.dispatch(manifest.id)
        return attempt
    }

    @Test func gitSourcesRecordTheResolvedCommit() async throws {
        let m = try await MemoryHarness()
        let head = try await SchedulerHarness.gitOutput("git rev-parse HEAD", in: m.h.checkout, h: m.h)
        let (source, _) = try await m.broker.gitSource(project: m.project, commit: "HEAD", path: "src/a.swift", at: 1)
        #expect(source.gitOID == head)
        await #expect(throws: MemoryBrokerError.invalidCommit("--output=x")) {
            _ = try await m.broker.gitSource(project: m.project, commit: "--output=x", path: "src/a.swift", at: 1)
        }
        await #expect(throws: MemoryBrokerError.invalidCommit("nirgendwo")) {
            _ = try await m.broker.gitSource(project: m.project, commit: "nirgendwo", path: "src/a.swift", at: 1)
        }
    }
}

@Suite struct MemoryStoreCheckTests {
    @Test func bulkImportIsIdempotent() async throws {
        let m = try await MemoryHarness()
        let draft = MemoryDraft(scope: .project, projectID: m.project, title: "Import", body: "Einmal", sources: [.user(at: 1)])
        let first = try await m.store.addMemories([draft, draft])
        #expect(first.count == 2 && first[0].id == first[1].id)
        #expect(try await m.store.addMemories([draft]).map(\.id) == [first[0].id])
        // A draft that differs only in its pin, or repeats a retired import, is a new revision.
        var pinned = draft
        pinned.pinned = true
        let other = try await m.store.addMemories([pinned])
        #expect(other[0].id != first[0].id)
        let edited = try await m.store.reviseMemory(other[0].entryID, expectedActive: other[0].id, title: "Import", body: "Bearbeitet", kind: .observation, sources: [.user(at: 2)])
        #expect(try await m.store.addMemory(pinned).id == edited.id)
        try await m.store.retireMemory(first[0].id)
        let revived = try await m.store.addMemory(draft)
        #expect(revived.id != first[0].id && revived.state == .active)
        await #expect(throws: MemoryError.invalidScope) {
            _ = try await m.store.addMemories([MemoryDraft(scope: .task, projectID: m.otherProject, taskID: m.t1, title: "x", body: "y", sources: [.user(at: 1)])])
        }
    }

    @Test func noSourceRevealsAnotherProject() async throws {
        let m = try await MemoryHarness()
        try await m.store.setMemoryPolicy(project: m.otherProject, allowGlobal: true, providers: [.claude, .fake])
        let foreign = try await m.note(.project, "Fremd", "Interna", project: m.otherProject)
        // A project entry cannot derive from another project's revision.
        await #expect(throws: MemoryError.foreignUpstream(foreign.id)) {
            _ = try await m.store.addMemory(MemoryDraft(scope: .project, projectID: m.project, title: "Abgeleitet", body: "aus fremd",
                sources: [MemorySourceDraft(kind: .derived, observedAt: 2, upstreamRevisionID: foreign.id)]))
        }
        // A global note's user source names its origin only to that project.
        let global = try await m.store.addMemory(MemoryDraft(scope: .global, title: "Regel", body: "Allgemein",
            sources: [MemorySourceDraft(kind: .user, observedAt: 3, locator: "secret/plan.md", originProjectID: m.otherProject)]))
        let seenByA = try await m.store.memorySources(global.id, viewer: m.project)
        #expect(seenByA.allSatisfy { $0.draft.originProjectID == nil && $0.draft.locator == "crossProject" })
        #expect(try await m.store.memorySources(global.id, viewer: m.otherProject).first?.draft.locator == "secret/plan.md")
        // A derivation from A that also names B as its origin shows no details to A.
        let ownNote = try await m.note(.project, "Eigen", "Inhalt aus A")
        let mixed = try await m.store.addMemory(MemoryDraft(scope: .global, title: "Gemischt", body: "Zwei Herkünfte",
            sources: [MemorySourceDraft(kind: .derived, observedAt: 5, originProjectID: m.otherProject, upstreamRevisionID: ownNote.id)]))
        #expect(try await m.store.memorySources(mixed.id, viewer: m.project).map(\.draft.locator) == ["crossProject"])
        // Without any origin a global note's sources still show no details in a project.
        let loose = try await m.store.addMemory(MemoryDraft(scope: .global, title: "Lose", body: "Ohne Herkunft",
            sources: [MemorySourceDraft(kind: .user, observedAt: 4, locator: "privat/notiz.md")]))
        #expect(try await m.store.memorySources(loose.id, viewer: m.project).map(\.draft.locator) == ["crossProject"])
        #expect(try await m.store.memorySources(loose.id, viewer: nil).map(\.draft.locator) == ["privat/notiz.md"])
    }

    @Test func bootstrapRunsPendingPurgeJobs() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "kaiorx-boot-\(UUID().uuidString)").path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let path = base + "/m.sqlite"
        let backup = path + ".backup-v5-1"
        do {
            let store = try Store(path: path, clock: { 10 })
            let project = ProjectID()
            try await store.execute(Command(.openProject(id: project, name: "P", rootLocator: base)))
            let note = try await store.addMemory(MemoryDraft(scope: .project, projectID: project, title: "t", body: "geheimnisvoll", sources: [.user(at: 1)]))
            FileManager.default.createFile(atPath: backup, contents: Data("old copy geheimnisvoll".utf8))
            _ = try await store.forgetMemory([note.entryID])
            await store.close()
        }
        let store = try Store(path: path, clock: { 20 })
        _ = try await RunCoordinator(store: store, adapters: []).bootstrap()
        #expect(!FileManager.default.fileExists(atPath: backup))
        #expect(try await store.runPurgeJobs().done.isEmpty)
    }
}

@Suite struct MemoryForgetCheckTests {
    /// The author attempt received the marker; its candidate's tests printed it and a reviewer
    /// ran but has not recorded its review when the entry is forgotten.
    @Test func forgettingCoversCandidateEventsReviewersAndLaterTexts() async throws {
        let h = try await IntegrationHarness()
        let store = h.base.store
        let marker = "tapirGeheim"
        try await store.setMemoryPolicy(project: h.base.project, allowGlobal: false, providers: [.claude, .fake])
        let note = try await store.addMemory(MemoryDraft(scope: .project, projectID: h.base.project, title: "Quelle", body: "Wissen: \(marker)", sources: [.user(at: 1)]))
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        let author = try #require(tree.attemptID)
        let excerpt = "Wissen: \(marker)"
        _ = try await store.prepareManifest(attempt: author, reviewerProvider: .fake, baseOID: nil, items: [ManifestItemRecord(
            position: 0, revisionID: note.id, byteFrom: 0, byteTo: excerpt.utf8.count, excerptDigest: Canonical.sha256Hex(Data(excerpt.utf8)),
            tokenEstimate: 5, reason: .lexical, rank: 0
        )])
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        let printing = TestProfile(executable: "/bin/sh", arguments: ["-c", "echo \(marker); exit 0"])
        _ = try await h.integration.runTests(candidate.id, profile: printing)
        let reviewer = try await h.integration.startReview(candidate.id, provider: .fake, model: "reviewer", criteria: "ok")
        _ = try await h.coordinator.waitUntilFinished(reviewer)

        let oidBefore = try #require(try await store.candidate(candidate.id)?.candidateOID)
        let early = try await store.recordReview(
            candidate: candidate.id, oid: oidBefore, reviewerAttemptID: nil, origin: .userImported, reviewerProvider: nil, status: .approved,
            summary: "ok", findings: [FindingDraft(severity: .minor, path: "a.txt", line: 1, impact: "stil", suggestion: "umbenennen")]
        )
        let finding = try #require(try await store.findings(candidate: candidate.id).first { _ in true })
        _ = early
        _ = try await store.decideFinding(finding.id, .accepted, reason: "passt, siehe \(marker)")

        _ = try await store.forgetMemory([note.entryID])
        #expect(try await store.attempt(reviewer)?.state == .succeeded)
        // No new reviewer for a candidate whose author's content was forgotten.
        await #expect(throws: MemoryError.self) {
            _ = try await h.integration.startReview(candidate.id, provider: .fake, model: "reviewer", criteria: "ok")
        }
        #expect(try await store.findings(candidate: candidate.id).first { $0.id == finding.id }?.reason == Store.purgedText)
        _ = try await store.decideFinding(finding.id, .rejected, reason: "wieder \(marker)")
        let purgedReviewer = try await store.events(limit: 100_000).filter { $0.attemptID == reviewer }
        #expect(purgedReviewer.contains { $0.kind == .contentPurged })
        // Texts recorded after the forget are not stored either.
        let oid = try #require(try await store.candidate(candidate.id)?.candidateOID)
        let review = try await store.recordReview(
            candidate: candidate.id, oid: oid, reviewerAttemptID: nil, origin: .userImported, reviewerProvider: nil, status: .changesRequested,
            summary: "sieht \(marker)", findings: [FindingDraft(severity: .blocking, path: "a.txt", line: 1, impact: marker, suggestion: marker)]
        )
        #expect(review.summary == Store.purgedText)
        let test = try await store.recordTest(
            candidate: candidate.id, oid: oid, profileDigest: "p", status: .failed, exitCode: 1, changedTestInputs: [], summary: "wieder \(marker)"
        )
        #expect(test.summary == Store.purgedText)
        try await store.transitionCandidate(candidate.id, to: .rejected, reason: "tests: \(marker)")
        let events = try await store.events(limit: 100_000)
        #expect(events.allSatisfy { $0.payload.map { !String(decoding: $0, as: UTF8.self).contains(marker) } ?? true })
        await store.close()
        for suffix in ["", "-wal"] {
            let data = FileManager.default.contents(atPath: await store.path + suffix) ?? Data()
            #expect(data.range(of: Data(marker.utf8)) == nil, "\(suffix)")
        }
    }

    /// A failing test puts its stderr into the candidate's rejection reason, an event without
    /// an attempt: forgetting removes that payload too.
    @Test func forgettingPurgesCandidateStateChangeReasons() async throws {
        let h = try await IntegrationHarness()
        let store = h.base.store
        let marker = "gnuGeheim"
        try await store.setMemoryPolicy(project: h.base.project, allowGlobal: false, providers: [.claude, .fake])
        let note = try await store.addMemory(MemoryDraft(scope: .project, projectID: h.base.project, title: "Quelle", body: "Wissen: \(marker)", sources: [.user(at: 1)]))
        let (_, tree) = try await h.authorResult("echo eins > a.txt")
        let author = try #require(tree.attemptID)
        let excerpt = "Wissen: \(marker)"
        _ = try await store.prepareManifest(attempt: author, reviewerProvider: .fake, baseOID: nil, items: [ManifestItemRecord(
            position: 0, revisionID: note.id, byteFrom: 0, byteTo: excerpt.utf8.count, excerptDigest: Canonical.sha256Hex(Data(excerpt.utf8)),
            tokenEstimate: 5, reason: .lexical, rank: 0
        )])
        guard case .built(let candidate) = try await h.integration.buildCandidate(from: tree.id) else { Issue.record("not built"); return }
        let failing = TestProfile(executable: "/bin/sh", arguments: ["-c", "echo \(marker) >&2; exit 1"])
        _ = try await h.integration.runTests(candidate.id, profile: failing)
        #expect(try await store.candidate(candidate.id)?.state == .rejected)
        func leaks() async throws -> Bool {
            try await store.events(limit: 100_000).contains { $0.payload.map { String(decoding: $0, as: UTF8.self).contains(marker) } ?? false }
        }
        #expect(try await leaks())
        _ = try await store.forgetMemory([note.entryID])
        #expect(try await !leaks())
        await store.close()
        for suffix in ["", "-wal"] {
            let data = FileManager.default.contents(atPath: await store.path + suffix) ?? Data()
            #expect(data.range(of: Data(marker.utf8)) == nil, "\(suffix)")
        }
    }

    /// Two different provider failures whose reports a forget removed are not one repeated
    /// failure for the router.
    @Test func purgedFailureReportsDoNotCountAsARepeat() async throws {
        let words = Mutex(["alpha", "beta", "gamma", "delta"])
        let h = try await SchedulerHarness(script: { _ in
            let word = words.withLock { $0.removeFirst() }
            return FakeScript(steps: [.emit(.started(sessionID: "s")), .emit(.completed(.failed(reason: "Fehler \(word) im Parser")))])
        })
        try await h.store.setMemoryPolicy(project: h.project, allowGlobal: false, providers: [.claude, .fake])
        let note = try await h.store.addMemory(MemoryDraft(scope: .project, projectID: h.project, title: "Wissen", body: "Wissen", sources: [.user(at: 1)]))
        try await h.activate([planTask("A")])
        let scheduler = h.scheduler()
        for round in 0..<2 {
            _ = try await scheduler.tick()
            let last = try #require(try await h.authorAttempts("A").last)
            if round == 0 {
                _ = try await h.store.prepareManifest(attempt: last.id, reviewerProvider: nil, baseOID: nil, items: [ManifestItemRecord(
                    position: 0, revisionID: note.id, byteFrom: 0, byteTo: 6, excerptDigest: Canonical.sha256Hex(Data("Wissen".utf8)),
                    tokenEstimate: 2, reason: .lexical, rank: 0
                )])
            }
            _ = try await h.coordinator.waitUntilFinished(last.id)
        }
        let report = try await h.store.forgetMemory([note.entryID])
        #expect(report.revisions == 1)
        _ = try await scheduler.tick()
        let decisions = try await h.store.decisions(task: try await h.task("A").id)
        #expect(decisions.map(\.rule).prefix(3) == ["difficulty", "repair", "repair"])
    }
}
