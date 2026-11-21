import Domain
import Foundation
import Memory
import Storage

/// One line of an attempt's timeline. Text is always plain text: the view never turns it into
/// links or rich text (provider and repository text is data, Plan/laufzeitvertrag.md).
public struct TimelineRow: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case started, message, tool, usage, diagnostic, limit, completed, state, purged, gap, other
    }

    public var id: Int
    public var kind: Kind
    public var at: Int64
    public var text: String
    /// A tool call and its end are grouped under the call's item ID.
    public var itemID: String?
    /// The text was cut at the row limit.
    public var truncated: Bool

    public init(id: Int, kind: Kind, at: Int64, text: String, itemID: String? = nil, truncated: Bool = false) {
        self.id = id
        self.kind = kind
        self.at = at
        self.text = text
        self.itemID = itemID
        self.truncated = truncated
    }
}

/// An attempt's timeline with bounded memory: at most `maxRows` rows (the oldest drop, with a
/// gap row saying so), message deltas merged per item up to `maxItemBytes`. It can open on the
/// newest page of a run and take older pages in front (`prepend`), so the last view needs no
/// replay of every delta.
public struct Timeline: Sendable, Equatable {
    public let maxRows: Int
    public let maxItemBytes: Int
    public private(set) var rows: [TimelineRow] = []
    /// Ordinal of the last event read: the next page starts after it.
    public private(set) var lastOrdinal = 0
    /// Ordinal of the oldest event read (0 before the first): older pages end before it.
    public private(set) var firstOrdinal = 0
    public private(set) var droppedRows = 0
    private var nextID = 0
    /// Rows taken in front get IDs below zero, so every ID stays unique.
    private var previousID = -1
    private var openMessage: [String: Int] = [:]
    /// Message rows whose text came from a final message: older deltas never change them.
    private var finalRows: Set<Int> = []
    /// Time of the event at `firstOrdinal` (for a gap row in front of it).
    private var firstAt: Int64 = 0
    private var reachedStart = false

    public init(maxRows: Int = 2_000, maxItemBytes: Int = 256 * 1024) {
        self.maxRows = maxRows
        self.maxItemBytes = maxItemBytes
    }

    /// Older events may exist and can still be shown: nothing dropped yet (older rows would
    /// leave a hole) and no empty older page seen.
    public var canLoadOlder: Bool { firstOrdinal > 1 && droppedRows == 0 && !reachedStart }

    /// Appends one page of events (in ordinal order). A missing ordinal becomes a gap row. On an
    /// empty timeline the page may start anywhere: it is then the newest page of the run.
    public mutating func append(_ events: [EventRecord]) {
        for event in events {
            let ordinal = event.ordinal ?? lastOrdinal + 1
            if ordinal <= lastOrdinal { continue }
            if ordinal > lastOrdinal + 1, lastOrdinal > 0 {
                add(TimelineRow(id: 0, kind: .gap, at: event.at, text: Self.gapText(ordinal - lastOrdinal - 1)))
            }
            if firstOrdinal == 0 {
                firstOrdinal = ordinal
                firstAt = event.at
            }
            lastOrdinal = ordinal
            consume(event)
        }
    }

