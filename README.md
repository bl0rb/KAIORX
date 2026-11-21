# KAIORX
KAIORX is a native macOS AI development environment that orchestrates multiple coding agents, including Claude Code and OpenAI Codex, with intelligent model escalation, parallel workflows, and persistent project memory.

## Status

Beta in preparation. Swift 6, macOS 15+ on Apple silicon. Packages A to H of the plan are implemented in `Packages/KAIORXKit` and the app; what remains are the owner's manual beta checks (see below).

**Live-verified providers** (automatic runs allowed only for exactly these builds):

| Provider | Version | Mode | Evidence |
|---|---|---|---|
| Claude Code | 2.1.329 | subscription login | `docs/live-acceptance/20261120-1429-a265/` |
| Codex | 0.170.0 | CLI-managed ChatGPT login | `docs/live-acceptance/20261120-1429-a265/` |

Any other version or build stays manual until it passes its own live acceptance.

What the packages deliver:

- **B, local core:** typed domain, single-writer SQLite store with migrations, an event journal and restart recovery, a deterministic fake adapter, the run coordinator.
- **C, workspace and safe runner:** child processes in their own process group with an explicit environment, bounded output and stop/drain; macOS sandbox confinement (ADR 0002); host Git with sanitized settings and a locked worktree per attempt outside your checkout.
- **D, provider adapters:** Claude Code (headless `stream-json`) and the Codex App Server (stdio JSON-RPC), contract-tested against fixtures and the installed protocol schema. Provider CLIs run in the `agentCLI` role with your home folder hidden except their install folder, their own state folder and the worktree (ADR 0003, ADR 0008).
- **E, check and integrate:** a sealed author result becomes a candidate that another provider reviews; you approve it and it is published with a journaled compare-and-swap, delivered as a branch or reverted the same way (ADR 0004).
- **F, plan and scheduling:** plans as validated DAGs with write areas, kept as immutable revisions; a scheduler that respects slots, write areas, consent, quota and budgets (ADR 0005).
- **G, memory and sources:** task, project and global notes with provenance, searchable with SQLite FTS5; agents get only the excerpts granted for their project, task and provider; forgetting removes every local copy (ADR 0006).
- **H, workspace and beta:** the native app (`KAIORX.xcodeproj`, SwiftUI/AppKit) with projects, jobs, a filtered monitor, candidate review with per-file diffs, decision sheets, an editor that writes only on Save, a PTY terminal, onboarding and backup restore (ADR 0007).
- **A, live acceptance:** the owner-only kit `kaiorx-acceptance` checks one provider version live and proposes the matrix change that the owner commits (`docs/live-acceptance/README.md`, ADR 0008).

Still open before the beta:

- **End-to-end run in the app** with the real Claude Code and Codex (plan, author, review, approval, publication). So far the providers were checked live only through the acceptance kit.
- **Owner's beta checks** in `docs/beta-checklist.md`: signing and notarization with a Developer ID, a clean Mac, macOS 15, offline first launch, VoiceOver and keyboard, quitting during a run, the untouched checkout, contrast and Dark Mode, restore.
- **Optional live checks of package A:** second-account detection, Claude quota signals, login expiry and token refresh, Codex SIWC login.
- **Performance:** FTS at 10,000 chunks meets its target with little headroom; the reference Mac is still to be chosen.

## Build and test

```sh
scripts/test.sh                                      # package tests
swift run --package-path Packages/KAIORXKit kaiorx-dev --help
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project KAIORX.xcodeproj -scheme KAIORX -skipPackagePluginValidation build   # the app
xcodebuild -project KAIORX.xcodeproj -scheme KAIORX -skipPackagePluginValidation test    # UI tests
```

`scripts/test.sh` works with the Command Line Tools alone. The app and its UI tests need Xcode. UI tests run on a temporary database and Git repository with fake providers only. `-skipPackagePluginValidation` allows SwiftTerm's build-info plugin on the command line; Xcode asks once in the GUI.

## Performance

`kaiorx-bench` measures the beta targets of the plan on synthetic data in a temporary folder, with paced fake providers (never a real CLI, never the app's database):

```sh
swift run -c release --package-path Packages/KAIORXKit kaiorx-bench --full --out <folder>   # several minutes
swift run --package-path Packages/KAIORXKit kaiorx-bench                                     # quick harness check
```

Baseline on an M4 MacBook Air (16 GB, release build): [docs/performance/2026-11-20-mac16-12.md](docs/performance/2026-11-20-mac16-12.md).

| Target (plan) | Measured p95 | Result |
|---|---|---|
| FTS query at 10,000 active chunks < 200 ms | 185 ms (provider path with grants), 111 ms (owner view) | met, little headroom |
| FTS load test at 50,000 chunks | 1,254 ms (provider path) | no target; grows with the corpus |
| UI event < 250 ms after local receipt, two runs | 107 ms to the app state, 99 ms to the monitor timeline | met |
| Replay of the last view without reading every delta | workspace view reads no events; the monitor opens a run on its newest 1,000 of 50,004 events (5 ms, release, 2026-11-21; the full history takes 222 ms for comparison), older pages on request | met |
| Stop and approval usable with two active runs | Stop shown after 48 ms, approve + publish 122 ms | met (250 ms assumed; the plan names no number) |

Not covered: memory pressure, a cold OS file cache, time to the first model token, SwiftUI rendering. The reference Mac for the beta is still to be chosen.

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
| `Packages/KAIORXKit/Sources/Bench/`, `docs/performance/` | Performance harness `kaiorx-bench` and measured baselines |
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
