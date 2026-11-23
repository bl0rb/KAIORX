import Darwin
import Foundation

/// Temporary folders for tests. All of them live in one folder per test process,
/// `$TMPDIR/kaiorx-testrun-<pid>`, which is removed when the process exits. Folders of earlier
/// test processes that no longer run (a crash, a killed run) are removed by the next one.
public enum Scratch {
    static let prefix = "kaiorx-testrun-"

    /// A fresh, empty folder `<label>-<uuid>` in this process's test folder.
    public static func directory(_ label: String) throws -> URL {
        let url = root.appending(path: "\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// This process's test folder, created on first use.
    public static let root: URL = {
        let temporary = FileManager.default.temporaryDirectory
        removeStaleRoots(in: temporary)
        let url = temporary.appending(path: prefix + String(getpid()))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        atexit { Scratch.remove(Scratch.root.path(percentEncoded: false)) }
        return url
    }()

    /// Removes test folders whose process is gone.
    static func removeStaleRoots(in temporary: URL) {
        let folder = temporary.path(percentEncoded: false)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        for name in names where name.hasPrefix(prefix) {
            guard let pid = pid_t(name.dropFirst(prefix.count)), pid != getpid() else { continue }
            if kill(pid, 0) == -1, errno == ESRCH { remove((folder.hasSuffix("/") ? folder : folder + "/") + name) }
        }
    }

    /// Removes a folder, also read-only folders in it (sealed worktrees). Symlinks are removed,
    /// never followed.
    public static func remove(_ folder: String) {
        if let paths = FileManager.default.enumerator(atPath: folder) {
            for case let path as String in paths {
                var info = stat()
                let full = folder + "/" + path
                if lstat(full, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { chmod(full, info.st_mode | S_IRWXU) }
            }
        }
        chmod(folder, S_IRWXU)
        try? FileManager.default.removeItem(atPath: folder)
    }
}
