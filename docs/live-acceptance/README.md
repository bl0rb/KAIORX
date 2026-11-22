# Live acceptance (owner only)

These steps unlock automatic runs for a provider version. Only the account owner may do them, by hand, on their own Mac. Claude Code, Codex, scripts and CI never run them (CLAUDE.md, ADR 0008).

## Before you start

1. **Open Terminal.app yourself.** The kit refuses to run from the KAIORX terminal, from Claude Code, from Codex or from any script.
2. **Build the kit:**

   ```sh
   swift build --package-path Packages/KAIORXKit --product kaiorx-acceptance
   ```

3. **Run the preflight:**

   ```sh
   Packages/KAIORXKit/.build/debug/kaiorx-acceptance preflight
   ```

   It shows the binaries, their versions and the OS isolation. It makes no model calls.
4. **Sign in** with the commands the preflight prints. They use KAIORX's own configuration folders, not `~/.claude` or `~/.codex`.
5. **Turn off usage credits at the provider:**
   - Claude: usage credits.
   - ChatGPT: credit use for other apps, or set an app limit below 100 %.

## Run

```sh
Packages/KAIORXKit/.build/debug/kaiorx-acceptance run both --model <claude-model> --codex-model <codex-model>
```

- **Touch ID:** the kit asks for Touch ID or your password once.
- **Steps that use your quota:** before each one, the kit shows the exact task and asks you to type a phrase. The task is a harmless read or write on synthetic data in `~/Library/Application Support/KAIORX/acceptance/<run>`.
- **Revocation:** when asked, sign out of KAIORX's folder or revoke access at the provider, then continue:

  ```sh
  Packages/KAIORXKit/.build/debug/kaiorx-acceptance resume <run>
  ```

  Sign in again afterwards.
- **Second account:** this step is optional. Type `überspringen` to skip it.

## Afterwards

1. **Read the report:** `report.md` in the run folder. It lists every step, what was observed and what remains open.
2. **Export it:**

   ```sh
   Packages/KAIORXKit/.build/debug/kaiorx-acceptance export <run> --to docs/live-acceptance
   ```

   This copies the report, the redacted recordings and, only if the run passed, `matrix.patch`. Review the copied fixtures before committing them.
3. **Review the patch.** It changes up to two files:
   - `Compatibility.swift`: the matrix entry becomes `liveVerified` with the build and the report. A version that is already `liveVerified` with the same build keeps its entry; the patch then changes only the profiles (the kit says so).
   - `VerifiedModelProfiles.swift`: the model the run used, as author and reviewer, with tier `standard` (ADR 0012). A rerun of the same model and version replaces its entry and keeps the tier; another model of the same version is added beside the existing one. The tier is a product setting: you may change it in the patch before committing, and you must when the kit notes that another model of the version exists (one model per version, role and tier; for example `intensive` for a stronger model). Leave the other fields as proposed.
4. **Apply the patch yourself** and commit it together with the report:

   ```sh
   git apply docs/live-acceptance/<run>/matrix.patch
   ```

   A test checks every `liveVerified` entry and every model profile against its committed report.
5. **Restart KAIORX.** The app registers the model profiles at start.

## What to expect

- **Home folder hidden:** every task runs with your home folder hidden. Only the CLI's install folder, KAIORX's configuration folder for it, the working folder and, for Claude, the keychain stay readable. The isolation step fails if the agent can read your home folder.
- **No separate hidden-home turn:** the hidden-home step refers to the read task, which already runs with home hidden. It needs no quota of its own.
- **Recordings:** if the kit discards a recording, the report names the kind of private value and where it was found, never the value itself. The report itself is all a passed acceptance needs.
- **Before committing:** read the exported fixtures. They should contain only placeholders such as `<home>`, `<email-1>` or `<request-id>`, no names, paths, email addresses or request IDs.
