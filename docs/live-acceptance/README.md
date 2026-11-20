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
3. **Apply the patch yourself** and commit it together with the report:

   ```sh
   git apply docs/live-acceptance/<run>/matrix.patch
   ```

   A test checks every `liveVerified` entry against its committed report.

## What to expect

With the current isolation, agents can still read your home folder; only the credential folders are hidden. The isolation step therefore reports a failure, and automation stays locked.

The extra read with your home folder hidden shows whether the CLIs work under the stricter protection. That result decides the next step.
