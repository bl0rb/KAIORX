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
/// gap row saying so), message deltas merged per item up to `maxItemBytes`.
public struct Timeline: Sendable, Equatable {
    public let maxRows: Int
    public let maxItemBytes: Int
    public private(set) var rows: [TimelineRow] = []
    /// Ordinal of the last event read: the next page starts after it.
    public private(set) var lastOrdinal = 0
    public private(set) var droppedRows = 0
    private var nextID = 0
    private var openMessage: [String: Int] = [:]

    public init(maxRows: Int = 2_000, maxItemBytes: Int = 256 * 1024) {
        self.maxRows = maxRows
        self.maxItemBytes = maxItemBytes
    }

    /// Appends one page of events (in ordinal order). A missing ordinal becomes a gap row.
    public mutating func append(_ events: [EventRecord]) {
        for event in events {
            let ordinal = event.ordinal ?? lastOrdinal + 1
            if ordinal <= lastOrdinal { continue }
            if ordinal > lastOrdinal + 1, lastOrdinal > 0 {
                add(TimelineRow(id: 0, kind: .gap, at: event.at, text: "Anzeige unvollständig: \(ordinal - lastOrdinal - 1) Ereignisse fehlen"))
            }
            lastOrdinal = ordinal
            consume(event)
        }
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
        } else {
            var row = TimelineRow(id: 0, kind: .message, at: at, text: text, itemID: item)
            if row.text.utf8.count > maxItemBytes {
                row.text = String(decoding: Array(row.text.utf8.prefix(maxItemBytes)), as: UTF8.self)
                row.truncated = true
            }
            let id = add(row)
            openMessage[item] = id
        }
        if final { openMessage[item] = nil }
    }

    @discardableResult
    private mutating func add(_ row: TimelineRow) -> Int {
        var row = row
        row.id = nextID
        nextID += 1
        rows.append(row)
        if rows.count > maxRows {
            let drop = rows.count - maxRows
            droppedRows += drop
            rows.removeFirst(drop)
        }
        return row.id
    }

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
