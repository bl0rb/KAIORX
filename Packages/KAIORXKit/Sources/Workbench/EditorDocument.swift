import CryptoKit
import Domain
import Foundation

/// Which file a document is: in the user's checkout, in an attempt worktree, or in a commit.
public enum DocumentID: Sendable, Equatable, Hashable {
    case checkout(project: ProjectID, path: String)
    case worktree(WorktreeID, path: String)
    case commit(project: ProjectID, oid: String, path: String)

    public var path: String {
        switch self {
        case .checkout(_, let path), .worktree(_, let path), .commit(_, _, let path): path
        }
    }
}

/// Whether a document may be edited, and if not, why (shown to the user).
public enum DocumentAccess: Sendable, Equatable {
    case writable
    case readOnly(ReadOnlyReason)

    public var isWritable: Bool { self == .writable }
}

public enum ReadOnlyReason: String, Sendable, Equatable, Error {
    case worktree, frozen, activeAttempt, commit, binary, tooLarge, notRegularFile, protectedPath, outsideRoot, notUTF8

    public var text: String {
        switch self {
        case .worktree: "Arbeitsstände von Versuchen sind schreibgeschützt; bearbeite im eigenen Checkout."
        case .frozen: "Eingefrorener Kandidatenstand: schreibgeschützt."
        case .activeAttempt: "Ein laufender Versuch schreibt hier: schreibgeschützt."
        case .commit: "Stand aus einem Commit: schreibgeschützt."
        case .binary: "Binärdatei: nur Anzeige."
        case .tooLarge: "Zu groß zum Bearbeiten."
        case .notRegularFile: "Keine normale Datei (zum Beispiel ein symbolischer Link)."
        case .protectedPath: "Git- und Werkzeugverzeichnisse werden nicht bearbeitet."
        case .outsideRoot: "Liegt außerhalb des Projektordners."
        case .notUTF8: "Kein UTF-8-Text: nur Anzeige."
        }
    }
}

/// What the document knew about the file when it was opened or last saved.
public struct FileFingerprint: Sendable, Equatable {
    public var sha256: String
    public var size: Int
    public var inode: UInt64
    public var modified: Int64

    public static func of(_ data: Data, attributes: [FileAttributeKey: Any]) -> FileFingerprint {
        FileFingerprint(
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), size: data.count,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            modified: Int64(((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
        )
    }
}

public enum SaveOutcome: Sendable, Equatable {
    case saved(FileFingerprint)
    /// The file changed on disk since it was opened: the user decides (diff of both texts).
    /// `fingerprint` is of exactly the disk version shown; keeping one's own text overwrites
    /// only that version.
    case externalChange(disk: String?, fingerprint: FileFingerprint?)
    case refused(ReadOnlyReason)
}

public enum EditorError: Error, Equatable, Sendable {
    case invalidPath(String)
    case unreadable(String)
}

/// Editor rules (ADR 0007, Plan/macos-und-git.md): only the user's own checkout is writable, and
/// only by the user's explicit Save; the file must be a regular UTF-8 file inside the project root,
/// not under `.git`, `.codex` or `.agents`, at most `maxBytes`. Saving checks the fingerprint
/// taken at open and writes atomically (temporary file, fsync, rename), keeping the mode.
public enum EditorFiles {
    public static let maxBytes = 2 * 1024 * 1024
    static let protectedComponents: Set<String> = [".git", ".codex", ".agents"]

    /// The checked absolute file for `path` under `root`, or why it may not be written.
    public static func resolve(root: String, path: String) -> Result<String, ReadOnlyReason> {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return .failure(.outsideRoot) }
        let components = path.split(separator: "/").map(String.init)
        if components.contains(where: { protectedComponents.contains($0.lowercased()) }) { return .failure(.protectedPath) }
        let rootURL = URL(filePath: root).standardizedFileURL.resolvingSymlinksInPath()
        let file = rootURL.appending(path: path).standardizedFileURL
        // Every existing parent must be a real directory inside the root (no symlinked parents).
        var current = rootURL
        for component in components.dropLast() {
            current = current.appending(path: component)
            var isDirectory: ObjCBool = false
            let attributes = try? FileManager.default.attributesOfItem(atPath: current.path(percentEncoded: false))
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink { return .failure(.notRegularFile) }
            if FileManager.default.fileExists(atPath: current.path(percentEncoded: false), isDirectory: &isDirectory), !isDirectory.boolValue {
                return .failure(.notRegularFile)
            }
        }
        let resolved = file.resolvingSymlinksInPath().path(percentEncoded: false)
        guard resolved.hasPrefix(rootURL.path(percentEncoded: false)) else { return .failure(.outsideRoot) }
        return .success(file.path(percentEncoded: false))
    }

    /// The access for a document given what the store knows about its worktree.
    public static func access(_ id: DocumentID, worktree: WorktreeRecord? = nil, attemptActive: Bool = false) -> DocumentAccess {
        switch id {
        case .commit: return .readOnly(.commit)
        case .worktree:
            if worktree?.state == .frozen { return .readOnly(.frozen) }
            if attemptActive { return .readOnly(.activeAttempt) }
            return .readOnly(.worktree)
        case .checkout: return .writable
        }
    }

    /// Reads a checkout file for editing: its text, fingerprint and access.
    public static func open(root: String, path: String) throws -> (text: String, fingerprint: FileFingerprint?, access: DocumentAccess) {
        let file: String
        switch resolve(root: root, path: path) {
        case .success(let value): file = value
        case .failure(let reason): return ("", nil, .readOnly(reason))
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file) else {
            // A new file: empty, writable.
            return ("", nil, .writable)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return ("", nil, .readOnly(.notRegularFile)) }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else { return ("", nil, .readOnly(.tooLarge)) }
        guard let data = FileManager.default.contents(atPath: file) else { throw EditorError.unreadable(path) }
        let fingerprint = FileFingerprint.of(data, attributes: attributes)
        if data.contains(0) { return ("", fingerprint, .readOnly(.binary)) }
        guard let text = String(data: data, encoding: .utf8) else { return ("", fingerprint, .readOnly(.notUTF8)) }
        return (text, fingerprint, .writable)
    }

    /// Saves `text` if the file still matches `expected` (nil: the file must not exist yet).
    public static func save(root: String, path: String, text: String, expected: FileFingerprint?) throws -> SaveOutcome {
        let file: String
        switch resolve(root: root, path: path) {
        case .success(let value): file = value
        case .failure(let reason): return .refused(reason)
        }
        let data = Data(text.utf8)
        guard data.count <= maxBytes else { return .refused(.tooLarge) }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file)
        if let attributes {
            guard attributes[.type] as? FileAttributeType == .typeRegular else { return .refused(.notRegularFile) }
            let current = FileManager.default.contents(atPath: file) ?? Data()
            let now = FileFingerprint.of(current, attributes: attributes)
            guard let expected, now.sha256 == expected.sha256, now.size == expected.size else {
                return .externalChange(disk: String(data: current, encoding: .utf8), fingerprint: now)
            }
        } else if expected != nil {
            // It existed at open and is gone now.
            return .externalChange(disk: nil, fingerprint: nil)
        }
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        let folder = (file as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let temporary = folder + "/.kaiorx-save-\(UUID().uuidString)"
        let fd = Darwin.open(temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(mode))
        guard fd >= 0 else { throw EditorError.unreadable(path) }
        var ok = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        ok = ok && fsync(fd) == 0 && fchmod(fd, mode_t(mode)) == 0
        Darwin.close(fd)
        guard ok, rename(temporary, file) == 0 else {
            unlink(temporary)
            throw EditorError.unreadable(path)
        }
        let saved = try FileManager.default.attributesOfItem(atPath: file)
        return .saved(FileFingerprint.of(data, attributes: saved))
    }
}

/// The editor's model, without the text view: identity, base text, dirty flag, access, outcome.
/// The text view owns typing and undo.
public struct EditorDocument: Sendable {
    public let id: DocumentID
    public let root: String
    public private(set) var access: DocumentAccess
    public private(set) var base: String
    public private(set) var fingerprint: FileFingerprint?
    public var text: String
    /// The disk version that blocked the last Save (text and its fingerprint), until decided.
    public private(set) var conflict: (disk: String?, fingerprint: FileFingerprint?)?