    /// Takes one older page (in ordinal order, before `firstOrdinal`) in front, with the same
    /// rows a replay from the start would show: a message still open at the page's end merges
    /// with its continuation in the shown rows and moves up to where it began (a final text
    /// wins, the byte bound holds for the joined text), a missing ordinal between the page and
    /// the shown rows becomes a gap row, and the oldest rows drop beyond `maxRows`. An empty page
    /// means nothing older is left. Ignored once rows were dropped.
    public mutating func prepend(_ events: [EventRecord]) {
        guard firstOrdinal > 0 else {
            append(events)
            return
        }
        guard droppedRows == 0 else { return }
        let page = events.filter { ($0.ordinal ?? .max) < firstOrdinal }.sorted { $0.ordinal! < $1.ordinal! }
        guard let first = page.first, let firstPageOrdinal = first.ordinal, let lastPageOrdinal = page.last?.ordinal else {
            reachedStart = true
            return
        }
        var older = Timeline(maxRows: maxRows, maxItemBytes: maxItemBytes)
        older.lastOrdinal = firstPageOrdinal - 1
        older.append(page)
        if lastPageOrdinal + 1 < firstOrdinal {
            older.add(TimelineRow(id: 0, kind: .gap, at: firstAt, text: Self.gapText(firstOrdinal - lastPageOrdinal - 1)))
        }

        // Continuations: the first shown message row of an item still open at the page's end.
        var shown = rows
        var merged: Set<Int> = []
        var stillOpen: [String: Int] = [:]
        // Indices first: merged rows take over newer IDs, which may equal other older IDs.
        let open = older.openMessage.compactMap { item, id in older.rows.firstIndex { $0.id == id }.map { (item, $0) } }
        for (item, olderIndex) in open {
            guard let index = shown.firstIndex(where: { $0.kind == .message && $0.itemID == item }) else {
                stillOpen[item] = olderIndex
                continue
            }
            let newer = shown.remove(at: index)
            var row = older.rows[olderIndex]
            if finalRows.contains(newer.id) {
                row.text = newer.text
                row.truncated = newer.truncated
            } else if !row.truncated {
                row.text += newer.text
                row.truncated = newer.truncated
                if row.text.utf8.count > maxItemBytes {
                    row.text = String(decoding: Array(row.text.utf8.prefix(maxItemBytes)), as: UTF8.self)
                    row.truncated = true
                }
            }
            // The newer row's ID stays: an open item keeps pointing at it.
            row.id = newer.id
            row.at = newer.at
            older.rows[olderIndex] = row
            merged.insert(olderIndex)
        }

        // Fresh IDs below zero, rising from top to bottom.
        var renamed: [Int: Int] = [:]
        for index in older.rows.indices.reversed() where !merged.contains(index) {
            renamed[older.rows[index].id] = previousID
            older.rows[index].id = previousID
            previousID -= 1
        }
        finalRows.formUnion(older.finalRows.compactMap { renamed[$0] })
        for (item, index) in stillOpen { openMessage[item] = older.rows[index].id }

        rows = older.rows + shown
        droppedRows += older.droppedRows
        firstOrdinal = firstPageOrdinal
        firstAt = first.at
        trim()
    }

    private mutating func consume(_ event: EventRecord) {
        if event.payload == nil, event.payloadPurgedAt != nil {
            add(TimelineRow(id: 0, kind: .purged, at: event.at, text: "Inhalt gelöscht"))
            return
        }
        guard let data = event.payload, let agent = try? JSONDecoder().decode(AgentEvent.self, from: data) else {
            add(TimelineRow(id: 0, kind: event.kind == .attemptStateChanged ? .state : .other, at: event.at, text: Self.headerText(event.kind)))
            return
        }
        switch agent {
        case .started: add(TimelineRow(id: 0, kind: .started, at: event.at, text: "Gestartet"))
        case .messageDelta(let item, let text): appendMessage(item, text, at: event.at, final: false)
        case .messageFinal(let item, let text): appendMessage(item, text, at: event.at, final: true)
        case .toolStarted(let item, let toolClass):
            add(TimelineRow(id: 0, kind: .tool, at: event.at, text: "Werkzeug \(toolClass) gestartet", itemID: item))
        case .toolEnded(let item, let status):
            add(TimelineRow(id: 0, kind: .tool, at: event.at, text: "Werkzeug beendet: \(status)", itemID: item))
        case .usage(let sample):
            add(TimelineRow(id: 0, kind: .usage, at: event.at, text: "Verbrauch: \(Self.usageText(sample))"))
        case .diagnostic(let message): add(TimelineRow(id: 0, kind: .diagnostic, at: event.at, text: message))
        case .rateLimited: add(TimelineRow(id: 0, kind: .limit, at: event.at, text: "Nutzungslimit erreicht"))
        case .quotaObserved: add(TimelineRow(id: 0, kind: .limit, at: event.at, text: "Kontingent gemeldet"))
        case .completed(let status):
            let text = switch status {
            case .succeeded: "Abgeschlossen"
            case .failed(let reason): "Fehlgeschlagen: \(reason)"
            case .cancelled: "Abgebrochen"
            }
            add(TimelineRow(id: 0, kind: .completed, at: event.at, text: text))
        }
    }

