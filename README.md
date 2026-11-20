# KAIORX
KAIORX is a native macOS AI development environment that orchestrates multiple coding agents, including Claude Code and OpenAI Codex, with intelligent model escalation, parallel workflows, and persistent project memory.

## Status

Early implementation. Planned in Swift 6 for macOS 15+ on Apple silicon.

Package B (local core) is in progress in `Packages/KAIORXKit`:

- **Domain:** typed IDs, state machines for jobs, tasks and attempts, commands, events
- **Storage:** single-writer SQLite store with migrations, an event journal and restart recovery
- **Providers:** the adapter contract and a deterministic fake adapter
- **Orchestration:** run coordinator, plus a workspace service that journals every Git side effect

Package C (workspace and safe runner) is also in progress:

- **ProcessHost:** child processes in their own process group, with an explicit environment, bounded output, stop/drain, and macOS sandbox confinement
- **Workspace:** host Git with sanitized settings, a locked worktree per attempt outside the user's checkout, results committed to private refs, and test runs

Package D (provider adapters) is in progress offline. Adapters exist for Claude Code (headless `stream-json`) and the Codex App Server (stdio JSON-RPC). They are tested against fixture programs, and the Codex messages are checked against the protocol schema of the installed version. Automatic runs stay blocked until the live, user-authorized subscription runs of package A pass. See `docs/adr/0003-anbieteradapter-offline.md`.

Package E (check and integrate) is in progress. A sealed author result is merged into the job's integration target as a candidate. The candidate is tested and reviewed by another provider, then approved by the user and published with a journaled compare-and-swap. It can be delivered as a new branch or reverted through the same chain. A task moves together with its candidate. See `docs/adr/0004-integration-und-freigabe.md`.

Package F (plan and scheduling) is in progress. A job's tasks form a validated plan (a DAG with write areas, criteria and difficulty), kept as immutable revisions. A scheduler starts ready tasks in critical-path order within slot, write-area, consent, quota and budget limits, and picks a model tier with repair and escalation rules. Without a live-verified provider, only an explicit user start runs. See `docs/adr/0005-plan-scheduler-routing.md`.

Package G (memory and sources) is in progress. Confirmed task, project and global notes with provenance (user, Git blob, test, review, derived) are searchable with SQLite FTS5. An agent gets only excerpts granted for its project, task and provider (and the planned reviewer), selected deterministically and sent in one handover transaction with the attempt start. Forgetting removes every local copy, including derived notes, the content of attempts that received it and old app backups. See `docs/adr/0006-memory-und-quellen.md`.

Package H (workspace and beta) is in progress. The native app (`KAIORX.xcodeproj`, SwiftUI and AppKit) shows projects, jobs and tasks, a filtered monitor with a bounded timeline, candidate review with per-file diffs against the first parent, and decision sheets that name the action, its scope and what a rejection means. Approvals bind to the commit shown and expire. The app also has an editor that writes only to your own checkout and only on Save, a PTY terminal (SwiftTerm) with a filtered environment, onboarding with local checks, and restore of migration backups protected by a purge ledger. The UI-independent logic lives in the `Workbench` target. A signed, notarized beta needs the owner's Developer ID (`scripts/release.sh`, `docs/beta-checklist.md`). See `docs/adr/0007-arbeitsoberflaeche-und-beta.md`.

Package A (live acceptance) has an owner-only kit, `kaiorx-acceptance`. The account owner runs it by hand in Terminal.app to check one provider version live: binary identity, subscription-only login, billing, read and write tasks on synthetic data, isolation probes, cancellation and revocation. It writes a report with redacted recordings, plus a proposed matrix change that the owner reviews and commits. It never runs from tests, CI or an agent. See `docs/live-acceptance/README.md` and `docs/adr/0008-live-abnahme-durch-den-kontoinhaber.md`.

## Build and test

```sh
scripts/test.sh                                      # package tests
swift run --package-path Packages/KAIORXKit kaiorx-dev --help
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project KAIORX.xcodeproj -scheme KAIORX -skipPackagePluginValidation build   # the app
xcodebuild -project KAIORX.xcodeproj -scheme KAIORX -skipPackagePluginValidation test    # UI tests
```

`scripts/test.sh` works with the Command Line Tools alone. The app and its UI tests need Xcode. UI tests run on a temporary database and Git repository with fake providers only. `-skipPackagePluginValidation` allows SwiftTerm's build-info plugin on the command line; Xcode asks once in the GUI.

## Repository

| Path | Content |
|---|---|
| `Packages/KAIORXKit/` | Swift package: Domain, Storage, Memory, Providers, ProcessHost, Workspace, Orchestration, Workbench, `kaiorx-dev` |
| `KAIORX.xcodeproj`, `App/` | The macOS app (SwiftUI/AppKit, SwiftTerm pinned to 1.99.3) |
| `Tests/UITests/` | XCUITests of the app |
| `App/Assets.xcassets`, `Design/branding/` | App icon ("Constellation K") and its source artwork (SVG, 1024 px) |
| `docs/live-acceptance/` | Owner guide for the live acceptance; committed reports and recordings |
| `scripts/release.sh`, `docs/beta-checklist.md` | Owner-run signing, notarization and the manual beta checks |
| `docs/adr/` | Architecture decisions that change the plan (German) |
| `scripts/test.sh` | Package test runner |
| `CLAUDE.md` | Project context and rule index for Claude Code |
| `.claude/rules/` | Model escalation rules, loaded automatically by Claude Code |
| `.claude/agents/` | Subagents `scout` (L1, read-only) and `escalation-reviewer` (L3) |
| `.claude/README.md` | Model escalation documentation: configuration, limits, test matrix (German) |

## Developing with Claude Code

Work on this repo uses three model tiers:

- **L1:** `scout` does broad, read-only lookups.
- **L2:** The main session keeps each task from start to finish.
- **L3:** `escalation-reviewer` answers single hard questions, but only when the escalation policy allows it.

The models for L1 and L3 are set in the agents' frontmatter. You choose the session model with `/model`. See [.claude/README.md](.claude/README.md) for details.