    public var isDirty: Bool { text != base }
    public var title: String { (id.path as NSString).lastPathComponent }

    public init(id: DocumentID, root: String, text: String, fingerprint: FileFingerprint?, access: DocumentAccess) {
        self.id = id
        self.root = root
        self.access = access
        self.base = text
        self.text = text
        self.fingerprint = fingerprint
    }

    public static func open(_ id: DocumentID, root: String, worktree: WorktreeRecord? = nil, attemptActive: Bool = false) throws -> EditorDocument {
        let opened = try EditorFiles.open(root: root, path: id.path)
        var access = opened.access
        if case .checkout = id {} else { access = EditorFiles.access(id, worktree: worktree, attemptActive: attemptActive) }
        return EditorDocument(id: id, root: root, text: opened.text, fingerprint: opened.fingerprint, access: access)
    }

    /// The explicit Save. Only a writable checkout document saves.
    public mutating func save() throws -> SaveOutcome {
        guard case .checkout = id else {
            if case .readOnly(let reason) = access { return .refused(reason) }
            return .refused(.worktree)
        }
        if case .readOnly(let reason) = access { return .refused(reason) }
        let outcome = try EditorFiles.save(root: root, path: id.path, text: text, expected: fingerprint)
        switch outcome {
        case .saved(let new):
            base = text
            fingerprint = new
            conflict = nil
        case .externalChange(let disk, let fingerprint):
            conflict = (disk, fingerprint)
        case .refused: break
        }
        return outcome
    }

    /// The user keeps the disk version: the buffer becomes the file on disk.
    public mutating func reloadFromDisk() throws {
        let opened = try EditorFiles.open(root: root, path: id.path)
        base = opened.text
        text = opened.text
        fingerprint = opened.fingerprint
        conflict = nil
        if case .checkout = id { access = opened.access }
    }

    /// The user keeps their text after seeing the external change: the next Save overwrites
    /// exactly the disk version they saw, never a newer one (that one blocks again).
    public mutating func keepMine() {
        guard let conflict else { return }
        fingerprint = conflict.fingerprint
        self.conflict = nil
    }

    /// The external change as a line diff (disk version against this buffer).
    public var conflictDiff: [DiffLine] {
        guard let conflict else { return [] }
        return LineDiff.lines(from: conflict.disk ?? "", to: text)
    }
}
