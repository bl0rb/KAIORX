import Domain
import Foundation
import Memory
import Testing
@testable import Orchestration
@testable import Storage

/// The read set of a retrieval (ADR 0006 §4, §5) against a model computed in the test from what
/// the test itself wrote: scopes, grants per provider and reviewer, revocations, policy, global
/// scope, staleness, expiry and withheld contradictions.
@Suite struct MemoryReadSetTests {
    /// Deterministic generator (SplitMix64), so a failure is reproducible from its seed.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
    }

    struct Note {
        var record: MemoryRevisionRecord
        var pinned: Bool
        var expired: Bool
        var id: MemoryRevisionID { record.id }
    }

    /// What the test knows: notes, live grants (revision, target project, provider), edges.
    struct World {
        var notes: [Note] = []
        var grants = Set<String>()
        var contradicts: [(MemoryRevisionID, MemoryRevisionID)] = []
        var neighbours: [(MemoryRevisionID, MemoryRevisionID)] = []
        var stale = Set<MemoryRevisionID>()

        static func key(_ revision: MemoryRevisionID, _ project: ProjectID, _ provider: ProviderKind) -> String {
            revision.uuidString + project.uuidString + provider.rawValue
        }
    }

    static func evidence(_ m: MemoryHarness, _ revision: MemoryRevisionID) async throws -> MemorySourceID {
        try #require(try await m.store.memorySources(revision, viewer: nil).first?.id)
    }

    static func edgeAllowed(_ a: MemoryRevisionRecord, _ b: MemoryRevisionRecord) -> Bool {
        if a.id == b.id { return false }
        if a.scope == .global || b.scope == .global { return true }
        if a.projectID != b.projectID { return false }
        return !(a.scope == .task && b.scope == .task && a.taskID != b.taskID)
    }

    /// A random corpus over both projects, both tasks and the global scope; every note matches
    /// `zebramix` and stays under 20 per scope, so every usable note is an FTS hit.
    static func world(_ m: MemoryHarness, seed: UInt64) async throws -> World {
        var rng = Seeded(state: seed)
        var world = World()
        let now = m.h.clock.now
        for index in 0..<36 {
            let (scope, project, task): (MemoryScope, ProjectID?, TaskID?) = switch index % 5 {
            case 0: (.task, m.project, m.t1)
            case 1: (.task, m.project, m.t2)
            case 2: (.project, m.project, nil)
            case 3: (.project, m.otherProject, nil)
            default: (.global, nil, nil)
            }
            let roll = Double.random(in: 0..<1, using: &rng)
            let validUntil: Int64? = roll < 0.2 ? now - 1 : roll < 0.3 ? now + 1_000_000 : nil
            let pinned = rng.chance(0.25)
            let record = try await m.store.addMemory(MemoryDraft(
                scope: scope, projectID: project, taskID: task, title: "Notiz \(index)",
                body: "zebramix Eintrag \(index) " + String(repeating: "füll ", count: index % 7),
                sources: [.user(at: Int64(index))], pinned: pinned, validUntil: validUntil
            ))
            world.notes.append(Note(record: record, pinned: pinned, expired: roll < 0.2))
        }
        for note in world.notes {
            let target = note.record.projectID ?? m.project
            for provider in [ProviderKind.claude, .fake, .codex] where rng.chance(0.75) {
                let id = try #require(try await m.store.grantMemory([note.id], to: target, provider: provider).first)
                if rng.chance(0.15) {
                    _ = try await m.store.revokeMemoryGrant(id)
                } else {
                    world.grants.insert(World.key(note.id, target, provider))
                }
            }
            if rng.chance(0.15) { world.stale.insert(note.id) }
        }
        var seen = Set<String>()
        for kind in [MemoryEdgeType.contradicts, .dependsOn, .verifies] {
            var made = 0
            while made < 9 {
                let a = world.notes[Int.random(in: 0..<world.notes.count, using: &rng)].record
                let b = world.notes[Int.random(in: 0..<world.notes.count, using: &rng)].record
                let pair = [a.id.uuidString, b.id.uuidString].sorted().joined()
                guard edgeAllowed(a, b), seen.insert(pair + kind.rawValue).inserted else { continue }
                try await m.store.addMemoryEdge(from: a.id, to: b.id, type: kind, evidence: try await evidence(m, a.id))
                if kind == .contradicts { world.contradicts.append((a.id, b.id)) } else { world.neighbours.append((a.id, b.id)) }
                made += 1
            }
        }
        return world
    }

    /// The expected candidates of `reader`, from the world alone.
    static func expected(
        _ m: MemoryHarness, _ world: World, _ reader: MemoryReader, query: Bool
    ) -> (pins: [MemoryRevisionID], hits: Set<MemoryRevisionID>, neighbours: [MemoryRevisionID: MemoryRevisionID], withheld: Set<MemoryRevisionID>) {
        let policy: [ProjectID: (global: Bool, providers: Set<ProviderKind>)] = [
            m.project: (true, [.claude, .fake]), m.otherProject: (false, [.claude, .fake]),
        ]
        let rules = policy[reader.projectID]!
        if let provider = reader.provider {
            if !rules.providers.contains(provider) { return ([], [], [:], []) }
            if let reviewer = reader.reviewerProvider, !rules.providers.contains(reviewer) { return ([], [], [:], []) }
        }
        let byID = Dictionary(uniqueKeysWithValues: world.notes.map { ($0.id, $0) })
        func inScope(_ note: Note) -> Bool {
            switch note.record.scope {
            case .task: note.record.taskID != nil && note.record.taskID == reader.taskID && note.record.projectID == reader.projectID
            case .project: note.record.projectID == reader.projectID
            case .global: rules.global || reader.provider == nil
            }
        }
        func usable(_ note: Note) -> Bool {
            guard inScope(note), !note.expired else { return false }
            guard let provider = reader.provider else { return true }
            if world.stale.contains(note.id) { return false }
            return ([provider] + (reader.reviewerProvider.map { [$0] } ?? [])).allSatisfy {
                world.grants.contains(World.key(note.id, reader.projectID, $0))
            }
        }
        func blocked(_ note: Note) -> Bool {
            world.contradicts.contains { edge in
                guard edge.0 == note.id || edge.1 == note.id, let other = byID[edge.0 == note.id ? edge.1 : edge.0] else { return false }
                return inScope(other) && !usable(other)
            }
        }
        let open = world.notes.filter { usable($0) && !blocked($0) }
        let pins = open.filter(\.pinned).map(\.id).sorted { $0.uuidString < $1.uuidString }
        guard query else {
            return (pins, [], [:], Set(world.notes.filter { usable($0) && $0.pinned && blocked($0) }.map(\.id)))
        }
        var neighbours: [MemoryRevisionID: MemoryRevisionID] = [:]
        let openIDs = Set(open.map(\.id))
        for hit in open {
            let others = world.neighbours.compactMap { edge -> MemoryRevisionID? in
                edge.0 == hit.id ? edge.1 : edge.1 == hit.id ? edge.0 : nil
            }.sorted { $0.uuidString < $1.uuidString }
            if let first = others.first(where: openIDs.contains) { neighbours[hit.id] = first }
        }
        return (pins, openIDs, neighbours, Set(world.notes.filter { usable($0) && blocked($0) }.map(\.id)))
    }

    static func readers(_ m: MemoryHarness) -> [MemoryReader] {
        [
            MemoryReader(projectID: m.project, taskID: m.t1, provider: .claude, reviewerProvider: .fake),
            MemoryReader(projectID: m.project, taskID: m.t1, provider: .claude),
            MemoryReader(projectID: m.project, taskID: m.t2, provider: .fake, reviewerProvider: .claude),
            MemoryReader(projectID: m.project, taskID: nil, provider: .fake, reviewerProvider: .fake),
            MemoryReader(projectID: m.otherProject, taskID: nil, provider: .claude, reviewerProvider: .fake),
            MemoryReader(projectID: m.project, taskID: m.t1, provider: nil),
            MemoryReader(projectID: m.otherProject, taskID: nil, provider: nil),
            // Not allowed by the policy: nothing at all.
            MemoryReader(projectID: m.project, taskID: m.t1, provider: .codex, reviewerProvider: .claude),
            MemoryReader(projectID: m.project, taskID: m.t1, provider: .claude, reviewerProvider: .codex),
        ]
    }

    @Test(arguments: [UInt64(7), 4711, 90210])
    func everyReaderGetsExactlyItsReadSet(seed: UInt64) async throws {
        let m = try await MemoryHarness()
        let world = try await Self.world(m, seed: seed)
        let byID = Dictionary(uniqueKeysWithValues: world.notes.map { ($0.id, $0.record) })
        var covered = (pins: 0, hits: 0, neighbours: 0, withheld: 0)
        for (position, reader) in Self.readers(m).enumerated() {
            let context = "seed \(seed), reader \(position)"
            let want = Self.expected(m, world, reader, query: true)
            let got = try await m.store.memoryCandidates(reader, query: QueryTerms.ftsQuery(["zebramix"]), stale: world.stale)
            #expect(got.pins.map(\.revisionID) == want.pins, "\(context): pins")
            #expect(Set(got.hits.map(\.revisionID)) == want.hits, "\(context): hits")
            #expect(got.hits.count == want.hits.count, "\(context): one chunk per note")
            #expect(Set(got.withheld) == want.withheld && got.withheld.count == want.withheld.count, "\(context): withheld")
            let rowToRevision = Dictionary(uniqueKeysWithValues: got.hits.map { ($0.chunkRowID, $0.revisionID) })
            let neighbours = Dictionary(uniqueKeysWithValues: got.neighbours.map { (rowToRevision[$0.key]!, $0.value.revisionID) })
            #expect(neighbours == want.neighbours, "\(context): neighbours")
            covered = (covered.pins + got.pins.count, covered.hits + got.hits.count, covered.neighbours + neighbours.count, covered.withheld + got.withheld.count)
            // Deterministic order: BM25, then revision ID.
            for (a, b) in zip(got.hits, got.hits.dropFirst()) {
                #expect(a.score < b.score || (a.score == b.score && a.revisionID.uuidString < b.revisionID.uuidString), "\(context): order")
            }
            // Every excerpt carries its revision's entry, scope and confirmation time.
            for candidate in got.pins + got.hits + Array(got.neighbours.values) {
                let record = try #require(byID[candidate.revisionID])
                #expect(candidate.entryID == record.entryID && candidate.scope == record.scope && candidate.confirmedAt == record.confirmedAt, "\(context)")
            }
            #expect(got == (try await m.store.memoryCandidates(reader, query: QueryTerms.ftsQuery(["zebramix"]), stale: world.stale)), "\(context): repeatable")
            // An empty query yields only pins, and withholds only among them.
            let pinsOnly = Self.expected(m, world, reader, query: false)
            let bare = try await m.store.memoryCandidates(reader, query: nil, stale: world.stale)
            #expect(bare.pins.map(\.revisionID) == pinsOnly.pins && bare.hits.isEmpty && bare.neighbours.isEmpty, "\(context): no query")
            #expect(Set(bare.withheld) == pinsOnly.withheld, "\(context): no query withheld")
        }
        // The corpus exercises every rule, not only the trivial ones.
        #expect(covered.pins > 0 && covered.hits > 0 && covered.neighbours > 0 && covered.withheld > 0, "seed \(seed): \(covered)")
    }

    @Test func notesTheReaderMayNotUseNeverTakeTheTwentySlotsOfAScope() async throws {
        let m = try await MemoryHarness()
        // 25 better matches without a grant (or stale, or expired) and one weaker usable note.
        var blocked: [MemoryRevisionRecord] = []
        for index in 0..<25 {
            blocked.append(try await m.store.addMemory(MemoryDraft(
                scope: .project, projectID: m.project, title: "Stark \(index)", body: "zebraslot zebraslot zebraslot",
                sources: [.user(at: Int64(index))], validUntil: index % 5 == 4 ? m.h.clock.now - 1 : nil
            )))
        }
        let stale = Set(blocked.enumerated().filter { $0.offset % 5 == 3 }.map(\.element.id))
        try await m.grantAll(blocked.enumerated().filter { $0.offset % 5 >= 3 }.map(\.element))
        let weak = try await m.note(.project, "Schwach", "zebraslot steht in einem langen Text mit vielen weiteren Wörtern und noch mehr Wörtern")
        try await m.grantAll([weak])
        let c = try await m.store.memoryCandidates(m.reader(m.t1), query: QueryTerms.ftsQuery(["zebraslot"]), stale: stale)
        #expect(c.hits.map(\.revisionID) == [weak.id])
        // 25 usable notes: exactly the 20 best of the scope, in BM25 and revision order.
        try await m.grantAll(blocked)
        let all = try await m.store.memoryCandidates(m.reader(m.t1), query: QueryTerms.ftsQuery(["zebraslot"]), stale: [])
        let open = blocked.enumerated().filter { $0.offset % 5 != 4 }.map(\.element.id).sorted { $0.uuidString < $1.uuidString }
        #expect(all.hits.map(\.revisionID) == Array(open.prefix(20)))
    }

    /// A reserved author attempt on a fresh task of the harness job (one manifest per attempt).
    static func freshAttempt(_ m: MemoryHarness) async throws -> AttemptID {
        let task = TaskID()
        try await m.store.execute(Command(.createTask(id: task, jobID: m.jobA, title: "T")))
        try await m.store.execute(Command(.transitionTask(id: task, to: .ready, expectedVersion: 1)))
        return try await m.attempt(task)
    }

    @Test func dispatchRechecksExpiryStalenessAndTheReviewerGrant() async throws {
        let m = try await MemoryHarness()
        let soon = try await m.store.addMemory(MemoryDraft(
            scope: .project, projectID: m.project, title: "Bald", body: "zebrabald läuft ab", sources: [.user(at: 1)], validUntil: m.h.clock.now + 1_000
        ))
        let steady = try await m.note(.project, "Fest", "zebrabald bleibt")
        try await m.grantAll([soon, steady])
        let expiring = try await Self.freshAttempt(m)
        let manifest = try await m.broker.prepare(attempt: expiring, reviewerProvider: .fake, query: MemoryQuery(texts: ["zebrabald"]))
        #expect(Set(manifest.items.map(\.revisionID)) == [soon.id, steady.id])
        m.h.clock.advance(2_000)
        await #expect(throws: MemoryError.dispatchRefused("revisionNotUsable:\(soon.id.uuidString)")) {
            try await m.store.dispatchManifest(manifest.id, stale: [])
        }
        #expect(try await m.store.attempt(expiring)?.state == .reserved)
        // A stale item refuses the dispatch.
        let staled = try await Self.freshAttempt(m)
        let next = try await m.broker.prepare(attempt: staled, reviewerProvider: .fake, query: MemoryQuery(texts: ["zebrabald"]))
        #expect(next.items.map(\.revisionID) == [steady.id])
        await #expect(throws: MemoryError.dispatchRefused("revisionNotUsable:\(steady.id.uuidString)")) {
            try await m.store.dispatchManifest(next.id, stale: [steady.id])
        }
        // The reviewer's grant counts as much as the author's: revoking it revokes the package.
        let reviewed = try await Self.freshAttempt(m)
        let last = try await m.broker.prepare(attempt: reviewed, reviewerProvider: .fake, query: MemoryQuery(texts: ["zebrabald"]))
        #expect(last.items.map(\.revisionID) == [steady.id])
        let fakeGrant = try #require(try await m.store.grantMemory([steady.id], to: m.project, provider: .fake).first)
        _ = try await m.store.revokeMemoryGrant(fakeGrant)
        #expect(try await m.store.manifest(last.id).delivery == .revoked)
        let empty = try await Self.freshAttempt(m)
        #expect(try await m.broker.prepare(attempt: empty, reviewerProvider: .fake, query: MemoryQuery(texts: ["zebrabald"])).items.isEmpty)
        // Without a reviewer the author's own grant suffices.
        let solo = try await Self.freshAttempt(m)
        let alone = try await m.broker.prepare(attempt: solo, reviewerProvider: nil, query: MemoryQuery(texts: ["zebrabald"]))
        #expect(alone.items.map(\.revisionID) == [steady.id])
        try await m.store.dispatchManifest(alone.id, stale: [])
        #expect(try await m.store.attempt(solo)?.state == .starting)
    }
}