    private mutating func appendMessage(_ item: String, _ text: String, at: Int64, final: Bool) {
        if let index = openMessage[item].flatMap({ id in rows.firstIndex { $0.id == id } }) {
            var row = rows[index]
            if final {
                row.text = text
                row.truncated = false
            } else if !row.truncated {
                row.text += text
            }
            if row.text.utf8.count > maxItemBytes {
                row.text = String(decoding: Array(row.text.utf8.prefix(maxItemBytes)), as: UTF8.self)
                row.truncated = true
            }
            row.at = at
            rows[index] = row
            if final { finalRows.insert(row.id) }
        } else {
            var row = TimelineRow(id: 0, kind: .message, at: at, text: text, itemID: item)
            if row.text.utf8.count > maxItemBytes {
                row.text = String(decoding: Array(row.text.utf8.prefix(maxItemBytes)), as: UTF8.self)
                row.truncated = true
            }
            let id = add(row)
            openMessage[item] = id
            if final { finalRows.insert(id) }
        }
        if final { openMessage[item] = nil }
    }

    @discardableResult
    private mutating func add(_ row: TimelineRow) -> Int {
        var row = row
        row.id = nextID
        nextID += 1
        rows.append(row)
        trim()
        return row.id
    }

    /// The oldest rows drop beyond `maxRows`.
    private mutating func trim() {
        guard rows.count > maxRows else { return }
        let drop = rows.count - maxRows
        droppedRows += drop
        for row in rows.prefix(drop) { finalRows.remove(row.id) }
        rows.removeFirst(drop)
    }

    static func gapText(_ missing: Int) -> String { "Anzeige unvollständig: \(missing) Ereignisse fehlen" }

    static func usageText(_ sample: UsageSample) -> String {
        var parts: [String] = []
        if let value = sample.inputTokens { parts.append("Eingabe \(value)") }
        if let value = sample.outputTokens { parts.append("Ausgabe \(value)") }
        if let value = sample.cachedTokens { parts.append("Cache \(value)") }
        return (parts.isEmpty ? ["keine Angaben"] : parts).joined(separator: ", ") + (sample.cumulative ? " (kumuliert)" : "")
    }

    static func headerText(_ kind: EventKind) -> String {
        switch kind {
        case .attemptReserved: "Reserviert"
        case .attemptStateChanged: "Zustand geändert"
        case .memoryDispatched: "Memory-Paket übergeben"
        case .memoryRevoked: "Memory-Paket widerrufen"
        case .contentPurged: "Inhalt gelöscht"
        default: kind.rawValue
        }
    }
}

/// How the monitor reads a selected attempt (App/ToolViews.swift `MonitorView`): opening reads
/// only the newest pages (`open`), older pages come on request (`Store.latestAttemptEvents`
/// before `Timeline.firstOrdinal`), new events after `Timeline.lastOrdinal` as before.
public enum TimelinePaging {
    public struct Limits: Sendable, Equatable {
        /// Events per page, for newer and older pages alike.
        public var pageSize: Int
        /// Opening stops once the view has this many rows or has read this many events: enough
        /// to fill the view, far fewer than a long run has (deltas merge, a page can be one row).
        public var openRows: Int
        public var openEvents: Int

        public init(pageSize: Int, openRows: Int, openEvents: Int) {
            self.pageSize = pageSize
            self.openRows = openRows
            self.openEvents = openEvents
        }

        public static let app = Limits(pageSize: 500, openRows: 30, openEvents: 1_000)
    }

    public static var pageSize: Int { Limits.app.pageSize }

