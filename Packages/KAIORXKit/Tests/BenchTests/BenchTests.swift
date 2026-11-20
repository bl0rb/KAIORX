import Foundation
import Testing
@testable import Bench

/// The harness itself at small sizes: every scenario runs, measures what it claims and reports
/// honestly. The figures of the plan come from `kaiorx-bench --full` in a release build.
@Suite(.serialized) struct BenchTests {
    @Test func statisticsUseTheNearestRank() {
        let stats = LatencyStats((1...20).map { Duration.milliseconds($0) })
        #expect(stats.count == 20 && stats.p50 == 10 && stats.p95 == 19 && stats.max == 20)
        #expect(LatencyStats([]).count == 0)
        let missed = BenchResult.p95("s", "m", [.milliseconds(300)], below: 250)
        #expect(missed.verdict == .missed && missed.target == "p95 < 250 ms")
        #expect(BenchResult.p95("s", "m", [], below: 250).verdict == .missed)
        #expect(BenchResult.p95("s", "m", [.milliseconds(5)], below: nil).verdict == .info)
    }

    @Test func everyNoteIsExactlyOneChunkAndEveryQueryHits() async throws {
        let results = try await FTSBench.run(.init(chunks: 300, coldQueries: 2))
        let warm = try #require(results.first { $0.metric == "query (provider with grants, warm)" })
        #expect(warm.stats?.count == 90)
        #expect(results.first { $0.metric == "query (provider, cold page cache)" }?.stats?.count == 2)
        #expect(results.first { $0.metric == "retrievals without a hit" }?.verdict == .met)
        // A rare-token query names one note only (it is not split into common parts).
        #expect(results.first { $0.metric == "FTS hits of a rare-token query" }?.value == 1)
    }

    @Test func twoPacedRunsAreMeasuredFromReceiptToTheAppState() async throws {
        let results = try await EventLatencyBench.run(.init(deltasPerRun: 15, interval: .milliseconds(10)))
        let state = try #require(results.first { $0.metric == "delta → app state published" }?.stats)
        #expect(state.count == 30)
        #expect(state.p50 > 0)
        #expect((results.first { $0.metric == "delta → monitor timeline (selected run)" }?.stats?.count ?? 0) > 0)
        #expect(results.first { $0.metric == "deltas never shown" }?.value == 0)
        let timelineCount = results.first { $0.metric == "delta → monitor timeline (selected run)" }?.stats?.count ?? 0
        let notListed = Int(results.first { $0.metric == "deltas never in the timeline" }?.value ?? -1)
        #expect(timelineCount + notListed == 15)
    }

    @Test func replayReportsThatTheTimelineReadsEveryDelta() async throws {
        let results = try await ReplayBench.run(.init(deltas: 120, repeats: 1))
        let read = try #require(results.first { $0.metric == "events the timeline reads" })
        #expect((read.value ?? 0) >= 122)  // started, 120 deltas, completed, plus state changes
        #expect(read.verdict == .missed)
    }

    @Test func approvalAndStopAreMeasuredWhileTwoRunsStream() async throws {
        let temporary = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        func benchFolders() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: temporary).filter { $0.hasPrefix("kaiorx-bench-control-") })
        }
        let before = try benchFolders()
        let results = try await ControlBench.run(.init(rounds: 1, interval: .milliseconds(20)))
        for metric in ["approve + publish (one click on the decision sheet)", "approve", "publish after approval", "Stop → acknowledged (cancelling)", "Stop → run ended"] {
            #expect(results.first { $0.metric == metric }?.stats?.count == 1, "\(metric)")
        }
        let shown = results.first { $0.metric == "Stop → shown in the app" }?.stats?.count ?? 0
        #expect(shown + Int(results.first { $0.metric == "Stops never shown within 1 s" }?.value ?? -1) == 1)
        // Sealed worktrees are read-only; the harness still removes its folder.
        let leftovers = try benchFolders().subtracting(before)
        #expect(leftovers.isEmpty, "\(leftovers)")
    }

    @Test func theReportNamesTheMachineButNoUserOrHost() throws {
        let report = BenchReport(date: "d", machine: .current(), build: "b", results: [BenchResult.p95("s", "m", [.milliseconds(1)], below: 250)])
        let text = report.markdown() + String(decoding: try report.json(), as: UTF8.self)
        #expect(text.contains("| s | m | 1 |") && text.contains("met") && text.contains(BenchReport.configuration))
        #expect(!text.contains(NSUserName()) && !text.contains(NSHomeDirectory()))
    }
}
