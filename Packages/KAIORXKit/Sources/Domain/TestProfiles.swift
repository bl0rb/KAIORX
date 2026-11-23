import Foundation

public enum TestProfileTag {}
public typealias TestProfileID = TypedID<TestProfileTag>

/// A test command of one project (ADR 0010): what runs, where, how long, and which paths count
/// as test inputs. The registry stores it per project under its name; it runs only after the
/// user confirmed exactly this content (its digest).
public struct TestProfileSpec: Sendable, Equatable, Hashable, Codable {
    public var name: String
    /// Absolute path of the program; started directly, never through a search path.
    public var executable: String
    public var arguments: [String]
    /// Relative to the candidate's QA worktree; must not leave it.
    public var workingDirectory: String
    public var timeoutSeconds: Int
    /// Tests that build into the worktree need write access there.
    public var writesWorktree: Bool
    /// Paths (prefixes) whose changes count as changed test inputs.
    public var testInputPrefixes: [String]

    public static let maxNameLength = 80
    public static let maxTimeoutSeconds = 6 * 60 * 60

    public init(
        name: String, executable: String, arguments: [String] = [], workingDirectory: String = ".", timeoutSeconds: Int = 600,
        writesWorktree: Bool = false, testInputPrefixes: [String] = []
    ) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.writesWorktree = writesWorktree
        self.testInputPrefixes = testInputPrefixes
    }

    /// The stored form: name and paths trimmed, an empty working directory is the worktree root,
    /// empty prefixes dropped.
    public func normalized() -> TestProfileSpec {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.executable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.workingDirectory = directory.isEmpty ? "." : directory
        copy.testInputPrefixes = testInputPrefixes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return copy
    }

    /// Why the profile cannot be stored; empty when it can.
    public var issues: [TestProfileIssue] {
        var issues: [TestProfileIssue] = []
        if name.isEmpty { issues.append(.emptyName) }
        // Counted in code points like the schema's `length(name)`, not in grapheme clusters.
        if name.unicodeScalars.count > Self.maxNameLength { issues.append(.nameTooLong) }
        if Self.hasControlCharacters(name) { issues.append(.controlCharacters("name")) }
        if !executable.hasPrefix("/") || executable.split(separator: "/").contains("..") { issues.append(.executableNotAbsolute) }
        if Self.hasControlCharacters(executable) { issues.append(.controlCharacters("executable")) }
        if arguments.contains(where: { $0.contains("\0") }) { issues.append(.controlCharacters("arguments")) }
        if !Self.staysInside(workingDirectory) { issues.append(.workingDirectoryLeavesWorktree) }
        if !(1...Self.maxTimeoutSeconds).contains(timeoutSeconds) { issues.append(.invalidTimeout) }
        for prefix in testInputPrefixes where !Self.staysInside(prefix) || prefix == "." { issues.append(.invalidTestInputPrefix(prefix)) }
        return issues
    }

    /// The digest a confirmation binds to: SHA-256 over the canonical JSON of every field. Any
    /// change (name included) gives a new digest and needs a new confirmation.
    public var digest: String {
        let content = DigestContent(
            kind: "testProfile", version: 1, name: name, executable: executable, arguments: arguments, workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds, writesWorktree: writesWorktree, testInputPrefixes: testInputPrefixes
        )
        // Encoding plain strings, numbers and booleans cannot fail.
        return Canonical.sha256Hex((try? Canonical.encode(content)) ?? Data())
    }

    private struct DigestContent: Encodable {
        let kind: String
        let version: Int
        let name: String
        let executable: String
        let arguments: [String]
        let workingDirectory: String
        let timeoutSeconds: Int
        let writesWorktree: Bool
        let testInputPrefixes: [String]
    }

    static func staysInside(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..") && !hasControlCharacters(path)
    }

    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}

public enum TestProfileIssue: Sendable, Equatable, Hashable {
    case emptyName
    case nameTooLong
    case controlCharacters(String)
    case executableNotAbsolute
    case workingDirectoryLeavesWorktree
    case invalidTimeout
    case invalidTestInputPrefix(String)
}

/// A registered profile. `isConfirmed` holds only while the confirmation names the stored digest
/// and the stored content still has that digest.
public struct TestProfileRecord: Sendable, Equatable, Identifiable {
    public var id: TestProfileID
    public var projectID: ProjectID
    public var spec: TestProfileSpec
    /// The digest stored with the content.
    public var digest: String
    /// The digest the user confirmed, with who and when.
    public var confirmedDigest: String?
    public var confirmedAt: Int64?
    public var confirmedBy: String?
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        id: TestProfileID, projectID: ProjectID, spec: TestProfileSpec, digest: String, confirmedDigest: String?, confirmedAt: Int64?,
        confirmedBy: String?, createdAt: Int64, updatedAt: Int64
    ) {
        self.id = id
        self.projectID = projectID
        self.spec = spec
        self.digest = digest
        self.confirmedDigest = confirmedDigest
        self.confirmedAt = confirmedAt
        self.confirmedBy = confirmedBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isConfirmed: Bool { confirmedAt != nil && confirmedDigest == digest && spec.digest == digest }
}
