# KAIORX
KAIORX is a native macOS AI development environment that orchestrates multiple coding agents, including Claude Code and OpenAI Codex, with intelligent model escalation, parallel workflows, and persistent project memory.

## Status

Planning phase. The app is planned in Swift 6 for macOS 15+ on Apple silicon. There is no application code yet.

## Repository

| Path | Content |
|---|---|
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
