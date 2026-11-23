import Foundation
import Testing
@testable import Domain

@Suite struct StateMachineTests {
    @Test func terminalStatesHaveNoSuccessors() {
        for state in JobState.allCases where state.isTerminal { #expect(state.successors.isEmpty, "\(state)") }
        for state in TaskState.allCases where state.isTerminal { #expect(state.successors.isEmpty, "\(state)") }
        for state in AttemptState.allCases where state.isTerminal { #expect(state.successors.isEmpty, "\(state)") }
    }

    @Test func noStateTransitionsToItself() {
        for state in JobState.allCases { #expect(!state.allowsTransition(to: state)) }
        for state in TaskState.allCases { #expect(!state.allowsTransition(to: state)) }
        for state in AttemptState.allCases { #expect(!state.allowsTransition(to: state)) }
    }

    @Test func attemptHappyPathAndCancellation() throws {
        let path: [AttemptState] = [.reserved, .starting, .running, .awaitingApproval, .running, .cancelling, .cancelled]
        for (from, to) in zip(path, path.dropFirst()) { try from.validateTransition(to: to) }
    }

    @Test func uncertainOnlyLeavesToTerminalStates() {
        #expect(AttemptState.uncertain.successors == [.succeeded, .failed, .cancelled])
        #expect(!AttemptState.uncertain.allowsTransition(to: .running))
    }

    @Test func reservedCannotSkipStarting() {
        #expect(!AttemptState.reserved.allowsTransition(to: .running))
        #expect(!AttemptState.reserved.allowsTransition(to: .succeeded))
    }

    @Test func invalidTransitionNamesEntityAndStates() {
        #expect(throws: DomainError.invalidTransition(entity: "task", from: "pending", to: "integrated")) {
            try TaskState.pending.validateTransition(to: .integrated)
        }
    }

    @Test func taskMainPathIsAllowed() throws {
        let path: [TaskState] = [.pending, .ready, .running, .resultReady, .verifying, .awaitingMerge, .integrated]
        for (from, to) in zip(path, path.dropFirst()) { try from.validateTransition(to: to) }
    }

    @Test func sideStatesReturnOnlyToTheInterruptedStage() {
        // pending → blocked → awaitingMerge would skip running, verifying and the result.
        #expect(!TaskState.blocked.allowsTransition(to: .awaitingMerge, resumeState: .pending))
        #expect(TaskState.blocked.allowsTransition(to: .pending, resumeState: .pending))
        #expect(!TaskState.blocked.allowsTransition(to: .integrated, resumeState: .awaitingMerge))
        #expect(!TaskState.blocked.allowsTransition(to: .pending))
        // conflict/needsChanges: back to the stage or to `ready` for new work, never skipping ahead.
        #expect(TaskState.conflict.allowsTransition(to: .verifying, resumeState: .verifying))
        #expect(!TaskState.conflict.allowsTransition(to: .awaitingMerge, resumeState: .verifying))
        #expect(TaskState.needsChanges.allowsTransition(to: .ready, resumeState: .verifying))
        #expect(!TaskState.needsChanges.allowsTransition(to: .running, resumeState: .verifying))
    }

    @Test func resumeStateIsRecordedOnEntryAndKeptBetweenSideStates() {
        #expect(TaskState.verifying.resumeState(after: .conflict, current: nil) == .verifying)
        #expect(TaskState.conflict.resumeState(after: .blocked, current: .verifying) == .verifying)
        #expect(TaskState.blocked.resumeState(after: .verifying, current: .verifying) == nil)
        #expect(TaskState.ready.resumeState(after: .running, current: nil) == nil)
    }

    @Test func everyOpenTaskCanBeBlockedOrEnded() {
        for state in TaskState.allCases where !state.isTerminal {
            #expect(state.allowsTransition(to: .cancelled), "\(state)")
            #expect(state.allowsTransition(to: .failed), "\(state)")
            if state != .blocked { #expect(state.allowsTransition(to: .blocked), "\(state)") }
        }
    }

    @Test func jobCannotSkipOrReturnToPlanning() {
        #expect(!JobState.active.allowsTransition(to: .planned))
        // draft → paused → active would skip planning.
        #expect(!JobState.paused.allowsTransition(to: .active, resumeState: .draft))
        #expect(JobState.paused.allowsTransition(to: .draft, resumeState: .draft))
        // active → paused → planned would return to planning without a new revision.
        #expect(!JobState.paused.allowsTransition(to: .planned, resumeState: .active))
        #expect(JobState.needsAttention.allowsTransition(to: .active, resumeState: .active))
    }

    @Test func pauseCancelAndAttentionNeedAReason() {
        #expect(JobState.allCases.filter(\.requiresReason) == [.paused, .cancelled, .needsAttention])
    }
}

@Suite struct ValueTests {
    @Test func typedIDEncodesAsLowercaseUUID() throws {
        let uuid = UUID()
        let id = TaskID(uuid)
        let data = try JSONEncoder().encode(id)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(uuid.uuidString.lowercased())\"")
        #expect(try JSONDecoder().decode(TaskID.self, from: data) == id)
        #expect(TaskID(string: uuid.uuidString) == id)
    }

    @Test func typedIDRejectsGarbage() {
        #expect(TaskID(string: "not-a-uuid") == nil)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TaskID.self, from: Data("\"x\"".utf8)) }
    }

    @Test func unknownEventKindsSurviveDecoding() throws {
        let kind = try JSONDecoder().decode(EventKind.self, from: Data("\"vendor.future\"".utf8))
        #expect(kind.rawValue == "vendor.future")
    }

    @Test func canonicalEncodingIsStable() throws {
        let spec = AttemptSpec(
            attemptID: AttemptID(), taskID: TaskID(), projectID: ProjectID(), role: .author,
            provider: .fake, runMode: .automatic, modelProfile: "standard", effectiveModel: "m", prompt: "p"
        )
        #expect(try spec.digest() == spec.digest())
        var changed = spec
        changed.prompt = "q"
        #expect(try spec.digest() != changed.digest())
        #expect(try Canonical.encode(["b": 1, "a": 2]) == Data(#"{"a":2,"b":1}"#.utf8))
    }

    @Test func agentEventRoundTripsAndMapsKinds() throws {
        let events: [AgentEvent] = [
            .started(sessionID: nil), .messageDelta(itemID: "i", text: "t"), .messageFinal(itemID: "i", text: "t"),
            .toolStarted(itemID: "i", toolClass: "read"), .toolEnded(itemID: "i", status: "ok"),
            .usage(UsageSample(inputTokens: 1)), .diagnostic(message: "x"), .completed(.failed(reason: "r")),
        ]
        for event in events {
            #expect(try JSONDecoder().decode(AgentEvent.self, from: Canonical.encode(event)) == event)
        }
        #expect(Set(events.map(\.kind)).count == events.count)
    }

    @Test func terminalStatusMapsToAttemptState() {
        #expect(TerminalStatus.succeeded.attemptState == .succeeded)
        #expect(TerminalStatus.failed(reason: "x").attemptState == .failed)
        #expect(TerminalStatus.cancelled.attemptState == .cancelled)
    }
}

@Suite struct JournalFormatTests {
    @Test func persistedEventJSONHasNamedKeys() throws {
        #expect(try String(decoding: Canonical.encode(AgentEvent.completed(.succeeded)), as: UTF8.self)
            == #"{"completed":{"status":{"succeeded":{}}}}"#)
        #expect(try String(decoding: Canonical.encode(AgentEvent.usage(UsageSample(outputTokens: 2))), as: UTF8.self)
            == #"{"usage":{"sample":{"cumulative":false,"outputTokens":2}}}"#)
    }
}

/// Command and spec digests are persisted and compared on replay; their encoding must not drift.
@Suite struct DigestStabilityTests {
    static let attempt = AttemptID(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
    static let task = TaskID(UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
    static let project = ProjectID(UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!)

    @Test func reserveCommandHasAGoldenEncoding() throws {
        let action = CommandAction.reserveAttempt(AttemptReservation(
            attemptID: Self.attempt, taskID: Self.task, projectID: Self.project, role: .author,
            provider: .fake, mode: .automatic, model: "m", specDigest: "d"
        ))
        let json = String(decoding: try Canonical.encode(action), as: UTF8.self)
        #expect(json == #"{"reserveAttempt":{"reservation":{"attemptID":"00000000-0000-0000-0000-00000000000a","mode":"automatic","model":"m","projectID":"00000000-0000-0000-0000-00000000000c","provider":"fake","role":"author","specDigest":"d","taskID":"00000000-0000-0000-0000-00000000000b"}}}"#)
    }

    @Test func specDigestIsGolden() throws {
        let spec = AttemptSpec(
            attemptID: Self.attempt, taskID: Self.task, projectID: Self.project, role: .author,
            provider: .fake, runMode: .automatic, modelProfile: "standard", effectiveModel: "m", prompt: "p"
        )
        #expect(try spec.digest() == "ca85651b63606d6404b15dacfadfbfa4943b7d9bca72950ad88ffdf627c70124")
    }
}
