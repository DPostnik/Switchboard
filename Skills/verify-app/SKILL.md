---
name: verify-app
description: Verify an authorized application change with the project's existing build, affected tests and, when needed, running-app checks. Use after implementation or when asked to verify a build; read-only reviews do not require a build.
metadata:
  description-ru: Проверка изменений приложения существующей сборкой, затронутыми тестами и проверкой запущенной версии при необходимости.
  description-en: Verify application changes with existing builds, affected tests and running-version checks when needed.
---

# Verify an application change

This flow organizes existing checks. It grants no execution, filesystem, restart, publication or scheduling permissions. Project instructions and current user constraints determine the required checks and their order.

1. **Select evidence.** Read the current project instructions and inspect the task's changes, including uncommitted changes from other chats. Use the matching section of [references/projects.md](references/projects.md) for known entry points; verify those files still exist. Choose the cheapest checks that prove the changed behavior. Distinguish task changes from unrelated work rather than reverting or committing it.
2. **Use the project queue when available.** For Switchboard, use `python3 scripts/verify-project.py` and `scripts/verification-README.md`. Submit an explicit reviewed patch and task manifest; never capture the entire dirty workspace as task ownership. Dependencies and user restrictions belong in the manifest. Join existing work through the queue instead of starting another build. Preserve required live verification and publication gates. If the queue cannot represent a task, report that precise limitation; do not silently bypass it.
3. **Check capacity.** Prefer `project_diagnostics` with `operation: "load"`, `"heavy_tasks"` or `"app"` for load, active heavy tasks and current-project application identity. It takes no command, path or other project argument. If unavailable, use the project's existing permitted diagnostic commands. Do not bypass a denied tool with another execution channel. Classify each build/test/probe as heavy; obey the shared Mac limits and wait when capacity is unavailable. Load and process lists are snapshots, not reservations.
4. **Use one lock owner.** Reuse the project's existing build/test script and its lock. Never acquire the same shared lock around a script that already acquires it. If the project has no lock, follow its existing coordination policy and report that limitation; do not silently install a global executor.
5. **Run the selected checks.** Batch source edits before compiling and build the app once at the end of the implementation. Follow the project's required build/test order. Prefer changed or targeted tests; use a full suite only when required by the scope. Keep the real exit code, save logs using existing script facilities, and read the failure log before any rerun. After a fix, rerun affected failures and any checks invalidated by the fix. A test that passed only on retry must be reported as such.
6. **Associate the result.** Record the checked revision, local changes, relevant source fingerprint when available, exact checks, outcomes and log locations in the project's established task record. Check for source changes during verification. If inputs changed, identify which results became stale and repeat only the affected work. A clean commit ID alone cannot identify a dirty build. An after-build fingerprint alone does not prove inputs stayed unchanged during compilation.
7. **Verify the running app when required.** Only restart when the changed behavior needs the running app and the project's restart policy authorizes it. For Switchboard follow the one-request idle restart protocol in the profile. Match the running process to the expected bundle and build identity, then check the actual changed behavior. Process start time alone is not a behavior test. State a remaining manual check as unverified.
8. **Finish with the evidence.** Report what changed, checks passed/failed, tested build identity and remaining blockers. Commit/push only under applicable project authorization after its required verification passes. CLI upgrades, releases and deployment are separate workflows; this flow does not invoke them.

## Missing project support

For an unknown project, derive a small profile from its actual instructions and scripts. Do not infer that a test filter, restart command, bundle identity or shared lock exists. If permissions block a required check, complete independent checks and report that exact blocker. Never report edited sources as an updated installed application.

## Pilot measurement

Use the capability ledger and available task records to compare equivalent completed tasks: user approval requests per task, repeated builds/tests, waiting time and verification failures. Count successful runs as well as requests; separate audit decisions. Mark missing denominators or latency data as unavailable. Do not schedule a future review or launch extra builds solely to improve the measurement. Extend the pilot when there are too few comparable tasks.
