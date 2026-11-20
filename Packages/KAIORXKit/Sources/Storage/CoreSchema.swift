/// Package B subset of the relational schema in Plan/laufzeitvertrag.md. Tables for policy,
/// consent, accounts, plans, worktrees, budgets, candidates and Git operations follow as new
/// migrations with their packages; applied migrations are never edited.
public enum CoreSchema {
    public static let migrations: [Migration] = [v1, v2, v3, v4]

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

    /// Package C: Git identity, worktrees and the journal of Git side effects.
    static let v2 = Migration(version: 2, name: "workspace", sql: """
        ALTER TABLE project ADD COLUMN object_format TEXT CHECK (object_format IN ('sha1', 'sha256'));
        ALTER TABLE job ADD COLUMN base_oid TEXT;
        ALTER TABLE job ADD COLUMN integration_ref TEXT;
        CREATE UNIQUE INDEX job_integration_ref ON job (integration_ref) WHERE integration_ref IS NOT NULL;

        CREATE TABLE worktree (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project(id),
            attempt_id TEXT UNIQUE REFERENCES attempt(id),
            path_token TEXT NOT NULL UNIQUE,
            base_oid TEXT NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ('author', 'reviewer', 'qa', 'integration')),
            owner_nonce TEXT NOT NULL CHECK (length(owner_nonce) >= 16),
            state TEXT NOT NULL CHECK (state IN ('preparing', 'ready', 'frozen', 'removing', 'removed', 'needsAttention')),
            result_oid TEXT,
            saved_tree TEXT,
            -- Outcome of sealing: committed result, no change at all, or only rejected changes.
            seal_status TEXT CHECK (seal_status IN ('committed', 'empty', 'rejectedOnly')),
            -- JSON object path -> rejection reason, kept with the result.
            rejected_json TEXT,
            version INTEGER NOT NULL CHECK (version >= 1),
            created_at INTEGER NOT NULL,
            CHECK ((seal_status = 'committed') = (result_oid IS NOT NULL))
        ) STRICT;
        CREATE INDEX worktree_project_state ON worktree (project_id, state);

        ALTER TABLE attempt ADD COLUMN worktree_id TEXT REFERENCES worktree(id);

        -- Written and committed before the Git side effect; recovery compares it with Git.
        CREATE TABLE git_operation (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project(id),
            worktree_id TEXT REFERENCES worktree(id),
            kind TEXT NOT NULL CHECK (kind IN ('updateRef', 'addWorktree', 'removeWorktree')),
            ref TEXT CHECK (ref IS NULL OR ref LIKE 'refs/kaiorx/%'),
            expected_old TEXT,
            desired_new TEXT,
            state TEXT NOT NULL CHECK (state IN ('prepared', 'applied', 'failed', 'needsAttention')),
            detail TEXT,
            -- A removal decided with force (no unsaved-work check); recovery finishes it the same way.
            force INTEGER NOT NULL DEFAULT 0 CHECK (force IN (0, 1)),
            created_at INTEGER NOT NULL,
            applied_at INTEGER,
            CHECK (force = 0 OR kind = 'removeWorktree'),
            CHECK ((kind = 'updateRef') = (ref IS NOT NULL AND desired_new IS NOT NULL)),
            CHECK (kind = 'updateRef' OR worktree_id IS NOT NULL)
        ) STRICT;
        CREATE UNIQUE INDEX git_operation_open_ref ON git_operation (project_id, ref)
            WHERE state = 'prepared' AND ref IS NOT NULL;
        CREATE UNIQUE INDEX git_operation_open_worktree ON git_operation (worktree_id)
            WHERE state = 'prepared' AND kind <> 'updateRef';
        CREATE INDEX git_operation_state ON git_operation (state, created_at);
        """)

