# Explicit batch verification pilot

`python3 scripts/verify-project.py` operates a durable local queue in `.build/verification`.
It never claims the shared dirty working tree as one task's changes. Submit an explicit
Git patch and base commit. The patch must include each relevant added file. Never put
credentials or private app state in a patch.

A task manifest is a JSON object:

```json
{
  "id": "queue-check-1",
  "title": "Verify queue change",
  "base": "HEAD",
  "patch": "/absolute/path/task.patch",
  "checks": [{"kind": "native-tests", "filters": ["QueueTests"]}],
  "needs_live": true,
  "restrictions": {},
  "dependencies": []
}
```

Run commands from the repository:

```sh
python3 scripts/verify-project.py submit /absolute/path/task.json
python3 scripts/verify-project.py status
python3 scripts/verify-project.py plan
python3 scripts/verify-project.py run --drain
python3 scripts/verify-project.py cancel queue-check-1
python3 scripts/verify-project.py recover
```

`plan` persists a compatible batch. `run` executes one planned or newly planned batch.
Task IDs bind immutable inputs. Use a new ID after changing a patch. Submission copies
and validates the explicit patch and resolves the base to a commit. Compatible tasks
can share a combined snapshot and one build. Conflicting patches fail before commands
run. The queue's executor lock serializes the persistent checkout. A waiting guard holds
the lease until the check command finishes, including after coordinator exit. The
command and its persistent helpers do not inherit the lease. If the guard itself
is forcibly killed, this protection no longer applies. Native scripts
still acquire the existing global build lock; the CLI never acquires that lock itself.
It checks host load and active heavy jobs before every check. A busy host leaves admission planned without consuming an attempt; it does not launch
a background retry. Capacity loss after completed checks blocks the batch rather than
replaying its build. A later explicit run can admit still-planned work.

Supported checks are `build`, `native-tests`, `web-build`, `web-tests`, and `verification-tests`. Native tests
require explicit test filters or a recorded `scope_reason` for build/toolchain/broad
cross-module changes, and imply a preceding build. Web tests require explicit
`src/...test.ts(x)` or `src/...spec.ts(x)` paths. Shell commands in task data are not
supported. No dependency installer runs automatically. Web checks require separately
authorized dependency preparation in the verification checkout. Restrictions support boolean `allow_tests` and `allow_publish`; prohibited operations
are blocked, and unknown policies are rejected. Dependencies name submitted task IDs.
The CLI preserves their ordered ancestor patches when constructing dependent snapshots.

Each check has a unique `.build/verification/logs/` output log and JSON sidecar with
snapshot identity, exact command, input file hashes, tool versions and executable
paths, elapsed time and exit status. Native test output is copied from `test-last.log`
to a unique companion log. `status.json` is an atomic, versioned UI projection; the
SQLite queue is authoritative. Interrupted execution becomes `interrupted`, not a
passing result. `recover` does not repeat commands. Do not retry uncertain external
actions after a transport failure.

Each successful native build archives its signed bundle under the batch directory,
with its verified tree, executable SHA-256, and digest of all bundle resources and modes. Later batches cannot overwrite that
archive. Exact machine-check cache reuse includes tree, toolchain, scripts and check
scope. A flaky native result is flagged and does not become a cached pass.

A task with `needs_live` remains `awaiting_live`. The explicit lifecycle is:

```sh
python3 scripts/verify-project.py install BATCH_ID
python3 scripts/verify-project.py confirm-live BATCH_ID /absolute/path/evidence.json
python3 scripts/verify-project.py publish BATCH_ID /absolute/path/messages.json --expected-remote-base FULL_COMMIT
python3 scripts/verify-project.py reconcile BATCH_ID
```

`install` validates the archived signature and executable identity, takes the existing
global build lock without nesting a build, stages the bundle, and preserves the replaced
bundle in `build/.replaced` for the old running process. It writes durable install and
restart intent before acting. It requests a restart exactly once, then returns
`waiting_for_restart`. An existing attempt blocks repetition, including after uncertain
transport delivery. Installation does not mark live behavior verified.

After restart, `confirm-live` requires JSON evidence with `snapshot_digest`,
`executable_sha256`, `running_executable` (absolute path), `pid`, `verified_by`, and
`checks` (concrete observed behavior). It verifies exact archived identity, matching
running executable and process start after the build. The verifier remains responsible
for the actual UI/behavior observations. Evidence is saved under the batch directory.

`publish` requires verified tasks, allowed publication policy and recorded live evidence
when requested. The commit-message JSON maps task IDs to English commit messages. It
creates per-task commits with the exact final verified tree, then pushes with an exact
remote-base lease. It never stages unrelated dirty files or changes the source branch.
The local branch intentionally stays unchanged and may require a later deliberate sync.
An exclusive durable publication attempt prevents blind push retries. `reconcile` reads
the remote tip after an uncertain outcome without repeating the push. Existing permissions
and project restart rules still apply.

Cheap policy checks: `python3 scripts/test-verify-project.py`. Snapshot and queue tests
are separate Python checks. These checks do not build or launch the app.

## Bootstrap of the coordinator

The first coordinator change is validated with the existing repository build workflow,
then affected/full checks as required, and one app restart. This bootstrap uses the
current authorized source tree so that an older HEAD-only patch snapshot cannot replace
other pending live app changes. The queue itself is exercised with lightweight fixture
repositories before it owns a real app verification. This exception is limited to the
coordinator's bootstrap; later queue tasks still require explicit patch ownership.

For coordinator Python changes, request `verification-tests` in the task manifest:

```json
{"kind": "verification-tests", "filters": []}
```

This fixed check runs `python3 -B scripts/test-verification.py`, which invokes only the
four lightweight queue, snapshot, CLI policy and integration suites. It accepts no
arbitrary test paths and does not recurse into itself. Native checks remain separate.
The `allow_tests: false` restriction also blocks this check.

## Delivery scope

The Python CLI and its tests work independently of the optional native status view.
This CLI delivery does not install or publish pending native UI changes. Queue
state and build artifacts remain local and must not be committed.
