import Domain
import Foundation
import SQLite3

/// A content-free record next to the database of every forget (purge job ID and time), kept
/// outside the database so that restoring an older backup cannot bring forgotten content back
/// (ADR 0007; closes the open point of ADR 0006). One line per job: `<id> <time>`.
public enum PurgeLedger {
    public static func path(for database: String) -> String { database + ".purge-ledger" }

    /// Appends jobs not yet recorded; the file is owner-only and fsynced.
    static func record(_ jobs: [(PurgeJobID, Int64)], database: String) throws {
        guard !jobs.isEmpty else { return }
        let file = path(for: database)
        let known = Set(entries(database: database).map(\.0))
        let lines = jobs.filter { !known.contains($0.0) }.map { "\($0.0.uuidString) \($0.1)\n" }.joined()
        guard !lines.isEmpty else { return }
        let fd = open(file, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SQLiteError(code: SQLITE_CANTOPEN, message: "Cannot open purge ledger: errno \(errno)") }
        defer { close(fd) }
        let data = Data(lines.utf8)
        let ok = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count }
        guard ok, fsync(fd) == 0 else { throw SQLiteError(code: SQLITE_IOERR, message: "Cannot write purge ledger") }
    }

    public static func entries(database: String) -> [(PurgeJobID, Int64)] {
        guard let text = try? String(contentsOfFile: path(for: database), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 2, let id = PurgeJobID(string: String(parts[0])), let at = Int64(parts[1]) else { return nil }
            return (id, at)
        }
    }

    /// The time of the newest forget, or nil if nothing was ever forgotten.
    public static func newest(database: String) -> Int64? { entries(database: database).map(\.1).max() }
}

/// A migration backup the app took before upgrading (`<db>.backup-v<N>-<time>`).
public struct BackupInfo: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var version: Int
    public var time: Int64
}

public enum RestoreError: Error, Equatable, Sendable {
    case notAnAppBackup(String)
    /// Taken before a forget: restoring it would bring forgotten content back.
    case predatesForget(backupTime: Int64, forgetTime: Int64)
    case databaseNewerThanApp(databaseVersion: Int, appVersion: Int)
    case checksumMismatch(version: Int)
    case integrityFailed(String)
    case schemaDiffers(version: Int)
    case databaseInUse(String)
}

public struct RestoreReport: Sendable, Equatable {
    public var restored: BackupInfo
    /// The database as it was before the restore, kept as a backup itself.
    public var previousBackup: String?
}

/// Restoring a migration backup (package H). The store must be closed: the restore takes the
/// same process lock. Validation runs on a private copy, never on the backup itself.
public enum BackupRestore {
    /// The app's own migration backups of `database`, newest first.
    public static func backups(of database: String) -> [BackupInfo] {
        let url = URL(filePath: database)
        let folder = url.deletingLastPathComponent().path(percentEncoded: false)
        let prefix = url.lastPathComponent + ".backup-v"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.compactMap { name -> BackupInfo? in
            guard name.hasPrefix(prefix) else { return nil }
            let rest = name.dropFirst(prefix.count).split(separator: "-")
            guard rest.count == 2, let version = Int(rest[0]), let time = Int64(rest[1]) else { return nil }
            let path = URL(filePath: folder).appending(path: name).path(percentEncoded: false)
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return BackupInfo(path: path, name: name, version: version, time: time)
        }.sorted { ($0.time, $0.name) > ($1.time, $1.name) }
    }

