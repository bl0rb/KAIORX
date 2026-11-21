import Domain
import Foundation

public enum TestProfileStoreError: Error, Equatable, Sendable {
    case invalid([TestProfileIssue])
    /// The profile is no longer what the confirmation sheet showed: confirm what is stored now.
    case digestChanged(shown: String, stored: String)
    case actorRequired
}

/// The test profile registry (ADR 0010). Profiles belong to a project and are found by name;
/// only a confirmed profile runs, and a confirmation covers exactly one digest.
extension Store {
    /// Proposes a profile, or replaces the content of the project's profile with the same name.
    /// Changed content drops the confirmation; the same content keeps it.
    @discardableResult
    public func proposeTestProfile(project: ProjectID, _ draft: TestProfileSpec) throws -> TestProfileRecord {
        let spec = draft.normalized()
        let issues = spec.issues
        guard issues.isEmpty else { throw TestProfileStoreError.invalid(issues) }
        let digest = spec.digest
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            try requireExists(db, table: "project", id: project.uuidString)
            let existing = try db.query(
                "SELECT id FROM test_profile WHERE project_id = ? AND name = ?", [.text(project.uuidString), .text(spec.name)]
            ) { try parseID($0.requiredText(0)) as TestProfileID }.first
            let id = existing ?? TestProfileID()
            let values: [SQLValue] = [
                .text(spec.executable), .text(try Self.json(spec.arguments)), .text(spec.workingDirectory), .integer(Int64(spec.timeoutSeconds)),
                .integer(spec.writesWorktree ? 1 : 0), .text(try Self.json(spec.testInputPrefixes)), .text(digest), .integer(now),
            ]
            if let existing {
                let before = try loadTestProfile(db, existing)
                if before.digest == digest, before.spec == spec { return before }
                // New content: the old confirmation does not cover it.
                try db.run(
                    """
                    UPDATE test_profile SET executable = ?, arguments_json = ?, working_directory = ?, timeout_seconds = ?,
                        writes_worktree = ?, test_input_prefixes_json = ?, digest = ?, updated_at = ?,
                        confirmed_digest = NULL, confirmed_at = NULL, confirmed_by = NULL
                    WHERE id = ?
                    """,
                    values + [.text(existing.uuidString)]
                )
            } else {
                try db.run(
                    """
                    INSERT INTO test_profile (executable, arguments_json, working_directory, timeout_seconds, writes_worktree,
                        test_input_prefixes_json, digest, updated_at, id, project_id, name, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    values + [.text(id.uuidString), .text(project.uuidString), .text(spec.name), .integer(now)]
                )
            }
            try appendProfileEvent(db, project: project, id: id, action: "proposed", digest: digest, actor: nil, now: now)
            return try loadTestProfile(db, id)
        }
    }

    /// The user's confirmation of exactly the digest the sheet showed. Refused when the stored
    /// profile has another digest, or its content no longer matches its digest.
    @discardableResult
    public func confirmTestProfile(_ id: TestProfileID, digest shown: String, actor: String) throws -> TestProfileRecord {
        guard !actor.trimmingCharacters(in: .whitespaces).isEmpty else { throw TestProfileStoreError.actorRequired }
        let db = try connection()
        let now = currentTime()
        return try db.transaction {
            let profile = try loadTestProfile(db, id)
            guard profile.digest == shown, profile.spec.digest == shown else {
                throw TestProfileStoreError.digestChanged(shown: shown, stored: profile.digest)
            }
            if profile.isConfirmed { return profile }
            try db.run(
                "UPDATE test_profile SET confirmed_digest = ?, confirmed_at = ?, confirmed_by = ? WHERE id = ? AND digest = ?",
                [.text(shown), .integer(now), .text(actor), .text(id.uuidString), .text(shown)]
            )
            try appendProfileEvent(db, project: profile.projectID, id: id, action: "confirmed", digest: shown, actor: actor, now: now)
            return try loadTestProfile(db, id)
        }
    }

    /// Removes a profile. Test results keep their digest; they no longer count for the gate.
    public func removeTestProfile(_ id: TestProfileID) throws {
        let db = try connection()
        let now = currentTime()
        try db.transaction {
            let profile = try loadTestProfile(db, id)
            try db.run("DELETE FROM test_profile WHERE id = ?", [.text(id.uuidString)])
            try appendProfileEvent(db, project: profile.projectID, id: id, action: "removed", digest: profile.digest, actor: nil, now: now)
        }
    }

    public func testProfiles(project: ProjectID) throws -> [TestProfileRecord] {
        let db = try connection()
        let ids = try db.query("SELECT id FROM test_profile WHERE project_id = ? ORDER BY name, id", [.text(project.uuidString)]) {
            try parseID($0.requiredText(0)) as TestProfileID
        }
        return try ids.map { try loadTestProfile(db, $0) }
    }

    public func testProfile(_ id: TestProfileID) throws -> TestProfileRecord? {
        let db = try connection()
        do { return try loadTestProfile(db, id) } catch StoreError.notFound { return nil }
    }

    private func appendProfileEvent(
        _ db: SQLiteConnection, project: ProjectID, id: TestProfileID, action: String, digest: String, actor: String?, now: Int64
    ) throws {
        var payload = ["testProfileID": id.uuidString, "action": action, "digest": digest]
        if let actor { payload["actor"] = actor }
        try appendEvent(
            db, kind: .policyDecided, projectID: project.uuidString, taskID: nil, attemptID: nil, payload: Canonical.encode(payload),
            dedupKey: nil, now: now
        )
    }

    func loadTestProfile(_ db: SQLiteConnection, _ id: TestProfileID) throws -> TestProfileRecord {
        guard let profile = try db.query(
            """
            SELECT id, project_id, name, executable, arguments_json, working_directory, timeout_seconds, writes_worktree,
                test_input_prefixes_json, digest, confirmed_digest, confirmed_at, confirmed_by, created_at, updated_at
            FROM test_profile WHERE id = ?
            """,
            [.text(id.uuidString)], { row in
                TestProfileRecord(
                    id: try parseID(row.requiredText(0)), projectID: try parseID(row.requiredText(1)),
                    spec: TestProfileSpec(
                        name: try row.requiredText(2), executable: try row.requiredText(3), arguments: try Self.decode(row.requiredText(4)),
                        workingDirectory: try row.requiredText(5), timeoutSeconds: Int(row.int(6)), writesWorktree: row.int(7) == 1,
                        testInputPrefixes: try Self.decode(row.requiredText(8))
                    ),
                    digest: try row.requiredText(9), confirmedDigest: row.text(10), confirmedAt: row.optionalInt(11), confirmedBy: row.text(12),
                    createdAt: row.int(13), updatedAt: row.int(14)
                )
            }
        ).first else { throw StoreError.notFound(entity: "test profile", id: id.uuidString) }
        return profile
    }
}
