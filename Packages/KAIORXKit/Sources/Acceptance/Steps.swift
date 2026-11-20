import CryptoKit
import Domain
import Foundation
import ProcessHost
import Providers
import Workspace

/// The steps of a live acceptance, cheapest first, the ones that disturb the owner's login last.
public enum StepID: String, Codable, Sendable, CaseIterable, Comparable {
    case identify, auth, billing, read, isolation, hiddenHome, author, cancel, quota, revoke, wrongAccount, parallel

    public var title: String {
        switch self {
        case .identify: "Programm identifizieren"
        case .auth: "Anmeldung und Plan prüfen"
        case .billing: "Abrechnung bestätigen"
        case .read: "Lesender Auftrag"
        case .isolation: "Isolation prüfen"
        case .hiddenHome: "Lesender Auftrag mit verborgenem Benutzerordner"
        case .author: "Schreibender Auftrag"
        case .cancel: "Abbruch"
        case .quota: "Kontingent beobachten"
        case .revoke: "Widerruf der Anmeldung"
        case .wrongAccount: "Falsches Konto"
        case .parallel: "Zwei Anbieter gleichzeitig"
        }
    }

    /// Needed for a passed acceptance; the others either pass or stay listed as a restriction.
    public var required: Bool {
        switch self {
        case .identify, .auth, .billing, .read, .isolation, .author, .cancel, .revoke: true
        case .hiddenHome, .quota, .wrongAccount, .parallel: false
        }
    }

    /// Uses the subscription (a model turn): needs the owner's typed consent each time.
    public var usesInference: Bool {
        switch self {
        case .read, .isolation, .author, .cancel, .parallel: true
        // Covered by the read, which runs with the home folder hidden.
        case .identify, .auth, .billing, .hiddenHome, .quota, .revoke, .wrongAccount: false
        }
    }

    public static func < (a: StepID, b: StepID) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

public struct StepResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case pending, passed, failed, skipped, waitingForOwner }

    public var status: Status
    /// What was observed (no private values).
    public var evidence: [String]
    /// What stays open when the step did not pass.
    public var limitation: String?

    public init(status: Status, evidence: [String] = [], limitation: String? = nil) {
        self.status = status
        self.evidence = evidence
        self.limitation = limitation
    }
}

/// One provider under acceptance.
public struct ProviderRun: Codable, Sendable {
    public var provider: ProviderKind
    /// As found (for example the npm launcher) and the native binary that runs.
    public var configuredPath: String
    public var nativePath: String
    public var model: String
    public var configDirectory: String
    public var identity: BinaryIdentity?
    public var signing: [String] = []
    public var steps: [StepID: StepResult] = [:]
    public var verdict: String?
    /// Salted hash of the account identity; kept in the run folder only, never in the report.
    public var accountFingerprint: String?
    public var fixtures: [String] = []

    public init(provider: ProviderKind, configuredPath: String, nativePath: String, model: String, configDirectory: String) {
        self.provider = provider
        self.configuredPath = configuredPath
        self.nativePath = nativePath
        self.model = model
        self.configDirectory = configDirectory
    }

    public var mode: String { provider == .claude ? "claudeSubscription" : "codexCliManaged" }

    /// Passed when every required step passed; optional steps that did not pass are restrictions.
    public var passed: Bool { StepID.allCases.filter { $0.required && $0 != .parallel }.allSatisfy { steps[$0]?.status == .passed } }

    public var restrictions: [String] {
        StepID.allCases.filter { $0 != .parallel }.compactMap { step in
            guard let result = steps[step] else { return step.required ? "\(step.title): nicht ausgeführt" : nil }
            if result.status == .passed { return result.limitation.map { "\(step.title): \($0)" } }
            return result.limitation.map { "\(step.title): \($0)" } ?? "\(step.title): \(result.status.rawValue)"
        }
    }
}

/// The state of a run, kept in its folder so it can be resumed after the owner acted.
public struct RunState: Codable, Sendable {
    public var schemaVersion = 1
    public var runID: String
    public var createdAt: Int64
    public var macOS: String
    public var arch: String
    public var kaiorxCommit: String?
    public var salt: String
    public var canaries: [String: String]
    public var providers: [ProviderRun]
    public var parallel: StepResult?

    public init(runID: String, createdAt: Int64, kaiorxCommit: String?, providers: [ProviderRun]) {
        self.runID = runID
        self.createdAt = createdAt
        self.macOS = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        self.arch = "arm64"
        #else
        self.arch = "x86_64"
        #endif
        self.kaiorxCommit = kaiorxCommit
        self.salt = UUID().uuidString
        func canary() -> String { "KAIORX-CANARY-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)) }
        self.canaries = ["facts": canary(), "neighbour": canary(), "home": canary(), "outside": canary(), "env": canary()]
        self.providers = providers
    }

    public static func load(_ folder: String) throws -> RunState {
        try JSONDecoder().decode(RunState.self, from: Data(contentsOf: URL(filePath: folder + "/state.json")))
    }

    public func save(_ folder: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = folder + "/state.json"
        try encoder.encode(self).write(to: URL(filePath: file), options: .atomic)
        chmod(file, 0o600)
    }
}

/// Folders of a run: everything below the owner's Application Support, never in a repository.
public struct RunFolders: Sendable {
    public let root: String
    public var data: String { root + "/data" }
    public var repoA: String { data + "/repo-a" }
    public var repoB: String { data + "/repo-b" }
    public var outside: String { data + "/outside" }
    public var temporary: String { root + "/tmp" }
    public var fixtures: String { root + "/fixtures" }
    public var layout: WorkspaceLayout { WorkspaceLayout(root: root + "/kaiorx") }

    public init(root: String) {
        self.root = root
    }

    public static func base() throws -> String {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appending(path: "KAIORX/acceptance").path(percentEncoded: false)
    }

    public func create() throws {
        for folder in [root, data, temporary, fixtures, layout.root] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

/// The confinement the product uses for an agent CLI (ADR 0003 role `agentCLI`): home hidden
/// except the CLI's install folder (ADR 0008, point 6).
public enum AgentConfinement {
    public static func make(
        provider: ProviderKind, spec: AttemptSpec, temporary: String, configDirectory: String, layout: WorkspaceLayout, home: String,
        extraHidden: [String], executable: String
    ) -> Confinement? {
        guard let worktree = spec.workingDirectory else { return nil }
        let profile = RoleProfile.agentCLI(
            stateDirectory: configDirectory, writesWorktree: spec.role == .author,
            protectedStateFiles: provider == .claude ? RoleProfile.claudeStateFiles : RoleProfile.codexStateFiles,
            needsKeychain: provider == .claude
        )
        return profile.confinement(
            worktree: worktree, runTemporaryDirectory: temporary, layout: layout, home: home, extraHidden: extraHidden, executable: executable
        )
    }
}

/// Hash of a folder's files (paths and contents, `.git` excluded): a read-only step must not change it.
public enum TreeHash {
    public static func of(_ folder: String, excluding: [String] = []) -> String {
        var hasher = SHA256()
        let enumerator = FileManager.default.enumerator(atPath: folder)
        var paths: [String] = []
        let skipped = [".git"] + excluding
        while let path = enumerator?.nextObject() as? String {
            if skipped.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { enumerator?.skipDescendants(); continue }
            paths.append(path)
        }
        for path in paths.sorted() {
            hasher.update(data: Data(path.utf8))
            var info = stat()
            if lstat(folder + "/" + path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, let data = FileManager.default.contents(atPath: folder + "/" + path) {
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