    /// Package E: integration candidates, their evidence, approvals and publication journal links.
    static let v3 = Migration(version: 3, name: "integration", sql: """
        CREATE TABLE candidate (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project(id),
            job_id TEXT NOT NULL REFERENCES job(id),
            task_id TEXT REFERENCES task(id),
            kind TEXT NOT NULL CHECK (kind IN ('implementation', 'revert')),
            author_attempt_id TEXT REFERENCES attempt(id),
            author_provider TEXT CHECK (author_provider IN ('claude', 'codex', 'fake')),
            result_oid TEXT,
            reverts_candidate_id TEXT REFERENCES candidate(id),
            previous_target_oid TEXT NOT NULL,
            candidate_oid TEXT,
            target_ref TEXT NOT NULL CHECK (target_ref LIKE 'refs/kaiorx/integrations/%'),
            worktree_id TEXT REFERENCES worktree(id),
            state TEXT NOT NULL CHECK (state IN
                ('conflicted', 'built', 'testing', 'reviewing', 'accepted', 'publishing', 'published', 'rejected', 'superseded')),
            conflicts_json TEXT NOT NULL DEFAULT '[]',
            version INTEGER NOT NULL CHECK (version >= 1),
            created_at INTEGER NOT NULL,
            -- An implementation needs its author attempt and result; a revert names what it reverts.
            CHECK ((kind = 'implementation' AND author_attempt_id IS NOT NULL AND result_oid IS NOT NULL AND task_id IS NOT NULL)
                OR (kind = 'revert' AND reverts_candidate_id IS NOT NULL)),
            CHECK (state IN ('conflicted', 'rejected', 'superseded') OR candidate_oid IS NOT NULL)
        ) STRICT;
        CREATE INDEX candidate_job_state ON candidate (job_id, state);
        -- At most one publication in flight per integration target.
        CREATE UNIQUE INDEX candidate_one_publishing ON candidate (target_ref) WHERE state = 'publishing';

        CREATE TABLE test_result (
            id TEXT PRIMARY KEY NOT NULL,
            candidate_id TEXT NOT NULL REFERENCES candidate(id),
            candidate_oid TEXT NOT NULL,
            profile_digest TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('passed', 'failed', 'crashed', 'timedOut', 'inputsModified', 'infrastructureError')),
            exit_code INTEGER,
            changed_test_inputs_json TEXT NOT NULL DEFAULT '[]',
            summary TEXT NOT NULL,
            at INTEGER NOT NULL
        ) STRICT;
        CREATE INDEX test_result_candidate ON test_result (candidate_id, at);

        CREATE TABLE review (
            id TEXT PRIMARY KEY NOT NULL,
            candidate_id TEXT NOT NULL REFERENCES candidate(id),
            candidate_oid TEXT NOT NULL,
            reviewer_attempt_id TEXT REFERENCES attempt(id),
            origin TEXT NOT NULL CHECK (origin IN ('provider', 'userImported')),
            reviewer_provider TEXT CHECK (reviewer_provider IN ('claude', 'codex', 'fake')),
            status TEXT NOT NULL CHECK (status IN ('approved', 'changesRequested', 'invalid')),
            summary TEXT NOT NULL,
            at INTEGER NOT NULL,
            CHECK (origin = 'userImported' OR (reviewer_attempt_id IS NOT NULL AND reviewer_provider IS NOT NULL))
        ) STRICT;
        CREATE INDEX review_candidate ON review (candidate_id, at);

        CREATE TABLE finding (
            id TEXT PRIMARY KEY NOT NULL,
            review_id TEXT NOT NULL REFERENCES review(id),
            severity TEXT NOT NULL CHECK (severity IN ('blocking', 'major', 'minor', 'comment')),
            path TEXT,
            line INTEGER,
            impact TEXT NOT NULL,
            suggestion TEXT NOT NULL,
            disposition TEXT NOT NULL CHECK (disposition IN ('open', 'accepted', 'rejected')),
            reason TEXT,
            CHECK (disposition = 'open' OR length(reason) > 0),
            CHECK (severity <> 'blocking' OR disposition <> 'accepted')
        ) STRICT;
        CREATE INDEX finding_review ON finding (review_id);

        CREATE TABLE approval (
            id TEXT PRIMARY KEY NOT NULL,
            candidate_id TEXT NOT NULL REFERENCES candidate(id),
            candidate_oid TEXT NOT NULL,
            expected_old_oid TEXT NOT NULL,
            target_ref TEXT NOT NULL,
            action TEXT NOT NULL CHECK (action IN ('publishIntegration')),
            policy_version INTEGER NOT NULL,
            actor TEXT NOT NULL CHECK (length(actor) > 0),
            state TEXT NOT NULL CHECK (state IN ('granted', 'consumed', 'revoked')),
            granted_at INTEGER NOT NULL,
            resolved_at INTEGER,
            CHECK ((state = 'granted') = (resolved_at IS NULL))
        ) STRICT;
        CREATE INDEX approval_candidate_state ON approval (candidate_id, state);

        ALTER TABLE task ADD COLUMN integrated_oid TEXT;
        ALTER TABLE git_operation ADD COLUMN candidate_id TEXT REFERENCES candidate(id);
        ALTER TABLE git_operation ADD COLUMN approval_id TEXT REFERENCES approval(id);
        """)