    /// The last view of an attempt and how many events it read.
    public static func open(_ attempt: AttemptID, store: Store, limits: Limits = .app) async throws -> (timeline: Timeline, eventsRead: Int) {
        var timeline = Timeline()
        var page = try await store.latestAttemptEvents(attempt, limit: limits.pageSize)
        var read = page.count
        timeline.append(page)
        while page.count == limits.pageSize, timeline.canLoadOlder, timeline.rows.count < limits.openRows, read < limits.openEvents {
            try Task.checkCancellation()
            page = try await store.latestAttemptEvents(attempt, beforeOrdinal: timeline.firstOrdinal, limit: limits.pageSize)
            read += page.count
            timeline.prepend(page)
        }
        // A short page reached the start of the run.
        if page.count < limits.pageSize { timeline.prepend([]) }
        return (timeline, read)
    }
}

/// Copying log text: always through the secret check, matches replaced (Plan/macos-und-git.md).
public enum LogRedactor {
    public static func redact(_ text: String) -> String {
        let found = SecretScanner.ranges(text)
        guard !found.isEmpty else { return text }
        var bytes = Array(text.utf8)
        // Each match runs over its whole range (an assignment's value, a key up to its END
        // line) and at least to the next whitespace; overlapping matches merge into one range,
        // replaced from the end so earlier offsets stay valid.
        var ranges: [(Range<Int>, String)] = []
        for (kind, range) in found where range.lowerBound < bytes.count {
            var end = min(range.upperBound, bytes.count)
            while end < bytes.count, ![0x20, 0x0A, 0x09, 0x0D].contains(bytes[end]) { end += 1 }
            if let last = ranges.last, range.lowerBound < last.0.upperBound {
                ranges[ranges.count - 1].0 = last.0.lowerBound..<max(last.0.upperBound, end)
            } else {
                ranges.append((range.lowerBound..<end, kind))
            }
        }
        for (range, kind) in ranges.reversed() {
            bytes.replaceSubrange(range, with: Array("[entfernt: \(kind)]".utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// The monitor's filter: by project, state group, provider and role.
public struct MonitorFilter: Sendable, Equatable {
    public enum StateGroup: String, Sendable, CaseIterable {
        case open, finished, all
    }

    public var project: ProjectID?
    public var states: StateGroup = .open
    public var provider: ProviderKind?
    public var role: AttemptRole?
    public var text = ""

    public init() {}

    public func matches(_ attempt: AttemptRecord, in state: WorkspaceState) -> Bool {
        switch states {
        case .open: if attempt.state.isTerminal { return false }
        case .finished: if !attempt.state.isTerminal { return false }
        case .all: break
        }
        if let provider, attempt.provider != provider { return false }
        if let role, attempt.role != role { return false }
        let task = state.tasks[attempt.taskID]
        if let project {
            guard let job = task.flatMap({ state.jobs[$0.jobID] }), job.projectID == project else { return false }
        }
        if !text.isEmpty {
            let haystack = [task?.title ?? "", attempt.model, Labels.provider(attempt.provider)].joined(separator: " ")
            if haystack.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
        }
        return true
    }
}

/// One monitor row: what Plan/macos-und-git.md asks per attempt.
public struct MonitorRow: Sendable, Equatable, Identifiable {
    public var id: AttemptID
    public var taskTitle: String
    public var provider: String
    public var model: String
    public var role: String
    public var status: StatusLabel
    public var runtime: String?
    public var lastActivity: Int64?
    public var canCancel: Bool

    public static func rows(_ state: WorkspaceState, filter: MonitorFilter, now: Int64) -> [MonitorRow] {
        state.attempts.values.filter { filter.matches($0, in: state) }
            .sorted { ($0.reservedAt, $0.id.uuidString) > ($1.reservedAt, $1.id.uuidString) }
            .map { attempt in
                let start = attempt.startedAt
                let end = attempt.endedAt ?? now
                return MonitorRow(
                    id: attempt.id, taskTitle: state.tasks[attempt.taskID]?.title ?? "–", provider: Labels.provider(attempt.provider),
                    model: attempt.model, role: Labels.role(attempt.role), status: Labels.attempt(attempt.state),
                    runtime: start.map { Labels.duration(end - $0) }, lastActivity: state.lastActivity[attempt.id],
                    canCancel: [.reserved, .starting, .running, .awaitingApproval].contains(attempt.state)
                )
            }
    }
}
