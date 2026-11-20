# Beta checklist (owner, manual)

These checks need the account owner, a Developer ID certificate, or a second Mac. They cannot run on the development machine, so nothing here is marked as done until the owner records the result.

1. **Sign and notarize:** run `scripts/release.sh "Developer ID Application: <Name> (<Team>)"` with a stored `notarytool` profile. It must end with `spctl` accepting the app.
2. **Clean Mac:** copy `build/release/KAIORX-notarized.zip` to a Mac that never had KAIORX or Xcode, unzip it and open it by double-click. Gatekeeper must not warn.
3. **macOS 15:** start the app on macOS 15 (the oldest supported version) and open a project.
4. **First launch offline:** turn Wi-Fi off before the first launch. Onboarding, opening a project, diffs and history must work; starting a run waits.
5. **VoiceOver and Full Keyboard Access:** do the main path by keyboard only, with VoiceOver on:
   1. open a project;
   2. create a job;
   3. consent;
   4. start;
   5. cancel with ⌘.;
   6. review;
   7. reject or approve.

   Check that status changes are announced once, bundled.
6. **Quit during a run:** quit while a run is active, then restart. The attempt shows as "Ungeklärt" and does not start twice.
7. **Your checkout stays untouched:** with uncommitted work in the checkout, run a job to publication. `git status` and `HEAD` of the checkout must be byte-identical before and after.
8. **Display:** check with Increase Contrast and in Dark Mode.
9. **Restore:** in Settings, mark a migration backup for restore and restart. Consents must be revoked. A backup older than a forget must be refused.
10. **Live provider runs (package A):** before any version is marked `liveVerified`, do one small, owner-authorized run per provider.
