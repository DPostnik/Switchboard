# Project verification profiles

These are entry points verified from repository files on 2026-11-09, not permission grants or proof that a command passed. Resolve the current project root from the chat, read its current instructions, and run commands there. Profiles do not authorize access to another project's sources.

## Switchboard - pilot

- Repository name: `codex-headroom-client`; bundle: `build/Switchboard.app`; executable: `Contents/MacOS/Switchboard`.
- Build: `zsh scripts/build-app.sh`. Required for app changes; run before the final verification/tests under the current project instructions.
- Tests: `zsh scripts/test.sh --changed`; targeted alternatives use repeatable `--filter Name`. For committed changes use `--base REV`. Use the full suite only for build/toolchain or broad cross-module changes.
- Existing coordinator: `scripts/swift-task.py` owns `~/Library/Caches/Switchboard/build.lock` behind both scripts. Do not wrap them in another acquisition of that lock.
- Test evidence: `.build/local-build/test-last.log`. Neither test nor build output may be piped to `head`/`tail` in a way that hides its exit code. Prefer the scripts' compact output over constructing shell wrappers.
- Identity: `build/Switchboard.app/Contents/Resources/build-info.json` includes build time, compiler, SDK, source fingerprint, version, commit, build count and dirty flag. Use it with the actual running process/bundle identity. Read-only diagnostics may report a subset; inspect only additional permitted data when needed.
- Running verification: after successful build and relevant tests, run `zsh scripts/request-app-restart.sh` exactly once when needed. End the turn waiting for the app's restart continuation. Do not retry an unacknowledged request. After continuation, verify process identity/freshness and the changed behavior before committing/pushing. If the build fails, report that the installed bundle is still the previous build and do not request a restart.
- Task record: update the existing task entry in `docs/improvements.md` with actual build/check results. User-visible changes also require an English `CHANGELOG.md` Unreleased entry and paired Russian/English app copy.

## Fringe - reference profile, runtime adoption pending

- Repository name: `fringe`; bundle: `build/Fringe.app`.
- Current project order: tests, then app build. Tests: `zsh scripts/test.sh`, or targeted Swift filters where suitable; build: `zsh scripts/build-app.sh`.
- `scripts/test.sh` runs both app tests and `Packages/FringeProtocol` tests; inspect the script before assuming a filter selects valid tests in both packages.
- The inspected test entry point calls Swift directly. Do not claim that it takes Switchboard's shared lock. Resolve heavy-job coordination under the current project rules before execution.
- Read the actual build metadata and current restart instructions; no generic restart or fingerprint is assumed here. Record actual results in `docs/improvements.md`.

## Prompter - reference profile, runtime adoption pending

- Repository name: `prompter`; build entry: `zsh build-prompter.sh`; bundle: `Prompter.app`; executable: `Contents/MacOS/Prompter`.
- The build script compiles Swift sources and signs the app. Its inspected plist has a fixed build number, so that number does not identify changed sources.
- Read current `AGENTS.md` and `SOLUTION.md`. Choose relevant existing tests from `tests/` for affected Python behavior; do not invent a universal affected-test command.
- Evaluations can call paid/live providers. Read their configuration and task authorization before using them; a Python unit test result does not verify the Swift overlay.
- No shared lock, restart protocol or source fingerprint is asserted by this profile. Establish the applicable coordination and running identity check before claiming adoption.
- Preserve Prompter's publication policy: its project instructions prohibit committing/publishing without a request. This flow does not inherit Switchboard's standing push authorization.