    /// Checks a backup: an app backup of this database, not older than the newest forget, a
    /// schema version this build knows with unchanged migrations, intact, and the same schema as
    /// a fresh database at that version.
    public static func validate(_ backup: BackupInfo, database: String, migrations: [Migration] = CoreSchema.migrations) throws -> Int {
        guard backups(of: database).contains(where: { $0.path == backup.path }) else { throw RestoreError.notAnAppBackup(backup.name) }
        if let forget = PurgeLedger.newest(database: database), backup.time <= forget {
            throw RestoreError.predatesForget(backupTime: backup.time, forgetTime: forget)
        }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "kaiorx-restore-\(UUID().uuidString)").path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let copy = scratch + "/check.sqlite"
        let source = try SQLiteConnection(path: backup.path, readOnly: true)
        defer { source.close() }
        try source.backup(to: copy)
        let checked = try SQLiteConnection(path: copy)
        defer { checked.close() }
        let version: Int
        do {
            version = try Migrator.validatedVersion(checked, migrations: migrations)
        } catch MigrationError.databaseNewerThanApp(let db, let app) {
            throw RestoreError.databaseNewerThanApp(databaseVersion: db, appVersion: app)
        } catch MigrationError.checksumMismatch(let version) {
            throw RestoreError.checksumMismatch(version: version)
        }
        let integrity = try checked.query("PRAGMA integrity_check") { $0.text(0) ?? "" }
        guard integrity == ["ok"] else { throw RestoreError.integrityFailed(integrity.prefix(3).joined(separator: "; ")) }
        let violations = try checked.query("PRAGMA foreign_key_check") { $0.text(0) ?? "" }
        guard violations.isEmpty else { throw RestoreError.integrityFailed("foreign keys: \(violations.count)") }
        // Same tables, indexes and triggers as this build creates for that version.
        let fresh = try SQLiteConnection(path: scratch + "/fresh.sqlite")
        defer { fresh.close() }
        try fresh.configure()
        _ = try Migrator.migrate(fresh, migrations: Array(migrations.prefix(version)), databasePath: nil, now: 0)
        func schema(_ db: SQLiteConnection) throws -> [String] {
            try db.query("SELECT type || ' ' || name || ' ' || COALESCE(sql, '') FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name") {
                try $0.requiredText(0)
            }
        }
        guard try schema(checked) == schema(fresh) else { throw RestoreError.schemaDiffers(version: version) }
        return version
    }

    /// The newest forget the current database itself knows (its purge jobs commit with the
    /// forget), nil if it has none or cannot be read.
    static func newestForgetInDatabase(_ database: String) -> Int64? {
        guard FileManager.default.fileExists(atPath: database), let db = try? SQLiteConnection(path: database, readOnly: false) else { return nil }
        defer { db.close() }
        return (try? db.query("SELECT MAX(at) FROM purge_job") { $0.optionalInt(0) })?.first ?? nil
    }

    /// The marker that consents must be revoked once the restored database opens; it stays until
    /// the revocation succeeded, across failed starts.
    public static func consentMarker(for database: String) -> String { database + ".revoke-consents" }

    /// Replaces the database with the backup after validating it. The current database is kept
    /// as a new backup first (a damaged one as a plain file copy). Open the store afterwards: it
    /// migrates forward, and the consent marker makes the next start revoke every consent.
    /// The process lock guarantees no app runs on this database meanwhile.
    public static func restore(_ backup: BackupInfo, database: String, now: Int64, migrations: [Migration] = CoreSchema.migrations) throws -> RestoreReport {
        let lock = open(Store.lockPath(for: database), O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw RestoreError.databaseInUse(database) }
        defer { close(lock) }
        // The short retry of `Store.acquireLock`: a child spawned on another thread briefly holds a
        // copy of a just-closed store's lock until its exec. A running app keeps it and is refused.
        guard Store.acquireLock(lock) else { throw RestoreError.databaseInUse(database) }
        // A forget the ledger missed (its write failed) still counts: the database knows it.
        if let forget = newestForgetInDatabase(database), backup.time <= forget {
            throw RestoreError.predatesForget(backupTime: backup.time, forgetTime: forget)
        }
        _ = try validate(backup, database: database, migrations: migrations)
        var previous: String?
        if FileManager.default.fileExists(atPath: database) {
            var time = now
            func free(_ name: String) -> String {
                while FileManager.default.fileExists(atPath: name.replacingOccurrences(of: "{t}", with: String(time))) { time += 1 }
                return name.replacingOccurrences(of: "{t}", with: String(time))
            }
            let version = (try? SQLiteConnection(path: database)).flatMap { current -> Int64? in
                defer { current.close() }
                return (try? current.query("SELECT COALESCE(MAX(version), 0) FROM schema_migration") { $0.int(0) })?.first
            }
            if let version, let current = try? SQLiteConnection(path: database), (try? current.backup(to: free("\(database).backup-v\(version)-{t}"))) != nil {
                current.close()
                previous = "\(database).backup-v\(version)-\(time)"
            } else {
                // Unreadable as a database: keep the bytes as they are, outside the backup list.
                let damaged = free("\(database).damaged-{t}")
                try FileManager.default.copyItem(atPath: database, toPath: damaged)
                for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: database + suffix) {
                    try? FileManager.default.copyItem(atPath: database + suffix, toPath: damaged + suffix)
                }
                previous = damaged
                for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: database + suffix) }
            }
        }
        // Before the copy: if anything after it fails, the next start still revokes.
        try Data(String(now).utf8).write(to: URL(filePath: consentMarker(for: database)), options: .atomic)
        chmod(consentMarker(for: database), 0o600)
        let source = try SQLiteConnection(path: backup.path, readOnly: true)
        defer { source.close() }
        let destination = try SQLiteConnection(path: database)
        defer { destination.close() }
        chmod(database, 0o600)
        try destination.configure()
        try source.copy(into: destination)
        try destination.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        return RestoreReport(restored: backup, previousBackup: previous)
    }
}
