import Foundation

/// A UUID tagged with the entity it identifies, so a `TaskID` can never be passed where an
/// `AttemptID` is expected. Stored and encoded as lowercase UUID text.
public struct TypedID<Tag>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.rawValue = uuid
    }

    public var uuidString: String { rawValue.uuidString.lowercased() }
    public var description: String { uuidString }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let uuid = UUID(uuidString: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid UUID: \(text)")
        }
        self.rawValue = uuid
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuidString)
    }
}

public enum ProjectTag {}
public enum JobTag {}
public enum TaskTag {}
public enum AttemptTag {}
public enum CommandTag {}
public enum EventTag {}
public enum ArtifactTag {}

public typealias ProjectID = TypedID<ProjectTag>
public typealias JobID = TypedID<JobTag>
public typealias TaskID = TypedID<TaskTag>
public typealias AttemptID = TypedID<AttemptTag>
/// Idempotency key of a command. The same key with a different payload is an error.
public typealias CommandID = TypedID<CommandTag>
public typealias EventID = TypedID<EventTag>
public typealias ArtifactID = TypedID<ArtifactTag>
