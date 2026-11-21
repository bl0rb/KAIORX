import Domain
import Foundation

/// One ordered, atomic schema step. The checksum detects an applied migration whose SQL changed.
public struct Migration: Sendable, Equatable {
    public let version: Int
    public let name: String
    public let sql: String

    public init(version: Int, name: String, sql: String) {
        self.version = version
        self.name = name
        self.sql = sql
    }

    public var checksum: String { Canonical.sha256Hex(Data(sql.utf8)) }
}

public enum MigrationError: Error, Equatable, Sendable {
    /// Versions must start at 1 and increase by one.
    case invalidSequence
    /// An applied migration differs from the one this build ships.
    case checksumMismatch(version: Int)
    /// The database was written by a newer build.
    case databaseNewerThanApp(databaseVersion: Int, appVersion: Int)
}

public struct MigrationReport: Sendable, Equatable {
    public var previousVersion: Int
    public var appliedVersions: [Int]
    /// Online backup taken before upgrading an existing database.
    public var backupPath: String?
}

enum Migrator {
    static func migrate(
        _ db: SQLiteConnection, migrations: [Migration], databasePath: String?, now: Int64
    ) throws -> MigrationReport {
        guard migrations.map(\.version) == Array(stride(from: 1, through: migrations.count, by: 1)) else {
            throw MigrationError.invalidSequence
        }
        try db.execute("""
            CREATE TABLE IF NOT EXISTS schema_migration (
                version INTEGER PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                checksum TEXT NOT NULL,
                applied_at INTEGER NOT NULL
            ) STRICT;
            """)

        // `Store` holds the process lock, so no other process migrates concurrently. The backup
        // needs a read-only source connection and is taken first; the write transaction then
        // validates again and applies every pending migration atomically: the database either
        // reaches the app version or stays where it was.
        let before = try validatedVersion(db, migrations: migrations)
        var backupPath: String?
        if before > 0, before < (migrations.last?.version ?? 0), let databasePath {
            // Two backups of one version in the same millisecond (a restore, then the upgrade):
            // the next free millisecond, so no backup is overwritten or refused.
            var time = now
            while FileManager.default.fileExists(atPath: "\(databasePath).backup-v\(before)-\(time)") { time += 1 }
            let path = "\(databasePath).backup-v\(before)-\(time)"
            try db.backup(to: path)
            backupPath = path
        }
        return try db.transaction {
            let databaseVersion = try validatedVersion(db, migrations: migrations)
            var report = MigrationReport(previousVersion: databaseVersion, appliedVersions: [], backupPath: backupPath)
            for migration in migrations where migration.version > databaseVersion {
                try db.execute(migration.sql)
                try db.run(
                    "INSERT INTO schema_migration (version, name, checksum, applied_at) VALUES (?, ?, ?, ?)",
                    [.integer(Int64(migration.version)), .text(migration.name), .text(migration.checksum), .integer(now)]
                )
                report.appliedVersions.append(migration.version)
            }
            return report
        }
    }

    /// Current database version after checking it is not newer than the app and that every applied
    /// migration is unchanged.
    static func validatedVersion(_ db: SQLiteConnection, migrations: [Migration]) throws -> Int {
        let applied = try db.query("SELECT version, checksum FROM schema_migration ORDER BY version") {
            (version: Int($0.int(0)), checksum: try $0.requiredText(1))
        }
        let known = Dictionary(uniqueKeysWithValues: migrations.map { ($0.version, $0) })
        let appVersion = migrations.last?.version ?? 0
        let databaseVersion = applied.last?.version ?? 0
        if databaseVersion > appVersion {
            throw MigrationError.databaseNewerThanApp(databaseVersion: databaseVersion, appVersion: appVersion)
        }
        for row in applied {
            guard let migration = known[row.version], migration.checksum == row.checksum else {
                throw MigrationError.checksumMismatch(version: row.version)
            }
        }
        return databaseVersion
    }
}