    /// Package F (ADR 0005): plan revisions, consent, model profiles, budgets, quota and decisions.
    static let v4 = Migration(version: 4, name: "planning", sql: """
        CREATE TABLE plan_revision (
            id TEXT PRIMARY KEY NOT NULL,
            job_id TEXT NOT NULL REFERENCES job(id),
            rev INTEGER NOT NULL CHECK (rev >= 1),
            created_by TEXT NOT NULL CHECK (created_by IN ('user', 'planner')),
            digest TEXT NOT NULL,
            draft_json TEXT NOT NULL,
            estimate_json TEXT NOT NULL DEFAULT '{}',
            created_at INTEGER NOT NULL,
            validated_at INTEGER NOT NULL,
            accepted_at INTEGER,
            superseded_at INTEGER,
            UNIQUE (job_id, rev),
            CHECK (superseded_at IS NULL OR accepted_at IS NOT NULL)
        ) STRICT;

        CREATE TABLE plan_task (
            plan_id TEXT NOT NULL REFERENCES plan_revision(id),
            key TEXT NOT NULL CHECK (length(key) > 0),
            -- Set when the revision is accepted (new keys get their task then).
            task_id TEXT REFERENCES task(id),
            title TEXT NOT NULL,
            goal TEXT NOT NULL,
            criteria_json TEXT NOT NULL,
            read_paths_json TEXT NOT NULL,
            -- NULL: unknown, the whole project.
            write_paths_json TEXT,
            risk TEXT NOT NULL CHECK (risk IN ('normal', 'sensitive')),
            difficulty_json TEXT NOT NULL,
            tier TEXT NOT NULL CHECK (tier IN ('fast', 'standard', 'intensive')),
            uncertain INTEGER NOT NULL CHECK (uncertain IN (0, 1)),
            test_profile TEXT,
            PRIMARY KEY (plan_id, key)
        ) STRICT;
        CREATE UNIQUE INDEX plan_task_task ON plan_task (plan_id, task_id) WHERE task_id IS NOT NULL;

        CREATE TABLE dependency (
            plan_id TEXT NOT NULL,
            predecessor_key TEXT NOT NULL,
            successor_key TEXT NOT NULL,
            PRIMARY KEY (plan_id, predecessor_key, successor_key),
            FOREIGN KEY (plan_id, predecessor_key) REFERENCES plan_task(plan_id, key),
            FOREIGN KEY (plan_id, successor_key) REFERENCES plan_task(plan_id, key),
            CHECK (predecessor_key <> successor_key)
        ) STRICT;
        CREATE INDEX dependency_successor ON dependency (plan_id, successor_key);

        ALTER TABLE job ADD COLUMN current_plan_id TEXT REFERENCES plan_revision(id);
        ALTER TABLE task ADD COLUMN plan_key TEXT;
        ALTER TABLE task ADD COLUMN wait_reason TEXT;
        ALTER TABLE task ADD COLUMN ready_at INTEGER;
        CREATE UNIQUE INDEX task_plan_key ON task (job_id, plan_key) WHERE plan_key IS NOT NULL;

        CREATE TABLE provider_account (
            id TEXT PRIMARY KEY NOT NULL,
            provider TEXT NOT NULL CHECK (provider IN ('claude', 'codex', 'fake')),
            opaque_identity TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            UNIQUE (provider, opaque_identity)
        ) STRICT;

        CREATE TABLE consent (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project(id),
            job_id TEXT REFERENCES job(id),
            provider TEXT NOT NULL CHECK (provider IN ('claude', 'codex', 'fake')),
            account_id TEXT NOT NULL REFERENCES provider_account(id),
            mode TEXT NOT NULL CHECK (mode IN ('automatic', 'manual')),
            roles_json TEXT NOT NULL,
            write_roots_json TEXT NOT NULL,
            sensitive_roots_json TEXT NOT NULL,
            unconfirmed_attempt_limit INTEGER CHECK (unconfirmed_attempt_limit >= 0),
            scope_digest TEXT NOT NULL,
            granted_at INTEGER NOT NULL,
            expires_at INTEGER,
            revoked_at INTEGER
        ) STRICT;
        CREATE INDEX consent_project ON consent (project_id, provider);

        CREATE TABLE model_profile (
            id TEXT PRIMARY KEY NOT NULL,
            provider TEXT NOT NULL CHECK (provider IN ('claude', 'codex', 'fake')),
            role TEXT NOT NULL CHECK (role IN ('author', 'reviewer')),
            tier TEXT NOT NULL CHECK (tier IN ('fast', 'standard', 'intensive')),
            model TEXT NOT NULL,
            effort TEXT,
            context_limit INTEGER,
            typical_tokens INTEGER CHECK (typical_tokens >= 0),
            observed_duration_ms INTEGER,
            verified_at INTEGER,
            disabled_reason TEXT,
            created_at INTEGER NOT NULL
        ) STRICT;

        ALTER TABLE attempt ADD COLUMN base_oid TEXT;
        ALTER TABLE attempt ADD COLUMN account_id TEXT REFERENCES provider_account(id);
        ALTER TABLE attempt ADD COLUMN model_profile_id TEXT REFERENCES model_profile(id);
        ALTER TABLE attempt ADD COLUMN plan_id TEXT REFERENCES plan_revision(id);
        ALTER TABLE attempt ADD COLUMN tier TEXT CHECK (tier IN ('fast', 'standard', 'intensive'));
        ALTER TABLE attempt ADD COLUMN consent_id TEXT REFERENCES consent(id);
        CREATE INDEX attempt_account_state ON attempt (account_id, state);

        CREATE TABLE budget_bucket (
            id TEXT PRIMARY KEY NOT NULL,
            account_id TEXT NOT NULL REFERENCES provider_account(id),
            job_id TEXT NOT NULL REFERENCES job(id),
            token_limit INTEGER NOT NULL CHECK (token_limit >= 0),
            created_at INTEGER NOT NULL,
            UNIQUE (account_id, job_id)
        ) STRICT;

        CREATE TABLE reservation (
            id TEXT PRIMARY KEY NOT NULL,
            attempt_id TEXT NOT NULL UNIQUE REFERENCES attempt(id),
            bucket_id TEXT NOT NULL REFERENCES budget_bucket(id),
            reserved_tokens INTEGER NOT NULL CHECK (reserved_tokens >= 0),
            -- The size came from a fixed start value, not from the profile.
            size_uncertain INTEGER NOT NULL CHECK (size_uncertain IN (0, 1)),
            settled_tokens INTEGER,
            state TEXT NOT NULL CHECK (state IN ('held', 'settled', 'unresolved', 'released')),
            created_at INTEGER NOT NULL,
            settled_at INTEGER,
            CHECK ((state = 'settled') = (settled_tokens IS NOT NULL))
        ) STRICT;
        CREATE INDEX reservation_bucket_state ON reservation (bucket_id, state);

        CREATE TABLE quota_observation (
            id TEXT PRIMARY KEY NOT NULL,
            account_id TEXT NOT NULL REFERENCES provider_account(id),
            window_key TEXT NOT NULL,
            unit TEXT NOT NULL CHECK (unit IN ('percent', 'requests', 'tokens')),
            observed_limit INTEGER,
            observed_used INTEGER,
            reset_at INTEGER,
            observed_at INTEGER NOT NULL,
            source TEXT NOT NULL
        ) STRICT;
        CREATE INDEX quota_observation_window ON quota_observation (account_id, window_key, unit, observed_at);

        CREATE TABLE quota_block (
            id TEXT PRIMARY KEY NOT NULL,
            account_id TEXT NOT NULL REFERENCES provider_account(id),
            reason TEXT NOT NULL CHECK (reason IN ('rateLimited', 'usageLimit', 'revoked', 'planStop', 'manual')),
            -- NULL: until released by the user (once, if no reset is known).
            until INTEGER,
            -- Consecutive blocks of the account, for the doubling fallback.
            sequence INTEGER NOT NULL CHECK (sequence >= 1),
            created_at INTEGER NOT NULL,
            released_at INTEGER,
            released_by TEXT CHECK (released_by IN ('expiry', 'user')),
            CHECK ((released_at IS NULL) = (released_by IS NULL))
        ) STRICT;
        CREATE INDEX quota_block_account ON quota_block (account_id, released_at);

        CREATE TABLE decision (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project(id),
            job_id TEXT REFERENCES job(id),
            task_id TEXT REFERENCES task(id),
            attempt_id TEXT REFERENCES attempt(id),
            account_id TEXT REFERENCES provider_account(id),
            rule_version INTEGER NOT NULL,
            rule TEXT NOT NULL,
            evidence_json TEXT NOT NULL,
            outcome TEXT NOT NULL,
            actor TEXT NOT NULL CHECK (length(actor) > 0),
            remaining_attempts INTEGER,
            alternative TEXT,
            at INTEGER NOT NULL
        ) STRICT;
        CREATE INDEX decision_task ON decision (task_id, at);
        """)
}
