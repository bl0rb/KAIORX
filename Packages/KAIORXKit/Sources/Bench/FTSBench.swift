import Domain
import Foundation
import Memory
import Storage

/// Beta target: an FTS query over 10,000 active memory chunks within 200 ms (p95), plus a load
/// test at 50,000. Times the real retrieval path of an attempt's memory handover
/// (`QueryTerms` → `Store.memoryCandidates` → `Selector.select`, as `MemoryBroker.prepare` does),
/// once as the owner's view and once as a provider reader with grants (the costlier path).
public enum FTSBench {
    public struct Options: Sendable {
        public var chunks: Int
        public var coldQueries: Int
        public var target: Double?

        public init(chunks: Int, coldQueries: Int = 10, target: Double? = 200) {
            self.chunks = chunks
            self.coldQueries = coldQueries
            self.target = target
        }
    }

    /// Words of the synthetic corpus: every note has some common words, a few medium ones and one
    /// rare identifier, so the queries cover all three kinds of selectivity.
    static let common = ["projekt", "aufgabe", "test", "review", "commit", "datei", "modul", "fehler", "ergebnis", "status"]
    static let medium = (0..<100).map { "thema\($0)" }

    /// One note, under `Chunker.maxBytes`, so each note is exactly one chunk.
    static func body(_ index: Int) -> String {
        var words: [String] = []
        for position in 0..<48 {
            switch position % 6 {
            case 0: words.append(common[(index + position) % common.count])
            case 3: words.append(medium[(index * 7 + position) % medium.count])
            default: words.append("wort\((index * 31 + position * 17) % 997)")
            }
        }
        // A rare token per note (`zk4711q`): one plain word, so the query does not split it into
        // common identifier parts (`selectorKey4711` would also match `selector` everywhere).
        words.append("zk\(index)q")
        return words.joined(separator: " ") + "."
    }

    /// The fixed query mix: rare identifiers, medium topics, common words and mixed questions.
    static func queries(chunks: Int) -> [String] {
        let rare = (0..<10).map { "Wo steht zk\(($0 * 977 + 13) % chunks)q?" }
        let mid = (0..<10).map { "Notizen zu thema\($0 * 9) und thema\($0 * 9 + 4)" }
        let wide = (0..<10).map { "\(common[$0]) \(common[($0 + 3) % common.count]) im \(common[($0 + 5) % common.count])" }
        return rare + mid + wide
    }

    public static func run(_ options: Options) async throws -> [BenchResult] {
        let folder = try benchFolder("fts")
        defer { removeFolder(folder) }
        let path = folder + "/bench.sqlite"
        var store = try Store(path: path)
        let project = ProjectID()
        try await store.execute(Command(.openProject(id: project, name: "Bench", rootLocator: folder)))

        // Seed in batches of 1,000 notes (one transaction each); every note is one chunk.
        let seedStart = ContinuousClock.now
        var revisions: [MemoryRevisionID] = []
        var chunkCount = 0
        for batch in stride(from: 0, to: options.chunks, by: 1_000) {
            let drafts = (batch..<min(batch + 1_000, options.chunks)).map { index in
                MemoryDraft(scope: .project, projectID: project, title: "Notiz \(index)", body: body(index), sources: [.user(at: Int64(index))])
            }
            chunkCount += drafts.reduce(0) { $0 + Chunker.chunks($1.body).count }
            revisions += try await store.addMemories(drafts).map(\.id)
        }
        let seedDuration = ContinuousClock.now - seedStart
        guard chunkCount == options.chunks, revisions.count == options.chunks else {
            throw BenchError.unexpected("seeded \(revisions.count) notes with \(chunkCount) chunks, expected \(options.chunks)")
        }
        try await store.setMemoryPolicy(project: project, allowGlobal: false, providers: [.claude, .codex])
        for provider in [ProviderKind.claude, .codex] {
            for batch in stride(from: 0, to: revisions.count, by: 5_000) {
                try await store.grantMemory(Array(revisions[batch..<min(batch + 5_000, revisions.count)]), to: project, provider: provider)
            }
        }

        let texts = queries(chunks: options.chunks)
        let owner = MemoryReader(projectID: project, taskID: nil, provider: nil)
        let provider = MemoryReader(projectID: project, taskID: nil, provider: .claude, reviewerProvider: .codex)

        /// Time, selected excerpts and raw FTS hits of one retrieval.
        func query(_ reader: MemoryReader, _ text: String) async throws -> (Duration, Int, Int) {
            let start = ContinuousClock.now
            let fts = QueryTerms.ftsQuery(QueryTerms.extract(texts: [text]))
            let candidates = try await store.memoryCandidates(reader, query: fts, stale: [])
            let selected = Selector.select(pins: candidates.pins, hits: candidates.hits, neighbours: candidates.neighbours, limits: SelectionLimits())
            return (ContinuousClock.now - start, selected.count, candidates.hits.count)
        }

        // Warm: one pass to load the pages, then the measured passes.
        for text in texts { _ = try await query(owner, text) }
        var ownerSamples: [Duration] = []
        var providerSamples: [Duration] = []
        var empty = 0
        var rareHits: [Int] = []
        for _ in 0..<3 {
            for (position, text) in texts.enumerated() {
                let (ownerTime, ownerFound, _) = try await query(owner, text)
                ownerSamples.append(ownerTime)
                let (providerTime, providerFound, hits) = try await query(provider, text)
                providerSamples.append(providerTime)
                if ownerFound == 0 { empty += 1 }
                if providerFound == 0 { empty += 1 }
                if position < 10 { rareHits.append(hits) }
            }
        }
        // Cold SQLite page cache: close and reopen before each query (the OS file cache stays warm).
        var coldSamples: [Duration] = []
        for index in 0..<options.coldQueries {
            await store.close()
            store = try Store(path: path)
            let (time, found, _) = try await query(provider, texts[index % texts.count])
            coldSamples.append(time)
            if found == 0 { empty += 1 }
        }
        await store.close()

        let scenario = "fts-\(options.chunks)"
        let note = "\(options.chunks) active chunks, \(texts.count) queries × 3 passes, retriever v\(Retriever.version)"
        return [
            BenchResult(scenario: scenario, metric: "seed", value: LatencyStats.milliseconds(seedDuration), notes: ["addMemories in batches of 1,000"]),
            .p95(scenario, "query (owner view, warm)", ownerSamples, below: options.target, notes: [note]),
            .p95(scenario, "query (provider with grants, warm)", providerSamples, below: options.target, notes: [note, "the path an attempt's memory handover takes"]),
            .p95(scenario, "query (provider, cold page cache)", coldSamples, below: options.target, notes: ["store reopened before each query; OS file cache stays warm"]),
            BenchResult(
                scenario: scenario, metric: "retrievals without a hit", value: Double(empty), unit: "count", target: "0",
                verdict: empty == 0 ? .met : .missed, notes: ["owner, provider and cold; every query matches the corpus, so an empty result means a broken path"]
            ),
            BenchResult(
                scenario: scenario, metric: "FTS hits of a rare-token query", value: rareHits.isEmpty ? 0 : Double(rareHits.max()!), unit: "count",
                notes: ["10 of the 30 queries name one note's rare token; the other 20 match many or all notes"]
            ),
        ]
    }
}
