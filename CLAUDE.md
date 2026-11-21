# CLAUDE.md

KAIORX: native macOS-App (Swift 6, macOS 15+), die Claude Code und OpenAI
Codex in getrennten Git-Worktrees orchestriert. Lokale Planungsunterlagen
(nicht versioniert) liegen in `Plan/`, Einstieg `Plan/ARCHITEKTURPLAN.md`.
Verbindlich für Code: `Plan/laufzeitvertrag.md` (Zustände, Schema, Ereignisse).
Abweichungen vom Plan brauchen ein ADR in `docs/adr/`.

## Build and test

- Code lives in `Packages/KAIORXKit` (Swift 6 language mode, macOS 15).
- Run tests with `scripts/test.sh` (Swift Testing; works with Command Line Tools only).
- Dev CLI: `swift run --package-path Packages/KAIORXKit kaiorx-dev --db <tmp path> …`.
  Without `--db` it writes to the real Application Support database.
- Applied migrations in `CoreSchema` are never edited; schema changes are new migrations.
- The app is `KAIORX.xcodeproj` (`App/`, UI tests in `Tests/UITests`); UI-independent logic goes
  into the `Workbench` target. Xcode 27.2 is at `/Applications/Xcode.app` but `xcode-select` points
  to the Command Line Tools: build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  and `-skipPackagePluginValidation`. UI tests use `-KAIORXUITest` (temp DB/repo, fake providers).
- The editor saves only into the user's checkout on explicit Save (ADR 0007); everything else
  stays read-only. The user terminal runs via `ProcessHost.launchTerminal` with its own env list.
- Child processes only through `ProcessHost` (absolute executable, explicit environment);
  Git only through `GitRunner` and Git side effects only through `WorkspaceService`
  (journal first). Never run Git or tools in the user's checkout in a way that writes there.
- Confinement relies on `sandbox-exec` (ADR 0002); keep `Confinement.probe` and the
  isolation tests green.
- Provider adapters (ADR 0003): never mark a version `liveVerified` in `CompatibilityMatrix`
  without a passed live run by the account owner. A new Codex version needs a regenerated
  schema in `Tests/ProvidersTests/Fixtures/` and passing contract tests. Do not run the real
  `claude`/`codex` binaries for inference or log-in from code or tests.
- `kaiorx-acceptance` (ADR 0008) is the owner's live acceptance kit: never run it (it refuses agent
  contexts anyway), never set `liveVerified` by hand; only an owner-exported report with its
  `matrix.patch` does that, checked by the evidence test.

## Model escalation

Three model tiers. Decisions are made per task, not per message: a task stays
with the main agent (L2), single steps may go to L1 and single hard questions
to L3. The rules load automatically from `.claude/rules/`; each topic has
exactly one owner file:

| Topic | File |
|---|---|
| Tiers, model mapping, when to delegate | `.claude/rules/model-routing.md` |
| Task affinity, follow-ups, topic changes | `.claude/rules/context-continuity.md` |
| Escalation triggers, value check, fallback | `.claude/rules/escalation-policy.md` |
| Handover and return format | `.claude/rules/context-handover.md` |

Agents: `scout` (L1), `escalation-reviewer` (L3) in `.claude/agents/`.
Configuration, technical limits and test matrix: `.claude/README.md` (not auto-loaded).
