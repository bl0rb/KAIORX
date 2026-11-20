import Domain
import Foundation
import Storage
import Synchronization
import Workbench

/// The app's update loop off the main actor (App/AppModel.swift `startPump`, App/ToolViews.swift
/// `load`): `Projector.step`, the `Coalescer` publish gate, a 50 ms pause, and for the selected
/// attempt the monitor timeline that pages `attemptEvents` whenever its activity changes.
/// Records when each cursor and each timeline ordinal became visible.
final class AppPump: Sendable {
    struct Published: Sendable { var at: ContinuousClock.Instant; var cursor: Int64 }
    struct TimelineLoad: Sendable { var at: ContinuousClock.Instant; var attempt: AttemptID; var ordinal: Int; var eventsRead: Int }

    private let store: Store
    private let projector: Projector
    private let selected = Mutex<AttemptID?>(nil)
    private let published = Mutex<[Published]>([])
    private let loads = Mutex<[TimelineLoad]>([])
    private let stopped = Mutex(false)

    init(store: Store) {
        self.store = store
        projector = Projector(store: store)
    }

    func select(_ attempt: AttemptID?) { selected.withLock { $0 = attempt } }
    var publications: [Published] { published.withLock { $0 } }
    var timelineLoads: [TimelineLoad] { loads.withLock { $0 } }

    /// Runs until `stop()`; returns the last published state.
    func run() async throws -> WorkspaceState {
        let origin = ContinuousClock.now
        var coalescer = Coalescer()
        var latest = try await projector.load()
        var shown = latest
        var timeline = Timeline()
        var timelineAttempt: AttemptID?
        while !stopped.withLock({ $0 }) {
            var publish = false
            if let delta = try await projector.step() {
                latest = delta.state
                publish = coalescer.change(at: milliseconds(since: origin), critical: delta.critical, visible: true)
            } else {
                publish = coalescer.tick(at: milliseconds(since: origin), visible: true)
            }
            if publish {
                let previous = shown
                shown = latest
                published.withLock { $0.append(Published(at: .now, cursor: shown.cursor)) }
                // The monitor reloads when the selected attempt's activity changed.
                if let attempt = selected.withLock({ $0 }), attempt != timelineAttempt || shown.lastActivity[attempt] != previous.lastActivity[attempt] {
                    if attempt != timelineAttempt { timeline = Timeline(); timelineAttempt = attempt }
                    var read = 0
                    while true {
                        let page = try await store.attemptEvents(attempt, afterOrdinal: timeline.lastOrdinal, limit: 500)
                        read += page.count
                        timeline.append(page)
                        if page.count < 500 { break }
                    }
                    loads.withLock { $0.append(TimelineLoad(at: .now, attempt: attempt, ordinal: timeline.lastOrdinal, eventsRead: read)) }
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return shown
    }

    func stop() { stopped.withLock { $0 = true } }

    /// The first instant a cursor at or past `seq` was published.
    func visible(seq: Int64) -> ContinuousClock.Instant? {
        publications.first { $0.cursor >= seq }?.at
    }

    /// The first instant the timeline of `attempt` held `ordinal`.
    func inTimeline(_ attempt: AttemptID, ordinal: Int) -> ContinuousClock.Instant? {
        timelineLoads.first { $0.attempt == attempt && $0.ordinal >= ordinal }?.at
    }
}
