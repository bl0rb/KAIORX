/// Package B subset of the relational schema in Plan/laufzeitvertrag.md. Tables for policy,
/// consent, accounts, plans, worktrees, budgets, candidates and Git operations follow as new
/// migrations with their packages; applied migrations are never edited.
public enum CoreSchema {
    public static let migrations: [Migration] = [v1]

    static let v1 = Migration(version: 1, name: "core", sql: """
        CREATE TABLE project (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            root_locator TEXT NOT NULL UNIQUE,
            git_common_identity TEXT UNIQUE,
            created_at INTEGER NOT NULL,
            archived_at INTEGER
        ) STRICT;

        CREATE TABLE artifact (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT REFERENCES project(id),
            kind TEXT NOT NULL CHECK (kind IN ('goal', 'eventPayload')),
            path_token TEXT,
            inline_content BLOB,
            digest TEXT NOT NULL,
            byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
            sensitivity TEXT NOT NULL CHECK (sensitivity IN ('normal', 'sensitive')),
            expires_at INTEGER
        ) STRICT;

        CREATE TABLE job (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project(id),
            goal_artifact_id TEXT NOT NULL REFERENCES artifact(id),
            state TEXT NOT NULL CHECK (state IN
                ('draft', 'planned', 'active', 'done', 'paused', 'cancelled', 'needsAttention')),
            state_reason TEXT,
            -- Stage interrupted by `paused`/`needsAttention`; the only main-path state to return to.
            resume_state TEXT CHECK (resume_state IN ('draft', 'planned', 'active')),
            version INTEGER NOT NULL CHECK (version >= 1),
            created_at INTEGER NOT NULL,
            CHECK (state NOT IN ('paused', 'cancelled', 'needsAttention') OR length(state_reason) > 0),
            CHECK ((state IN ('paused', 'needsAttention')) = (resume_state IS NOT NULL))
        ) STRICT;

        CREATE TABLE task (
            id TEXT PRIMARY KEY NOT NULL,
            job_id TEXT NOT NULL REFERENCES job(id),
            title TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN
                ('pending', 'ready', 'running', 'resultReady', 'verifying', 'awaitingMerge', 'integrated',
                 'conflict', 'blocked', 'needsChanges', 'noResult', 'failed', 'cancelled')),
            current_attempt_id TEXT REFERENCES attempt(id) DEFERRABLE INITIALLY DEFERRED,
            -- Stage interrupted by `blocked`/`conflict`/`needsChanges`.
            resume_state TEXT CHECK (resume_state IN
                ('pending', 'ready', 'running', 'resultReady', 'verifying', 'awaitingMerge')),
            version INTEGER NOT NULL CHECK (version >= 1),
            created_at INTEGER NOT NULL,
            CHECK ((state IN ('blocked', 'conflict', 'needsChanges')) = (resume_state IS NOT NULL))
        ) STRICT;
        CREATE INDEX task_job_state ON task (job_id, state);

        CREATE TABLE attempt (
            id TEXT PRIMARY KEY NOT NULL,
            task_id TEXT NOT NULL REFERENCES task(id),
            role TEXT NOT NULL CHECK (role IN ('author', 'reviewer')),
            ordinal INTEGER NOT NULL CHECK (ordinal >= 1),
            provider TEXT NOT NULL CHECK (provider IN ('claude', 'codex', 'fake')),
            mode TEXT NOT NULL CHECK (mode IN ('automatic', 'manual')),
            model TEXT NOT NULL,
            effort TEXT,
            state TEXT NOT NULL CHECK (state IN
                ('reserved', 'starting', 'running', 'awaitingApproval', 'cancelling',
                 'succeeded', 'failed', 'cancelled', 'uncertain')),
            spec_digest TEXT NOT NULL,
            session_handle TEXT,
            reserved_at INTEGER NOT NULL,
            started_at INTEGER,
            ended_at INTEGER,
            error_class TEXT,
            version INTEGER NOT NULL CHECK (version >= 1),
            UNIQUE (task_id, role, ordinal),
            CHECK ((state IN ('succeeded', 'failed', 'cancelled')) = (ended_at IS NOT NULL))
        ) STRICT;
        CREATE INDEX attempt_task_started ON attempt (task_id, started_at);
        -- Exactly one active author per task; `uncertain` keeps the slot until reconciled.
        CREATE UNIQUE INDEX attempt_one_active_author ON attempt (task_id)
            WHERE role = 'author' AND state NOT IN ('succeeded', 'failed', 'cancelled');

        CREATE TABLE command (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            request_digest TEXT NOT NULL,
            object_id TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('applied')),
            result_ref TEXT,
            at INTEGER NOT NULL
        ) STRICT;

        CREATE TABLE event (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            event_id TEXT NOT NULL UNIQUE,
            schema_version INTEGER NOT NULL,
            project_id TEXT NOT NULL REFERENCES project(id),
            task_id TEXT REFERENCES task(id),
            attempt_id TEXT REFERENCES attempt(id),
            ordinal INTEGER,
            kind TEXT NOT NULL,
            at INTEGER NOT NULL,
            payload_id TEXT REFERENCES artifact(id),
            dedup_key TEXT,
            CHECK ((attempt_id IS NULL) = (ordinal IS NULL)),
            CHECK (dedup_key IS NULL OR (attempt_id IS NOT NULL AND length(dedup_key) > 0))
        ) STRICT;
        CREATE INDEX event_project_seq ON event (project_id, seq);
        CREATE UNIQUE INDEX event_attempt_ordinal ON event (attempt_id, ordinal) WHERE attempt_id IS NOT NULL;
        CREATE UNIQUE INDEX event_attempt_dedup ON event (attempt_id, dedup_key) WHERE dedup_key IS NOT NULL;
        """)
}
