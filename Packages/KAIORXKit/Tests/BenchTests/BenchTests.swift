import Foundation
import Testing
@testable import Bench
import Workbench

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

    @Test func replayOpensTheLastViewWithoutReadingEveryDelta() async throws {
        // The app's path at a twentieth of its sizes: pages of 25, open up to 50 events.
        let limits = TimelinePaging.Limits(pageSize: 25, openRows: 30, openEvents: 50)
        let results = try await ReplayBench.run(.init(deltas: 400, repeats: 1, limits: limits))
        let full = try #require(results.first { $0.metric == "events a full history load reads" }?.value)
        #expect(full >= 402)  // started, 400 deltas, completed, plus state changes
        let read = try #require(results.first { $0.metric == "events the last view reads" })
        #expect(read.value == 50 && read.verdict == .met)
        #expect(results.first { $0.metric == "last-view rows unlike the full history" }?.verdict == .met)
        #expect(results.first { $0.metric == "monitor: last view on selection" }?.stats?.count == 1)
        #expect(results.first { $0.metric == "monitor: full history (comparison)" }?.stats?.count == 1)
        // A run shorter than the opening limits is read whole: that is no saving.
        let short = try await ReplayBench.run(.init(deltas: 20, repeats: 1, limits: limits))
        #expect(short.first { $0.metric == "events the last view reads" }?.verdict == .missed)
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
