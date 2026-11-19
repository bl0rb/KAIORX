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

Package D (provider adapters) is in progress offline. Adapters exist for Claude Code (headless `stream-json`) and the Codex App Server (stdio JSON-RPC). They are tested against fixture programs, and the Codex messages are checked against the protocol schema of the installed version. Automatic runs stay blocked until the live, user-authorized subscription runs of package A pass. See `docs/adr/0003-anbieteradapter-offline.md`. The Xcode app is not set up yet; until then, `kaiorx-dev` is a development CLI.

Package E (check and integrate) is in progress. A sealed author result is merged into the job's integration target as a candidate. The candidate is tested and reviewed by another provider, then approved by the user and published with a journaled compare-and-swap. It can be delivered as a new branch or reverted through the same chain. A task moves together with its candidate. See `docs/adr/0004-integration-und-freigabe.md`.

## Build and test

```sh
scripts/test.sh                                      # all tests
swift run --package-path Packages/KAIORXKit kaiorx-dev --help
```

With only the Command Line Tools installed (no Xcode), `scripts/test.sh` passes the Swift Testing macro plugin path explicitly. With Xcode, `swift test --package-path Packages/KAIORXKit` works directly.

## Repository

| Path | Content |
|---|---|
| `Packages/KAIORXKit/` | Swift package: Domain, Storage, Providers, ProcessHost, Workspace, Orchestration, `kaiorx-dev` |
| `docs/adr/` | Architecture decisions that change the plan (German) |
| `scripts/test.sh` | Test runner |
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
