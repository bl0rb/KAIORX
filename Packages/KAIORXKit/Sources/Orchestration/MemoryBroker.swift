import Domain
import Foundation
import Memory
import Storage
import Workspace

public enum MemoryBrokerError: Error, Equatable, Sendable {
    case invalidPath(String)
    case notAFile(String, mode: String)
    case tooLarge(String, Int)
    case binary(String)
    case excludedPath(String)
    case attemptNotFound(AttemptID)
    case digestMismatch(position: Int)
}

/// What a context package is about: texts and symbols for the query terms.
public struct MemoryQuery: Sendable, Equatable {
    public var texts: [String]
    public var symbols: [String]
    public var inputWindowTokens: Int?

    public init(texts: [String], symbols: [String] = [], inputWindowTokens: Int? = nil) {
        self.texts = texts
        self.symbols = symbols
        self.inputWindowTokens = inputWindowTokens
    }
}

/// `Memory.retrieve / authorize / dispatch` of the runtime contract (ADR 0006): binds a request
/// to its attempt, checks Git evidence against the base, prepares, renders and dispatches
/// manifests, and forgets.
public actor MemoryBroker {
    private let store: Store
    private let workspace: WorkspaceService
    private let git: GitRunner
    private let coordinator: RunCoordinator
    public static let maxSourceBytes = 256 * 1024
    static let excludedNames: Set<String> = [".env", ".netrc", ".npmrc", ".pypirc", "id_rsa", "id_ed25519", "credentials", "known_hosts"]
    static let excludedSuffixes = [".pem", ".key", ".p12", ".pfx", ".keychain", ".sqlite", ".db"]

    public init(store: Store, workspace: WorkspaceService, git: GitRunner, coordinator: RunCoordinator) {
        self.store = store
        self.workspace = workspace
        self.git = git
        self.coordinator = coordinator
    }

    // MARK: Sources

    /// A Git source for a file in a commit, read from the commit (not a worktree): relative,
    /// a regular file, at most 256 KiB, text, not on the exclusion list. Returns the source and
    /// the file's text for the note.
    public func gitSource(project: ProjectID, commit: String, path raw: String, at time: Int64) async throws -> (MemorySourceDraft, String) {
        guard let path = WriteArea.normalize(raw), !path.isEmpty else { throw MemoryBrokerError.invalidPath(raw) }
        let name = (path as NSString).lastPathComponent.lowercased()
        if Self.excludedNames.contains(name) || Self.excludedSuffixes.contains(where: name.hasSuffix) { throw MemoryBrokerError.excludedPath(path) }
        let repository = try await workspace.attach(project)
        guard let entry = try await git.treeEntry(path, in: commit, repository: repository) else { throw MemoryBrokerError.invalidPath(path) }
        guard entry.type == "blob", entry.mode == "100644" || entry.mode == "100755" else { throw MemoryBrokerError.notAFile(path, mode: entry.mode) }
        let size = try await git.blobSize(entry.oid, repository: repository)
        guard size <= Self.maxSourceBytes else { throw MemoryBrokerError.tooLarge(path, size) }
        let data = try await git.blob(entry.oid, repository: repository)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw MemoryBrokerError.binary(path) }
        let source = MemorySourceDraft(
            kind: .git, observedAt: time, locator: path, gitOID: commit, blobOID: entry.oid, sourceDigest: Canonical.sha256Hex(data),
            originProjectID: project
        )
        return (source, text)
    }

    /// Revisions of the project whose evidence does not hold at `base`: a Git source whose blob
    /// differs or is gone (one batched lookup), a test or review source whose checked commit is
    /// not an ancestor of the base.
    public func staleRevisions(project: ProjectID, base: String?) async throws -> Set<MemoryRevisionID> {
        guard let base else { return [] }
        let repository = try await workspace.attach(project)
        var stale = Set<MemoryRevisionID>()
        let sources = try await store.gitSources(project: project)
        let blobs = try await git.blobs(at: sources.map(\.1), in: base, repository: repository)
        for (revision, path, blob) in sources where (blobs[path] ?? nil) != blob { stale.insert(revision) }
        var ancestry: [String: Bool] = [:]
        for (revision, commit) in try await store.checkedCommitSources(project: project) {
            if ancestry[commit] == nil { ancestry[commit] = (try? await git.isAncestor(commit, of: base, in: repository)) ?? false }
            if ancestry[commit] == false { stale.insert(revision) }
        }
        return stale
    }

    // MARK: Retrieval and manifests

    /// Prepares the context package of an attempt (ADR 0006 §5, §6): read set of its project,
    /// task and provider (and the planned reviewer provider), stale evidence excluded, selection
    /// with the limits. Nothing is sent yet.
    public func prepare(
        _ manifestID: MemoryManifestID = MemoryManifestID(), attempt attemptID: AttemptID, reviewerProvider: ProviderKind?, query: MemoryQuery
    ) async throws -> ManifestRecord {
        guard let attempt = try await store.attempt(attemptID), let task = try await store.task(attempt.taskID),
              let job = try await store.jobs().first(where: { $0.id == task.jobID }) else { throw MemoryBrokerError.attemptNotFound(attemptID) }
        let base = try await baseOID(attempt, job: job)
        let stale = try await staleRevisions(project: job.projectID, base: base)
        let reader = MemoryReader(projectID: job.projectID, taskID: task.id, provider: attempt.provider, reviewerProvider: reviewerProvider)
        let terms = QueryTerms.extract(texts: query.texts, symbols: query.symbols)
        let candidates = try await store.memoryCandidates(reader, query: QueryTerms.ftsQuery(terms), stale: stale)
        let chosen = Selector.select(
            pins: candidates.pins, hits: candidates.hits, neighbours: candidates.neighbours,
            limits: SelectionLimits(inputWindowTokens: query.inputWindowTokens)
        )
        var items: [ManifestItemRecord] = []
        var digests = Set<String>()
        for candidate in chosen {
            let revision = try await store.memoryRevision(candidate.revisionID)
            let excerpt = Self.excerpt(revision.body, candidate.byteFrom, candidate.byteTo)
            let digest = Canonical.sha256Hex(Data(excerpt.utf8))
            // The same text twice is one excerpt.
            guard digests.insert(digest).inserted else { continue }
            items.append(ManifestItemRecord(
                position: items.count, revisionID: candidate.revisionID, byteFrom: candidate.byteFrom, byteTo: candidate.byteTo,
                excerptDigest: digest, tokenEstimate: candidate.tokens, reason: candidate.reason, rank: items.count
            ))
        }
        return try await store.prepareManifest(manifestID, attempt: attemptID, reviewerProvider: reviewerProvider, baseOID: base, items: items)
    }

    /// The package text: quoted excerpts with their source markers; each excerpt's digest is
    /// checked against the immutable revision.
    public func render(_ manifestID: MemoryManifestID) async throws -> String {
        let manifest = try await store.manifest(manifestID)
        guard let attempt = try await store.attempt(manifest.attemptID), let task = try await store.task(attempt.taskID),
              let job = try await store.jobs().first(where: { $0.id == task.jobID }) else { throw MemoryBrokerError.attemptNotFound(manifest.attemptID) }
        var excerpts: [RenderedExcerpt] = []
        for item in manifest.items {
            let revision = try await store.memoryRevision(item.revisionID)
            let text = Self.excerpt(revision.body, item.byteFrom, item.byteTo)
            guard Canonical.sha256Hex(Data(text.utf8)) == item.excerptDigest else { throw MemoryBrokerError.digestMismatch(position: item.position) }
            excerpts.append(RenderedExcerpt(marker: try await marker(revision, item: item, viewer: job.projectID), text: text))
        }
        return ContextRenderer.render(excerpts)
    }

    /// The handover: stale evidence is recomputed, then the store rechecks and dispatches in one
    /// transaction (moving the attempt to `starting`). Returns the rendered package.
    public func dispatch(_ manifestID: MemoryManifestID) async throws -> String {
        let text = try await render(manifestID)
        let manifest = try await store.manifest(manifestID)
        guard let attempt = try await store.attempt(manifest.attemptID), let task = try await store.task(attempt.taskID),
              let job = try await store.jobs().first(where: { $0.id == task.jobID }) else { throw MemoryBrokerError.attemptNotFound(manifest.attemptID) }
        let stale = try await staleRevisions(project: job.projectID, base: manifest.baseOID)
        try await store.dispatchManifest(manifestID, stale: stale)
        return text
    }

    /// A manual handoff: the same checks, the user carries the text over.
    public func handOff(_ manifestID: MemoryManifestID) async throws -> String {
        let text = try await render(manifestID)
        let manifest = try await store.manifest(manifestID)
        guard let attempt = try await store.attempt(manifest.attemptID), let task = try await store.task(attempt.taskID),
              let job = try await store.jobs().first(where: { $0.id == task.jobID }) else { throw MemoryBrokerError.attemptNotFound(manifest.attemptID) }
        try await store.dispatchManifest(manifestID, stale: try await staleRevisions(project: job.projectID, base: manifest.baseOID), manual: true)
        return text
    }

    // MARK: Revocation and forgetting

    /// Revokes a grant and cancels open attempts that already received its content.
    public func revokeGrant(_ grant: MemoryGrantID) async throws -> [AttemptID] {
        let open = try await store.revokeMemoryGrant(grant)
        for attempt in open { try await coordinator.cancel(attempt, reason: "memoryGrantRevoked") }
        return open
    }

    /// Forgets entries: one transaction in the store, then running attempts that received the
    /// content are cancelled and the purge job runs.
    @discardableResult
    public func forget(_ entries: [MemoryEntryID]) async throws -> ForgetReport {
        let report = try await store.forgetMemory(entries)
        for attempt in report.attempts { try await coordinator.cancel(attempt, reason: "memoryForgotten") }
        try await store.runPurgeJobs()
        return report
    }

    @discardableResult
    public func forgetProject(_ project: ProjectID) async throws -> ForgetReport {
        let report = try await store.forgetProjectMemory(project)
        for attempt in report.attempts { try await coordinator.cancel(attempt, reason: "memoryForgotten") }
        try await store.runPurgeJobs()
        return report
    }

    // MARK: Helpers

    static func excerpt(_ body: String, _ from: Int, _ to: Int) -> String {
        let bytes = Array(body.utf8)
        guard from >= 0, to <= bytes.count, from < to else { return "" }
        return String(decoding: bytes[from..<to], as: UTF8.self)
    }

    private func baseOID(_ attempt: AttemptRecord, job: JobRecord) async throws -> String? {
        if let base = attempt.baseOID { return base }
        return try await store.integrationTip(job: job.id)
    }

    /// Scope, title, revision and the evidence as far as the viewer may see it.
    private func marker(_ revision: MemoryRevisionRecord, item: ManifestItemRecord, viewer: ProjectID) async throws -> String {
        let scope = switch revision.scope { case .task: "Aufgabennotiz"; case .project: "Projektnotiz"; case .global: "Globale Notiz" }
        var parts = ["\(scope) „\(revision.title)“", "Revision \(revision.number)", "Bytes \(item.byteFrom)–\(item.byteTo)", "Grund \(item.reason.rawValue)"]
        if revision.scope == .global, revision.projectID != viewer {
            parts.append("vom Benutzer projektübergreifend bestätigt")
        } else {
            for source in try await store.memorySources(revision.id, viewer: viewer) {
                switch source.draft.kind {
                case .git: parts.append("Git \(source.draft.gitOID.map { String($0.prefix(12)) } ?? "?") \(source.draft.locator ?? "")")
                case .test, .review: parts.append("\(source.draft.kind.rawValue) \(source.draft.gitOID.map { String($0.prefix(12)) } ?? "?")")
                case .user: parts.append("vom Benutzer erfasst")
                case .derived: parts.append("abgeleitet")
                }
            }
        }
        return parts.joined(separator: " · ")
    }
}
